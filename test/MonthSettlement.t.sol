// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {MarketPriceFeed} from "../src/MarketPriceFeed.sol";
import {Fixture} from "./utils/Fixture.sol";
import {TapeBoard} from "../src/TapeBoard.sol";
import {MonthBoard} from "../src/MonthBoard.sol";
import {MonthMachineSales} from "../src/month/MonthMachineSales.sol";
import {MonthState} from "../src/interfaces/IMonthBoard.sol";

/// @notice 月局收回本金（v2）：交接（运营地址专属，在接手方的收购拍卖里按它的收购价成交且不低于成本价，预算不够
///         只接一部分）、挂单（经 MonthMachineSales，≥ 成本价，可以随时改价；1 天未挂按成本价可买）、卖不出继续挖、
///         回馈资本滚入下一块月局、自动发放与自领不重复、资金守恒
contract MonthSettlementTest is Fixture {
    MonthBoard internal m; // 第 1 块月局：会进入结算
    address[] internal players;
    address internal buyer = address(0xB0B);
    address internal minter = address(0xA11CE);
    uint256 internal saleProceeds;
    uint256 internal relayProceeds;
    mapping(address => uint256) internal startBal;
    uint256 internal constant W0 = 30;
    uint256 internal constant W1 = 20;
    uint256 internal constant W2 = 40;

    function setUp() public override {
        super.setUp();
        _startGenesis();
        m = _monthBoard();
        bem.mint(buyer, 10_000 * BEM_1);
        vm.prank(buyer);
        bem.approve(address(sales), type(uint256).max);
    }

    /// @dev 第 1 块月局：招满（小数投入）→ 领回馈 → 收购 3 台矿机 → 挖 30 天 → 开奖 → 进入结算
    function _settle(bool withSubsidy) internal {
        uint256 i;
        while (m.state() == MonthState.Recruiting) {
            uint256 span = m.maxStake() - m.minStake();
            uint256 amt = m.minStake() + (uint256(keccak256(abi.encode("ms", i++))) % span) / 1e6 * 1e6;
            address u = _joinMonth(m, amt);
            players.push(u);
            startBal[u] = bem.balanceOf(u);
        }
        if (withSubsidy) {
            vm.deal(minter, 5 ether);
            vm.prank(minter);
            transistors.mint{value: 2_000 * 0.0011 ether}(0, 2_000);
            splitter.claimReward(1); // 月局是第 1 块开局的主板
            assertGt(m.subsidyCapital(), 0);
        }
        address seller = _newUser();
        _sellMonth(m, seller, W0);
        vm.warp(block.timestamp + 1 days);
        _sellMonth(m, seller, W1);
        _sellMonth(m, seller, W2);
        vm.warp(m.prepEnd());
        m.sync();
        pod.setRate(451_000); // 每单位权重每天 0.00451 BEM
        vm.warp(m.miningEnd());
        m.drawPrizes();
        rng.fulfill(m.pendingRequestId(), uint256(keccak256("month prizes")));
        m.finalizePrizes();
        assertEq(uint256(m.state()), uint256(MonthState.Settling));
        pod.setRate(0); // 之后的产出用 _yieldAll 手动注入，方便精确断言
    }

    /// @dev 一块正在准备矿机的新月局（之前那块招募已过期时先宣布失败、重开）
    function _freshPreparing() internal returns (MonthBoard r) {
        r = _monthBoard();
        if (block.timestamp >= r.recruitDeadline()) {
            r.closeRecruitment();
            r = _monthBoard();
        }
        _fillMonth(r);
        assertTrue(r.isPurchasing());
    }

    function _relay(uint256 index, MonthBoard to) internal {
        relayProceeds += _relayWhenPriced(m, index, to);
    }

    function _buy(uint256 index) internal {
        vm.prank(buyer);
        saleProceeds += sales.buyMachine(address(m), index, type(uint256).max);
    }

    // ---------------- 接力 ----------------

    function test_RelayAtReceiverBuyPrice() public {
        _settle(false);
        MonthBoard r = _freshPreparing();
        uint256 cost = m.machine(0).cost;
        uint256 principalBefore = m.principalRemaining();
        uint256 budgetBefore = r.budget();
        uint256 feeSafeBefore = bem.balanceOf(FEE_SAFE);
        // 收购价还低于成本价：成交失败，NFT 不动
        if (r.buyPrice() * m.machine(0).weight < cost) {
            vm.expectRevert(MonthBoard.PriceBelowMinimum.selector);
            sales.relay(address(m), 0, address(r));
            assertFalse(m.machine(0).sold);
        }
        uint256 paid = _relayWhenPriced(m, 0, r);
        assertGe(paid, cost, "never below cost");
        assertEq(paid, r.buyPrice() * m.machine(0).weight, "at the receiver's current buy price");
        assertEq(machines.ownerOf(m.machine(0).circuitId), address(r));
        assertTrue(m.machine(0).sold);
        assertEq(r.machine(0).cost, paid, "receiver cost basis = price paid");
        assertEq(r.budget(), budgetBefore - paid);
        // 溢价分成（规则决定 6.24）：超过成本价的部分 10% 给手续费地址，其余照旧先退本金
        uint256 fee = (paid - cost) * m.PREMIUM_FEE_BPS() / 10_000;
        assertEq(m.PREMIUM_FEE_BPS(), 1_000);
        assertEq(bem.balanceOf(FEE_SAFE) - feeSafeBefore, fee, "10% of the premium to the fee safe");
        assertEq(m.principalRemaining(), principalBefore - (paid - fee), "relay proceeds refund principal");
    }

    function test_RelayIsOperatorOnlyWithParticipantFallback() public {
        _settle(false);
        MonthBoard r = _freshPreparing();
        vm.prank(players[0]);
        vm.expectRevert(MonthMachineSales.NotAuthorized.selector);
        sales.relay(address(m), 0, address(r));
        vm.warp(m.settleStart() + 3 days);
        r = _freshPreparing();
        while (r.buyPrice() * m.machine(0).weight < m.machine(0).cost) {
            vm.warp(block.timestamp + 6 hours);
        }
        vm.prank(buyer); // 外人 3 天后仍然不行
        vm.expectRevert(MonthMachineSales.NotAuthorized.selector);
        sales.relay(address(m), 0, address(r));
        vm.prank(players[0]); // 本局持仓的持有人兜底
        sales.relay(address(m), 0, address(r));
        assertTrue(m.machine(0).sold);
    }

    function test_RelayRejectedWhenReceiverPriceBelowCost() public {
        _settle(false);
        // 全网算力暴增：接手方开局时快照的上限（365 天产出）跌到成本价以下，收购价涨到顶也不够
        pod.setTotalVerifWeight(pod.totalVerifWeight() * 4);
        MonthBoard r = _freshPreparing();
        vm.warp(block.timestamp + 60 hours);
        assertLt(m.machine(0).weight * r.buyPrice(), m.machine(0).cost);
        vm.expectRevert(MonthBoard.PriceBelowMinimum.selector);
        sales.relay(address(m), 0, address(r));
        assertEq(machines.ownerOf(m.machine(0).circuitId), address(m), "NFT stays");
    }

    /// @dev 外部审计 #3：月局的上限是开局（收购开始）时的快照，整个准备期内不随 PoD 的即时值变化
    function test_MonthCapIsSnapshotDuringPreparation() public {
        _settle(false);
        MonthBoard r = _freshPreparing();
        uint256 snap = r.buyPriceCap();
        assertGt(snap, 0);
        pod.setTotalVerifWeight(pod.totalVerifWeight() * 4); // 即时上限跌到 1/4
        assertEq(r.buyPriceCap(), snap);
        pod.setTotalVerifWeight(100_000); // 即时上限暴涨
        assertEq(r.buyPriceCap(), snap);
        _relay(0, r); // 按快照判断，成本价仍在上限以内
        assertTrue(m.machine(0).sold);
    }

    /// @dev 外部审计 #2：结算中哨兵触发，出售暂停；记录触发满 30 天后自动恢复（信标仍是升级后的）
    function test_SalesResumeThirtyDaysAfterTrip() public {
        _settle(false);
        vm.warp(m.settleStart() + 1 days); // 自动按成本价挂单
        uint256 cost = m.machine(0).cost;
        machineBeacon.upgradeTo(address(0xBAD));
        vm.prank(buyer);
        vm.expectRevert(MonthBoard.UpgradeSentinelTripped.selector);
        sales.buyMachine(address(m), 0, type(uint256).max);
        factory.noteSentinel();
        uint256 since = factory.sentinelSince();
        assertEq(since, block.timestamp);
        vm.warp(since + 30 days - 1);
        assertTrue(m.sentinelPaused());
        vm.prank(buyer);
        vm.expectRevert(MonthBoard.UpgradeSentinelTripped.selector);
        sales.buyMachine(address(m), 0, type(uint256).max);
        vm.warp(since + 30 days);
        assertTrue(m.sentinelTripped());
        assertFalse(m.sentinelPaused());
        _buy(0);
        assertEq(saleProceeds, cost);
    }

    function test_RelayOnlyWhatReceiverBudgetCovers() public {
        _settle(false);
        MonthBoard r = _freshPreparing();
        vm.warp(block.timestamp + 60 hours); // 接手方收购价到上限
        uint256 p1 = r.buyPrice() * m.machine(1).weight;
        uint256 p2 = r.buyPrice() * m.machine(2).weight;
        assertGe(p1, m.machine(1).cost);
        assertGe(p2, m.machine(2).cost);
        assertLt(p1, p2);
        // 先用拍卖买一台，让剩余预算介于两台待交接矿机的成交额之间
        (uint256 id,) = _newMachine(address(this), 10);
        uint256 w = (r.budget() - (p1 + p2) / 2) / r.buyPrice();
        pod.demote(pod.minerKey(address(machines), id), w);
        _traderSell(address(r), address(machines), id, address(this), w * r.buyPrice());
        assertGe(r.budget(), p1);
        assertLt(r.budget(), p2);
        vm.expectRevert(MonthBoard.InsufficientBudget.selector);
        sales.relay(address(m), 2, address(r)); // 40 权重的那台接不下
        _relay(1, r); // 20 权重的可以
        assertTrue(m.machine(1).sold);
        assertFalse(m.machine(2).sold);
    }

    function test_RelayOnlyBetweenMonthBoardsInPreparation() public {
        _settle(false);
        address standard = address(_board());
        vm.expectRevert(MonthBoard.NotMonthBoard.selector);
        sales.relay(address(m), 0, standard); // 标准局
        vm.expectRevert(MonthBoard.NotMonthBoard.selector);
        sales.relay(address(m), 0, address(m));
        MonthBoard r = _freshPreparing();
        vm.warp(r.prepEnd()); // 接手方准备期已过
        vm.expectRevert(MonthBoard.BuyRoundInactive.selector);
        sales.relay(address(m), 0, address(r));
        // 外人直接调用主板的交割 / 交接入口
        vm.expectRevert(MonthBoard.NotAuthorized.selector);
        m.relayOut(0, address(r));
        vm.expectRevert(MonthBoard.NotAuthorized.selector);
        m.releaseMachine(0, address(this), 1);
    }

    // ---------------- 卖价（第 8 阶段）：报价公式、整台 ≥ 成本价；过期暂停；停运 7 天按成本价 ----------------

    function test_FormulaPriceAtLeastCostAndOnlyOperatorPosts() public {
        _settle(false);
        uint256 cost = m.machine(0).cost;
        uint256 w = m.machine(0).weight;
        vm.prank(players[0]);
        vm.expectRevert(MarketPriceFeed.NotOperator.selector);
        priceFeed.post(1, 1);
        _postPrices(cost / w / 2, cost / w / 2); // 市价低于成本
        assertEq(sales.askPrice(address(m), 0), cost, "floored at cost");
        vm.warp(block.timestamp + 3 hours);
        uint256 unit = _unitFor(m, 0, 12_000);
        _postPrices(unit, unit);
        assertEq(sales.askPrice(address(m), 0), unit * w);
        vm.prank(buyer);
        vm.expectRevert(MonthMachineSales.PriceAboveMaximum.selector);
        sales.buyMachine(address(m), 0, cost);
    }

    function test_NoFeedSellsAtCostStaleFeedPausesAbandonedFeedSellsAtCost() public {
        _settle(false);
        uint256 cost = m.machine(1).cost;
        assertEq(sales.askPrice(address(m), 1), cost, "never posted: at cost");
        uint256 unit = _unitFor(m, 1, 15_000);
        _postPrices(unit, unit);
        assertEq(sales.askPrice(address(m), 1), unit * m.machine(1).weight);
        vm.warp(block.timestamp + 3 hours);
        assertEq(sales.askPrice(address(m), 1), 0, "stale: paused");
        vm.prank(buyer);
        vm.expectRevert(MonthMachineSales.NotForSale.selector);
        sales.buyMachine(address(m), 1, type(uint256).max);
        vm.warp(priceFeed.updatedAt() + 7 days);
        assertEq(sales.askPrice(address(m), 1), cost, "abandoned: at cost");
        _buy(1);
        assertEq(saleProceeds, cost);
    }

    /// @dev 卖价每小时按公式下调（卖一 × (99% − 0.5% × h)），降到买一后跟着买一，但整台不低于成本价
    function test_SellPriceFollowsFormulaHourly() public {
        _settle(false);
        uint256 cost = m.machine(0).cost;
        uint256 w = m.machine(0).weight;
        uint256 bid = _unitFor(m, 0, 11_000);
        uint256 ask = bid * 13 / 10;
        uint256 t0 = m.settleStart();
        _postPrices(bid, ask);
        uint256 n = (block.timestamp - t0) / 6 hours; // 规则决定 6.21：每 6 小时降 0.5%
        uint256 f = ask * (9_900 - 50 * n) / 10_000;
        assertEq(sales.askPrice(address(m), 0), (f > bid ? f : bid) * w);
        for (uint256 k = 0; k < 150; k++) {
            vm.warp(block.timestamp + 2 hours);
            _postPrices(bid, ask);
        }
        assertEq(sales.askPrice(address(m), 0), bid * w, "down to the bid");
        assertGe(sales.askPrice(address(m), 0), cost);
        // 主板交割也再查一次：没有清算计划时，卖矿合约以外的任何路径都不能低于成本价（这里直接冒充卖矿合约）
        vm.prank(address(sales));
        vm.expectRevert(MonthBoard.BelowCost.selector);
        m.releaseMachine(0, buyer, cost - 1);
    }

    /// @dev P-3 a：清算计划生效后，要价 = min(正常卖价, 计划价)；规则决定 6.33（审计 H-2）：计划价不低于买一 × 收购时权重 × 95%，
    ///      报价过期时计划价暂停
    function test_PlanPriceIsMinWithNormalNeverBelowMarketAndPausedWhenStale() public {
        _settle(false);
        uint256 cost = m.machine(0).cost;
        uint256 w = m.machine(0).weight;
        uint256 unit = _unitFor(m, 0, 15_000);
        _postPrices(unit, unit);
        uint256 normal = sales.askPrice(address(m), 0);
        uint256[] memory idx = new uint256[](1);
        uint128[] memory st = new uint128[](1);
        uint128[] memory fl = new uint128[](1);
        st[0] = uint128(cost * 12 / 10);
        fl[0] = uint128(cost / 2);
        vm.startPrank(address(governor)); // 冒充清算治理合约：计划生效
        m.startLiquidation();
        sales.installPlan(address(m), idx, st, fl);
        vm.stopPrank();
        // 市价（买一 × 95%）高于计划价：按市价的 95%，多数票不能低于市价甩卖
        uint256 market = unit * w * 9_500 / 10_000;
        assertGt(market, cost * 12 / 10);
        assertEq(sales.askPrice(address(m), 0), market, "plan never below 95% of the bid");
        assertGt(normal, market);
        vm.warp(block.timestamp + 3 hours); // 报价过期：正常卖价和计划价都暂停
        assertEq(sales.askPrice(address(m), 0), 0, "stale: paused");
        // 市场真的跌到成本的 20%：计划价降到底价后照常成交（低于成本价止损）
        uint256 low = _unitFor(m, 0, 2_000);
        _postPrices(low, low);
        vm.warp(block.timestamp + 7 days);
        _postPrices(low, low);
        assertEq(sales.askPrice(address(m), 0), cost / 2, "plan floor below cost");
        _buy(0);
        assertEq(saleProceeds, cost / 2);
    }

    function test_SaleAtMarketPremiumRefundsPrincipalAndSharesPremium() public {
        _settle(false);
        uint256 unit = _unitFor(m, 0, 12_000);
        _postPrices(unit, unit);
        uint256 price = unit * m.machine(0).weight;
        uint256 cost = m.machine(0).cost;
        uint256 allBefore = _totalOwedToPlayers();
        uint256 feeSafeBefore = bem.balanceOf(FEE_SAFE);
        _buy(0);
        assertEq(machines.ownerOf(m.machine(0).circuitId), buyer);
        // 溢价（超过成本价的部分）10% 给手续费地址（规则决定 6.24）；没有回馈资本时，其余都按投入比例归参与者
        uint256 fee = (price - cost) / 10;
        assertGt(fee, 0);
        assertEq(bem.balanceOf(FEE_SAFE) - feeSafeBefore, fee);
        assertApproxEqAbs(_totalOwedToPlayers() - allBefore, price - fee, players.length);
    }

    function test_UnsoldMachineKeepsMiningAndOperatorPushesYield() public {
        _settle(false);
        vm.warp(m.settleStart() + 1 days); // 都已按成本价挂单，但没人买
        uint256 foundationBefore = bem.balanceOf(FOUNDATION);
        uint256 feeBefore = bem.balanceOf(FEE_SAFE);
        sales.distribute(address(m), 1, players.length); // 先把未花完的本金发掉
        uint256 sum0 = _sumBalances();
        _yieldAll(6 * BEM_1);
        m.harvest();
        sales.distribute(address(m), 1, players.length);
        assertApproxEqAbs(_sumBalances() - sum0, 6 * BEM_1, players.length, "yield pushed pro rata");
        assertEq(bem.balanceOf(FOUNDATION), foundationBefore, "no 3% on post-draw yield");
        assertEq(bem.balanceOf(FEE_SAFE), feeBefore, "no 2% on post-draw yield");
        assertEq(m.finishedAt(), 0, "claim window not started while machines unsold");
    }

    function test_RevokedMachineIsNotSoldBelowCost() public {
        _settle(false);
        pod.revoke(m.machine(0).key);
        vm.warp(m.settleStart() + 1 days);
        assertEq(sales.askPrice(address(m), 0), m.machine(0).cost, "still priced at cost");
        _buy(1);
        _buy(2);
        assertGt(m.principalRemaining(), 0, "principal of the revoked machine is delayed");
        assertEq(m.unsoldMachines(), 1);
    }

    // ---------------- 回馈资本滚入下一块月局 ----------------

    function test_SubsidyCapitalRollsIntoNextMonthBoard() public {
        _settle(true);
        uint256 subsidy = m.subsidyCapital();
        vm.warp(m.settleStart() + 1 days); // 自动按成本价挂单
        _buy(0);
        _buy(1);
        _buy(2);
        assertEq(m.principalRemaining(), 0);
        assertEq(m.subsidyRemaining(), 0);
        assertEq(m.rolledOver(), subsidy, "subsidy capital returned to the month factory");
        assertEq(bem.balanceOf(address(monthFactory)), subsidy);
        // 参与者拿回本金，外加奖金池按比例分的一半（规则决定 6.20；抽奖的一半已经直接推送）
        uint256 drawn;
        for (uint256 i = 0; i < 5; i++) {
            drawn += m.prizeAmounts(i);
        }
        uint256 sharedHalf = drawn; // 奖金池为偶数时两半相等；为奇数时按比例的一半多 1 个最小单位
        assertApproxEqAbs(_totalOwedToPlayers(), m.totalStake() + sharedHalf, players.length + 1);

        MonthBoard r = _freshPreparing();
        assertEq(r.subsidyCapital(), subsidy, "rolled into the next month board");
        assertEq(r.budget(), r.totalStake() + subsidy);
        assertEq(bem.balanceOf(address(monthFactory)), 0);
    }

    // ---------------- 自动发放与自领 ----------------

    function test_DistributeAndSelfClaimNeverDoublePay() public {
        _settle(false);
        vm.warp(m.settleStart() + 1 days);
        _buy(0);
        _buy(1);
        _buy(2);
        uint256 n = players.length;
        uint256[] memory owedBefore = new uint256[](n);
        for (uint256 i = 0; i < n; i++) {
            owedBefore[i] = _mOwed(m, players[i]);
        }
        _mClaimAll(m, players[0]); // 1 号先自领
        vm.prank(players[1]); // 参与者在 3 天内不能代替运营地址分发
        vm.expectRevert(MonthBoard.NotAuthorized.selector);
        sales.distribute(address(m), 1, n);
        vm.prank(buyer);
        vm.expectRevert(MonthBoard.NotAuthorized.selector);
        sales.distribute(address(m), 1, n);
        sales.distribute(address(m), 1, 10); // 分批
        sales.distribute(address(m), 11, n);
        sales.distribute(address(m), 1, n); // 重复调用不会重复支付
        for (uint256 i = 0; i < n; i++) {
            assertEq(_mOwed(m, players[i]), 0);
            assertEq(passCircuits.ownerOf(m.socket(i + 1).passId), players[i], "pass returned");
        }
        uint256 claimedAgain = _mClaimAll(m, players[2]);
        assertEq(claimedAgain, 0);
        assertLe(bem.balanceOf(address(m)), n + 2, "dust only");
        assertGe(owedBefore[0], m.socket(1).stake, "principal fully returned");
    }

    // ---------------- 资金守恒 ----------------

    function test_MonthBoardConservesFunds() public {
        uint256 f0 = bem.balanceOf(FOUNDATION);
        uint256 fee0 = bem.balanceOf(FEE_SAFE);
        _settle(true);
        MonthBoard r = _freshPreparing();
        _relay(0, r); // 交接 1 台
        _postPrices(_unitFor(m, 1, 12_000), _unitFor(m, 1, 12_000)); // 按市价溢价卖 1 台
        _buy(1);
        vm.warp(block.timestamp + 10 days); // 卖不出的那台继续挖 10 天；报价停运（7 天）后按成本价卖
        _yieldAll(3 * BEM_1);
        m.harvest();
        _buy(2);
        assertEq(m.unsoldMachines(), 0);
        sales.distribute(address(m), 1, 15);
        for (uint256 i = 0; i < players.length; i++) {
            _mClaimAll(m, players[i]); // 已经推送过的人这里拿到 0
            assertGe(
                bem.balanceOf(players[i]) - startBal[players[i]], m.socket(i + 1).stake, "principal fully returned"
            );
        }
        uint256 inflow = m.totalStake() + m.totalEntryFees() + pod.totalPaidTo(address(m)) + m.subsidyCapital()
            + saleProceeds + relayProceeds;
        uint256 paidOut = _sumGains() + (bem.balanceOf(FOUNDATION) - f0)
            + (bem.balanceOf(FEE_SAFE) - fee0 - r.totalEntryFees()) + m.totalSpent() + m.rolledOver();
        uint256 bal = bem.balanceOf(address(m));
        assertEq(inflow, paidOut + bal, "inflow == paid out + balance");
        assertEq(m.liabilities(), bal);
        assertLe(bal, players.length + 10, "dust only");
        assertEq(m.principalRemaining(), 0);
        assertEq(m.subsidyRemaining(), 0);
        assertEq(m.rolledOver(), m.subsidyCapital());
    }

    // ---------------- 辅助 ----------------

    function _sumBalances() internal view returns (uint256 t) {
        for (uint256 i = 0; i < players.length; i++) {
            t += bem.balanceOf(players[i]);
        }
    }

    /// @dev 参与者从本局拿到的全部 BEM（奖金推送 + 发放 + 自领）
    function _sumGains() internal view returns (uint256 t) {
        for (uint256 i = 0; i < players.length; i++) {
            t += bem.balanceOf(players[i]) - startBal[players[i]];
        }
    }

    function _totalOwedToPlayers() internal view returns (uint256 t) {
        for (uint256 i = 0; i < players.length; i++) {
            t += _mOwed(m, players[i]);
        }
    }

    function _yieldAll(uint256 amount) internal {
        uint256 n = m.machineCount();
        for (uint256 i = 0; i < n; i++) {
            if (!m.machine(i).sold) pod.addYield(m.machine(i).key, amount / n);
        }
    }
}

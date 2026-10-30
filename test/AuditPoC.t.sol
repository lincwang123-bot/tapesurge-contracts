// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Fixture} from "./utils/Fixture.sol";
import {TapeBoard} from "../src/TapeBoard.sol";
import {MonthBoard} from "../src/MonthBoard.sol";
import {MarketPriceFeed} from "../src/MarketPriceFeed.sol";
import {MonthExitGovernor} from "../src/month/MonthExitGovernor.sol";
import {PositionExchange} from "../src/month/PositionExchange.sol";
import {MachineLister} from "../src/market/MachineLister.sol";
import {MonthState} from "../src/interfaces/IMonthBoard.sol";
import {BoardState, SettleMode} from "../src/interfaces/ITapeBoard.sol";

/// @notice 第三方审计（2026-10-24）的 5 个复现测试，修复后（v2.0-audit.2，规则决定 6.33）改为回归测试：每种攻击都应被拒绝。
contract AuditPoCTest is Fixture {
    // ------------------------------------------------------------------
    // PoC-1：报价"每次最多变动 5%"的限制，在上一次报价过期（3 小时）后失效
    // ------------------------------------------------------------------
    function test_PoC1_FeedLimitHoldsAfterStaleness() public {
        TapeBoard b = _startGenesis();
        _fillUniform(b, 25, 20 * BEM_1); // 招满 500 BEM，开局
        assertEq(uint256(b.state()), uint256(BoardState.Active));
        uint256 cap = b.buyPriceCap();
        uint256 fair = cap / 3; // 假设真实市价约为上限的 1/3
        priceFeed.post(fair, fair);
        assertEq(b.buyPrice(), fair);

        // 停报 3 小时后（甚至更久），一次涨 20 倍仍然被拒（审计 H-1）
        vm.warp(priceFeed.updatedAt() + 3 hours);
        vm.expectRevert(MarketPriceFeed.ChangeTooLarge.selector);
        priceFeed.post(fair * 20, fair * 20);
        vm.warp(priceFeed.updatedAt() + 6 days);
        vm.expectRevert(MarketPriceFeed.ChangeTooLarge.selector);
        priceFeed.post(fair * 20, fair * 20);
        assertEq(b.buyPrice(), 0, "stale: purchases paused, not at the cap");
        // 每次最多 5%
        priceFeed.post(fair * 105 / 100, fair * 105 / 100);
        assertLe(b.buyPrice(), fair * 105 / 100);
    }

    // ------------------------------------------------------------------
    // PoC-2：月局多数清算计划没有价格下限，>50% 持仓可以把矿机按 1 wei 卖给自己
    // ------------------------------------------------------------------
    function _settledMonthWithMachines() internal returns (MonthBoard m) {
        _startGenesis();
        m = _monthBoard();
        _fillMonth(m); // 25 份 × 4 BEM = 100 BEM
        address seller = _newUser();
        _sellMonth(m, seller, 30);
        _sellMonth(m, seller, 20);
        _sellMonth(m, seller, 40);
        vm.warp(m.prepEnd());
        m.sync();
        vm.warp(m.miningEnd());
        m.drawPrizes(); // 奖金池为 0，直接进入结算
        assertEq(uint256(m.state()), uint256(MonthState.Settling));
    }

    function test_PoC2_MonthMajoritySqueezeBlocked() public {
        MonthBoard m = _settledMonthWithMachines();
        // 1 wei 起价的计划发布不了（起价不低于成本价，审计 H-2）
        uint256 n = m.unsoldMachines();
        uint256[] memory idx = new uint256[](n);
        uint128[] memory st = new uint128[](n);
        uint128[] memory fl = new uint128[](n);
        for (uint256 i = 0; i < n; i++) {
            idx[i] = i;
            st[i] = 1;
            fl[i] = 1;
        }
        vm.expectRevert(MonthExitGovernor.BadPlan.selector);
        governor.publishPlan(address(m), idx, st, fl);
        // 起价 = 成本价、底价 1 wei 的计划可以发布并通过，但成交价不低于当时买一 × 算力 × 95%
        uint256 unit = _unitFor(m, 0, 8_000); // 市场：约成本价的 80%
        _postPrices(unit, unit);
        for (uint256 i = 0; i < n; i++) {
            st[i] = m.machine(i).cost;
        }
        bytes32 h = governor.publishPlan(address(m), idx, st, fl);
        _passPlan(m, h);
        vm.warp(block.timestamp + 8 days); // 计划价早已降到 1 wei
        _postPrices(unit, unit);
        for (uint256 i = 0; i < n; i++) {
            uint256 market = priceFeed.bid() * m.machine(i).weight * 9_500 / 10_000;
            assertGe(sales.askPrice(address(m), i), market, "never below 95% of the bid");
        }
        // 报价过期：计划价暂停，不能趁机低价成交
        vm.warp(block.timestamp + 3 hours);
        assertEq(sales.askPrice(address(m), 0), 0);
    }

    function _passPlan(MonthBoard m, bytes32 h) internal {
        // 攻击者控制插槽 1–13（52%）：13 个小号各带一张通行证加入，或在盘口收购
        vm.warp(m.settleStart() + 7 days);
        uint256[] memory sup = new uint256[](3);
        for (uint256 s = 1; s <= 3; s++) {
            sup[s - 1] = s;
            uint256[] memory one = new uint256[](1);
            one[0] = s;
            vm.prank(m.socket(s).owner);
            governor.support(address(m), one, h);
        }
        if (priceFeed.updatedAt() != 0) _postPrices(priceFeed.bid(), priceFeed.ask());
        governor.openVote(address(m), h, sup);
        uint8 yes = governor.YES();
        uint8 no = governor.NO();
        for (uint256 s = 1; s <= 13; s++) {
            uint256[] memory one = new uint256[](1);
            one[0] = s;
            vm.prank(m.socket(s).owner);
            governor.castVote(address(m), one, yes);
        }
        // 少数派 12 份全部反对也没用
        for (uint256 s = 14; s <= 25; s++) {
            uint256[] memory one = new uint256[](1);
            one[0] = s;
            vm.prank(m.socket(s).owner);
            governor.castVote(address(m), one, no);
        }
        vm.warp(block.timestamp + 24 hours);
        governor.finalizeVote(address(m));
        vm.warp(block.timestamp + 24 hours);
        governor.execute(address(m));
    }

    // ------------------------------------------------------------------
    // PoC-3：TapeOut 信标升级一次后哨兵永久处于"触发"状态；冷静期结束后新开的局，任何一个持有人都能单方面提前终局
    // ------------------------------------------------------------------
    function test_PoC3_AfterCoolingNewBoardsCannotBeEndedByOneHolder() public {
        TapeBoard b0 = _startGenesis();
        machineBeacon.upgradeTo(address(0xBAD)); // TapeOut 例行升级电路合约
        factory.noteSentinel();
        vm.warp(block.timestamp + 30 days + 1);
        assertFalse(b0.sentinelPaused(), "cooling period over: boards run normally again");
        assertTrue(b0.sentinelTripped(), "but the sentinel stays tripped forever");

        // 冷静期后招募失败的旧板关闭，工厂照常开新局
        b0.closeRecruitment();
        TapeBoard b = _board();
        assertTrue(address(b) != address(b0));
        while (b.state() == BoardState.Recruiting) _join(b, b.maxStake()); // 重开后目标减半
        assertEq(uint256(b.state()), uint256(BoardState.Active));
        _sell(b, _newUser(), 200);

        // 冷静期过后新开的局：不能再被任何一个持有人单方面结束（审计 M-1）
        address one = b.socket(8).owner;
        vm.prank(one);
        vm.expectRevert(TapeBoard.SentinelNotTripped.selector);
        b.emergencyExit(8);
        assertEq(uint256(b.state()), uint256(BoardState.Active));

        MonthBoard m = _monthBoard();
        if (block.timestamp >= m.recruitDeadline()) {
            m.closeRecruitment();
            m = _monthBoard();
        }
        _fillMonth(m);
        _sellMonth(m, _newUser(), 30);
        vm.warp(m.prepEnd());
        m.sync();
        assertEq(uint256(m.state()), uint256(MonthState.Mining));
        address mh = m.socket(3).owner;
        vm.prank(mh);
        vm.expectRevert(MonthBoard.SentinelNotTripped.selector);
        m.emergencySettle();
        assertEq(uint256(m.state()), uint256(MonthState.Mining));
    }

    // ------------------------------------------------------------------
    // PoC-4：标准局的"通用买单"不区分持仓是否已出局；出局者（已拿走 105%）可以把持仓卖给原本想买在局持仓的买单
    // ------------------------------------------------------------------
    function test_PoC4_StdBidRejectsEjectedPosition() public {
        TapeBoard b = _startGenesis();
        _fillUniform(b, 25, 20 * BEM_1);
        _sell(b, _newUser(), 200);
        vm.warp(b.initialBuyEnd());

        // 开奖：第 5 号出局，持有人当场拿到 105%
        uint256 slot = 5;
        address holder = b.socket(slot).owner;
        uint256 before = bem.balanceOf(holder);
        _topUpPool(b);
        b.pulse();
        rng.fulfill(b.pendingRequestId(), _wordFor(b, slot));
        assertTrue(b.socket(slot).ejected);
        uint256 payout = bem.balanceOf(holder) - before;
        assertEq(payout, 21 * BEM_1);

        // 买单挂在出局之后（出局前挂的买单会因局交易版本号 +1 失效）
        address bidder = _newUser();
        bem.mint(bidder, 1_000 * BEM_1);
        vm.startPrank(bidder);
        bem.approve(address(exchange), type(uint256).max);
        // 按"在局持仓"定价：每 1 BEM 本金出 1 BEM
        uint256 bidId =
            exchange.placeBid(address(b), 1e8, 100 * BEM_1, 1, type(uint96).max, uint64(block.timestamp + 10 days));
        vm.stopPrank();

        // 出局者不能把已经兑现的持仓卖给买单（审计 M-2）；没出局的持仓照常可以卖
        vm.startPrank(holder);
        positions.approve(address(exchange), positions.idOf(address(b), slot));
        vm.expectRevert(PositionExchange.PositionEjected.selector);
        exchange.sellToBid(bidId, slot, 0);
        vm.stopPrank();
        uint256 alive = slot == 1 ? 2 : 1;
        if (b.socket(alive).ejected) alive = 3;
        address h2 = b.socket(alive).owner;
        vm.startPrank(h2);
        positions.approve(address(exchange), positions.idOf(address(b), alive));
        exchange.sellToBid(bidId, alive, 0);
        vm.stopPrank();
        assertEq(b.socket(alive).owner, bidder);
    }

    // ------------------------------------------------------------------
    // PoC-5：矿机撤回主板后，任何人往它的挂单库打 BNB 都会触发结算，矿机被转进 MachineLister 永久卡死
    // ------------------------------------------------------------------
    function test_PoC5_ProceedsAfterRecallRejected() public {
        _startGenesis();
        MonthBoard m = _monthBoard();
        _fillMonth(m);
        (uint256 id,,) = _sellMonth(m, _newUser(), 30);
        vm.warp(m.prepEnd());
        m.sync();
        vm.warp(m.miningEnd());
        m.drawPrizes();
        assertEq(uint256(m.state()), uint256(MonthState.Settling));

        uint256 unit = _unitFor(m, 0, 11_000);
        _postPrices(unit, unit);
        lister.list(address(m), 0);
        address vault = lister.vaultOf(address(m), 0);
        assertEq(machines.ownerOf(id), vault);

        // 报价过期 → 任何人可撤回；矿机回到主板
        vm.warp(block.timestamp + 3 hours + 1);
        lister.recall(address(m), 0);
        assertEq(machines.ownerOf(id), address(m));
        _postPrices(unit, unit);

        // 有人（误操作 / 市场迟到的付款）往旧挂单库打 BNB
        address someone = address(0xCAFE);
        vm.deal(someone, 10 ether);
        vm.prank(someone);
        (bool ok,) = vault.call{value: 10 ether}("");
        assertFalse(ok, "payment to a recalled vault is rejected (audit L-1)");
        assertFalse(m.machine(0).sold);
        assertEq(machines.ownerOf(id), address(m), "machine stays with the board");
        assertEq(someone.balance, 10 ether);
    }

    // ------------------------------------------------------------------
    // M-4：运营地址设成 0（紧急刹车）不会让结算中的月局立刻按成本价被买走；7 天没报价才按成本价兜底
    // ------------------------------------------------------------------
    function test_M4_OperatorZeroPausesInsteadOfCostPrice() public {
        MonthBoard m = _settledMonthWithMachines();
        uint256 unit = _unitFor(m, 0, 13_000);
        _postPrices(unit, unit);
        uint256 cost = m.machine(0).cost;
        assertGt(sales.askPrice(address(m), 0), cost);
        vm.prank(FEE_SAFE);
        factory.setOperator(address(0));
        assertEq(sales.askPrice(address(m), 0), 0, "paused, not sold at cost");
        vm.warp(priceFeed.updatedAt() + 7 days);
        assertEq(sales.askPrice(address(m), 0), cost, "abandoned for 7 days: anyone may buy at cost");
    }

    function _wordFor(TapeBoard b, uint256 slot) internal view returns (uint256 w) {
        for (uint256 i = 0; i < 20_000; i++) {
            w = uint256(keccak256(abi.encode("word", i)));
            if (b.previewEject(w) == slot) return w;
        }
        revert("no word");
    }
}


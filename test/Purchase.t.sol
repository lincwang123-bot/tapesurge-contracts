// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Fixture} from "./utils/Fixture.sol";
import {TapeBoard} from "../src/TapeBoard.sol";
import {BoardState} from "../src/interfaces/ITapeBoard.sol";
import {BoardFactory} from "../src/BoardFactory.sol";

/// @notice 采购拍卖（价格逐步上涨的荷兰式拍卖）：价格曲线、产出上限、矿机资格、旧产出归卖家、预算
contract PurchaseTest is Fixture {
    TapeBoard internal b;
    address internal seller;

    function setUp() public override {
        super.setUp();
        b = _startGenesis();
        _fillUniform(b, 25, 20 * BEM_1);
        seller = _newUser();
    }

    function _expectedCap() internal view returns (uint256) {
        uint256 perDay = pod.currentRate() * 1 days * 9_900 / 10_000 / pod.totalVerifWeight();
        uint256 cap = perDay * 365;
        return cap > 3 * BEM_1 ? 3 * BEM_1 : cap;
    }

    function test_PriceCapIsOneYearOfUnitYield() public view {
        // 7,200 BEM/天 × 99% ÷ 1,580,163 × 365 ≈ 1.6465 BEM / 单位权重
        uint256 cap = b.buyPriceCap();
        assertEq(cap, _expectedCap());
        assertApproxEqAbs(cap, 1.6465e8, 0.0005e8);
    }

    function test_PriceRisesFromHalfCapToCap() public {
        uint256 cap = b.buyPriceCap();
        assertTrue(b.isPurchasing());
        assertEq(b.buyPrice(), cap * 5_000 / 10_000);
        vm.warp(block.timestamp + 6 hours);
        assertEq(b.buyPrice(), cap * 5_500 / 10_000);
        vm.warp(block.timestamp + 54 hours); // 共 60 小时，10 步
        assertEq(b.buyPrice(), cap);
        vm.warp(block.timestamp + 3 days);
        assertEq(b.buyPrice(), cap); // 不超过上限
    }

    function test_AbsoluteMaxPriceApplies() public {
        // 开局（收购开始、快照上限）之前单位产出就很高：按产出算的上限超过 3 BEM，取绝对上限
        pod.setTotalVerifWeight(100_000);
        _deploySystem(defaultParams());
        TapeBoard nb = _startGenesis();
        _fillUniform(nb, 25, 20 * BEM_1);
        assertEq(nb.buyPriceCap(), 3 * BEM_1);
    }

    /// @dev 外部审计 #3：本轮的上限是收购开始时的快照，本轮内不随 PoD 的即时值变化（变高变低都不变）；
    ///      新一轮收购开始时重新快照
    function test_CapIsSnapshotForTheWholeRound() public {
        uint256 snap = _expectedCap();
        assertEq(b.buyPriceCap(), snap);
        pod.setTotalVerifWeight(100_000); // 单位产出暴涨
        assertEq(b.buyPriceCap(), snap, "does not rise within the round");
        vm.warp(block.timestamp + 6 hours);
        assertEq(b.buyPrice(), snap * 5_500 / 10_000, "price steps are based on the snapshot");
        pod.setTotalVerifWeight(MAINNET_VERIFIED_WEIGHT * 2); // 单位产出减半
        assertEq(b.buyPriceCap(), snap, "does not fall within the round");
        // 按快照价成交
        (uint256 id,) = _newMachine(seller, 100);
        assertEq(_traderSell(address(b), address(machines), id, seller, 100 * (snap * 5_500 / 10_000)), 100 * (snap * 5_500 / 10_000));
        // 本轮结束后领到回馈补贴：开启新一轮，按当时的即时值重新快照
        vm.warp(b.buyRoundEnd());
        _depositSubsidy(b, 10 * BEM_1);
        assertTrue(b.isPurchasing());
        assertApproxEqRel(b.buyPriceCap(), snap / 2, 0.001e18, "new round, new snapshot");
    }

    /// @dev 由分账合约存入回馈补贴（模拟 claimReward）
    function _depositSubsidy(TapeBoard board, uint256 amount) internal {
        bem.mint(address(splitter), amount);
        vm.startPrank(address(splitter));
        bem.approve(address(board), amount);
        board.depositSubsidy(amount);
        vm.stopPrank();
    }

    /// @dev 收购开始时读不到单位产出：上限快照为 0，暂停收购；之后第一次有人卖矿机时补一次快照
    function test_RevertWhen_YieldRateUnavailable() public {
        pod.setTotalVerifWeight(0); // 读不到单位产出
        _deploySystem(defaultParams());
        TapeBoard nb = _startGenesis();
        _fillUniform(nb, 25, 20 * BEM_1);
        assertEq(nb.buyPriceCap(), 0);
        assertEq(nb.buyPrice(), 0);
        (uint256 id,) = _newMachine(seller, 100);
        pod.setTotalVerifWeight(0); // 登记矿机会加总权重，这里再清零
        _toTrader(address(nb), address(machines), id, seller);
        vm.prank(address(trader));
        vm.expectRevert(TapeBoard.PriceUnavailable.selector);
        nb.sellMachine(address(machines), id, 0);
        // PoD 恢复：卖矿机时补拍快照，之后本轮都按它计价
        pod.setTotalVerifWeight(MAINNET_VERIFIED_WEIGHT);
        uint256 spent = 100 * (_expectedCap() / 2); // 先算好：_expectedCap 会调用 PoD，不能夹在 prank 和 sellMachine 之间
        vm.prank(address(trader));
        assertEq(nb.sellMachine(address(machines), id, spent), spent);
        assertEq(nb.buyPriceCap(), _expectedCap());
    }

    function test_SellMachinePaysWeightTimesPriceAndOldYieldToSeller() public {
        (uint256 id, bytes32 key) = _newMachine(seller, 100);
        pod.addYield(key, 5 * BEM_1); // 卖之前累积的旧产出
        uint256 price = b.buyPrice();
        uint256 paid = _traderSell(address(b), address(machines), id, seller, 100 * price);

        assertEq(paid, 100 * price);
        assertEq(bem.balanceOf(seller), paid + 5 * BEM_1); // 旧产出发给了卖家
        assertEq(machines.ownerOf(id), address(b));
        assertEq(b.budget(), 500 * BEM_1 - paid);
        assertEq(b.totalWeightBought(), 100);
        assertEq(b.activeWeight(), 100);
        assertEq(b.machineCount(), 1);
        assertEq(b.pool(), 0);

        // 转入后的产出归主板，进入脉冲池
        pod.addYield(key, 2 * BEM_1);
        b.harvest();
        assertEq(b.pool(), 2 * BEM_1);
        assertEq(bem.balanceOf(seller), paid + 5 * BEM_1);
    }

    function test_TimeBasedYieldFlowsToBoard() public {
        pod.setRate(451_000); // ≈ 0.00451 BEM / 单位权重 / 天
        (,, uint256 paid) = _sell(b, seller, 200);
        vm.warp(block.timestamp + 10 days);
        b.harvest();
        assertEq(b.pool(), 200 * 451_000 * 10);
        assertGt(paid, 0);
    }

    /// @dev 规则决定 6.37：主板只认 MarketTrader，矿机持有人自己不能按报价卖给主板
    function test_RevertWhen_CallerIsNotTrader() public {
        (uint256 id,) = _newMachine(seller, 100);
        uint256 price = b.buyPrice();
        vm.startPrank(seller);
        machines.approve(address(b), id);
        vm.expectRevert(TapeBoard.NotAuthorized.selector);
        b.sellMachine(address(machines), id, 100 * price);
        vm.stopPrank();
    }

    function test_RevertWhen_TraderIsNotMachineOwner() public {
        (uint256 id,) = _newMachine(seller, 100);
        vm.prank(seller);
        machines.approve(address(b), id);
        // 卖家授权了主板，MarketTrader 也不能卖不在自己手里的矿机
        vm.prank(address(trader));
        vm.expectRevert(TapeBoard.NotMachineOwner.selector);
        b.sellMachine(address(machines), id, 0);
    }

    function test_RevertWhen_MachineNotEligible() public {
        // 未验证
        (uint256 id1, bytes32 k1) = _newMachine(seller, 100);
        pod.setFlags(k1, true, false);
        // 未在挖
        (uint256 id2, bytes32 k2) = _newMachine(seller, 100);
        pod.setFlags(k2, false, true);
        // 运行不满 7 天
        (uint256 id3, bytes32 k3) = _newMachine(seller, 100);
        pod.setSince(k3, block.timestamp - 6 days);
        // 算力超过上限 / 低于下限
        (uint256 id4,) = _newMachine(seller, 301);
        (uint256 id5,) = _newMachine(seller, 9);
        uint256[5] memory ids = [id1, id2, id3, id4, id5];
        for (uint256 i = 0; i < ids.length; i++) {
            _toTrader(address(b), address(machines), ids[i], seller);
            vm.prank(address(trader));
            vm.expectRevert(TapeBoard.MachineNotEligible.selector);
            b.sellMachine(address(machines), ids[i], 0);
        }
    }

    /// @dev 审计 #5：PoD 返回的电路合约地址或编号和查询的矿机不一致（字段错位）时，当作读取失败
    function test_RevertWhen_PoDReturnsAnotherMachine() public {
        (uint256 id1, bytes32 k1) = _newMachine(seller, 100);
        pod.setIdentity(k1, address(machines), id1 + 1000);
        (uint256 id2, bytes32 k2) = _newMachine(seller, 100);
        pod.setIdentity(k2, address(0xC0DE), id2);
        uint256[2] memory ids = [id1, id2];
        for (uint256 i = 0; i < ids.length; i++) {
            _toTrader(address(b), address(machines), ids[i], seller);
            vm.prank(address(trader));
            vm.expectRevert(TapeBoard.MachineNotEligible.selector);
            b.sellMachine(address(machines), ids[i], 0);
        }
    }

    /// @dev 实际花费不得超过 计价算力 × 收购价上限；按实际花费记账（规则决定 6.22 / 6.37）
    function test_SpentAboveCapReverts() public {
        (uint256 id,) = _newMachine(seller, 100);
        uint256 price = b.buyPrice();
        _toTrader(address(b), address(machines), id, seller);
        vm.startPrank(address(trader));
        vm.expectRevert(TapeBoard.PriceAboveMaximum.selector);
        b.sellMachine(address(machines), id, 100 * price + 1);
        assertEq(b.sellMachine(address(machines), id, 100 * price - 7), 100 * price - 7);
        vm.stopPrank();
        assertEq(b.totalSpent(), 100 * price - 7);
    }

    function test_RevertWhen_BudgetInsufficient() public {
        vm.warp(block.timestamp + 60 hours); // 价格到上限 ≈ 1.6465
        _sell(b, seller, 300); // ≈ 494 BEM
        (uint256 id,) = _newMachine(seller, 10); // ≈ 16.5 BEM > 剩余预算
        uint256 spent = 10 * b.buyPrice();
        _toTrader(address(b), address(machines), id, seller);
        vm.prank(address(trader));
        vm.expectRevert(TapeBoard.InsufficientBudget.selector);
        b.sellMachine(address(machines), id, spent);
    }

    function test_RoundEndsAndUnspentBudgetStays() public {
        (,, uint256 paid) = _sell(b, seller, 100);
        vm.warp(block.timestamp + 7 days);
        assertFalse(b.isPurchasing());
        assertEq(b.buyPrice(), 0);
        (uint256 id,) = _newMachine(seller, 100);
        _toTrader(address(b), address(machines), id, seller);
        vm.prank(address(trader));
        vm.expectRevert(TapeBoard.BuyRoundInactive.selector);
        b.sellMachine(address(machines), id, 0);
        // 买不满时剩下的 BEM 留在主板
        assertEq(b.budget(), 500 * BEM_1 - paid);
        assertEq(bem.balanceOf(address(b)), 500 * BEM_1 - paid);
    }

    function test_RevokedMachineStopsCountingAndCanReturn() public {
        (, bytes32 key,) = _sell(b, seller, 100);
        pod.addYield(key, 3 * BEM_1);
        pod.revoke(key);
        b.syncMachine(0);
        assertFalse(b.machine(0).active);
        assertEq(b.activeWeight(), 0);
        // 撤销前的产出在同步时领回
        assertEq(b.pool(), 3 * BEM_1);
        pod.addYield(key, 1 * BEM_1);
        b.harvest();
        assertEq(b.pool(), 3 * BEM_1); // 不再领取
        pod.setFlags(key, true, true);
        b.syncMachine(0);
        assertTrue(b.machine(0).active);
        b.harvest();
        assertEq(b.pool(), 4 * BEM_1);
    }

    function test_HarvestFallsBackWhenClaimManyFails() public {
        _sell(b, seller, 100);
        _sell(b, seller, 50);
        _yield(b, 0, 1 * BEM_1);
        _yield(b, 1, 2 * BEM_1);
        pod.setClaimManyReverts(true);
        assertEq(b.harvest(), 3 * BEM_1);
        assertEq(b.pool(), 3 * BEM_1);
    }

    function test_RevertWhen_TooManyMachines() public {
        BoardFactory.Params memory p = defaultParams();
        p.board.maxMachines = 3;
        _deploySystem(p);
        TapeBoard nb = _startGenesis();
        _fillUniform(nb, 25, 20 * BEM_1);
        for (uint256 i = 0; i < 3; i++) {
            _sell(nb, seller, 10);
        }
        (uint256 id,) = _newMachine(seller, 10);
        _toTrader(address(nb), address(machines), id, seller);
        vm.prank(address(trader));
        vm.expectRevert(TapeBoard.TooManyMachines.selector);
        nb.sellMachine(address(machines), id, 0);
    }

    function test_StateGuards() public {
        TapeBoard next = _board();
        assertEq(uint256(next.state()), uint256(BoardState.Recruiting));
        vm.expectRevert(TapeBoard.WrongState.selector);
        next.harvest();
        vm.expectRevert(TapeBoard.WrongState.selector);
        next.pulse();
        vm.expectRevert(TapeBoard.OnlySplitter.selector);
        b.depositSubsidy(1);
    }
}

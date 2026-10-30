// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Fixture} from "./utils/Fixture.sol";
import {TapeBoard} from "../src/TapeBoard.sol";
import {BoardFactory} from "../src/BoardFactory.sol";
import {BoardState, SettleMode} from "../src/interfaces/ITapeBoard.sol";
import {IBeacon} from "../src/interfaces/ITapeOut.sol";

/// @notice 升级哨兵：电路合约信标的实现地址变化后进入 30 天冷静期（暂停加入、开新主板、矿机买卖），允许提前退出
contract SentinelTest is Fixture {
    TapeBoard internal b;

    function setUp() public override {
        super.setUp();
        b = _startGenesis();
    }

    function test_PassBeaconUpgradeBlocksJoinAndAllowsImmediateRefund() public {
        address u = _join(b, 10 * BEM_1);
        assertFalse(b.sentinelTripped());
        tapeout.circuitsBeacon().upgradeTo(address(0xBAD));
        assertTrue(b.sentinelTripped());

        address v = _newUser();
        uint256 id = _mintPass(v);
        bem.mint(v, 100 * BEM_1);
        vm.startPrank(v);
        passCircuits.approve(address(b), id);
        bem.approve(address(b), type(uint256).max);
        vm.expectRevert(TapeBoard.UpgradeSentinelTripped.selector);
        b.join(id, 10 * BEM_1);
        vm.stopPrank();

        // 不必等 7 天：立即结束招募、全额退款；不再重开新主板
        b.closeRecruitment();
        assertEq(uint256(b.state()), uint256(BoardState.Failed));
        assertEq(factory.recruitingBoard(), address(0));
        stdSales.claimAll(address(b), _slotOf(b, u));
        assertEq(bem.balanceOf(u), 20 * BEM_1);
    }

    function test_MachineBeaconUpgradePausesAuctionsButGameContinues() public {
        _fillUniform(b, 20, 20 * BEM_1);
        address[] memory small = _fillUniform(b, 20, 5 * BEM_1);
        address seller = _newUser();
        _sell(b, seller, 200);
        machineBeacon.upgradeTo(address(0xBAD));
        assertTrue(b.sentinelTripped());

        // 暂停采购拍卖
        (uint256 id,) = _newMachine(seller, 100);
        _toTrader(address(b), address(machines), id, seller);
        vm.prank(address(trader));
        vm.expectRevert(TapeBoard.UpgradeSentinelTripped.selector);
        b.sellMachine(address(machines), id, 0);

        // 照常领取产出、开奖
        _topUpPool(b);
        _pulseAndFulfill(b, 12345);
        assertEq(b.aliveCount(), 39);

        // 只有未出局的参与者可以发起退出
        uint256 ejectedSlot;
        for (uint256 s = 1; s <= 40; s++) {
            if (b.socket(s).ejected) ejectedSlot = s;
        }
        address ejectedOwner = b.socket(ejectedSlot).owner;
        vm.prank(ejectedOwner);
        vm.expectRevert(TapeBoard.NotAliveParticipant.selector);
        b.emergencyExit(ejectedSlot);
        address alive = small[0] == ejectedOwner ? small[1] : small[0];
        uint256 aliveSlot = _slotOf(b, alive);
        vm.prank(address(0x1234)); // 不是这份持仓的持有人
        vm.expectRevert(TapeBoard.NotAliveParticipant.selector);
        b.emergencyExit(aliveSlot);
        vm.prank(alive);
        b.emergencyExit(aliveSlot);
        assertEq(uint256(b.state()), uint256(BoardState.Liquidating));
        assertEq(uint256(b.settleMode()), uint256(SettleMode.Fallback));

        // 终局拍卖也暂停；信标恢复后可以继续
        bem.mint(address(this), 1_000 * BEM_1);
        bem.approve(address(stdSales), type(uint256).max);
        _postPrices(b.sellFloorPrice(), b.sellFloorPrice()); // 市价期：报价后按公式价可买
        vm.expectRevert(TapeBoard.UpgradeSentinelTripped.selector);
        stdSales.buyMachine(address(b), 0, type(uint256).max);
        machineBeacon.upgradeTo(address(0xB1B1));
        assertFalse(b.sentinelTripped());
        stdSales.buyMachine(address(b), 0, type(uint256).max);
    }

    /// @dev 外部审计 #2：哨兵触发后矿机收购暂停；记录触发满 30 天后自动恢复（信标仍是升级后的）；
    ///      冷静期内新的加入也暂停；这期间参与者仍可提前退出
    function test_PurchaseResumesThirtyDaysAfterTrip() public {
        _fillUniform(b, 25, 20 * BEM_1);
        address seller = _newUser();
        machineBeacon.upgradeTo(address(0xBAD));
        factory.noteSentinel();
        uint256 since = factory.sentinelSince();
        assertEq(since, block.timestamp);
        (uint256 id,) = _newMachine(seller, 100);
        _toTrader(address(b), address(machines), id, seller);
        vm.prank(address(trader));
        vm.expectRevert(TapeBoard.UpgradeSentinelTripped.selector);
        b.sellMachine(address(machines), id, 0);
        // 冷静期内新的加入也暂停（招募中的标准局 #2）
        TapeBoard next = TapeBoard(factory.recruitingBoard());
        address u = _newUser();
        uint256 passId = _mintPass(u);
        bem.mint(u, 100 * BEM_1);
        vm.startPrank(u);
        passCircuits.approve(address(next), passId);
        bem.approve(address(next), type(uint256).max);
        uint256 amt = next.minStake();
        vm.expectRevert(TapeBoard.UpgradeSentinelTripped.selector);
        next.join(passId, amt);
        vm.stopPrank();
        // 满 30 天：本轮已经结束，回馈补贴开启新一轮收购，可以照常卖矿机
        vm.warp(since + 30 days);
        assertTrue(b.sentinelTripped());
        assertFalse(b.sentinelPaused());
        bem.mint(address(splitter), 10 * BEM_1);
        vm.startPrank(address(splitter));
        bem.approve(address(b), 10 * BEM_1);
        b.depositSubsidy(10 * BEM_1);
        vm.stopPrank();
        pod.setSince(pod.minerKey(address(machines), id), block.timestamp - 30 days);
        uint256 spent = 100 * b.buyPrice();
        vm.prank(address(trader));
        assertGt(b.sellMachine(address(machines), id, spent), 0);
    }

    /// @dev 外部审计 #2：提前退出后终局拍卖暂停，满 30 天后自动恢复出售
    function test_AuctionResumesThirtyDaysAfterTrip() public {
        address[] memory players = _fillUniform(b, 25, 20 * BEM_1);
        _sell(b, _newUser(), 200);
        machineBeacon.upgradeTo(address(0xBAD));
        assertEq(factory.sentinelSince(), 0);
        uint256 slot0 = _slotOf(b, players[0]);
        vm.prank(players[0]);
        b.emergencyExit(slot0); // 30 天内参与者可以提前退出，并顺带记下触发时间
        uint256 since = factory.sentinelSince();
        assertEq(since, block.timestamp);
        bem.mint(address(this), 1_000 * BEM_1);
        bem.approve(address(stdSales), type(uint256).max);
        vm.warp(since + 30 days - 1); // 冷静期最后一刻：仍在 30 天市价期，报价后也不能买
        _postPrices(b.sellFloorPrice(), b.sellFloorPrice());
        vm.expectRevert(TapeBoard.UpgradeSentinelTripped.selector);
        stdSales.buyMachine(address(b), 0, type(uint256).max);
        factory.noteSentinel(); // 已记录的时间不会被刷新
        assertEq(factory.sentinelSince(), since);
        vm.warp(since + 30 days);
        assertGt(stdSales.buyMachine(address(b), 0, type(uint256).max), 0);
        assertEq(b.unsoldMachines(), 0);
    }

    /// @dev 没人记录时一直暂停；任何人都可以记录；信标恢复后买卖立即恢复，再调用会清零记录
    function test_NoteSentinelRecordsAndResets() public {
        factory.noteSentinel();
        assertEq(factory.sentinelSince(), 0, "not tripped: nothing recorded");
        machineBeacon.upgradeTo(address(0xBAD));
        vm.warp(block.timestamp + 365 days);
        assertTrue(b.sentinelPaused(), "never noted: stays paused");
        vm.prank(address(0xCAFE));
        factory.noteSentinel();
        assertEq(factory.sentinelSince(), block.timestamp);
        machineBeacon.upgradeTo(address(0xB1B1));
        assertFalse(b.sentinelPaused());
        factory.noteSentinel();
        assertEq(factory.sentinelSince(), 0, "recovered: reset");
    }

    /// @dev 项目方 2026-10-20 方案 A：登记满 30 天后，新的加入和开新主板也一起恢复（哨兵是 30 天冷静期）
    function test_JoinAndNewBoardsResumeAfterCoolingPeriod() public {
        _join(b, 10 * BEM_1);
        machineBeacon.upgradeTo(address(0xBAD));
        factory.noteSentinel();
        uint256 since = factory.sentinelSince();
        // 冷静期内：加入被拒绝
        address u = _newUser();
        uint256 passId = _mintPass(u);
        bem.mint(u, 100 * BEM_1);
        vm.startPrank(u);
        passCircuits.approve(address(b), passId);
        bem.approve(address(b), type(uint256).max);
        vm.expectRevert(TapeBoard.UpgradeSentinelTripped.selector);
        b.join(passId, 10 * BEM_1);
        vm.stopPrank();
        // 冷静期内可以立即结束招募、全额退款；工厂不重开，reopen 也不行
        b.closeRecruitment();
        assertEq(uint256(b.state()), uint256(BoardState.Failed));
        assertEq(factory.recruitingBoard(), address(0));
        vm.expectRevert(BoardFactory.SentinelTripped.selector);
        factory.reopen();
        vm.warp(since + 30 days - 1);
        vm.expectRevert(BoardFactory.SentinelTripped.selector);
        factory.reopen();
        // 满 30 天（信标仍是升级后的）：任何人可以重开同一编号，可以加入
        vm.warp(since + 30 days);
        assertTrue(b.sentinelTripped());
        TapeBoard nb = TapeBoard(factory.reopen());
        assertEq(nb.number(), 1);
        assertEq(factory.recruitingBoard(), address(nb));
        vm.expectRevert(BoardFactory.NothingToReopen.selector);
        factory.reopen();
        _join(nb, 10 * BEM_1);
        assertEq(nb.socketCount(), 1);
        // 冷静期过后，招募失败照常自动重开
        vm.warp(nb.recruitDeadline());
        nb.closeRecruitment();
        assertEq(uint256(nb.state()), uint256(BoardState.Failed));
        address again = factory.recruitingBoard();
        assertTrue(again != address(0) && again != address(nb), "reopened automatically");
    }

    /// @dev 冷静期内不能开局；登记满 30 天后可以开局（同时开出第 1 块月局）
    function test_GenesisWaitsForCoolingPeriod() public {
        _deploySystem(defaultParams());
        machineBeacon.upgradeTo(address(0xBAD));
        factory.noteSentinel();
        uint256 since = factory.sentinelSince();
        vm.warp(block.timestamp + 7 days);
        vm.expectRevert(BoardFactory.SentinelTripped.selector);
        factory.startGenesis();
        vm.warp(since + 30 days);
        priceFeed.post(1, 1);
        factory.startGenesis();
        assertTrue(factory.recruitingBoard() != address(0));
        assertTrue(monthFactory.recruitingBoard() != address(0));
    }

    function test_UnreadableBeaconCountsAsTripped() public {
        vm.mockCallRevert(address(machineBeacon), abi.encodeWithSelector(IBeacon.implementation.selector), "");
        assertTrue(b.sentinelTripped());
    }

    function test_RevertWhen_EmergencyExitWithoutTrip() public {
        _fillUniform(b, 25, 20 * BEM_1);
        address holder = b.socket(1).owner;
        vm.prank(holder);
        vm.expectRevert(TapeBoard.SentinelNotTripped.selector);
        b.emergencyExit(1);
    }

    function test_StartGenesisBlockedWhenTripped() public {
        _deploySystem(defaultParams());
        machineBeacon.upgradeTo(address(0xBAD));
        vm.warp(block.timestamp + 7 days);
        vm.expectRevert(BoardFactory.SentinelTripped.selector);
        factory.startGenesis();
    }
}

// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Fixture} from "./utils/Fixture.sol";
import {TapeBoard} from "../src/TapeBoard.sol";
import {MonthBoard} from "../src/MonthBoard.sol";
import {MonthFactory} from "../src/MonthFactory.sol";
import {ChainlinkVRFAdapter} from "../src/random/ChainlinkVRFAdapter.sol";
import {MockBeacon} from "../src/mocks/MockCircuits.sol";

/// @notice 2026-10-20 主网定稿前的内审修改：
///         F1 升级哨兵的登记会随信标 implementation 变化作废（恢复后再次升级会重新进入冷静期）；
///         F3 构造参数校验（时长上下限、VRF 适配器参数）。
contract HardeningTest is Fixture {
    // =====================================================================
    // F1：哨兵登记不会过期复用
    // =====================================================================

    /// @dev 场景 1：升级 → 登记 → 恢复 → 30 天后再次升级（换了别的 implementation）：重新进入冷静期
    function test_SecondUpgradeAfterRecoveryStartsNewCoolingPeriod() public {
        TapeBoard b = _startGenesis();
        machineBeacon.upgradeTo(address(0xBAD1));
        factory.noteSentinel();
        uint256 first = factory.sentinelSince();
        assertEq(first, block.timestamp);
        assertTrue(b.sentinelPaused());
        // 恢复原版本（没人调用 noteSentinel 清零）
        vm.warp(block.timestamp + 5 days);
        machineBeacon.upgradeTo(address(0xB1B1));
        assertFalse(b.sentinelTripped());
        assertFalse(b.sentinelPaused());
        assertEq(factory.sentinelSince(), 0, "record no longer matches the beacons");
        // 30 天以后再次升级：旧登记作废，重新进入冷静期（没人登记时一直暂停）
        vm.warp(first + 60 days);
        machineBeacon.upgradeTo(address(0xBAD2));
        assertTrue(b.sentinelTripped());
        assertEq(factory.sentinelSince(), 0);
        assertTrue(b.sentinelPaused(), "second upgrade gets its own cooling period");
    }

    /// @dev 场景 2：第二次升级后调用 noteSentinel：从调用时刻重新计 30 天
    function test_NoteAfterSecondUpgradeRestartsThirtyDays() public {
        TapeBoard b = _startGenesis();
        machineBeacon.upgradeTo(address(0xBAD1));
        factory.noteSentinel();
        vm.warp(block.timestamp + 40 days);
        assertFalse(b.sentinelPaused(), "first cooling period is over");
        // 第二次升级（信标没有恢复，直接换成另一个 implementation）
        machineBeacon.upgradeTo(address(0xBAD2));
        assertTrue(b.sentinelPaused(), "record is void after the implementation changed");
        factory.noteSentinel();
        uint256 second = factory.sentinelSince();
        assertEq(second, block.timestamp);
        vm.warp(second + 30 days - 1);
        assertTrue(b.sentinelPaused());
        factory.noteSentinel(); // 同一个 implementation 再调用不刷新
        assertEq(factory.sentinelSince(), second);
        vm.warp(second + 30 days);
        assertFalse(b.sentinelPaused());
        // 信标恢复后调用：清零
        machineBeacon.upgradeTo(address(0xB1B1));
        factory.noteSentinel();
        assertEq(factory.sentinelSince(), 0);
    }

    /// @dev 场景 3：只有月局监控的信标变化：只影响月局；登记、作废和重新计时同样生效
    function test_OnlyMonthBeaconChanges() public {
        MockBeacon monthBeacon = new MockBeacon(address(0xB2B2));
        MonthFactory.Params memory mp = defaultMonthParams();
        mp.board.machineBeacon = address(monthBeacon);
        _deploySystem(defaultParams(), mp);
        TapeBoard b = _startGenesis();
        MonthBoard m = _monthBoard();

        monthBeacon.upgradeTo(address(0xBAD1));
        assertFalse(b.sentinelTripped(), "standard boards are not affected");
        assertFalse(b.sentinelPaused());
        assertTrue(m.sentinelTripped());
        assertTrue(m.sentinelPaused(), "no record yet: month boards pause");
        factory.noteSentinel();
        uint256 since = factory.sentinelSince();
        assertEq(since, block.timestamp, "month beacon alone is enough to record");
        vm.warp(since + 30 days);
        assertFalse(m.sentinelPaused());
        // 月局信标恢复后又换成另一个 implementation：重新进入冷静期，标准局始终不受影响
        monthBeacon.upgradeTo(address(0xB2B2));
        vm.warp(block.timestamp + 10 days);
        monthBeacon.upgradeTo(address(0xBAD2));
        assertEq(factory.sentinelSince(), 0);
        assertTrue(m.sentinelPaused());
        assertFalse(b.sentinelPaused());
        factory.noteSentinel();
        assertEq(factory.sentinelSince(), block.timestamp);
    }

    // =====================================================================
    // F3：构造参数校验
    // =====================================================================

    function test_RevertWhen_TapeBoardDurationsOutOfRange() public {
        TapeBoard.Config memory base = factory.boardConfig();
        TapeBoard.Config memory c = base;
        c.vrfRetryDelay = 1 hours - 1; // VRF 重发至少隔 1 小时
        vm.expectRevert(TapeBoard.BadConfig.selector);
        new TapeBoard(c);
        c = factory.boardConfig();
        c.recruitDuration = 0;
        vm.expectRevert(TapeBoard.BadConfig.selector);
        new TapeBoard(c);
        c = factory.boardConfig();
        c.buyRoundDuration = 0;
        vm.expectRevert(TapeBoard.BadConfig.selector);
        new TapeBoard(c);
        c = factory.boardConfig();
        c.operatorGrace = 3650 days + 1; // 任何时长都不超过 10 年
        vm.expectRevert(TapeBoard.BadConfig.selector);
        new TapeBoard(c);
        c = factory.boardConfig();
        c.sentinelResumeDelay = type(uint256).max;
        vm.expectRevert(TapeBoard.BadConfig.selector);
        new TapeBoard(c);
        // 边界值可以
        c = factory.boardConfig();
        c.vrfRetryDelay = 1 hours;
        c.claimWindow = 3650 days;
        assertGt(address(new TapeBoard(c)).code.length, 20_000, "boundary values deploy");
    }

    function test_RevertWhen_MonthBoardDurationsOutOfRange() public {
        MonthBoard.Config memory c = monthFactory.boardConfig();
        c.vrfRetryDelay = 0;
        vm.expectRevert(MonthBoard.BadConfig.selector);
        new MonthBoard(c);
        c = monthFactory.boardConfig();
        c.prepDuration = 0;
        vm.expectRevert(MonthBoard.BadConfig.selector);
        new MonthBoard(c);
        c = monthFactory.boardConfig();
        c.recruitDuration = 0;
        vm.expectRevert(MonthBoard.BadConfig.selector);
        new MonthBoard(c);
        c = monthFactory.boardConfig();
        c.miningDuration = 3650 days + 1;
        vm.expectRevert(MonthBoard.BadConfig.selector);
        new MonthBoard(c);
        c = monthFactory.boardConfig();
        assertGt(address(new MonthBoard(c)).code.length, 20_000, "default config deploys");
    }

    function test_RevertWhen_VRFAdapterParamsInvalid() public {
        address coord = address(0xC00D);
        bytes32 kh = bytes32(uint256(1));
        vm.expectRevert(ChainlinkVRFAdapter.BadConfig.selector);
        new ChainlinkVRFAdapter(address(0), kh, 1, 3, 750_000, true, address(factory));
        vm.expectRevert(ChainlinkVRFAdapter.BadConfig.selector);
        new ChainlinkVRFAdapter(coord, kh, 1, 3, 750_000, true, address(0));
        vm.expectRevert(ChainlinkVRFAdapter.BadConfig.selector);
        new ChainlinkVRFAdapter(coord, kh, 1, 3, 0, true, address(factory));
        vm.expectRevert(ChainlinkVRFAdapter.BadConfig.selector);
        new ChainlinkVRFAdapter(coord, kh, 1, 2, 750_000, true, address(factory));
        vm.expectRevert(ChainlinkVRFAdapter.BadConfig.selector);
        new ChainlinkVRFAdapter(coord, kh, 1, 201, 750_000, true, address(factory));
        ChainlinkVRFAdapter ok = new ChainlinkVRFAdapter(coord, kh, 1, 200, 750_000, true, address(factory));
        assertEq(ok.requestConfirmations(), 200);
    }

    /// @dev 主网晶体管合约的协议费 getter 是 protocolFee()；mock 两个都有，值相同
    function test_MockTransistorsExposeProtocolFee() public view {
        assertEq(transistors.protocolFee(), transistors.PROTOCOL_FEE());
        assertEq(transistors.protocolFee(), 0.0001 ether);
    }
}

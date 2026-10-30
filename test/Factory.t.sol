// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Fixture} from "./utils/Fixture.sol";
import {TapeBoard} from "../src/TapeBoard.sol";
import {BoardFactory} from "../src/BoardFactory.sol";
import {GenesisSplitter} from "../src/GenesisSplitter.sol";
import {TapeSurgeDefaults} from "../script/TapeSurgeDefaults.sol";
import {BoardState} from "../src/interfaces/ITapeBoard.sol";

/// @notice 开局条件、主板编号、只认自己创建的主板、参数校验
contract FactoryTest is Fixture {
    function test_RevertWhen_GenesisConditionNotMet() public {
        vm.warp(block.timestamp + 7 days - 1);
        vm.expectRevert(BoardFactory.GenesisConditionNotMet.selector);
        factory.startGenesis();
    }

    /// @dev 开局前必须报过价（全局审计 G-1）：否则第一块标准局和月局会按默认曲线收购
    function test_RevertWhen_GenesisBeforeFirstPrice() public {
        vm.warp(block.timestamp + 7 days);
        vm.expectRevert(BoardFactory.FeedNotPosted.selector);
        factory.startGenesis();
        priceFeed.post(1, 1);
        factory.startGenesis();
        assertTrue(factory.genesisStarted());
    }

    function test_GenesisAfterSevenDays() public {
        TapeBoard b = _startGenesis();
        assertTrue(factory.genesisStarted());
        assertEq(b.number(), 1);
        assertEq(b.target(), 500 * BEM_1);
        assertEq(uint256(b.state()), uint256(BoardState.Recruiting));
        assertEq(b.recruitDeadline(), block.timestamp + 7 days);
        vm.expectRevert(BoardFactory.GenesisAlreadyStarted.selector);
        factory.startGenesis();
    }

    function test_GenesisWhenTenThousandTransistorsMinted() public {
        address whale = address(0xF00D);
        vm.deal(whale, 20 ether);
        vm.prank(whale);
        transistors.mint{value: 9_999 * 0.0011 ether}(0, 9_999);
        vm.expectRevert(BoardFactory.GenesisConditionNotMet.selector);
        factory.startGenesis();
        vm.prank(whale);
        transistors.mint{value: 0.0011 ether}(0, 1);
        vm.expectRevert(BoardFactory.FeedNotPosted.selector);
        factory.startGenesis();
        priceFeed.post(1, 1);
        address b = factory.startGenesis();
        assertEq(factory.boardByNumber(1), b);
        // 开局前先分账：10 BNB → 回购 4 / 项目方 1 / 基金会 2 / 回馈 3
        assertEq(splitter.buybackPool(), 4 ether);
        assertEq(splitter.rewardBucket(1), 1 ether);
        assertEq(FOUNDATION.balance, 2 ether);
        assertEq(FEE_SAFE.balance, 1 ether);
    }

    function test_NextBoardOpensWhenPreviousStarts() public {
        TapeBoard b1 = _startGenesis();
        assertEq(factory.recruitingBoard(), address(b1));
        _fillUniform(b1, 25, 20 * BEM_1);
        TapeBoard b2 = _board();
        assertEq(b2.number(), 2);
        assertEq(factory.boardByNumber(2), address(b2));
        assertEq(factory.numberOf(address(b2)), 2);
        assertTrue(factory.isBoard(address(b1)) && factory.isBoard(address(b2)));
        assertFalse(factory.isBoard(address(this)));
    }

    function test_OnlyRecruitingBoardCanReport() public {
        TapeBoard b1 = _startGenesis();
        vm.expectRevert(BoardFactory.OnlyRecruitingBoard.selector);
        factory.onBoardStarted(true, 0);
        vm.expectRevert(BoardFactory.OnlyRecruitingBoard.selector);
        factory.onBoardFailed();
        _fillUniform(b1, 25, 20 * BEM_1);
        vm.prank(address(b1)); // 已开局的主板不能再报告
        vm.expectRevert(BoardFactory.OnlyRecruitingBoard.selector);
        factory.onBoardStarted(true, 0);
    }

    function test_BoardsCannotBeReinitialized() public {
        TapeBoard b1 = _startGenesis();
        vm.expectRevert(TapeBoard.OnlyFactory.selector);
        b1.initialize(9, 500 * BEM_1, BEM_1, 20 * BEM_1);
        vm.prank(address(factory));
        vm.expectRevert(TapeBoard.AlreadyInitialized.selector);
        b1.initialize(9, 500 * BEM_1, BEM_1, 20 * BEM_1);
        TapeBoard impl = TapeBoard(factory.boardImplementation());
        vm.expectRevert(TapeBoard.OnlyFactory.selector);
        impl.initialize(1, 500 * BEM_1, BEM_1, 20 * BEM_1);
    }

    /// @dev 外部审计 #2 / #6 / #8 相关的默认参数
    function test_AuditDefaults() public view {
        assertEq(factory.boardConfig().sentinelResumeDelay, 30 days);
        assertEq(monthFactory.boardConfig().sentinelResumeDelay, 30 days);
        assertEq(splitter.maxSlippageBps(), 200, "mainnet default 2%");
        assertEq(TapeSurgeDefaults.MAINNET_MAX_SLIPPAGE_BPS, 200);
        assertEq(TapeSurgeDefaults.TESTNET_MAX_SLIPPAGE_BPS, 300, "testnet unchanged");
        assertEq(TapeSurgeDefaults.VRF_CALLBACK_GAS, 750_000);
    }

    function test_BoardConfigIsPublic() public view {
        TapeBoard.Config memory c = factory.boardConfig();
        assertEq(c.passCircuits, address(passCircuits));
        assertEq(c.splitter, address(splitter));
        assertEq(c.entryFeeBps, 100);
        assertEq(c.sellFloorBps, 6_000);
        assertEq(c.operatorGrace, 3 days);
        assertEq(c.claimWindow, 365 days);
        assertEq(factory.minStakeBps(), 20);
        assertEq(factory.maxStakeBps(), 400);
        (uint256 lo, uint256 hi) = factory.stakeRange(250 * BEM_1);
        assertEq(lo, 0.5e8);
        assertEq(hi, 10 * BEM_1);
    }

    function test_RevertWhen_BadTargetRules() public {
        BoardFactory.Params memory p = defaultParams();
        p.targets.maxStakeBps = 3_001; // 按 60% 开局时可能只有 1 个人
        _deploySplitter(defaultSplitterParams(), p);
        vm.expectRevert(BoardFactory.BadParams.selector);
        new BoardFactory(p);
        p = defaultParams();
        p.targets.initialTarget = 50 * BEM_1; // 低于下限
        _deploySplitter(defaultSplitterParams(), p);
        vm.expectRevert(BoardFactory.BadParams.selector);
        new BoardFactory(p);
    }

    /// @dev 分账合约是单独部署的：它记下的 boardFactory 必须正好是这个 BoardFactory
    function test_RevertWhen_SplitterBelongsToAnotherFactory() public {
        BoardFactory.Params memory p = defaultParams();
        GenesisSplitter.Params memory sp = defaultSplitterParams();
        sp.boardFactory = address(0xFAC7);
        p.splitter = address(new GenesisSplitter{value: 0.001 ether}(sp));
        vm.expectRevert(BoardFactory.BadParams.selector);
        new BoardFactory(p);
        p.splitter = address(0);
        vm.expectRevert(BoardFactory.BadParams.selector);
        new BoardFactory(p);
    }

    function test_SplitterIsWiredToFactory() public view {
        assertEq(splitter.boardFactory(), address(factory));
        assertEq(address(factory.splitter()), address(splitter));
        assertEq(address(factory.transistors()), address(splitter.transistors()));
        assertEq(factory.passCircuits(), splitter.circuits());
        assertEq(transistors.creator(), address(splitter));
    }
}

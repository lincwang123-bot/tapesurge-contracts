// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Fixture} from "./utils/Fixture.sol";
import {StdMachineSales} from "../src/StdMachineSales.sol";
import {TapeBoard} from "../src/TapeBoard.sol";
import {BoardState} from "../src/interfaces/ITapeBoard.sol";
import {MockCircuits} from "../src/mocks/MockCircuits.sol";
import {MockTransistors} from "../src/mocks/MockTapeOut.sol";

/// @notice 通行证校验、一地址一局、投入范围、入场费托管、招募结果与主板金额自动调整
contract RecruitTest is Fixture {
    TapeBoard internal b;

    function setUp() public override {
        super.setUp();
        b = _startGenesis();
    }

    // ---------------- 通行证 ----------------

    function test_PassNetlistHashMatchesWhitepaper() public view {
        assertEq(keccak256(PASS_NETLIST), PASS_HASH);
        assertEq(b.PASS_NETLIST_HASH(), PASS_HASH);
        assertEq(b.PASS_CIRCUITS(), factory.passCircuits());
        assertEq(PASS_NETLIST.length, 35);
    }

    function test_PassIsAHalfAdder() public {
        address u = _newUser();
        uint256 id = _mintPass(u);
        // 附录 B 自查向量：0x00→0x00，0x01→0x01，0x02→0x01，0x03→0x02（1 + 1 = 2）
        assertEq(passCircuits.eval(id, hex"00"), hex"00");
        assertEq(passCircuits.eval(id, hex"01"), hex"01");
        assertEq(passCircuits.eval(id, hex"02"), hex"01");
        assertEq(passCircuits.eval(id, hex"03"), hex"02");
        (uint32 nIn, uint32 nOut, uint32 nState, uint32 gates) = passCircuits.circuitInfo(id);
        assertEq(nIn, 2);
        assertEq(nOut, 2);
        assertEq(nState, 0);
        assertEq(gates, 5);
        // 流片烧掉了 5 颗 NAND
        assertEq(transistors.balanceOf(u, 0), 0);
    }

    function test_JoinWithStandardPassLocksPass() public {
        address u = _newUser();
        uint256 id = _mintPass(u);
        _approveAndJoin(b, u, id, 10 * BEM_1);
        assertEq(passCircuits.ownerOf(id), address(b));
        assertEq(b.holderCount(u), 1);
        assertEq(b.socket(1).owner, u);
        assertEq(positions.ownerOf(positions.idOf(address(b), 1)), u, "position NFT minted to the joiner");
        assertEq(b.totalStake(), 10 * BEM_1);
        assertEq(b.socket(1).passId, id);
    }

    function test_RevertWhen_NonStandardNetlist() public {
        address u = _newUser();
        // 同样 5 个 NAND，只是换了门的顺序：功能一样，但哈希对不上
        bytes memory nl = hex"0000000200000300000002000004000000030000040000000400000400000005000006";
        uint256 id = _mintCircuit(u, nl);
        bem.mint(u, 100 * BEM_1);
        vm.startPrank(u);
        passCircuits.approve(address(b), id);
        bem.approve(address(b), type(uint256).max);
        vm.expectRevert(TapeBoard.NotStandardPass.selector);
        b.join(id, 10 * BEM_1);
        vm.stopPrank();
    }

    function test_RevertWhen_PassFromAnotherProcessor() public {
        // 另一个处理器上流片了一模一样的半加器：主板只认创世处理器的电路合约
        (address otherTransistors, address otherCircuits) =
            tapeout.createCPU{value: 0.001 ether}("Other", "OTH", "", 1000, 0);
        address u = _newUser();
        vm.deal(u, 1 ether);
        vm.startPrank(u);
        MockTransistors(otherTransistors).mint{value: 0.0005 ether}(0, 5);
        MockCircuits(otherCircuits).tapeout{value: 0.0002 ether}(PASS_NETLIST, 2, 2);
        vm.stopPrank();
        // 别人在创世处理器上已经有 1 号通行证
        address other = _newUser();
        uint256 genesisId = _mintPass(other);
        assertEq(genesisId, 1);
        bem.mint(u, 100 * BEM_1);
        vm.startPrank(u);
        bem.approve(address(b), type(uint256).max);
        vm.expectRevert(TapeBoard.NotPassOwner.selector);
        b.join(1, 10 * BEM_1);
        vm.stopPrank();
    }

    function test_RevertWhen_NotPassOwner() public {
        address owner = _newUser();
        uint256 id = _mintPass(owner);
        address thief = _newUser();
        bem.mint(thief, 100 * BEM_1);
        vm.startPrank(thief);
        bem.approve(address(b), type(uint256).max);
        vm.expectRevert(TapeBoard.NotPassOwner.selector);
        b.join(id, 10 * BEM_1);
        vm.stopPrank();
    }

    function test_RevertWhen_SameAddressJoinsTwice() public {
        address u = _newUser();
        _approveAndJoin(b, u, _mintPass(u), 5 * BEM_1);
        uint256 id2 = _mintPass(u);
        vm.startPrank(u);
        passCircuits.approve(address(b), id2);
        vm.expectRevert(TapeBoard.AlreadyJoined.selector);
        b.join(id2, 5 * BEM_1);
        vm.stopPrank();
    }

    function test_PassReusableInNextBoardAfterRefund() public {
        address u = _newUser();
        uint256 id = _mintPass(u);
        _approveAndJoin(b, u, id, 5 * BEM_1);
        vm.warp(block.timestamp + 7 days);
        b.closeRecruitment();
        b.returnPass(1);
        assertEq(passCircuits.ownerOf(id), u);
        TapeBoard b2 = _board();
        _approveAndJoin(b2, u, id, 5 * BEM_1);
        assertEq(passCircuits.ownerOf(id), address(b2));
    }

    // ---------------- 投入范围与入场费 ----------------

    function test_StakeRangeIsPointTwoToFourPercentOfTarget() public view {
        assertEq(b.target(), 500 * BEM_1);
        assertEq(b.minStake(), 1 * BEM_1);
        assertEq(b.maxStake(), 20 * BEM_1);
    }

    function test_FractionalStakeAccepted() public {
        _join(b, 1.5e8);
        _join(b, 19.99e8);
        assertEq(b.totalStake(), 1.5e8 + 19.99e8);
        assertEq(b.totalEntryFees(), 1.5e6 + 19.99e6);
    }

    function test_RevertWhen_StakeOutOfRange() public {
        address u = _newUser();
        uint256 id = _mintPass(u);
        bem.mint(u, 100 * BEM_1);
        vm.startPrank(u);
        passCircuits.approve(address(b), id);
        bem.approve(address(b), type(uint256).max);
        vm.expectRevert(TapeBoard.BadAmount.selector);
        b.join(id, 0.99e8);
        vm.expectRevert(TapeBoard.BadAmount.selector);
        b.join(id, 20.01e8);
        vm.expectRevert(TapeBoard.BadAmount.selector);
        b.join(id, 0);
        vm.stopPrank();
    }

    function test_EntryFeeHeldInBoardUntilStart() public {
        address u = _join(b, 20 * BEM_1);
        // 投 20 BEM 实际付 20.2 BEM（入场费 1%），入场费先留在主板
        assertEq(bem.balanceOf(u), 40 * BEM_1 - 20.2e8);
        assertEq(bem.balanceOf(address(b)), 20.2e8);
        assertEq(bem.balanceOf(FEE_SAFE), 0);
        _fillUniform(b, 24, 20 * BEM_1);
        assertEq(uint256(b.state()), uint256(BoardState.Active));
        // 开局后入场费一次转给手续费地址
        assertEq(bem.balanceOf(FEE_SAFE), 5 * BEM_1);
        assertEq(bem.balanceOf(address(b)), 500 * BEM_1);
        assertEq(b.budget(), 500 * BEM_1);
    }

    function test_LastJoinCappedToRemaining() public {
        _fillUniform(b, 24, 20 * BEM_1);
        _join(b, 15 * BEM_1); // 495
        address last = _newUser();
        uint256 id = _mintPass(last);
        _approveAndJoin(b, last, id, 20 * BEM_1);
        // 只接受到恰好满额：5 BEM + 0.05 BEM 入场费
        assertEq(b.socket(b.socketCount()).owner, last);
        assertEq(b.socket(b.socketCount()).stake, 5 * BEM_1);
        assertEq(bem.balanceOf(last), 40 * BEM_1 - 5.05e8);
        assertEq(b.totalStake(), 500 * BEM_1);
        assertEq(uint256(b.state()), uint256(BoardState.Active));
    }

    function test_ExactRemainderBelowMinimumAccepted() public {
        _fillUniform(b, 24, 20 * BEM_1);
        _join(b, 19.5e8); // 剩 0.5 BEM，小于最小投入 1 BEM
        _join(b, 0.5e8);
        assertEq(b.totalStake(), 500 * BEM_1);
        assertEq(uint256(b.state()), uint256(BoardState.Active));
    }

    // ---------------- 招募结果 ----------------

    function test_FailedRecruitmentRefundsStakeFeeAndPass() public {
        address u1 = _newUser();
        uint256 id1 = _mintPass(u1);
        _approveAndJoin(b, u1, id1, 20 * BEM_1);
        address u2 = _join(b, 7.5e8);
        vm.warp(block.timestamp + 7 days);
        vm.expectRevert(TapeBoard.RecruitmentClosed.selector);
        vm.prank(u2);
        b.join(1, BEM_1);

        b.closeRecruitment();
        assertEq(uint256(b.state()), uint256(BoardState.Failed));
        assertEq(stdSales.owed(address(b), 1), 20.2e8);
        // 任何人都可以替参与者领取，钱只打给参与者本人
        b.withdraw(1);
        b.returnPass(1);
        assertEq(bem.balanceOf(u1), 40 * BEM_1);
        assertEq(passCircuits.ownerOf(id1), u1);
        stdSales.claimAll(address(b), 2);
        assertEq(bem.balanceOf(u2), 15 * BEM_1);
        assertEq(bem.balanceOf(address(b)), 0);
        vm.expectRevert(TapeBoard.NothingToWithdraw.selector);
        b.withdraw(1);

        // 自动重开第 1 块，目标 × 0.5
        TapeBoard b2 = _board();
        assertTrue(address(b2) != address(b));
        assertEq(b2.number(), 1);
        assertEq(factory.boardByNumber(1), address(b2));
        assertEq(factory.attemptsOf(1), 2);
        assertEq(b2.target(), 250 * BEM_1);
        assertEq(b2.minStake(), 0.5e8);
        assertEq(b2.maxStake(), 10 * BEM_1);
    }

    function test_CannotCloseBeforeDeadline() public {
        _join(b, 20 * BEM_1);
        vm.warp(block.timestamp + 7 days - 1);
        vm.expectRevert(TapeBoard.CannotClose.selector);
        b.closeRecruitment();
    }

    function test_PartialStartAtSixtyPercent() public {
        _fillUniform(b, 15, 20 * BEM_1); // 300 BEM = 60%
        vm.warp(block.timestamp + 7 days);
        b.closeRecruitment();
        assertEq(uint256(b.state()), uint256(BoardState.Active));
        assertEq(b.budget(), 300 * BEM_1);
        assertEq(bem.balanceOf(FEE_SAFE), 3 * BEM_1);
        TapeBoard b2 = _board();
        assertEq(b2.number(), 2);
        assertEq(b2.target(), 375 * BEM_1); // × 0.75
    }

    function test_BelowSixtyPercentFails() public {
        _fillUniform(b, 14, 20 * BEM_1);
        _join(b, 19.99e8); // 299.99 BEM < 60%
        vm.warp(block.timestamp + 7 days);
        b.closeRecruitment();
        assertEq(uint256(b.state()), uint256(BoardState.Failed));
    }

    function test_FastFillGrowsTargetUpToCap() public {
        uint256[5] memory expected = [uint256(625), 781, 976, 1000, 1000];
        TapeBoard cur = b;
        for (uint256 i = 0; i < expected.length; i++) {
            _fillToTarget(cur);
            cur = _board();
            assertEq(cur.target(), expected[i] * BEM_1, "target");
            assertEq(cur.number(), i + 2);
        }
        // 1,000 BEM 时投入范围为 2–40 BEM
        assertEq(cur.minStake(), 2 * BEM_1);
        assertEq(cur.maxStake(), 40 * BEM_1);
    }

    function test_FillAfterTwoDaysKeepsTarget() public {
        vm.warp(block.timestamp + 2 days);
        _fillToTarget(b);
        assertEq(_board().target(), 500 * BEM_1);
    }

    function test_FailuresShrinkTargetToFloor() public {
        uint256[4] memory expected = [uint256(250), 125, 100, 100];
        for (uint256 i = 0; i < expected.length; i++) {
            TapeBoard cur = _board();
            vm.warp(block.timestamp + 7 days);
            cur.closeRecruitment();
            assertEq(_board().target(), expected[i] * BEM_1);
            assertEq(_board().number(), 1);
        }
        // 100 BEM 时投入范围为 0.2–4 BEM
        assertEq(_board().minStake(), 0.2e8);
        assertEq(_board().maxStake(), 4 * BEM_1);
    }

    function test_NumberingCountsOnlyStartedBoards() public {
        vm.warp(block.timestamp + 7 days);
        b.closeRecruitment();
        TapeBoard retry = _board();
        _fillToTarget(retry);
        assertEq(factory.boardByNumber(1), address(retry));
        assertEq(_board().number(), 2);
        assertTrue(factory.isBoard(address(b)));
        assertEq(factory.boardCount(), 3);
    }

    function test_Params1000With20Cap() public {
        _deploySystem(params1000());
        TapeBoard big = _startGenesis();
        assertEq(big.target(), 1_000 * BEM_1);
        assertEq(big.minStake(), BEM_1);
        assertEq(big.maxStake(), 20 * BEM_1);
        _fillUniform(big, 50, 20 * BEM_1);
        assertEq(uint256(big.state()), uint256(BoardState.Active));
        assertEq(bem.balanceOf(FEE_SAFE), 10 * BEM_1);
        // 2 天内招满：下一块 1,000 × 1.25 封顶 1,000
        assertEq(_board().target(), 1_000 * BEM_1);
    }

    function test_FailedRefundsDistributedByOperator() public {
        address u1 = _join(b, 20 * BEM_1);
        address u2 = _join(b, 5 * BEM_1);
        vm.warp(block.timestamp + 7 days);
        b.closeRecruitment();
        vm.prank(u1); // 参与者 3 天内不能代替运营地址分发（rc6 起分批发放在 StdMachineSales）
        vm.expectRevert(StdMachineSales.NotAuthorized.selector);
        stdSales.distribute(address(b), 1, 2);
        vm.warp(block.timestamp + 3 days);
        vm.prank(address(0xBAD)); // 外人始终不行
        vm.expectRevert(StdMachineSales.NotAuthorized.selector);
        stdSales.distribute(address(b), 1, 2);
        vm.prank(u1); // 3 天后参与者兜底
        stdSales.distribute(address(b), 1, 2);
        assertEq(bem.balanceOf(u1), 40 * BEM_1);
        assertEq(bem.balanceOf(u2), 10 * BEM_1);
        assertEq(passCircuits.ownerOf(b.socket(1).passId), u1);
        assertEq(passCircuits.ownerOf(b.socket(2).passId), u2);
        stdSales.distribute(address(b), 1, 2); // 运营地址重复调用：没有可领的，跳过
        assertEq(bem.balanceOf(address(b)), 0);
    }

    function _fillToTarget(TapeBoard cur) internal {
        uint256 maxS = cur.maxStake();
        while (cur.state() == BoardState.Recruiting) {
            _join(cur, maxS);
        }
    }
}

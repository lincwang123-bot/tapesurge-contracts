// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Fixture} from "./utils/Fixture.sol";
import {TapeBoard} from "../src/TapeBoard.sol";
import {BoardState, SettleMode} from "../src/interfaces/ITapeBoard.sol";
import {BoardFactory} from "../src/BoardFactory.sol";

/// @notice 开奖门槛、出局分配 95 / 3 / 2（没有调用者奖励）、VRF 超时、硅王
contract DrawTest is Fixture {
    TapeBoard internal b;
    address[] internal players;
    address internal keeper = address(0xBEEF);

    function setUp() public override {
        super.setUp();
        b = _startGenesis();
        // 20 人各投 20 BEM + 20 人各投 5 BEM = 500 BEM
        address[] memory a = _fillUniform(b, 20, 20 * BEM_1);
        address[] memory c = _fillUniform(b, 20, 5 * BEM_1);
        for (uint256 i = 0; i < a.length; i++) {
            players.push(a[i]);
        }
        for (uint256 i = 0; i < c.length; i++) {
            players.push(c[i]);
        }
        assertEq(uint256(b.state()), uint256(BoardState.Active));
        _sell(b, _newUser(), 200);
    }

    /// @dev 找一个会抽中 slot 的随机数
    function _wordFor(uint256 slot) internal view returns (uint256 w) {
        for (uint256 i = 0; i < 20_000; i++) {
            w = uint256(keccak256(abi.encode("word", i)));
            if (b.previewEject(w) == slot) return w;
        }
        revert("no word");
    }

    function test_ThresholdIsMaxStakeTimes105Over95() public view {
        assertEq(b.maxAliveStake(), 20 * BEM_1);
        assertEq(b.drawThreshold(), 2_210_526_316); // 21 ÷ 0.95 = 22.10526316 BEM
        assertEq(b.drawThreshold(), _gross(20 * BEM_1));
    }

    function test_RevertWhen_PoolBelowThreshold() public {
        _yield(b, 0, b.drawThreshold() - 1);
        vm.expectRevert(TapeBoard.BelowThreshold.selector);
        b.pulse();
        _yield(b, 0, 1);
        b.pulse();
        assertTrue(b.drawPending());
        vm.expectRevert(TapeBoard.DrawAlreadyPending.selector);
        b.pulse();
    }

    function test_EjectionPushes105ReturnsPassAndSplits95_3_2() public {
        uint256 slot = 3; // 投 20 BEM 的人
        address p = b.socket(slot).owner;
        uint256 passId = b.socket(slot).passId;
        uint256 balBefore = bem.balanceOf(p);
        _topUpPool(b);
        b.harvest();
        uint256 poolBefore = b.pool();
        b.pulse(); // 测试合约是运营地址
        rng.fulfill(b.pendingRequestId(), _wordFor(slot));

        uint256 gross = _gross(20 * BEM_1);
        assertTrue(b.socket(slot).ejected);
        // 105% 直接推送给出局者，通行证同时退还
        assertEq(bem.balanceOf(p) - balBefore, 21 * BEM_1);
        assertEq(b.credit(p), 0);
        assertEq(passCircuits.ownerOf(passId), p);
        assertTrue(b.socket(slot).passReturned);
        // 3% 基金会，2% 全部给手续费 Safe（不再有调用者奖励）
        assertEq(b.credit(FOUNDATION), gross * 300 / 10_000);
        assertEq(b.credit(FEE_SAFE), gross - 21 * BEM_1 - gross * 300 / 10_000);
        assertEq(b.credit(address(this)), 0, "no caller reward");
        assertApproxEqAbs(b.credit(FEE_SAFE) * 10_000 / gross, 200, 1);
        assertEq(b.pool(), poolBefore - gross);
        assertEq(b.aliveCount(), 39);
        assertEq(b.aliveStake(), 480 * BEM_1);
        assertEq(b.liabilities(), gross - 21 * BEM_1, "only fee credits remain");
        // 已经推送过，自领没有可领的（持仓和地址记账两边都没有）
        vm.expectRevert(TapeBoard.NothingToWithdraw.selector);
        b.withdraw(slot);
        vm.expectRevert(TapeBoard.NothingToWithdraw.selector);
        b.withdrawCredit(p);
        vm.expectRevert(TapeBoard.PassAlreadyReturned.selector);
        b.returnPass(slot);
    }

    function test_SmallStakeEjection() public {
        uint256 slot = 30; // 投 5 BEM 的人
        address p = b.socket(slot).owner;
        uint256 balBefore = bem.balanceOf(p);
        _topUpPool(b);
        b.pulse();
        rng.fulfill(b.pendingRequestId(), _wordFor(slot));
        assertEq(bem.balanceOf(p) - balBefore, 5.25e8);
    }

    function test_ThresholdFollowsRemainingMaxStake() public {
        // 把 20 个投 20 BEM 的人全部抽走后，门槛降到 5 × 1.05 ÷ 0.95
        for (uint256 slot = 1; slot <= 20; slot++) {
            _topUpPool(b);
            b.pulse();
            rng.fulfill(b.pendingRequestId(), _wordFor(slot));
        }
        assertEq(b.maxAliveStake(), 5 * BEM_1);
        assertEq(b.drawThreshold(), _gross(5 * BEM_1));
    }

    function test_RandomnessOnlyFromSourceAndOnlyLatestRequest() public {
        _topUpPool(b);
        b.pulse();
        uint256 id = b.pendingRequestId();
        vm.expectRevert(TapeBoard.OnlyRandomSource.selector);
        b.onRandomness(id, 1);
        // 错误的请求编号：忽略
        vm.prank(address(rng));
        b.onRandomness(id + 7, 1);
        assertTrue(b.drawPending());
        assertEq(b.aliveCount(), 40);
        rng.fulfill(id, 1);
        assertEq(b.aliveCount(), 39);
        // 重复回调：忽略
        rng.fulfill(id, 2);
        assertEq(b.aliveCount(), 39);
    }

    function test_RetryOnlyAfter24HoursAndOldRequestStillCounts() public {
        _topUpPool(b);
        b.pulse();
        uint256 oldId = b.pendingRequestId();
        vm.expectRevert(TapeBoard.TooEarly.selector);
        b.retryDraw();
        vm.warp(block.timestamp + 1 days - 1);
        vm.expectRevert(TapeBoard.TooEarly.selector);
        b.retryDraw();
        vm.warp(block.timestamp + 1);
        // 24 小时后只有运营地址能重发；参与者还要再等 3 天，外人始终不行
        address player = b.socket(1).owner;
        vm.prank(player);
        vm.expectRevert(TapeBoard.NotAuthorized.selector);
        b.retryDraw();
        b.retryDraw();
        uint256 newId = b.pendingRequestId();
        assertTrue(newId != oldId);
        // 审计 M-3：重发不作废已在路上的结果——同一次开奖的旧请求先到就用它，之后的新请求回调被忽略（只出局一人）
        rng.fulfill(oldId, 123);
        assertEq(b.aliveCount(), 39);
        assertFalse(b.drawPending());
        rng.fulfill(newId, 456);
        assertEq(b.aliveCount(), 39);
        // 下一次开奖开始后，上一次开奖的请求不再有效
        _topUpPool(b);
        b.pulse();
        uint256 nextId = b.pendingRequestId();
        rng.fulfill(newId, 789);
        assertEq(b.aliveCount(), 39, "a request from the previous draw is ignored");
        rng.fulfill(nextId, 789);
        assertEq(b.aliveCount(), 38);
    }

    function test_ParticipantCanRetryThreeDaysAfterRetryBecomesPossible() public {
        _topUpPool(b);
        b.pulse();
        address player = b.socket(1).owner;
        vm.warp(block.timestamp + 1 days + 3 days - 1);
        vm.prank(player);
        vm.expectRevert(TapeBoard.NotAuthorized.selector);
        b.retryDraw();
        vm.warp(block.timestamp + 1);
        vm.prank(keeper); // 外人
        vm.expectRevert(TapeBoard.NotAuthorized.selector);
        b.retryDraw();
        vm.prank(player);
        b.retryDraw();
        assertEq(b.pendingRequestId(), 2);
    }

    // ---------------- 运营地址专属 + 参与者 3 天兜底 ----------------

    function test_PulseIsOperatorOnly() public {
        _topUpPool(b);
        address player = b.socket(1).owner;
        vm.prank(player);
        vm.expectRevert(TapeBoard.NotAuthorized.selector);
        b.pulse();
        vm.prank(keeper);
        vm.expectRevert(TapeBoard.NotAuthorized.selector);
        b.pulse();
        b.pulse(); // 运营地址
        assertTrue(b.drawPending());
    }

    function test_ParticipantFallbackThreeDaysAfterLastPulse() public {
        _topUpPool(b);
        _pulseAndFulfill(b, uint256(keccak256("first")));
        uint256 last = b.lastPulseAt();
        _topUpPool(b);
        address player = b.socket(1).owner == address(0) ? b.socket(2).owner : b.socket(1).owner;
        vm.warp(last + 3 days - 1);
        vm.prank(player);
        vm.expectRevert(TapeBoard.NotAuthorized.selector);
        b.pulse();
        vm.warp(last + 3 days);
        // 外人在 3 天后仍然不行
        vm.prank(keeper);
        vm.expectRevert(TapeBoard.NotAuthorized.selector);
        b.pulse();
        // 本局参与者（包括已出局的人）可以兜底
        vm.prank(player);
        b.pulse();
        assertTrue(b.drawPending());
    }

    function test_FeeSafeChangesOperatorAndZeroOperatorLetsParticipantsAct() public {
        vm.prank(keeper);
        vm.expectRevert(BoardFactory.OnlyFeeSafe.selector);
        factory.setOperator(keeper);
        vm.expectEmit(true, true, false, false, address(factory));
        emit BoardFactory.OperatorChanged(address(this), keeper);
        vm.prank(FEE_SAFE);
        factory.setOperator(keeper);
        assertEq(factory.operator(), keeper);
        _topUpPool(b);
        vm.expectRevert(TapeBoard.NotAuthorized.selector);
        b.pulse(); // 旧运营地址失效
        // 运营地址设成 0：只剩参与者，随时可以推进
        vm.prank(FEE_SAFE);
        factory.setOperator(address(0));
        vm.prank(b.socket(5).owner);
        b.pulse();
        assertTrue(b.drawPending());
    }

    function test_SafeExitAfterSevenDaysWithoutVrf() public {
        _topUpPool(b);
        b.pulse();
        vm.expectRevert(TapeBoard.TooEarly.selector);
        b.triggerSafeExit();
        vm.warp(block.timestamp + 1 days);
        b.retryDraw(); // 重发不会重置 7 天的计时
        vm.warp(block.timestamp + 6 days - 1);
        vm.expectRevert(TapeBoard.TooEarly.selector);
        b.triggerSafeExit();
        vm.warp(block.timestamp + 1);
        b.triggerSafeExit();
        assertEq(uint256(b.state()), uint256(BoardState.Liquidating));
        assertEq(uint256(b.settleMode()), uint256(SettleMode.SafeExit));
        // 停摆后的回调一律作废
        rng.fulfill(b.pendingRequestId(), 5);
        assertEq(b.aliveCount(), 40);
    }

    function test_RevertWhen_SafeExitWithoutPendingDraw() public {
        vm.expectRevert(TapeBoard.NoPendingDraw.selector);
        b.triggerSafeExit();
        vm.expectRevert(TapeBoard.NoPendingDraw.selector);
        b.retryDraw();
    }

    function test_KingCrownedThenPaid105ThenNormalFinale() public {
        _drawUntilKing(b, 42);
        uint256 kingSlot = b.kingSocket();
        assertTrue(kingSlot != 0);
        assertFalse(b.socket(kingSlot).ejected);
        address king = b.socket(kingSlot).owner;
        uint256 kingStake = b.socket(kingSlot).stake;
        assertEq(b.aliveCount(), 1);
        assertEq(b.drawThreshold(), _gross(kingStake));
        // 硅王不再抽签：脉冲池够付他的 105% 时直接推送给他
        _topUpPool(b);
        uint256 kingBal = bem.balanceOf(king);
        b.pulse();
        assertTrue(b.kingPaid());
        assertEq(uint256(b.state()), uint256(BoardState.Liquidating));
        assertEq(uint256(b.settleMode()), uint256(SettleMode.Normal));
        assertEq(bem.balanceOf(king) - kingBal, kingStake * 10_500 / 10_000);
    }

    function test_EveryoneEjectedExactlyOnce() public {
        _drawUntilKing(b, 7);
        uint256 ejected;
        for (uint256 s = 1; s <= 40; s++) {
            if (b.socket(s).ejected) ejected++;
        }
        assertEq(ejected, 39);
        assertEq(b.aliveStake(), b.socket(b.kingSocket()).stake);
    }

    // ---------------- 推送失败时的兜底（VRF 回调不能失败） ----------------

    function test_EjectionSucceedsWhenPassReturnFails() public {
        uint256 slot = 3;
        address p = b.socket(slot).owner;
        uint256 passId = b.socket(slot).passId;
        vm.mockCallRevert(
            address(passCircuits),
            abi.encodeWithSelector(passCircuits.transferFrom.selector, address(b), p, passId),
            "paused"
        );
        _topUpPool(b);
        b.pulse();
        rng.fulfill(b.pendingRequestId(), _wordFor(slot));
        assertTrue(b.socket(slot).ejected, "callback still succeeded");
        assertFalse(b.socket(slot).passReturned);
        assertEq(passCircuits.ownerOf(passId), address(b));
        vm.clearMockedCalls();
        b.returnPass(slot); // 本人之后自领
        assertEq(passCircuits.ownerOf(passId), p);
    }

    function test_EjectionFallsBackToCreditWhenPushFails() public {
        uint256 slot = 3;
        address p = b.socket(slot).owner;
        vm.mockCallRevert(address(bem), abi.encodeWithSelector(bem.transfer.selector, p, 21 * BEM_1), "blocked");
        _topUpPool(b);
        b.pulse();
        rng.fulfill(b.pendingRequestId(), _wordFor(slot));
        assertTrue(b.socket(slot).ejected);
        assertEq(b.credit(p), 21 * BEM_1, "kept as credit");
        vm.clearMockedCalls();
        uint256 bal = bem.balanceOf(p);
        b.withdrawCredit(p); // 推送失败的 105% 记在地址上（rc6 起用 withdrawCredit 领）
        assertEq(bem.balanceOf(p) - bal, 21 * BEM_1);
    }
}

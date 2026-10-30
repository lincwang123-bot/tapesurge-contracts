// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {StdMachineSales} from "../src/StdMachineSales.sol";
import {Fixture} from "./utils/Fixture.sol";
import {TapeBoard} from "../src/TapeBoard.sol";
import {BoardState, SettleMode} from "../src/interfaces/ITapeBoard.sol";

/// @notice 终局拍卖与底池分配：正常终局 65 / 30 / 3 / 2、最长期限保底、VRF 安全退出、领取期限
contract SettlementTest is Fixture {
    TapeBoard internal b;
    address internal keeper = address(0xBEEF);
    address internal buyer = address(0xB0B);
    uint256 internal constant N = 40;

    function setUp() public override {
        super.setUp();
        b = _startGenesis();
        _fillUniform(b, 20, 20 * BEM_1);
        _fillUniform(b, 20, 5 * BEM_1);
        _sell(b, _newUser(), 200);
        bem.mint(buyer, 10_000 * BEM_1);
        vm.prank(buyer);
        bem.approve(address(b), type(uint256).max);
    }

    function _owner(uint256 slot) internal view returns (address) {
        return b.socket(slot).owner;
    }

    function _stake(uint256 slot) internal view returns (uint256) {
        return b.socket(slot).stake;
    }

    function _finishNormally() internal {
        _drawUntilKing(b, 99);
        _topUpPool(b);
        b.pulse();
        assertEq(uint256(b.settleMode()), uint256(SettleMode.Normal));
    }

    /// @dev 第 30 天起降价拍卖，再过 14 天降到底价时买走第 0 台
    function _buyMachineAtFloor() internal returns (uint256 cost) {
        vm.warp(b.liquidationStart() + 30 days);
        stdSales.startAuction(address(b));
        vm.warp(block.timestamp + 14 days);
        cost = _stdBuy(b, 0, buyer);
        assertEq(cost, uint256(b.machine(0).weight) * b.sellFloorPrice(), "floor");
    }

    /// @dev 买走第 0 台矿机（市价期报价无效时先按底价报价，经 StdMachineSales）
    function _buyMachine() internal returns (uint256 cost) {
        cost = _stdBuy(b, 0, buyer);
    }

    // ---------------- 终局拍卖 ----------------

    /// @dev 第 30 天起降价拍卖；报价无效时起价 = 采购均价 × 150%，14 天降到 60%，底价停 7 天后循环
    function test_SellAuctionDecaysToFloorThenRestarts() public {
        _finishNormally();
        uint256 avg = b.totalSpent() / b.totalWeightBought();
        uint256 start = avg * 15_000 / 10_000;
        uint256 floor = avg * 6_000 / 10_000;
        assertEq(b.sellStartPrice(), start);
        assertEq(b.sellFloorPrice(), floor);
        (uint256 p, uint8 phase) = stdSales.askPrice(address(b), 0);
        assertEq(phase, 0, "market period without a fresh feed: not for sale");
        vm.warp(b.liquidationStart() + 30 days);
        stdSales.startAuction(address(b));
        (p, phase) = stdSales.askPrice(address(b), 0);
        assertEq(phase, 2);
        assertEq(p, start);
        vm.warp(block.timestamp + 7 days);
        (p,) = stdSales.askPrice(address(b), 0);
        assertEq(p, start - (start - floor) / 2);
        vm.warp(block.timestamp + 7 days);
        (p,) = stdSales.askPrice(address(b), 0);
        assertEq(p, floor);
        vm.warp(block.timestamp + 7 days - 1);
        (p,) = stdSales.askPrice(address(b), 0);
        assertEq(p, floor); // 在底价停留 7 天
        vm.warp(block.timestamp + 1);
        (p,) = stdSales.askPrice(address(b), 0);
        assertEq(p, start); // 重新开始下一轮拍卖
    }

    function test_BuyMachineTransfersNftAndKeepsPendingYieldForPot() public {
        _finishNormally();
        bytes32 key = b.machine(0).key;
        pod.addYield(key, 4 * BEM_1);
        uint256 price = b.sellFloorPrice();
        _postPrices(price, price); // 测试合约是运营地址：卖价 = max(买一, 卖一 × 99%) = 买一
        vm.startPrank(buyer);
        bem.approve(address(stdSales), type(uint256).max);
        vm.expectRevert(StdMachineSales.PriceAboveMaximum.selector);
        stdSales.buyMachine(address(b), 0, price - 1);
        vm.stopPrank();
        uint256 allocatedBefore = b.potAllocated();
        uint256 cost = _buyMachine();
        assertEq(cost, 200 * price);
        assertEq(machines.ownerOf(b.machine(0).circuitId), buyer);
        // 卖出前的产出和卖出所得都并入底池
        assertEq(b.potAllocated() - allocatedBefore, cost + 4 * BEM_1);
        assertEq(b.unsoldMachines(), 0);
        assertEq(b.finishedAt(), block.timestamp);
        vm.prank(buyer);
        vm.expectRevert(StdMachineSales.AlreadySold.selector);
        stdSales.buyMachine(address(b), 0, type(uint256).max);
        vm.expectRevert(TapeBoard.NotAuthorized.selector); // 主板交割只认卖矿单例
        b.releaseMachine(0, buyer, 1, 0);
    }

    function test_UnsoldMachineKeepsMiningIntoPot() public {
        _finishNormally();
        uint256 kingSlot = b.kingSocket();
        uint256 kingBefore = _owedOf(b, _owner(kingSlot));
        uint256 p1Before = _owedOf(b, _owner(kingSlot == 1 ? 2 : 1));
        uint256 feeBefore = b.credit(FEE_SAFE);
        _yield(b, 0, 10 * BEM_1);
        vm.prank(keeper); // harvest 任何人可调，没有调用者奖励
        b.harvest();
        // 30% 给硅王，65% 按投入分给其余人，2% 全部给手续费 Safe
        assertApproxEqAbs(_owedOf(b, _owner(kingSlot)) - kingBefore, 3 * BEM_1, 1);
        uint256 restStake = 500 * BEM_1 - _stake(kingSlot);
        uint256 slot = kingSlot == 1 ? 2 : 1;
        assertApproxEqAbs(_owedOf(b, _owner(slot)) - p1Before, 6.5e8 * _stake(slot) / restStake, 1);
        assertEq(b.credit(keeper), 0, "no caller reward");
        assertEq(b.credit(FEE_SAFE) - feeBefore, 10 * BEM_1 * 200 / 10_000);
    }

    /// @dev 审计 #4：在 PoD 上暂时未验证的矿机按收购时的权重 × 底价出售，不会被 0 价拿走
    function test_RevokedMachineSellsAtFloorNotFree() public {
        _finishNormally();
        pod.revoke(b.machine(0).key);
        uint256 expected = uint256(b.machine(0).weight) * b.sellFloorPrice();
        assertGt(expected, 0);
        assertEq(_buyMachine(), expected);
        assertEq(machines.ownerOf(b.machine(0).circuitId), buyer);
    }

    // ---------------- 正常终局 65 / 30 / 3 / 2 ----------------

    function test_NormalFinaleSplitsPot65_30_3_2() public {
        // 记下每个人加入后的余额：出局时 105% 直接推送
        uint256[] memory bal0 = new uint256[](N + 1);
        for (uint256 s = 1; s <= N; s++) {
            bal0[s] = bem.balanceOf(_owner(s));
        }
        _drawUntilKing(b, 99);
        uint256 kingSlot = b.kingSocket();
        address king = _owner(kingSlot);
        uint256 kingStake = _stake(kingSlot);
        for (uint256 s = 1; s <= N; s++) {
            if (s == kingSlot) continue;
            assertEq(bem.balanceOf(_owner(s)) - bal0[s], _stake(s) * 10_500 / 10_000, "105% pushed on ejection");
            assertEq(passCircuits.ownerOf(b.socket(s).passId), _owner(s), "pass returned on ejection");
            assertEq(b.credit(_owner(s)), 0);
        }
        uint256 foundationBefore = b.credit(FOUNDATION);
        uint256 feeBefore = b.credit(FEE_SAFE);

        // 运营地址推动最后一次脉冲：硅王拿 105%（推送），然后进入终局
        _topUpPool(b);
        b.pulse();
        assertEq(uint256(b.settleMode()), uint256(SettleMode.Normal));
        uint256 kGross = _gross(kingStake);
        uint256 kPayout = kingStake * 10_500 / 10_000;
        uint256 kFoundation = kGross * 300 / 10_000;
        uint256 kFee = kGross - kPayout - kFoundation;
        assertEq(bem.balanceOf(king) - bal0[kingSlot], kPayout);

        vm.warp(block.timestamp + 3 days);
        _buyMachine();
        uint256 pot = b.potAllocated();
        assertGt(pot, 0);

        uint256 restStake = 500 * BEM_1 - kingStake;
        for (uint256 s = 1; s <= N; s++) {
            uint256 potShare = _owedOf(b, _owner(s));
            if (s == kingSlot) {
                assertApproxEqAbs(potShare, pot * 3_000 / 10_000, 1, "king 30%");
            } else {
                assertApproxEqAbs(potShare, pot * 6_500 / 10_000 * _stake(s) / restStake, 2, "65% pro rata");
            }
        }
        assertApproxEqAbs(b.credit(FOUNDATION) - foundationBefore - kFoundation, pot * 300 / 10_000, 1, "foundation 3%");
        assertApproxEqAbs(b.credit(FEE_SAFE) - feeBefore - kFee, pot * 200 / 10_000, 1, "fee 2%");
        assertEq(b.credit(buyer) + b.credit(address(this)), 0, "no caller reward");

        // 运营地址分批推送；之后自领拿到 0；合约里只剩取整尘埃
        stdSales.distribute(address(b), 1, 15);
        stdSales.distribute(address(b), 16, 100);
        for (uint256 s = 1; s <= N; s++) {
            uint256 balBefore = bem.balanceOf(_owner(s));
            stdSales.claimAll(address(b), s);
            assertEq(bem.balanceOf(_owner(s)), balBefore, "no double pay");
            assertEq(passCircuits.ownerOf(b.socket(s).passId), _owner(s));
        }
        b.withdrawCredit(FOUNDATION);
        b.withdrawCredit(FEE_SAFE);
        assertLe(bem.balanceOf(address(b)), N + 2);
        assertEq(b.liabilities(), bem.balanceOf(address(b)));
        assertApproxEqAbs(bem.balanceOf(king) - bal0[kingSlot], kPayout + pot * 3_000 / 10_000, 1);
    }

    // ---------------- 异常结局：统一保底公式、收 2% 手续费、不收 3% 基金会、无调用者奖励（规则决定 6.37）----------------

    struct Snap {
        uint256[] credits;
        uint256 foundation;
        uint256 fee;
        uint256 keeper;
        uint256 caller;
    }

    function _snap() internal view returns (Snap memory sn) {
        sn.credits = new uint256[](N + 1);
        for (uint256 s = 1; s <= N; s++) {
            sn.credits[s] = b.credit(_owner(s));
        }
        sn.foundation = b.credit(FOUNDATION);
        sn.fee = b.credit(FEE_SAFE);
        sn.keeper = b.credit(keeper);
        sn.caller = b.credit(address(this));
    }

    /// @dev 异常结局的分配：先收 2% 手续费（规则决定 6.37），其余先退未出局者投入（不够按比例），剩余全部按投入分给所有参与者；
    ///      基金会、调用者都没有新增记账；没有硅王奖。
    function _assertAbnormalSplit(Snap memory sn) internal view {
        uint256 gross = b.potAllocated();
        uint256 fee = b.credit(FEE_SAFE) - sn.fee;
        assertApproxEqAbs(fee, gross * 200 / 10_000, 10, "2% fee on the pot");
        uint256 pot = gross - fee;
        uint256 aliveStake = b.priorityStake();
        uint256 total = 500 * BEM_1;
        assertGt(pot, 0);
        for (uint256 s = 1; s <= N; s++) {
            uint256 got = _owedOf(b, _owner(s)) - sn.credits[s];
            uint256 expected;
            if (pot >= aliveStake) {
                uint256 proRata = (pot - aliveStake) * _stake(s) / total;
                expected = b.socket(s).ejected ? proRata : _stake(s) + proRata;
            } else {
                expected = b.socket(s).ejected ? 0 : pot * _stake(s) / aliveStake;
            }
            assertApproxEqAbs(got, expected, 2, "abnormal split");
        }
        assertEq(b.credit(FOUNDATION), sn.foundation, "no 3% foundation");
        assertEq(b.credit(keeper), sn.keeper, "no keeper reward");
        assertEq(b.credit(address(this)), sn.caller, "no caller reward");
        assertEq(b.credit(buyer), 0, "no buyer reward");
        assertEq(b.kingPot(), 0, "no king prize");
    }

    function _ejectSome(uint256 k, string memory tag) internal {
        for (uint256 i = 0; i < k; i++) {
            _topUpPool(b);
            _pulseAndFulfill(b, uint256(keccak256(abi.encode(tag, i))));
        }
    }

    function test_MaxDurationFallbackRefundsAliveFirstThenProRataAll() public {
        _ejectSome(10, "fb");
        vm.expectRevert(TapeBoard.NotExpired.selector);
        b.expire();
        vm.warp(b.startedAt() + 730 days);
        Snap memory sn = _snap();
        uint256 aliveStake = b.aliveStake();
        b.expire();
        assertEq(uint256(b.settleMode()), uint256(SettleMode.Fallback));
        assertEq(b.priorityStake(), aliveStake);

        // 以采购均价附近卖出矿机；拍卖期间 keeper 领取产出也没有奖励
        vm.warp(block.timestamp + 9 days + 8 hours);
        _yield(b, 0, 7 * BEM_1);
        vm.prank(keeper);
        b.harvest();
        _buyMachine();
        assertGt(b.potAllocated(), aliveStake, "pot covers alive principal");
        _assertAbnormalSplit(sn);
    }

    function test_FallbackProRataWhenPotBelowAlivePrincipal() public {
        vm.warp(b.startedAt() + 730 days);
        b.expire(); // 没人出局：40 人全部未出局，优先额 = 500 BEM
        // 矿机在底价卖出：底池不够退全部本金
        _buyMachineAtFloor();
        uint256 pot = b.potAllocated() - b.credit(FEE_SAFE); // 扣掉 2% 手续费（规则决定 6.37）
        assertLt(pot, 500 * BEM_1);
        for (uint256 s = 1; s <= N; s++) {
            assertApproxEqAbs(_owedOf(b, _owner(s)), pot * _stake(s) / (500 * BEM_1), 2, "pro rata principal");
        }
        assertEq(b.credit(FOUNDATION), 0); // 异常结局不收基金会 3%
    }

    function test_ExpireImmediatelyWhenNoMachineBought() public {
        // 新开一块主板，首轮收购一台都没买到
        TapeBoard nb = _board(); // 第 1 块 2 天内招满，第 2 块目标 625 BEM，单人最多 25 BEM
        uint256 maxS = nb.maxStake();
        _fillUniform(nb, 25, maxS);
        assertEq(uint256(nb.state()), uint256(BoardState.Active));
        vm.expectRevert(TapeBoard.NotExpired.selector);
        nb.expire();
        vm.warp(block.timestamp + 7 days);
        nb.expire();
        assertEq(uint256(nb.settleMode()), uint256(SettleMode.Fallback));
        // 本金扣 2% 手续费后退回（规则决定 6.37；入场费开局时已转给手续费地址）
        for (uint256 s = 1; s <= 25; s++) {
            assertApproxEqAbs(_owedOf(nb, nb.socket(s).owner), maxS * 9_800 / 10_000, 1);
        }
        assertEq(nb.finishedAt(), block.timestamp);
    }

    // ---------------- VRF 安全退出：与保底公式相同 ----------------

    function test_SafeExitRefundsAliveFirstThenProRataAll() public {
        _ejectSome(5, "se");
        _topUpPool(b);
        b.pulse(); // VRF 从此不再响应
        vm.warp(block.timestamp + 7 days);
        Snap memory sn = _snap();
        uint256 aliveStake = b.aliveStake();
        vm.prank(keeper);
        b.triggerSafeExit();
        assertEq(uint256(b.settleMode()), uint256(SettleMode.SafeExit));
        assertEq(b.priorityStake(), aliveStake, "alive get principal first");
        vm.warp(block.timestamp + 3 days);
        _buyMachine();
        _assertAbnormalSplit(sn);
        // 未出局者至少拿回全部投入
        for (uint256 s = 1; s <= N; s++) {
            if (!b.socket(s).ejected) assertGe(_owedOf(b, _owner(s)) - sn.credits[s], _stake(s));
        }
    }

    function test_SafeExitProRataWhenPotBelowAlivePrincipal() public {
        _topUpPool(b);
        b.pulse(); // 第一次开奖就停摆：40 人全部未出局
        vm.warp(block.timestamp + 7 days);
        Snap memory sn = _snap();
        b.triggerSafeExit();
        _buyMachineAtFloor(); // 底价
        assertLt(b.potAllocated(), 500 * BEM_1);
        _assertAbnormalSplit(sn);
    }

    // ---------------- 升级哨兵退出：与保底公式相同 ----------------

    function test_EmergencyExitUsesFallbackFormula() public {
        _ejectSome(8, "em");
        machineBeacon.upgradeTo(address(0xBAD));
        Snap memory sn = _snap();
        uint256 aliveSlot;
        for (uint256 s = 1; s <= N; s++) {
            if (!b.socket(s).ejected) aliveSlot = s;
        }
        address aliveOwner = _owner(aliveSlot);
        vm.prank(aliveOwner);
        b.emergencyExit(aliveSlot);
        assertEq(uint256(b.settleMode()), uint256(SettleMode.Fallback));
        assertEq(b.credit(_owner(aliveSlot)), sn.credits[aliveSlot] + 0, "no caller reward on top");
        // 拍卖在哨兵触发期间暂停；信标恢复后卖出
        machineBeacon.upgradeTo(address(0xB1B1));
        vm.warp(block.timestamp + 5 days);
        _buyMachine();
        _assertAbnormalSplit(sn);
    }

    // ---------------- 领取期限（设计审计 M3）----------------

    /// @dev 规则决定 6.13：过期未领的 BEM 转到黑洞地址销毁，不再给基金会
    function test_UnclaimedFundsBurnedAfterClaimWindow() public {
        _finishNormally();
        _buyMachine();
        b.withdraw(1); // 1 号领了，其他人没领
        vm.expectRevert(TapeBoard.TooEarly.selector);
        b.closeClaims();
        vm.warp(block.timestamp + 365 days);
        uint256 left = bem.balanceOf(address(b));
        uint256 fBefore = bem.balanceOf(FOUNDATION);
        uint256 burnBefore = bem.balanceOf(0x000000000000000000000000000000000000dEaD);
        b.closeClaims();
        assertEq(bem.balanceOf(0x000000000000000000000000000000000000dEaD) - burnBefore, left);
        assertEq(bem.balanceOf(FOUNDATION), fBefore, "foundation gets nothing from expiry");
        assertEq(bem.balanceOf(address(b)), 0);
        assertEq(_owedOf(b, _owner(2)), 0);
        vm.expectRevert(TapeBoard.ClaimsAreClosed.selector);
        b.withdraw(2);
        // 通行证不过期，随时可以取回（出局者的通行证在出局时已经退还，这里取回硅王的）
        address king = _owner(b.kingSocket());
        b.returnPass(b.kingSocket());
        assertEq(passCircuits.ownerOf(b.socket(b.kingSocket()).passId), king);
    }

    function test_NoClaimDeadlineWhileMachinesUnsold() public {
        _finishNormally();
        vm.warp(block.timestamp + 400 days);
        vm.expectRevert(TapeBoard.TooEarly.selector);
        b.closeClaims();
    }

    function test_FailedBoardClaimWindow() public {
        TapeBoard nb = _board();
        address u = _join(nb, 10 * BEM_1);
        vm.warp(block.timestamp + 7 days);
        nb.closeRecruitment();
        vm.warp(block.timestamp + 365 days);
        nb.closeClaims();
        assertEq(_owedOf(nb, u), 0);
        nb.returnPass(1);
    }
}

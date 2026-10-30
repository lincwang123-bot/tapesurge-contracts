// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Fixture} from "./utils/Fixture.sol";
import {TapeBoard} from "../src/TapeBoard.sol";
import {BoardFactory} from "../src/BoardFactory.sol";
import {BoardState, SettleMode} from "../src/interfaces/ITapeBoard.sol";

/// @notice 端到端：一整局（小数投入、按时间产出、回馈补贴、多台矿机、终局拍卖多轮、推送 + 自领），
///         检查资金守恒：所有流入 = 各方实际收到的 BEM + 合约余额，且全部发放后合约里只剩取整尘埃。
///         出局时 105% 直接推送，终局由运营地址分批推送，部分人自领；不再有调用者奖励。
abstract contract ConservationBase is Fixture {
    TapeBoard internal b;
    address internal buyer = address(0xB0B);
    uint256 internal saleProceeds;
    mapping(address => uint256) internal startBal;
    uint256 internal foundation0;
    uint256 internal fee0;

    function _params() internal view virtual returns (BoardFactory.Params memory);

    function setUp() public override {
        vm.warp(START_TIME);
        _deployMocks();
        _deploySystem(_params());
        // 开局前有人铸了 2,000 颗晶体管 → 回馈桶 1 有 0.2 BNB
        vm.deal(address(0xA11CE), 10 ether);
        vm.prank(address(0xA11CE));
        transistors.mint{value: 2_000 * 0.0011 ether}(0, 2_000);
        b = _startGenesis();
        // 小数投入（精确到 0.01 BEM），最后一笔补到恰好满额
        uint256 i;
        while (b.state() == BoardState.Recruiting) {
            uint256 lo = b.minStake();
            uint256 span = b.maxStake() - lo;
            uint256 amt = lo + (uint256(keccak256(abi.encode("stake", i++))) % span) / 1e6 * 1e6;
            address u = _join(b, amt);
            startBal[u] = bem.balanceOf(u);
        }
        foundation0 = bem.balanceOf(FOUNDATION);
        fee0 = bem.balanceOf(FEE_SAFE); // 已经包含本局开局时转出的入场费
        bem.mint(buyer, 100_000 * BEM_1);
        vm.prank(buyer);
        bem.approve(address(b), type(uint256).max);
    }

    function _buyRound() internal {
        address seller = _newUser();
        _sell(b, seller, 120);
        vm.warp(block.timestamp + 1 days);
        _sell(b, seller, 80);
        vm.warp(block.timestamp + 2 days);
        _sell(b, seller, 50);
        vm.warp(block.timestamp + 5 days); // 首轮收购结束
        splitter.claimReward(1); // 回馈补贴 → 新一轮收购
        assertGt(b.totalSubsidy(), 0);
        _sell(b, seller, 40);
    }

    /// @dev 按天推进：运营地址（测试合约）领取产出，够门槛就开奖
    function _playUntil(uint256 maxDays, bool stopAtKing) internal {
        pod.setRate(4_510_000); // 每单位权重每天 0.0451 BEM（加速 10 倍，让测试局在几个月内结束）
        for (uint256 d = 0; d < maxDays; d++) {
            if (b.state() != BoardState.Active) return;
            if (stopAtKing && b.aliveCount() == 1) return;
            vm.warp(block.timestamp + 1 days);
            (bool ok,) = address(b).call(abi.encodeCall(TapeBoard.pulse, ()));
            if (ok && b.drawPending()) {
                rng.fulfill(b.pendingRequestId(), uint256(keccak256(abi.encode("vrf", d))));
            }
        }
    }

    function _buy(uint256 index) internal {
        saleProceeds += _stdBuy(b, index, buyer);
    }

    /// @dev 前一半参与者自领，后一半由运营地址分批推送；基金会和手续费 Safe 由任何人代领
    function _payEveryone() internal {
        uint256 n = b.socketCount();
        for (uint256 slot = 1; slot <= n / 2; slot++) {
            stdSales.claimAll(address(b), slot);
        }
        stdSales.distribute(address(b), 1, n / 3); // 前面已自领的人拿到 0，不会重复支付
        stdSales.distribute(address(b), n / 3, n);
        if (b.credit(FOUNDATION) > 0) b.withdrawCredit(FOUNDATION);
        if (b.credit(FEE_SAFE) > 0) b.withdrawCredit(FEE_SAFE);
    }

    function _assertConservation() internal view {
        uint256 inflow =
            b.totalStake() + b.totalEntryFees() + pod.totalPaidTo(address(b)) + b.totalSubsidy() + saleProceeds;
        uint256 gains;
        for (uint256 slot = 1; slot <= b.socketCount(); slot++) {
            address u = b.socket(slot).owner;
            gains += bem.balanceOf(u) - startBal[u];
        }
        uint256 paidOut = gains + (bem.balanceOf(FOUNDATION) - foundation0) + (bem.balanceOf(FEE_SAFE) - fee0)
            + b.totalEntryFees() + b.totalSpent();
        uint256 bal = bem.balanceOf(address(b));
        assertEq(inflow, paidOut + bal, "inflow == paid out + balance");
        assertEq(b.liabilities(), bal, "only unclaimable dust left in liabilities");
        assertLe(bal, b.socketCount() + 10, "dust only");
        assertEq(b.credit(address(this)) + b.credit(buyer), 0, "no caller rewards");
    }

    function test_FullNormalGameConservesFunds() public {
        _buyRound();
        _playUntil(2_000, false);
        assertEq(uint256(b.state()), uint256(BoardState.Liquidating), "game finished");
        assertEq(uint256(b.settleMode()), uint256(SettleMode.Normal));
        assertTrue(b.kingPaid());
        // 每个人都拿到了 105%（出局时直接推送；硅王在最后一次脉冲时推送）
        for (uint256 s = 1; s <= b.socketCount(); s++) {
            address u = b.socket(s).owner;
            assertGe(bem.balanceOf(u) - startBal[u], uint256(b.socket(s).stake) * 10_500 / 10_000);
        }
        // 终局拍卖：一台按起始价附近卖，一台降到底价才卖，一台等下一轮重新拍卖，期间继续产出
        vm.warp(block.timestamp + 1 days);
        _buy(0);
        vm.warp(block.timestamp + 14 days);
        b.harvest();
        _buy(1);
        vm.warp(block.timestamp + 7 days);
        _buy(2);
        vm.warp(block.timestamp + 3 days);
        b.sweep();
        _buy(3);
        assertEq(b.unsoldMachines(), 0);
        _payEveryone();
        _assertConservation();
        // 全部通行证已退还
        for (uint256 s = 1; s <= b.socketCount(); s++) {
            assertEq(passCircuits.ownerOf(b.socket(s).passId), b.socket(s).owner);
        }
    }

    /// @dev 异常结局：卖掉 4 台矿机（跨不同拍卖时点），检查基金会没有新增记账、手续费地址按进入底池的金额记 2%
    ///      （规则决定 6.37），然后全员领取
    function _liquidateAbnormally() internal {
        uint256 foundationCredit0 = b.credit(FOUNDATION);
        uint256 feeCredit0 = b.credit(FEE_SAFE);
        uint256 pot0 = b.potAllocated();
        for (uint256 i = 0; i < 4; i++) {
            vm.warp(block.timestamp + 5 days);
            b.harvest();
            _buy(i);
        }
        assertEq(b.credit(FOUNDATION), foundationCredit0, "abnormal: no 3%");
        assertApproxEqAbs(b.credit(FEE_SAFE) - feeCredit0, (b.potAllocated() - pot0) * 200 / 10_000, 10, "abnormal: 2% fee");
        _payEveryone();
        _assertConservation();
    }

    function test_FallbackGameConservesFunds() public {
        _buyRound();
        _playUntil(40, true);
        assertEq(uint256(b.state()), uint256(BoardState.Active));
        assertGt(b.socketCount() - b.aliveCount(), 0, "some ejected");
        vm.warp(b.startedAt() + 730 days);
        b.expire();
        assertEq(uint256(b.settleMode()), uint256(SettleMode.Fallback));
        _liquidateAbnormally();
    }

    function test_SafeExitGameConservesFunds() public {
        _buyRound();
        _playUntil(40, true);
        assertGt(b.socketCount() - b.aliveCount(), 0, "some ejected");
        if (!b.drawPending()) {
            _topUpPool(b);
            b.pulse(); // 这次请求之后 VRF 不再响应
        }
        vm.warp(block.timestamp + 7 days);
        b.triggerSafeExit();
        assertEq(uint256(b.settleMode()), uint256(SettleMode.SafeExit));
        _liquidateAbnormally();
    }

    function test_EmergencyExitGameConservesFunds() public {
        _buyRound();
        _playUntil(40, true);
        tapeout.circuitsBeacon().upgradeTo(address(0xBAD)); // 通行证电路合约的信标被升级
        uint256 alive;
        for (uint256 s = 1; s <= b.socketCount(); s++) {
            if (!b.socket(s).ejected) alive = s;
        }
        address holder = b.socket(alive).owner;
        vm.prank(holder);
        b.emergencyExit(alive);
        assertEq(uint256(b.settleMode()), uint256(SettleMode.Fallback));
        tapeout.circuitsBeacon().upgradeTo(address(0xC1C1)); // 恢复后终局拍卖继续
        _liquidateAbnormally();
    }
}

/// @notice 默认参数：主板 500 BEM、单人 1–20 BEM
contract Conservation500Test is ConservationBase {
    function _params() internal view override returns (BoardFactory.Params memory) {
        return defaultParams();
    }
}

/// @notice 参数化：主板 1,000 BEM、单人 1–20 BEM
contract Conservation1000Test is ConservationBase {
    function _params() internal view override returns (BoardFactory.Params memory) {
        return params1000();
    }
}

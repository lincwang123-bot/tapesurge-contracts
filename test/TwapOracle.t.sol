// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {TickMath} from "../src/libraries/TickMath.sol";
import {PancakeV3TwapOracle} from "../src/oracle/PancakeV3TwapOracle.sol";
import {MockV3Pool} from "../src/mocks/MockSwap.sol";

contract TickMathHarness {
    function sqrtAt(int24 t) external pure returns (uint160) {
        return TickMath.getSqrtRatioAtTick(t);
    }
}

/// @notice TWAP 预言机：TickMath 已知值、多跳报价、窗口下限
contract TwapOracleTest is Test {
    address internal constant WBNB = address(0x2000);
    address internal constant USDT = address(0x1000);
    address internal constant BEM = address(0x3000);
    TickMathHarness internal tm = new TickMathHarness();

    function test_TickMathKnownValues() public view {
        assertEq(tm.sqrtAt(0), 1 << 96);
        assertEq(tm.sqrtAt(-887272), 4295128739);
        assertEq(tm.sqrtAt(887272), 1461446703485210103287273052203988822378723970342);
        // 1.0001^(±1) 的平方根
        assertEq(tm.sqrtAt(1), 79232123823359799118286999568);
        assertEq(tm.sqrtAt(-1), 79224201403219477170569942574);
    }

    function test_RevertWhen_TickOutOfRange() public {
        vm.expectRevert(TickMath.TickOutOfRange.selector);
        tm.sqrtAt(887273);
    }

    function _oracle(int24 tick1, int24 tick2, uint32 window) internal returns (PancakeV3TwapOracle o) {
        vm.warp(1_790_000_000);
        // 池 1：USDT(token0) / WBNB(token1)；池 2：USDT(token0) / BEM(token1)
        MockV3Pool p1 = new MockV3Pool(USDT, WBNB, tick1);
        MockV3Pool p2 = new MockV3Pool(USDT, BEM, tick2);
        address[] memory tokens = new address[](3);
        tokens[0] = WBNB;
        tokens[1] = USDT;
        tokens[2] = BEM;
        address[] memory pools = new address[](2);
        pools[0] = address(p1);
        pools[1] = address(p2);
        o = new PancakeV3TwapOracle(tokens, pools, window);
    }

    function test_QuoteAtTickZeroIsOneToOne() public {
        PancakeV3TwapOracle o = _oracle(0, 0, 30 minutes);
        assertEq(o.quoteAtTick(0, 1e18, WBNB, USDT), 1e18);
        assertEq(o.quoteBemOut(1e18), 1e18);
    }

    function test_MultiHopQuoteChainsBothPools() public {
        // 1 BNB ≈ 700 USDT：USDT 是 token0，价格 = WBNB/USDT = 1/700 → tick ≈ −65,513
        // 1 USDT ≈ 1/32.5 BEM（8 位小数 vs 18 位）：BEM/USDT = 1e8/(32.5e18) → tick ≈ −265,078
        int24 t1 = -65_513;
        int24 t2 = -265_078;
        PancakeV3TwapOracle o = _oracle(t1, t2, 30 minutes);
        uint256 usdt = o.quoteAtTick(t1, 1e18, WBNB, USDT);
        uint256 bem = o.quoteAtTick(t2, usdt, USDT, BEM);
        assertEq(o.quoteBemOut(1e18), bem);
        assertApproxEqRel(usdt, 700e18, 0.001e18);
        // 1 BNB ≈ 700 / 32.5 ≈ 21.54 BEM
        assertApproxEqRel(bem, 21.54e8, 0.002e18);
        assertEq(o.twapTick(o.pools(0)), t1);
    }

    function test_RevertWhen_WindowShorterThan30Minutes() public {
        vm.expectRevert(PancakeV3TwapOracle.BadWindow.selector);
        _oracle(0, 0, 29 minutes);
    }

    function test_RevertWhen_PoolDoesNotMatchPath() public {
        MockV3Pool p1 = new MockV3Pool(USDT, WBNB, 0);
        address[] memory tokens = new address[](3);
        tokens[0] = WBNB;
        tokens[1] = USDT;
        tokens[2] = BEM;
        address[] memory pools = new address[](2);
        pools[0] = address(p1);
        pools[1] = address(p1); // 第二跳应该是 USDT/BEM
        vm.expectRevert(PancakeV3TwapOracle.BadPath.selector);
        new PancakeV3TwapOracle(tokens, pools, 30 minutes);
    }
}

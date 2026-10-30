// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IBemPriceOracle, IV3PoolObserve} from "../interfaces/ISwap.sol";
import {TickMath} from "../libraries/TickMath.sol";

/// @title PancakeSwap V3 多跳 TWAP 预言机（BNB → BEM 参考价）
/// @notice 不可升级，没有管理员（没有任何特权角色）。沿着与兑换相同的路径（默认 WBNB →（WBNB/USDT 池）→ USDT →（BEM/USDT 1% 池）→ BEM），
///         用每个池子过去 `window` 秒的时间加权平均 tick 逐跳换算，给分账合约算"最低成交量"。
///         窗口不少于 30 分钟（设计审计 M1）。
/// @dev 池子需要足够的 observation cardinality（window 秒内的历史）；不足时 observe 会 revert，
///      回购会暂停，而不是按可能被操纵的价格成交。
contract PancakeV3TwapOracle is IBemPriceOracle {
    uint32 public constant MIN_WINDOW = 30 minutes;

    uint32 public immutable window;
    address[] public tokens; // 路径上的代币：tokens[0] = WBNB，最后一个 = BEM
    address[] public pools; // pools[i] 是 tokens[i] / tokens[i+1] 的池子

    error BadPath();
    error BadWindow();

    constructor(address[] memory tokens_, address[] memory pools_, uint32 window_) {
        if (window_ < MIN_WINDOW) revert BadWindow();
        if (tokens_.length < 2 || pools_.length != tokens_.length - 1) revert BadPath();
        for (uint256 i = 0; i < pools_.length; i++) {
            address t0 = IV3PoolObserve(pools_[i]).token0();
            address t1 = IV3PoolObserve(pools_[i]).token1();
            bool ok = (t0 == tokens_[i] && t1 == tokens_[i + 1]) || (t0 == tokens_[i + 1] && t1 == tokens_[i]);
            if (!ok) revert BadPath();
        }
        tokens = tokens_;
        pools = pools_;
        window = window_;
    }

    function hops() external view returns (uint256) {
        return pools.length;
    }

    function twapTick(address pool) public view returns (int24 tick) {
        uint32[] memory ago = new uint32[](2);
        ago[0] = window;
        ago[1] = 0;
        (int56[] memory cum,) = IV3PoolObserve(pool).observe(ago);
        int56 delta = cum[1] - cum[0];
        int56 w = int56(uint56(window));
        tick = int24(delta / w);
        if (delta < 0 && (delta % w != 0)) tick--;
    }

    /// @notice bnbIn 个 WBNB 按 TWAP 逐跳换算能得到多少 BEM。
    function quoteBemOut(uint256 bnbIn) external view returns (uint256 amount) {
        amount = bnbIn;
        for (uint256 i = 0; i < pools.length; i++) {
            amount = quoteAtTick(twapTick(pools[i]), amount, tokens[i], tokens[i + 1]);
        }
    }

    /// @notice 与 Uniswap V3 OracleLibrary.getQuoteAtTick 相同：按 tick 价格把 baseAmount 个 base 换算成 quote。
    function quoteAtTick(int24 tick, uint256 baseAmount, address baseToken, address quoteToken)
        public
        pure
        returns (uint256 quoteAmount)
    {
        uint160 sqrtRatioX96 = TickMath.getSqrtRatioAtTick(tick);
        if (sqrtRatioX96 <= type(uint128).max) {
            uint256 ratioX192 = uint256(sqrtRatioX96) * sqrtRatioX96;
            quoteAmount = baseToken < quoteToken
                ? Math.mulDiv(ratioX192, baseAmount, 1 << 192)
                : Math.mulDiv(1 << 192, baseAmount, ratioX192);
        } else {
            uint256 ratioX128 = Math.mulDiv(sqrtRatioX96, sqrtRatioX96, 1 << 64);
            quoteAmount = baseToken < quoteToken
                ? Math.mulDiv(ratioX128, baseAmount, 1 << 128)
                : Math.mulDiv(1 << 128, baseAmount, ratioX128);
        }
    }
}

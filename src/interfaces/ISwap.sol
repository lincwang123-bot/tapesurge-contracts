// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @notice PancakeSwap V3 SwapRouter（v3-periphery 版本，带 deadline）的多跳兑换。
/// @dev 设计审计 M1：回购和回馈换币走最深的 BEM/USDT 1% 池，路径为 WBNB →(费率)→ USDT →(1%)→ BEM。
///      path 编码：token(20 字节) | fee(3 字节) | token | fee | token。tokenIn = WBNB 且随调用附带 BNB 时，
///      路由会自动把 BNB 包装成 WBNB（PeripheryPayments.pay）。主网路由 0x1b81…eB14（主网分叉演练已验证）。
interface ISwapRouter {
    struct ExactInputParams {
        bytes path;
        address recipient;
        uint256 deadline;
        uint256 amountIn;
        uint256 amountOutMinimum;
    }

    function exactInput(ExactInputParams calldata params) external payable returns (uint256 amountOut);
}

/// @notice 价格预言机：给出 bnbIn 按参考价（30 分钟以上的 TWAP）应换得多少 BEM。
///         分账合约用它算"最低成交量"，防止滑点和夹子攻击。
interface IBemPriceOracle {
    function quoteBemOut(uint256 bnbIn) external view returns (uint256 bemOut);
}

/// @notice PancakeSwap V3 池子的 TWAP 接口（与 Uniswap V3 相同）。
interface IV3PoolObserve {
    function observe(uint32[] calldata secondsAgos)
        external
        view
        returns (int56[] memory tickCumulatives, uint160[] memory secondsPerLiquidityCumulativeX128s);

    function token0() external view returns (address);
    function token1() external view returns (address);
}

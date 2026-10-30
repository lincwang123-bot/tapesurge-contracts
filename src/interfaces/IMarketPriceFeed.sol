// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @notice 主板和卖矿合约用到的报价 / 定价接口（MarketPriceFeed）
interface IMarketPriceFeed {
    function buyQuote(uint256 cap, uint256 curvePrice, uint256 since) external view returns (uint256);
    function sellQuote(uint256 since) external view returns (uint256);
    function fresh() external view returns (bool);
    function abandoned() external view returns (bool);
    function bid() external view returns (uint256);
    function updatedAt() external view returns (uint256);
    /// @notice 规则决定 6.29：保持排序第一的目标价（每单位权重），无效时为 0
    function floorQuote() external view returns (uint256);
}

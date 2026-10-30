// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @notice 挂单模块（MachineLister）对卖矿合约开放的接口
interface IMachineLister {
    /// @notice 撤掉第 index 台矿机在各市场的挂单，把矿机和挂单库里的产出还给主板。
    ///         卖矿合约随时可调（普通买家 / 交接要先拿回矿机）；其他人只能在这台矿机现在不能卖时调用。
    function recall(address board, uint256 index) external;
}

/// @notice 两个卖矿合约（StdMachineSales / MonthMachineSales）给挂单模块用的接口
interface IMachineSales {
    /// @notice 现在买走第 index 台矿机要付的总价（BEM，0 = 现在不能买）
    function quote(address board, uint256 index) external view returns (uint256);
    /// @notice 只认挂单模块：把矿机寄售给挂单库
    function consign(address board, uint256 index, address vault) external;
    function buyMachine(address board, uint256 index, uint256 maxPrice) external returns (uint256);
    function LISTER() external view returns (address);
}

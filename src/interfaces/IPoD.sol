// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @title PoD 挖矿合约接口 `0x7E2E0DC66a3bD9103E69b766afA62d9f7b697b46`
/// @notice 来自链上读取与 eth_call 模拟（`模拟/PoD链上核查.py`）：
///         - 矿机 key = minerKey(电路合约, 电路编号)，只和电路有关；
///         - claim 任何人都能调，产出总是付给 NFT 的**当前持有者**；
///         - stop / arm 只有当前持有者能调；
///         - 矿机转给合约后继续挖，权重和资格留在矿机上。
interface IPoD {
    function minerKey(address circuits, uint256 id) external pure returns (bytes32);

    /// @notice 读取矿机信息。
    /// @dev ⚠️ 返回值的字段含义是**推断**的（源码未公开）。主网返回 22 个 32 字节字，2026-10-24 分叉实测（PoDReader 的说明）：
    ///      [0] 电路合约  [1] 电路编号  [2] 已验证任务号（0 = 未验证池）  [3] 基础算力  [7] 处理器倍数
    ///      [8] 开挖时间  [9] 状态（1 = 在挖，3 = 已停）  [10] 登记人  [19] 已验证池里分产出的权重  [20] 未验证池权重。
    ///      这里只声明前 11 个字段（类型只为生成选择器，[7] / [9] 实际不是 bool）；
    ///      主板合约不直接 abi.decode 返回值，而是用 `PoDReader` 按 32 字节字的位置读取。
    function getMiner(bytes32 key)
        external
        view
        returns (
            address circuits,
            uint256 circuitId,
            uint256 taskId,
            uint256 weight,
            uint256 field4,
            uint256 field5,
            uint256 field6,
            bool mining,
            uint256 since,
            bool verified,
            address registrant
        );

    function pending(bytes32 key) external view returns (uint256);

    /// @notice 领取产出，付给 NFT 当前持有者。任何人可调。
    function claim(bytes32 key) external;

    function claimMany(bytes32[] calldata keys) external;

    /// @notice 仅当前持有者可调。
    function stop(bytes32 key) external;

    /// @notice 仅当前持有者可调。
    function arm(address circuits, uint256 id) external;

    function totalVerifWeight() external view returns (uint256);

    /// @notice 当前每秒产出（BEM 最小单位），主网读到 8,333,333，即每天 7,200 BEM。
    function currentRate() external view returns (uint256);

    function processorMultiplier(address circuits) external view returns (uint256);
}

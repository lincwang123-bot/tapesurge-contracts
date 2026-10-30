// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @notice 月局的状态
/// - Recruiting：招募中（3 天）
/// - Failed：招募失败，全员退款、退还通行证
/// - Preparing：已开局，准备矿机（接手上一块月局的矿机 + 收购拍卖，最多 3 天）
/// - Mining：挖矿 30 天，产出进奖金池
/// - Drawing：等待 VRF 开奖
/// - Settling：已开奖（或不抽奖结算），收回本金：接力 / 对外拍卖（底价 = 成本价）/ 卖不出继续挖
enum MonthState {
    Uninitialized,
    Recruiting,
    Failed,
    Preparing,
    Mining,
    Drawing,
    Settling
}

interface IMonthBoard {
    function state() external view returns (MonthState);
    /// @notice 接力：上一块月局已经把矿机 NFT 转给本合约，本合约按成本价付款（只接受同一月局工厂创建的主板）
    function acceptRelay(bytes32 key, uint256 circuitId, uint256 cost) external;
}

interface IMonthFactory {
    function openFirst() external returns (address board);
    /// @return rollover 转给刚开局主板的滚存资金（上一批月局收回的回馈部分）
    function onBoardStarted(bool full, uint256 elapsed) external returns (uint256 rollover);
    function onBoardFailed() external;
    function isBoard(address account) external view returns (bool);
    function boardImplementation() external view returns (address);
}

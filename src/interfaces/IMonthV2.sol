// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {MonthState} from "./IMonthBoard.sol";

/// @notice v2 月局主板对单例合约（持仓凭证、卖矿、清算治理）开放的接口
interface IMonthBoardV2 {
    /// @dev 与 MonthBoard.Socket 的字段顺序和类型完全相同（socket(slot) 的返回值）
    struct Position {
        address owner;
        uint96 stake;
        uint256 passId;
        uint128 claimed;
        bool refunded;
        bool passReturned;
        uint32 version;
    }

    /// @dev 与 MonthBoard.Machine 的字段顺序和类型完全相同（machine(index) 的返回值）
    struct MachineView {
        bytes32 key;
        uint256 circuitId;
        address collection;
        uint64 weight;
        bool active;
        bool sold;
        uint128 cost;
    }

    function state() external view returns (MonthState);
    function settleStart() external view returns (uint256);
    function PRICE_FEED() external view returns (address);
    function totalStake() external view returns (uint256);
    function socketCount() external view returns (uint256);
    function holderCount(address account) external view returns (uint256);
    function liquidating() external view returns (bool);
    function governanceLocked() external view returns (bool);
    function tradeEpoch() external view returns (uint64);
    function claimsClosed() external view returns (bool);
    function finishedAt() external view returns (uint256);
    function socket(uint256 slot) external view returns (Position memory);
    function machine(uint256 index) external view returns (MachineView memory);
    function machineCount() external view returns (uint256);
    function withdraw(uint256 slot) external returns (uint256 amount);
    function returnPass(uint256 slot) external;
    function unsoldMachines() external view returns (uint256);
    function sentinelPaused() external view returns (bool);

    /// @dev 只认持仓凭证合约：所有转移路径都经过这里（锁、结转、退通行证、版本号）
    function onPositionTransfer(uint256 slot, address from, address to) external;
    /// @dev 只认卖矿合约：从卖矿合约收 price 个 BEM，把第 index 台矿机转给 to
    function releaseMachine(uint256 index, address to, uint256 price) external;
    /// @dev 只认卖矿合约：在新月局的收购拍卖里按不低于成本价卖出第 index 台矿机
    function relayOut(uint256 index, address newBoard) external returns (uint256 paid);
    /// @dev 只认卖矿合约：把第 index 台矿机转给挂单库寄售
    function consign(uint256 index, address to) external;
    /// @dev 只认清算治理合约
    function setGovernanceLock(bool locked) external;
    function startLiquidation() external;

    /// @dev 新月局的收购入口（rc8 起带合集参数）
    function sellMachine(address collection, uint256 circuitId, uint256 minPricePerWeight) external returns (uint256 paid);
    function TRADER() external view returns (address);
}

/// @notice 持仓凭证（ERC-721）的铸造入口
interface IMonthPositions {
    function mint(address to, uint256 slot) external;
    function idOf(address board, uint256 slot) external pure returns (uint256);
}



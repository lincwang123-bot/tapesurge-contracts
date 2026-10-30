// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @notice 主板状态
/// - Recruiting：招募中（7 天）
/// - Failed：招募失败，全员退款、退还通行证
/// - Active：已开局，对应白皮书的"采购 / 运行"两个阶段（采购拍卖进行中时 isPurchasing() = true）
/// - Liquidating：抽签已结束，终局荷兰式拍卖卖矿机并分配底池（正常终局或各种保底）
enum BoardState {
    Uninitialized,
    Recruiting,
    Failed,
    Active,
    Liquidating
}

/// @notice 底池的分配方式
/// - Normal：正常终局，65% 按投入分给硅王以外的人 / 30% 硅王 / 3% 基金会 / 2% 手续费
/// - Fallback：最长期限保底 / 首轮收购一台没买到 / 升级哨兵后的退出
/// - SafeExit：VRF 停摆超过 7 天
///   Fallback 与 SafeExit 只是触发原因不同，分配公式相同：先收 2% 手续费（规则决定 6.37；不收基金会 3%），再退未出局者的
///   投入（不够按比例），剩余部分全部按投入分给所有参与者（含已出局者）；没有调用者奖励，不发硅王奖；卖矿溢价分成照收
enum SettleMode {
    None,
    Normal,
    Fallback,
    SafeExit
}

interface ITapeBoard {
    function state() external view returns (BoardState);
    function number() external view returns (uint256);
    function depositSubsidy(uint256 amount) external;
    function sentinelTripped() external view returns (bool);
    /// @notice 升级哨兵的冷静期：已触发且（注册中心的）登记不满 sentinelResumeDelay（30 天）
    function sentinelPaused() external view returns (bool);
    /// @notice 升级哨兵监控的两个信标（矿机电路 / 创世通行证电路）；月局实现合约也有同名的 getter
    function MACHINE_BEACON() external view returns (address);
    function PASS_BEACON() external view returns (address);
}

interface IBoardFactory {
    /// @param full 是否招满目标金额（否则是 7 天到期、达到 60% 按实际金额开局）
    /// @param elapsed 从主板开出到开局用了多久
    function onBoardStarted(bool full, uint256 elapsed) external;
    function onBoardFailed() external;
    function boardByNumber(uint256 number) external view returns (address);
    function isBoard(address account) external view returns (bool);
}

/// @notice 首批回馈的领取对象（标准局和月局都实现）。GenesisSplitter 只通过这个接口和主板交互。
interface IRewardTarget {
    /// @notice 现在能否接收回馈补贴（标准局：采购 / 运行中；月局：开局后、局终结算前）
    function acceptsSubsidy() external view returns (bool);
    /// @notice 是否已结束（之后它那一桶的新增收入转入回购）
    function rewardEnded() external view returns (bool);
    function depositSubsidy(uint256 amount) external;
}

/// @notice 主板注册中心（由 BoardFactory 担任）：两种局合计的开局顺序、是否官方主板。
/// @dev BoardFactory 没有显式继承这个接口（它的 splitter() 返回 GenesisSplitter 类型），但 ABI 完全一致。
interface IBoardHub {
    /// @notice 两种局合计第 rank 个真正开局的主板（rank 从 1 开始；GenesisSplitter 按它发前 5 块的回馈）
    function rewardBoard(uint256 rank) external view returns (address);
    /// @notice 由月局工厂在月局开局时调用，登记开局顺序
    function registerStart(address board) external returns (uint256 rank);
    function isBoard(address account) external view returns (bool);
    function monthFactory() external view returns (address);
    function passCircuits() external view returns (address);
    function splitter() external view returns (address);
    /// @notice 运营地址：开奖、自动发放、月局矿机交接 / 挂单由它执行；它 3 天没执行时由本局参与者兜底。可以为 0。
    function operator() external view returns (address);
    /// @notice 第一次登记到升级哨兵触发的时间（两种局共用；0 = 未登记或已恢复）
    function sentinelSince() external view returns (uint256);
    /// @notice 登记升级哨兵触发（任何人可调；信标恢复后再调用清零）
    function noteSentinel() external;
}

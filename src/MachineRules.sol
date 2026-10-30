// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IPoD} from "./interfaces/IPoD.sol";
import {ITapeOutFactory} from "./interfaces/ITapeOut.sol";
import {PoDReader} from "./libraries/PoDReader.sol";

/// @title MachineRules（主板收哪些矿机、按多少算力计价；单例，两种局共用；规则决定 6.26）
/// @notice 只读，没有管理员，不可升级。主板收购（sellMachine）和标准局同步矿机状态（syncMachine）都问它：
///         - 合集：任何由 TapeOut 处理器工厂创建的处理器的电路合约（factory.isCPU），并且运行时代码和官方矿机电路合约
///           完全相同。工厂创建的电路合约都是同一个信标代理（信标地址写在代码里），代码相同 ⇒ 用的是同一个信标，主板的
///           升级哨兵（监控这个信标）就覆盖得到。2026-10-24 核对：官方矿机 0xb1024b… 和 Behemoth 0x1F5Cb4… 的代码哈希相同。
///         - 资格：PoD 上状态为在挖、在已验证池里、运行满 minAge，计价算力在 [minWeight, maxWeight] 内。
///         - 计价算力 = min(基础算力 × 处理器倍数, 已验证池权重)（PoDReader；不含会被更优电路抢走的最优加成）。
///           PoD 按已验证池权重分产出，所以"每单位算力"的产出对所有合集都一样，按每单位算力定价的公式不用改。
contract MachineRules {
    address public immutable POD;
    address public immutable TAPEOUT_FACTORY;
    /// @notice 代码哈希的参照：官方矿机电路合约
    address public immutable REFERENCE_CIRCUITS;
    bytes32 public immutable MACHINE_CODEHASH;

    error BadConfig();
    error MachineNotEligible();

    constructor(address pod, address tapeoutFactory, address referenceCircuits) {
        if (pod == address(0) || tapeoutFactory == address(0) || referenceCircuits.code.length == 0) {
            revert BadConfig();
        }
        POD = pod;
        TAPEOUT_FACTORY = tapeoutFactory;
        REFERENCE_CIRCUITS = referenceCircuits;
        MACHINE_CODEHASH = referenceCircuits.codehash;
    }

    /// @notice collection 是不是主板收的矿机合集（工厂创建的处理器 + 代码和官方矿机电路合约相同）
    function isMachineCollection(address collection) public view returns (bool) {
        return collection.codehash == MACHINE_CODEHASH && ITapeOutFactory(TAPEOUT_FACTORY).isCPU(collection);
    }

    /// @notice 收购前的检查：合集、PoD 资格。不合格时回滚 MachineNotEligible。
    /// @return key PoD 的矿机 key
    /// @return weight 计价算力
    function check(address collection, uint256 circuitId, uint256 minWeight, uint256 maxWeight, uint256 minAge)
        external
        view
        returns (bytes32 key, uint256 weight)
    {
        if (!isMachineCollection(collection)) revert MachineNotEligible();
        key = IPoD(POD).minerKey(collection, circuitId);
        (bool ok, PoDReader.MinerView memory m) = PoDReader.tryRead(POD, key, collection, circuitId);
        if (!ok || !m.verified || !m.mining) revert MachineNotEligible();
        if (m.weight < minWeight || m.weight > maxWeight) revert MachineNotEligible();
        if (minAge > 0 && (m.since == 0 || m.since > block.timestamp || block.timestamp - m.since < minAge)) {
            revert MachineNotEligible();
        }
        weight = m.weight;
    }

    /// @notice 矿机现在是否还在挖、在已验证池里（读不到时为 false）。标准局 syncMachine 用它决定计不计入在挖权重。
    function live(bytes32 key, address collection, uint256 circuitId) external view returns (bool) {
        (bool ok, PoDReader.MinerView memory v) = PoDReader.tryRead(POD, key, collection, circuitId);
        return ok && v.verified && v.mining && v.weight > 0;
    }
}

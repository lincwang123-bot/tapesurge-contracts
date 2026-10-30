// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IPoD} from "../interfaces/IPoD.sol";

/// @title 读取 PoD 的矿机信息与产出速率
/// @notice PoD 源码未公开验证，getMiner 的字段含义是从链上读取**推断**的。getMiner 返回 22 个 32 字节字（扁平的静态元组）。
///         2026-10-24 主网分叉实测（`test/probe/PoDWordsProbe.t.sol`，区块 129350109；MARKET-PROBE.md 第 4 节）确认：
///           [0] 电路合约  [1] 编号  [2] 已验证任务号（0 = 在未验证池）  [3] 基础算力（不含倍数、不含最优加成）
///           [7] 处理器倍数（官方 1、Behemoth 6；停挖后不变）  [8] 开挖时间  [9] 状态（1 = 在挖，3 = 已停）
///           [14] 最优加成（基础单位）  [18] 停挖时的区块号
///           [19] 已验证池里实际分产出的权重 = (基础算力 + 最优加成) × 倍数（停挖、在未验证池时为 0）
///           [20] 未验证池里的权重
///         PoD 按 [19] 分产出（一天的产出 ÷ [19] 对官方和 Behemoth 矿机都等于每单位产出），totalVerifWeight 是 [19] 的合计。
///         rc7 及以前把 [7] 当成"在挖"、把 [9] ≠ 0 当成"已验证"、把 [3] 当成权重，会把已停挖 / 在未验证池的矿机当成合格，
///         并且按基础算力给倍数 > 1 的合集计价，rc8 改正。
///         这里不用 abi.decode，而是按 32 字节字的位置读取需要的字段；如果字段位置以后变了，只需要改这里的常量。
///         tryRead 会核对返回的电路合约地址和编号与查询的矿机一致，不一致时当作读取失败（审计 #5）。
library PoDReader {
    uint256 internal constant WORD_CIRCUITS = 0;
    uint256 internal constant WORD_CIRCUIT_ID = 1;
    uint256 internal constant WORD_BASE = 3;
    uint256 internal constant WORD_MULTIPLIER = 7;
    uint256 internal constant WORD_SINCE = 8; // 推断：开挖时间
    uint256 internal constant WORD_STATUS = 9;
    uint256 internal constant WORD_VERIFIED_WEIGHT = 19;
    uint256 internal constant STATUS_MINING = 1;
    uint256 internal constant MIN_WORDS = 20;

    struct MinerView {
        address circuits;
        uint256 circuitId;
        uint256 weight; // 计价算力 = min(基础算力 × 倍数, 已验证池权重)：不含最优加成（加成会被更优的电路抢走）
        bool mining; // 状态 = 在挖
        uint256 since;
        bool verified; // 在已验证池里、权重 > 0
    }

    /// @return ok 调用成功、返回长度足够，并且返回的电路合约地址和编号与 circuits / circuitId 一致
    function tryRead(address pod, bytes32 key, address circuits, uint256 circuitId)
        internal
        view
        returns (bool ok, MinerView memory m)
    {
        bytes memory ret;
        (ok, ret) = pod.staticcall(abi.encodeWithSelector(IPoD.getMiner.selector, key));
        if (!ok || ret.length < MIN_WORDS * 32) return (false, m);
        m.circuits = address(uint160(_word(ret, WORD_CIRCUITS)));
        m.circuitId = _word(ret, WORD_CIRCUIT_ID);
        if (m.circuits != circuits || m.circuitId != circuitId) return (false, m);
        uint256 paid = _word(ret, WORD_VERIFIED_WEIGHT);
        // min(基础算力 × 倍数, paid)，先比较再相乘，字段异常时也不会溢出
        uint256 mult = _word(ret, WORD_MULTIPLIER);
        uint256 base = _word(ret, WORD_BASE);
        m.weight = mult == 0 ? 0 : base <= paid / mult ? base * mult : paid;
        m.mining = _word(ret, WORD_STATUS) == STATUS_MINING;
        m.since = _word(ret, WORD_SINCE);
        m.verified = paid > 0;
    }

    /// @notice 每单位已验证权重每天的产出（BEM 最小单位）= currentRate × 86400 × 已验证份额 ÷ 已验证总权重。
    /// @return ok 两个读取都成功且总权重 > 0
    function tryUnitYieldPerDay(address pod, uint256 verifiedShareBps) internal view returns (bool ok, uint256 perDay) {
        (bool ok1, bytes memory r1) = pod.staticcall(abi.encodeWithSelector(IPoD.currentRate.selector));
        (bool ok2, bytes memory r2) = pod.staticcall(abi.encodeWithSelector(IPoD.totalVerifWeight.selector));
        if (!ok1 || !ok2 || r1.length < 32 || r2.length < 32) return (false, 0);
        uint256 rate = abi.decode(r1, (uint256));
        uint256 total = abi.decode(r2, (uint256));
        if (total == 0) return (false, 0);
        return (true, rate * 1 days * verifiedShareBps / 10_000 / total);
    }

    function _word(bytes memory data, uint256 index) private pure returns (uint256 w) {
        assembly {
            w := mload(add(add(data, 32), mul(index, 32)))
        }
    }
}

// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {EjectionTree} from "../../src/libraries/EjectionTree.sol";

/// @notice 测试用：直接调用主板使用的 EjectionTree 库，按主板相同的公式抽签。
contract TreeHarness {
    using EjectionTree for EjectionTree.Tree;

    EjectionTree.Tree internal t;

    constructor(uint256 capacity) {
        t.init(capacity);
    }

    function insert(uint256 slot, uint256 stake) external {
        t.insert(slot, stake);
    }

    function remove(uint256 slot, uint256 stake) external {
        t.remove(slot, stake);
    }

    function select(uint256 aliveSum, uint256 r) external view returns (uint256) {
        return t.selectEject(aliveSum, r);
    }

    function maxStake() external view returns (uint256) {
        return t.maxStake();
    }

    function prefix(uint256 m) external view returns (uint256 count, uint256 sum) {
        return t.prefix(m);
    }

    function findByCount(uint256 k) external view returns (uint256) {
        return t.findByCount(k);
    }

    /// @notice 穷举 r ∈ [0, (n−1)·S)，统计每个插槽被抽中的次数（应恰好等于 S − wⱼ）。
    function countAll(uint256 aliveCount, uint256 aliveSum) external view returns (uint256[] memory counts) {
        counts = new uint256[](t.capacity + 1);
        uint256 total = (aliveCount - 1) * aliveSum;
        for (uint256 r = 0; r < total; r++) {
            counts[t.selectEject(aliveSum, r)]++;
        }
    }

    /// @notice 跑 games 局完整的游戏（每轮按 S − wⱼ 抽一人出局，直到只剩 1 人），返回每个插槽当硅王的次数。
    ///         每局结束后把硅王也移出，树恢复为空，可以重复使用。
    function runGames(uint256[] calldata stakes, uint256 games, uint256 seed) external returns (uint256[] memory wins) {
        uint256 n = stakes.length;
        wins = new uint256[](n + 1);
        uint256 total;
        for (uint256 i = 0; i < n; i++) {
            total += stakes[i];
        }
        for (uint256 g = 0; g < games; g++) {
            for (uint256 i = 0; i < n; i++) {
                t.insert(i + 1, stakes[i]);
            }
            uint256 alive = n;
            uint256 s = total;
            while (alive > 1) {
                uint256 word = uint256(keccak256(abi.encode(seed, g, alive)));
                uint256 slot = t.selectEject(s, word % ((alive - 1) * s));
                uint256 w = stakes[slot - 1];
                t.remove(slot, w);
                s -= w;
                alive--;
            }
            uint256 king = t.findByCount(1);
            wins[king]++;
            t.remove(king, stakes[king - 1]);
        }
    }
}

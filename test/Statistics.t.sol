// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test, console2} from "forge-std/Test.sol";
import {TreeHarness} from "./utils/TreeHarness.sol";

/// @notice 统计测试：大量模拟开局，硅王频率 ≈ 投入占比。
///         期望值就是 `模拟/反推出局概率.py` 用精确分数枚举得到的 wᵢ / S（三组例子全部精确吻合）。
///         随机数用固定种子的 keccak 序列，结果可复现；容差取 5 个标准差。
contract StatisticsTest is Test {
    function _check(uint256[] memory w, uint256 games, uint256 seed) internal {
        TreeHarness h = new TreeHarness(w.length);
        uint256[] memory wins = h.runGames(w, games, seed);
        uint256 s;
        for (uint256 i = 0; i < w.length; i++) {
            s += w[i];
        }
        uint256 chi2x1000; // 卡方统计量 × 1000，仅输出参考
        uint256 totalWins;
        for (uint256 i = 0; i < w.length; i++) {
            uint256 expected = games * w[i] / s; // 精确值 = wᵢ / S
            uint256 var_ = games * w[i] * (s - w[i]) / (s * s);
            uint256 tol = 5 * _sqrt(var_) + 2;
            uint256 got = wins[i + 1];
            totalWins += got;
            uint256 diff = got > expected ? got - expected : expected - got;
            assertLe(diff, tol, "king frequency off");
            if (expected > 0) chi2x1000 += diff * diff * 1000 / expected;
            console2.log("stake", w[i], "king count", got);
            console2.log("   expected", expected, "tolerance", tol);
        }
        assertEq(totalWins, games);
        console2.log("chi-square x1000 (df = n-1):", chi2x1000);
    }

    function test_Stats_1_20_79() public {
        uint256[] memory w = new uint256[](3);
        w[0] = 1;
        w[1] = 20;
        w[2] = 79;
        _check(w, 20_000, 1);
    }

    function test_Stats_1_20_5_10_64() public {
        uint256[] memory w = new uint256[](5);
        w[0] = 1;
        w[1] = 20;
        w[2] = 5;
        w[3] = 10;
        w[4] = 64;
        _check(w, 20_000, 2);
    }

    function test_Stats_EightPlayers() public {
        uint256[] memory w = new uint256[](8);
        uint256[8] memory v = [uint256(1), 1, 2, 5, 10, 20, 20, 41];
        for (uint256 i = 0; i < 8; i++) {
            w[i] = v[i];
        }
        _check(w, 20_000, 3);
    }

    /// @dev 主板实际规模：500 BEM、投入 1–20 BEM（以 BEM 最小单位，含小数）。按投入档位汇总频率。
    function test_Stats_RealisticBoard() public {
        uint256 n = 60;
        uint256[] memory w = new uint256[](n);
        uint256[5] memory tiers = [uint256(1e8), 2.5e8, 5e8, 10e8, 20e8];
        uint256 s;
        for (uint256 i = 0; i < n; i++) {
            w[i] = tiers[uint256(keccak256(abi.encode("tier", i))) % 5];
            s += w[i];
        }
        uint256 games = 2_000;
        TreeHarness h = new TreeHarness(n);
        uint256[] memory wins = h.runGames(w, games, 4);
        for (uint256 t = 0; t < 5; t++) {
            uint256 tierStake;
            uint256 tierWins;
            for (uint256 i = 0; i < n; i++) {
                if (w[i] == tiers[t]) {
                    tierStake += w[i];
                    tierWins += wins[i + 1];
                }
            }
            uint256 expected = games * tierStake / s;
            uint256 tol = 5 * _sqrt(games * tierStake / s * (s - tierStake) / s) + 2;
            uint256 diff = tierWins > expected ? tierWins - expected : expected - tierWins;
            console2.log("tier stake", tiers[t], "wins", tierWins);
            console2.log("   expected", expected, "tolerance", tol);
            assertLe(diff, tol, "tier frequency off");
        }
    }

    function _sqrt(uint256 x) internal pure returns (uint256 y) {
        if (x == 0) return 0;
        y = x;
        uint256 z = (x + 1) / 2;
        while (z < y) {
            y = z;
            z = (x / z + z) / 2;
        }
    }
}

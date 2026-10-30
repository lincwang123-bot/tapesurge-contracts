// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {TreeHarness} from "./utils/TreeHarness.sol";

/// @notice 树状数组 + 最大值线段树：精确穷举与模糊测试
contract EjectionTreeTest is Test {
    function _build(uint256[] memory stakes) internal returns (TreeHarness h) {
        h = new TreeHarness(stakes.length);
        for (uint256 i = 0; i < stakes.length; i++) {
            h.insert(i + 1, stakes[i]);
        }
    }

    /// @dev 白皮书例子：A 投 1、B 投 20、C 投 79。穷举 r ∈ [0, 200)，
    ///      每人被抽中的次数恰好是 S − wⱼ = 99 / 80 / 21，即 49.5% / 40% / 10.5%。
    function test_ExhaustiveFirstRoundMatchesWhitepaperExample() public {
        uint256[] memory w = new uint256[](3);
        w[0] = 1;
        w[1] = 20;
        w[2] = 79;
        TreeHarness h = _build(w);
        uint256[] memory c = h.countAll(3, 100);
        assertEq(c[1], 99);
        assertEq(c[2], 80);
        assertEq(c[3], 21);
    }

    /// @dev 中间有人出局后，剩下的人仍然恰好按 S − wⱼ 被抽中，出局者永远不会再被抽中。
    function test_ExhaustiveAfterRemoval() public {
        uint256[] memory w = new uint256[](5);
        w[0] = 5;
        w[1] = 7;
        w[2] = 11;
        w[3] = 13;
        w[4] = 2;
        TreeHarness h = _build(w);
        h.remove(2, 7);
        h.remove(5, 2);
        // 剩 5、11、13：S = 29，(n−1)S = 58
        uint256[] memory c = h.countAll(3, 29);
        assertEq(c[1], 24);
        assertEq(c[2], 0);
        assertEq(c[3], 18);
        assertEq(c[4], 16);
        assertEq(c[5], 0);
        assertEq(h.maxStake(), 13);
    }

    /// @dev 白皮书 3.2 节第二个例子：1、20、5、10、64
    function test_ExhaustiveFiveSlots() public {
        uint256[] memory w = new uint256[](5);
        w[0] = 1;
        w[1] = 20;
        w[2] = 5;
        w[3] = 10;
        w[4] = 64;
        TreeHarness h = _build(w);
        uint256[] memory c = h.countAll(5, 100);
        for (uint256 i = 0; i < 5; i++) {
            assertEq(c[i + 1], 100 - w[i]);
        }
    }

    /// @dev 随机投入、随机出局若干人后，二进制下降查找的结果与线性扫描完全一致。
    function testFuzz_SelectMatchesLinearScan(uint256 seed, uint8 nRaw, uint8 removeRaw) public {
        uint256 n = bound(nRaw, 2, 60);
        uint256[] memory w = new uint256[](n);
        for (uint256 i = 0; i < n; i++) {
            w[i] = bound(uint256(keccak256(abi.encode(seed, i))), 1, 40e8);
        }
        TreeHarness h = _build(w);
        bool[] memory gone = new bool[](n);
        uint256 removes = bound(removeRaw, 0, n - 2);
        for (uint256 k = 0; k < removes; k++) {
            uint256 j = uint256(keccak256(abi.encode(seed, "rm", k))) % n;
            while (gone[j]) j = (j + 1) % n;
            gone[j] = true;
            h.remove(j + 1, w[j]);
        }
        uint256 s;
        uint256 alive;
        uint256 maxW;
        for (uint256 i = 0; i < n; i++) {
            if (!gone[i]) {
                s += w[i];
                alive++;
                if (w[i] > maxW) maxW = w[i];
            }
        }
        assertEq(h.maxStake(), maxW);
        (uint256 cnt, uint256 sum) = h.prefix(n);
        assertEq(cnt, alive);
        assertEq(sum, s);
        for (uint256 q = 0; q < 8; q++) {
            uint256 r = uint256(keccak256(abi.encode(seed, "r", q))) % ((alive - 1) * s);
            // 线性扫描：第一个"前缀权重 > r"的人
            uint256 acc;
            uint256 expected;
            for (uint256 i = 0; i < n; i++) {
                if (gone[i]) continue;
                acc += s - w[i];
                if (acc > r) {
                    expected = i + 1;
                    break;
                }
            }
            assertEq(h.select(s, r), expected);
        }
    }

    function test_FindByCountAndMaxAfterRemovals() public {
        uint256[] memory w = new uint256[](6);
        for (uint256 i = 0; i < 6; i++) {
            w[i] = (i + 1) * 3;
        }
        TreeHarness h = _build(w);
        assertEq(h.maxStake(), 18);
        h.remove(6, 18);
        assertEq(h.maxStake(), 15);
        h.remove(1, 3);
        h.remove(3, 9);
        assertEq(h.findByCount(1), 2);
        assertEq(h.findByCount(2), 4);
        assertEq(h.findByCount(3), 5);
        h.remove(5, 15);
        h.remove(4, 12);
        assertEq(h.findByCount(1), 2);
        assertEq(h.maxStake(), 6);
        h.remove(2, 6);
        assertEq(h.maxStake(), 0);
    }

    function test_RevertWhen_SlotOutOfRange() public {
        TreeHarness h = new TreeHarness(4);
        vm.expectRevert();
        h.insert(0, 1);
        vm.expectRevert();
        h.insert(5, 1);
    }
}

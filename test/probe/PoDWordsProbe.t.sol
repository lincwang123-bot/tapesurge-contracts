// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test, console2} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";

interface IPoDProbe {
    function minerKey(address circuits, uint256 id) external view returns (bytes32);
    function claim(bytes32 key) external;
    function stop(bytes32 key) external;
    function pending(bytes32 key) external view returns (uint256);
    function totalVerifWeight() external view returns (uint256);
    function currentRate() external view returns (uint256);
    function processorMultiplier(address circuits) external view returns (uint256);
}

/// @title PoD getMiner 各字段含义 + 多合集矿机的产出比例（主网分叉）
/// @notice MARKET_PROBE=1 BSC_RPC_URL=<主网 RPC> forge test --match-contract PoDWordsProbe -vv
contract PoDWordsProbe is Test {
    IPoDProbe internal constant POD = IPoDProbe(0x7E2E0DC66a3bD9103E69b766afA62d9f7b697b46);
    IERC20 internal constant BEM = IERC20(0x5ce033B2bFCa3Af30b3e8C8457DeaF776A8b695a);
    address internal constant OFFICIAL = 0xb1024b89886B9a34Aa4ff5F31C411D708b20a14C;
    address internal constant BEHEMOTH = 0x1F5Cb4aeaE1807Bf60c3b9C0D8aDBCC14e91f12C;

    function setUp() public {
        if (!vm.envOr("MARKET_PROBE", false)) return;
        uint256 blk = vm.envOr("FORK_BLOCK", uint256(0));
        if (blk == 0) vm.createSelectFork(vm.envString("BSC_RPC_URL"));
        else vm.createSelectFork(vm.envString("BSC_RPC_URL"), blk);
    }

    function _words(bytes32 key) internal view returns (uint256[] memory w) {
        (bool ok, bytes memory ret) = address(POD).staticcall(abi.encodeWithSignature("getMiner(bytes32)", key));
        require(ok, "getMiner");
        w = new uint256[](ret.length / 32);
        for (uint256 i = 0; i < w.length; i++) {
            uint256 v;
            assembly {
                v := mload(add(add(ret, 32), mul(i, 32)))
            }
            w[i] = v;
        }
    }

    function _log(string memory tag, uint256[] memory w) internal pure {
        console2.log(tag);
        for (uint256 i = 0; i < w.length; i++) {
            if (i == 0 || i == 10) console2.log("  word", i, vm.toString(address(uint160(w[i]))));
            else console2.log("  word", i, w[i]);
        }
    }

    /// @dev 一天的产出 ÷ 各候选权重字段：PoD 按哪个字段分产出
    function _accrual(address col, uint256 id) internal returns (uint256 perDay, uint256[] memory w) {
        bytes32 key = POD.minerKey(col, id);
        w = _words(key);
        address owner = IERC721(col).ownerOf(id);
        POD.claim(key);
        uint256 b0 = BEM.balanceOf(owner);
        vm.warp(block.timestamp + 1 days);
        vm.roll(block.number + 115_200);
        POD.claim(key);
        perDay = BEM.balanceOf(owner) - b0;
        vm.warp(block.timestamp - 1 days);
        vm.roll(block.number - 115_200);
    }

    function test_WhichWeightPoDPays() public {
        if (!vm.envOr("MARKET_PROBE", false)) return vm.skip(true);
        console2.log("multiplier official", POD.processorMultiplier(OFFICIAL));
        console2.log("multiplier behemoth", POD.processorMultiplier(BEHEMOTH));
        console2.log("totalVerifWeight", POD.totalVerifWeight(), "rate", POD.currentRate());
        uint256 unit = POD.currentRate() * 1 days * 9900 / 10_000 / POD.totalVerifWeight();
        console2.log("unit per day (99% verified share / totalVerifWeight)", unit);

        uint256 snap = vm.snapshotState();
        (uint256 a, uint256[] memory wa) = _accrual(OFFICIAL, 8672);
        _log("official #8672", wa);
        console2.log("official per day", a, "per word3", a / wa[3]);
        console2.log("official per word19", a / wa[19]);
        vm.revertToState(snap);
        (uint256 b, uint256[] memory wb) = _accrual(BEHEMOTH, 1509);
        _log("behemoth #1509", wb);
        console2.log("behemoth per day", b, "per word3", b / wb[3]);
        console2.log("behemoth per word19", b / wb[19]);
    }

    /// @dev 停止挖矿后哪些字段变化（第 7 个字是不是"在挖"）
    function test_StopChangesWhichWords() public {
        if (!vm.envOr("MARKET_PROBE", false)) return vm.skip(true);
        address[2] memory cols = [OFFICIAL, BEHEMOTH];
        uint256[2] memory ids = [uint256(8672), 1509];
        for (uint256 k = 0; k < 2; k++) {
            bytes32 key = POD.minerKey(cols[k], ids[k]);
            uint256[] memory w0 = _words(key);
            vm.prank(IERC721(cols[k]).ownerOf(ids[k]));
            POD.stop(key);
            uint256[] memory w1 = _words(key);
            for (uint256 i = 0; i < w0.length; i++) {
                if (w0[i] != w1[i]) console2.log("changed word", i, w0[i], w1[i]);
            }
            console2.log("totalVerifWeight after stop", POD.totalVerifWeight());
        }
    }
}

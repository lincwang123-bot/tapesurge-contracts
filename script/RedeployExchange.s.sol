// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script, console2} from "forge-std/Script.sol";
import {PositionExchange} from "../src/month/PositionExchange.sol";

/// @notice 在 BSC 主网单独部署新版持仓盘口 PositionExchange（没有管理员、不可升级，升级就是换成新地址）。
///         构造参数全部从 deployments/56.json 读（BEM、MonthPositions、MonthFactory、BoardFactory），和旧盘口逐项核对；
///         旧盘口必须从没挂过买单、托管为 0，否则拒绝（有托管时要先通知买家撤单）。链上没有任何合约引用盘口地址，
///         部署后把三份 56.json（contracts / bot / dapp）里的 positionExchange 换成新地址，再跑 mainnet.sh check。
///
///         只模拟：  forge script script/RedeployExchange.s.sol --rpc-url $BSC_RPC_URL --sender <你的地址>
///         广播：    同上加 --broadcast --account <keystore 名>（或 --ledger），由你自己签名
contract RedeployExchange is Script {
    function run() external returns (PositionExchange fresh) {
        require(block.chainid == 56, "RedeployExchange: only BSC mainnet (chain id 56)");
        string memory json = vm.readFile(vm.envOr("DEPLOYMENT_FILE", string("deployments/56.json")));
        address bem = vm.parseJsonAddress(json, ".bem");
        address positions = vm.parseJsonAddress(json, ".monthPositions");
        address monthFactory = vm.parseJsonAddress(json, ".monthFactory");
        address factory = vm.parseJsonAddress(json, ".factory");
        PositionExchange old = PositionExchange(vm.parseJsonAddress(json, ".positionExchange"));

        require(address(old.BEM()) == bem, "old exchange BEM mismatch");
        require(address(old.POSITIONS()) == positions, "old exchange POSITIONS mismatch");
        require(address(old.FACTORY()) == monthFactory, "old exchange FACTORY mismatch");
        require(address(old.STD_FACTORY()) == factory, "old exchange STD_FACTORY mismatch");
        require(old.lastBidId() == 0 && old.totalEscrow() == 0, "old exchange has bids: ask bidders to cancel first");
        console2.log("old exchange", address(old), "bids 0, escrow 0");

        vm.startBroadcast();
        fresh = new PositionExchange(bem, positions, monthFactory, factory);
        vm.stopBroadcast();

        require(fresh.bidEpoch(0) == 0, "fresh exchange lacks bidEpoch");
        console2.log("new PositionExchange", address(fresh));
        console2.log("next: set positionExchange in contracts/, bot/ and dapp/ deployments/56.json, then mainnet.sh check");
    }
}

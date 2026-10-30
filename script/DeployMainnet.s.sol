// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script, console2} from "forge-std/Script.sol";
import {TapeSurgeDefaults} from "./TapeSurgeDefaults.sol";
import {TapeSurgeDeploy} from "./TapeSurgeDeploy.sol";
import {PancakeV3TwapOracle} from "../src/oracle/PancakeV3TwapOracle.sol";
import {ITapeOutFactory, IBeacon, ITransistors} from "../src/interfaces/ITapeOut.sol";

interface ISafeView {
    function getThreshold() external view returns (uint256);
    function getOwners() external view returns (address[] memory);
}

interface IVRFCoordinatorView {
    function getSubscription(uint256 subId)
        external
        view
        returns (uint96 balance, uint96 nativeBalance, uint64 reqCount, address owner, address[] memory consumers);
}

interface IERC1155Balance {
    function balanceOf(address account, uint256 id) external view returns (uint256);
}

interface IV3PoolView {
    function observe(uint32[] calldata secondsAgos) external view returns (int56[] memory, uint160[] memory);
}

/// @title BSC 主网部署脚本（只接受链 ID 56）
/// @notice 用 script/mainnet.sh 执行：simulate（默认，只模拟）/ deploy（需要你自己的 --account 或 --ledger，
///         手动输入 DEPLOY 才广播）/ check（部署后的只读核对）。部署逻辑在 script/TapeSurgeDeploy.sol，
///         主网地址在 TapeSurgeDefaults.mainnetAddresses()。
///
///         环境变量：
///         - OPERATOR（必填，非零）：运营地址。等于部署者时会打印警告（运营私钥应该是单独的热钱包）。
///         - VRF_SUBSCRIPTION_ID（必填）：Chainlink VRF v2.5 订阅号（vrf.chain.link 上创建）。
///         - VRF_KEY_HASH（默认 200 gwei 档）、VRF_NATIVE_PAYMENT（默认 true，用 BNB 付费）、
///           VRF_CONFIRMATIONS（默认 10，理由见 TapeSurgeDefaults.MAINNET_VRF_CONFIRMATIONS）。
///         - MAX_GAS_PRICE_WEI（默认 0.1 gwei，BSC 当前约 0.05 gwei）：余额检查按这个 gas 价格算。
///         - RESERVE_TRANSISTORS（默认 330 = 66 张通行证，规则决定 6.32；0 = 不铸）：全部合约部署完后，同一批广播的最后一笔
///           由部署者按公开价格（每颗 0.001 BNB + TapeOut 协议费）铸造这么多颗 NAND，留作社区空投。
///         - PENDING_FILE（默认 deployments/56.pending.json）：模拟阶段写出的地址文件；mainnet.sh 在广播后确认
///           每个合约都已上链，才把它改名为 deployments/56.json。
///
///         部署前自检（不通过就 revert）：每个外部地址都有代码；读出 deployFee 和电路信标当前的 implementation
///         （升级哨兵的基准）；两个池子的 30 分钟 TWAP 能读出来、观测记录覆盖 2 个窗口（1 小时），并打印 observation
///         cardinality；在本地试部署一个预言机，确认 1 BNB 能报出 BEM 价；两个 Safe 读得出 getThreshold / getOwners；
///         VRF 订阅所有者 = EXPECT_VRF_OWNER（默认项目方钱包）、预测的适配器地址已经是 consumer、订阅 BNB 余额 ≥ 0.02
///         （全局审计 G-4）；部署者余额够用；运营地址非零。部署后核对所有预测地址。
contract DeployMainnet is Script {
    uint256 internal constant DEPLOY_GAS_ESTIMATE = 50_000_000; // v2.0-rc8 分叉演练实测 4,271 万（15 笔），留余量

    function run() public virtual {
        require(block.chainid == 56, "DeployMainnet: only BSC mainnet (chain id 56)");
        (, address deployer,) = vm.readCallers();
        TapeSurgeDeploy.Settings memory s = _settings(deployer);
        _preflight(deployer, s);

        uint256 reserve = vm.envOr("RESERVE_TRANSISTORS", TapeSurgeDefaults.RESERVE_TRANSISTORS);
        vm.startBroadcast();
        TapeSurgeDeploy.Deployment memory d = TapeSurgeDeploy.deployMainnet(deployer, s);
        // 规则决定 6.32：社区空投预留，按公开价格铸造（铸造费照常进分账合约）。排在全部部署之后：部署地址按 nonce 预先算好
        if (reserve > 0) {
            ITransistors t = d.splitter.transistors();
            t.mint{value: (TapeSurgeDefaults.MINT_PRICE + t.protocolFee()) * reserve}(0, reserve); // 0 = NAND
        }
        vm.stopBroadcast();
        if (reserve > 0) {
            console2.log("reserved NAND transistors for the community airdrop", reserve, "passes", reserve / 5);
            console2.log("  deployer NAND balance", IERC1155Balance(address(d.splitter.transistors())).balanceOf(deployer, 0));
        }

        _log(d);
        _writePending(d);
        console2.log("");
        console2.log("NEXT STEPS:");
        console2.log("  1. bash script/mainnet.sh check   (VRF consumer", address(d.adapter), "was checked in preflight)");
        console2.log("  2. start the operator bot: it must post the first price before genesis (startGenesis reverts");
        console2.log("     FeedNotPosted until then)");
        console2.log("  3. genesis countdown has started: startGenesis() after 7 days or 10,000 transistors");
    }

    // =====================================================================
    // 设置
    // =====================================================================

    function _settings(address deployer) internal view returns (TapeSurgeDeploy.Settings memory s) {
        address op = vm.envOr("OPERATOR", address(0));
        require(op != address(0), "set OPERATOR (operator hot wallet address, non-zero)");
        uint256 subId = vm.envOr("VRF_SUBSCRIPTION_ID", uint256(0));
        require(subId != 0, "set VRF_SUBSCRIPTION_ID (Chainlink VRF v2.5 subscription id)");
        s = TapeSurgeDeploy.defaultSettings(op, subId);
        s.vrfKeyHash = vm.envOr("VRF_KEY_HASH", s.vrfKeyHash);
        s.vrfNativePayment = vm.envOr("VRF_NATIVE_PAYMENT", s.vrfNativePayment);
        uint256 conf = vm.envOr("VRF_CONFIRMATIONS", uint256(s.vrfConfirmations));
        require(conf >= 3 && conf <= 200, "VRF_CONFIRMATIONS must be 3-200 (Chainlink limits)");
        s.vrfConfirmations = uint16(conf);
        if (op == deployer) {
            console2.log("WARNING: OPERATOR == deployer. Use a separate operator hot wallet for the bot.");
        }
    }

    // =====================================================================
    // 部署前自检
    // =====================================================================

    function _preflight(address deployer, TapeSurgeDeploy.Settings memory s) internal {
        TapeSurgeDefaults.Mainnet memory m = TapeSurgeDefaults.mainnetAddresses();
        console2.log("== preflight (BSC mainnet, block", block.number, ")");
        console2.log("deployer", deployer);
        console2.log("operator", s.operator);

        _hasCode("TapeOut factory", m.tapeoutFactory);
        _hasCode("PoD", m.pod);
        _hasCode("machine circuits", m.machineCircuits);
        _hasCode("circuits beacon", m.circuitsBeacon);
        _hasCode("BEM", m.bem);
        _hasCode("WBNB", m.wbnb);
        _hasCode("USDT", m.usdt);
        _hasCode("Pancake V3 router", m.router);
        _hasCode("pool WBNB/USDT", m.poolWbnbUsdt);
        _hasCode("pool USDT/BEM", m.poolUsdtBem);
        _hasCode("VRF coordinator", m.vrfCoordinator);
        _hasCode("foundation Safe", m.foundationSafe);
        _hasCode("fee Safe", m.feeSafe);
        _hasCode("Firsto ask exchange", m.firstoAskExchange);
        _hasCode("Firsto bid exchange", m.firstoBidExchange);
        _hasCode("TapeOut official market", m.officialMarket);
        _hasCode("Seaport 1.6", m.seaport);

        uint256 fee = ITapeOutFactory(m.tapeoutFactory).deployFee();
        console2.log("createCPU deployFee (wei)", fee);
        console2.log("circuits beacon implementation (sentinel baseline)", IBeacon(m.circuitsBeacon).implementation());

        _pool("WBNB/USDT", m.poolWbnbUsdt);
        _pool("USDT/BEM", m.poolUsdtBem);
        // 本地试部署一个预言机（不广播），确认整条路径能报价
        {
            address[] memory tokens = new address[](3);
            tokens[0] = m.wbnb;
            tokens[1] = m.usdt;
            tokens[2] = m.bem;
            address[] memory pools = new address[](2);
            pools[0] = m.poolWbnbUsdt;
            pools[1] = m.poolUsdtBem;
            PancakeV3TwapOracle probe = new PancakeV3TwapOracle(tokens, pools, TapeSurgeDefaults.TWAP_WINDOW);
            uint256 q = probe.quoteBemOut(1 ether);
            require(q > 0, "TWAP quote is zero");
            console2.log("TWAP 30m: 1 BNB -> BEM (8 decimals)", q);
        }

        _safe("foundation Safe", m.foundationSafe);
        _safe("fee Safe", m.feeSafe);

        _vrf(m.vrfCoordinator, s, deployer);

        uint256 maxGasPrice = vm.envOr("MAX_GAS_PRICE_WEI", uint256(0.1 gwei)); // BSC 当前约 0.05 gwei
        uint256 reserve = vm.envOr("RESERVE_TRANSISTORS", TapeSurgeDefaults.RESERVE_TRANSISTORS);
        // 预留铸造：每颗 0.001 BNB + 协议费（主网实测 0.0001 BNB；这里按 0.0002 留余量），另加 50 万 gas
        uint256 reserveCost = reserve * (TapeSurgeDefaults.MINT_PRICE + 0.0002 ether);
        uint256 need = fee + reserveCost + (DEPLOY_GAS_ESTIMATE + (reserve > 0 ? 500_000 : 0)) * maxGasPrice;
        console2.log("community reserve: NAND transistors", reserve, "cost about (wei)", reserveCost);
        console2.log("deployer balance (wei)", deployer.balance, "needed (wei)", need);
        require(deployer.balance >= need, "deployer balance too low (deployFee + reserve mint + gas at MAX_GAS_PRICE_WEI)");

        _predicted(deployer);
        console2.log("== preflight ok");
    }

    /// @dev 订阅所有者、预测的适配器地址已在 consumer 名单里、订阅余额：不满足就不部署（全局审计 G-4）
    function _vrf(address coordinator, TapeSurgeDeploy.Settings memory s, address deployer) internal view {
        (uint96 bal, uint96 nativeBal, uint64 reqCount, address subOwner, address[] memory consumers) =
            IVRFCoordinatorView(coordinator).getSubscription(s.vrfSubscriptionId);
        console2.log("VRF subscription", s.vrfSubscriptionId, "owner", subOwner);
        console2.log("  LINK balance", uint256(bal), "native balance (wei)", uint256(nativeBal));
        console2.log("  requests so far", uint256(reqCount), "consumers", consumers.length);
        require(
            subOwner == vm.envOr("EXPECT_VRF_OWNER", TapeSurgeDefaults.MAINNET_VRF_OWNER),
            "VRF subscription owner is not EXPECT_VRF_OWNER"
        );
        (, address adapter,,,) = TapeSurgeDeploy.predict(deployer);
        bool isConsumer;
        for (uint256 i = 0; i < consumers.length; i++) {
            if (consumers[i] == adapter) isConsumer = true;
        }
        require(isConsumer, "add the predicted ChainlinkVRFAdapter as a subscription consumer first");
        console2.log("  predicted adapter is a consumer", adapter);
        if (s.vrfNativePayment) require(nativeBal >= TapeSurgeDefaults.MIN_VRF_NATIVE, "VRF subscription BNB balance < 0.02");
        else require(bal > 0, "VRF subscription has no LINK balance");
        console2.log("  keyHash");
        console2.logBytes32(s.vrfKeyHash);
        console2.log("  confirmations", uint256(s.vrfConfirmations), "callback gas", TapeSurgeDefaults.VRF_CALLBACK_GAS);
        console2.log("  native payment", s.vrfNativePayment);
    }

    function _predicted(address deployer) internal view {
        (address o, address a, address sp, address f, address mf) = TapeSurgeDeploy.predict(deployer);
        console2.log("predicted PancakeV3TwapOracle", o);
        console2.log("predicted ChainlinkVRFAdapter", a);
        console2.log("predicted GenesisSplitter", sp);
        console2.log("predicted BoardFactory (splitter.boardFactory / adapter.registry)", f);
        console2.log("predicted MonthFactory", mf);
        (address pos, address sal, address gov, address ex) = TapeSurgeDeploy.predictMonthV2(deployer);
        console2.log("predicted MonthPositions (v2)", pos);
        console2.log("predicted MonthMachineSales (v2)", sal);
        console2.log("predicted MonthExitGovernor (v2)", gov);
        console2.log("predicted PositionExchange (v2)", ex);
        console2.log("predicted MarketPriceFeed", TapeSurgeDeploy.predictPriceFeed(deployer));
        console2.log("predicted StdMachineSales", TapeSurgeDeploy.predictStdSales(deployer));
        (address fs, address ft, address mr, address ml) = TapeSurgeDeploy.predictMarkets(deployer);
        console2.log("predicted PancakeFirstoSwapper", fs);
        console2.log("predicted MarketTrader", ft);
        console2.log("predicted MachineRules", mr);
        console2.log("predicted MachineLister", ml);
    }

    function _hasCode(string memory name, address a) internal view {
        require(a.code.length > 0, string.concat("no code at ", name));
    }

    function _pool(string memory name, address pool) internal view {
        (bool ok, bytes memory ret) = pool.staticcall(abi.encodeWithSignature("slot0()"));
        require(ok && ret.length >= 128, string.concat("cannot read slot0 of ", name));
        (,,, uint16 cardinality) = abi.decode(ret, (uint160, int24, uint16, uint16));
        uint32[] memory ago = new uint32[](2);
        ago[0] = TapeSurgeDefaults.TWAP_WINDOW;
        ago[1] = 0;
        (int56[] memory cum,) = IV3PoolView(pool).observe(ago);
        int56 avgTick = (cum[1] - cum[0]) / int56(uint56(TapeSurgeDefaults.TWAP_WINDOW));
        console2.log(string.concat("pool ", name, " observation cardinality"), uint256(cardinality));
        console2.log(string.concat("pool ", name, " 30m average tick"), int256(avgTick));
        // 观测记录至少覆盖 2 个 TWAP 窗口（全局审计 G-4 / L-4）：覆盖不到时 observe 回滚
        ago[0] = uint32(TapeSurgeDefaults.MIN_TWAP_COVERAGE);
        (bool covered,) = pool.staticcall(abi.encodeCall(IV3PoolView.observe, (ago)));
        require(covered, string.concat("observations of ", name, " cover less than 2 TWAP windows"));
    }

    function _safe(string memory name, address safe) internal view {
        uint256 threshold = ISafeView(safe).getThreshold();
        address[] memory owners = ISafeView(safe).getOwners();
        require(threshold > 0 && owners.length >= threshold, string.concat("bad Safe ", name));
        console2.log(string.concat(name, " ", vm.toString(threshold), " of ", vm.toString(owners.length)), safe);
        for (uint256 i = 0; i < owners.length; i++) {
            console2.log("  owner", owners[i]);
        }
    }

    // =====================================================================
    // 输出
    // =====================================================================

    function _log(TapeSurgeDeploy.Deployment memory d) internal view {
        console2.log("== deployed");
        console2.log("PancakeV3TwapOracle", address(d.oracle));
        console2.log("ChainlinkVRFAdapter", address(d.adapter));
        console2.log("GenesisSplitter", address(d.splitter));
        console2.log("BoardFactory", address(d.factory));
        console2.log("MonthFactory", address(d.monthFactory));
        console2.log("TapeBoard implementation", d.factory.boardImplementation());
        console2.log("MonthBoard implementation", d.monthFactory.boardImplementation());
        console2.log("MonthPositions", address(d.positions));
        console2.log("MonthMachineSales", address(d.sales));
        console2.log("MonthExitGovernor", address(d.governor));
        console2.log("PositionExchange", address(d.exchange));
        console2.log("MarketPriceFeed", address(d.priceFeed));
        console2.log("StdMachineSales", address(d.stdSales));
        console2.log("PancakeFirstoSwapper", address(d.swapper));
        console2.log("MarketTrader", address(d.trader));
        console2.log("MachineRules", address(d.rules));
        console2.log("MachineLister", address(d.lister));
        console2.log("Genesis transistors", address(d.factory.transistors()));
        console2.log("Genesis circuits (passes)", d.factory.passCircuits());
        console2.log("operator", d.factory.operator());
        console2.log("genesis possible at (unix)", d.splitter.mintStart() + d.factory.genesisDelay());
    }

    /// @dev 键名和测试网的 deployments/97.json 一致（dApp 和运营机器人直接读这个文件），另加 vrfAdapter、operator、fromBlock。
    ///      fromBlock 先写模拟时的区块号（一定不晚于第一笔部署交易）；mainnet.sh 广播后会改成第一笔部署交易实际所在的区块。
    function _writePending(TapeSurgeDeploy.Deployment memory d) internal {
        TapeSurgeDefaults.Mainnet memory m = TapeSurgeDefaults.mainnetAddresses();
        string memory o = "mainnet";
        vm.serializeAddress(o, "bem", m.bem);
        vm.serializeAddress(o, "factory", address(d.factory));
        vm.serializeAddress(o, "monthFactory", address(d.monthFactory));
        vm.serializeAddress(o, "monthPositions", address(d.positions));
        vm.serializeAddress(o, "monthSales", address(d.sales));
        vm.serializeAddress(o, "monthGovernor", address(d.governor));
        vm.serializeAddress(o, "positionExchange", address(d.exchange));
        vm.serializeAddress(o, "priceFeed", address(d.priceFeed));
        vm.serializeAddress(o, "stdSales", address(d.stdSales));
        vm.serializeAddress(o, "firstoSwapper", address(d.swapper));
        vm.serializeAddress(o, "marketTrader", address(d.trader));
        vm.serializeAddress(o, "machineRules", address(d.rules));
        vm.serializeAddress(o, "machineLister", address(d.lister));
        vm.serializeAddress(o, "officialMarket", m.officialMarket);
        vm.serializeAddress(o, "seaport", m.seaport);
        vm.serializeAddress(o, "firstoAskExchange", m.firstoAskExchange);
        vm.serializeAddress(o, "firstoBidExchange", m.firstoBidExchange);
        vm.serializeAddress(o, "splitter", address(d.splitter));
        vm.serializeAddress(o, "transistors", address(d.factory.transistors()));
        vm.serializeAddress(o, "passCircuits", d.factory.passCircuits());
        vm.serializeAddress(o, "machines", m.machineCircuits);
        vm.serializeAddress(o, "pod", m.pod);
        vm.serializeAddress(o, "randomSource", address(d.adapter));
        vm.serializeAddress(o, "vrfAdapter", address(d.adapter));
        vm.serializeAddress(o, "router", m.router);
        vm.serializeAddress(o, "oracle", address(d.oracle));
        vm.serializeAddress(o, "tapeout", m.tapeoutFactory);
        vm.serializeAddress(o, "operator", d.factory.operator());
        vm.serializeBool(o, "mockRandom", false);
        string memory json = vm.serializeUint(o, "fromBlock", block.number);
        string memory path = vm.envOr("PENDING_FILE", string("deployments/56.pending.json"));
        vm.writeJson(json, path);
        console2.log("addresses written to", path, "(renamed to 56.json after the on-chain check)");
    }
}

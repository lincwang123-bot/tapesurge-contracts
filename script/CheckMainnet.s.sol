// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script, console2} from "forge-std/Script.sol";
import {TapeSurgeDefaults} from "./TapeSurgeDefaults.sol";
import {BoardFactory} from "../src/BoardFactory.sol";
import {MonthFactory} from "../src/MonthFactory.sol";
import {GenesisSplitter} from "../src/GenesisSplitter.sol";
import {TapeBoard} from "../src/TapeBoard.sol";
import {MonthBoard} from "../src/MonthBoard.sol";
import {MonthPositions} from "../src/month/MonthPositions.sol";
import {MonthMachineSales} from "../src/month/MonthMachineSales.sol";
import {MonthExitGovernor} from "../src/month/MonthExitGovernor.sol";
import {PositionExchange} from "../src/month/PositionExchange.sol";
import {MarketPriceFeed} from "../src/MarketPriceFeed.sol";
import {StdMachineSales} from "../src/StdMachineSales.sol";
import {MarketTrader} from "../src/market/MarketTrader.sol";
import {MachineLister} from "../src/market/MachineLister.sol";
import {MachineRules} from "../src/MachineRules.sol";
import {PancakeFirstoSwapper} from "../src/firsto/PancakeFirstoSwapper.sol";
import {ChainlinkVRFAdapter} from "../src/random/ChainlinkVRFAdapter.sol";
import {PancakeV3TwapOracle} from "../src/oracle/PancakeV3TwapOracle.sol";
import {ITransistors} from "../src/interfaces/ITapeOut.sol";

interface IVRFSubscriptionView {
    function getSubscription(uint256 subId)
        external
        view
        returns (uint96 balance, uint96 nativeBalance, uint64 reqCount, address owner, address[] memory consumers);
}

interface IPancakeV3PoolView {
    function slot0()
        external
        view
        returns (uint160, int24, uint16 observationIndex, uint16 observationCardinality, uint16, uint32, bool);
    function observations(uint256 index) external view returns (uint32 blockTimestamp, int56, uint160, bool initialized);
}

/// @title 主网部署后的只读核对（bash script/mainnet.sh check）
/// @notice 读取 deployments/56.json（DEPLOYMENT_FILE 可改），打印所有参数、收款地址、运营地址、哨兵状态、分账比例、
///         创世倒计时截止时间，和 TapeSurgeDefaults 的预期值逐项比较，不一致的标红（"MISMATCH"）。
///         EXPECT_OPERATOR 设置时同时核对运营地址。VRF 订阅所有者、适配器在 consumer 名单里、订阅余额、两个池子的观测覆盖时间
///         都是硬性检查（全局审计 G-4），不满足就算不通过。不发送任何交易。
contract CheckMainnet is Script {
    // forge 打印日志时会去掉颜色转义；颜色由 script/mainnet.sh 加（含 MISMATCH 的行标红）
    string internal constant RED = "";
    string internal constant GREEN = "";
    string internal constant RESET = "";

    uint256 internal mismatches;
    uint256 internal checks;

    BoardFactory internal factory;
    MonthFactory internal monthFactory;
    GenesisSplitter internal splitter;
    ChainlinkVRFAdapter internal adapter;
    PancakeV3TwapOracle internal oracle;
    MonthPositions internal positions;
    MonthMachineSales internal sales;
    MonthExitGovernor internal governor;
    PositionExchange internal exchange;
    MarketPriceFeed internal feed;
    StdMachineSales internal stdSales;
    MarketTrader internal ftrader;
    MachineRules internal rules;
    MachineLister internal lister;
    PancakeFirstoSwapper internal fswapper;

    function run() public {
        require(block.chainid == 56, "CheckMainnet: only BSC mainnet (chain id 56)");
        string memory json = vm.readFile(vm.envOr("DEPLOYMENT_FILE", string("deployments/56.json")));
        factory = BoardFactory(vm.parseJsonAddress(json, ".factory"));
        monthFactory = MonthFactory(vm.parseJsonAddress(json, ".monthFactory"));
        splitter = GenesisSplitter(payable(vm.parseJsonAddress(json, ".splitter")));
        adapter = ChainlinkVRFAdapter(vm.parseJsonAddress(json, ".vrfAdapter"));
        oracle = PancakeV3TwapOracle(vm.parseJsonAddress(json, ".oracle"));
        positions = MonthPositions(vm.parseJsonAddress(json, ".monthPositions"));
        sales = MonthMachineSales(vm.parseJsonAddress(json, ".monthSales"));
        governor = MonthExitGovernor(vm.parseJsonAddress(json, ".monthGovernor"));
        exchange = PositionExchange(vm.parseJsonAddress(json, ".positionExchange"));
        feed = MarketPriceFeed(vm.parseJsonAddress(json, ".priceFeed"));
        stdSales = StdMachineSales(vm.parseJsonAddress(json, ".stdSales"));
        ftrader = MarketTrader(payable(vm.parseJsonAddress(json, ".marketTrader")));
        rules = MachineRules(vm.parseJsonAddress(json, ".machineRules"));
        lister = MachineLister(payable(vm.parseJsonAddress(json, ".machineLister")));
        fswapper = PancakeFirstoSwapper(payable(vm.parseJsonAddress(json, ".firstoSwapper")));

        TapeSurgeDefaults.Mainnet memory m = TapeSurgeDefaults.mainnetAddresses();
        TapeSurgeDefaults.Addresses memory a =
            TapeSurgeDefaults.mainnetAddressesFor(m, address(oracle), address(adapter));
        a.monthPositions = address(positions);
        a.monthSales = address(sales);
        a.monthGovernor = address(governor);
        a.priceFeed = address(feed);
        a.stdSales = address(stdSales);
        a.marketTrader = address(ftrader);
        a.machineRules = address(rules);
        console2.log("== TapeSurge mainnet check, block", block.number, "time", block.timestamp);

        _wiring(m);
        _splitter(a);
        _boards(a);
        _monthV2(m);
        _vrf(m);
        _oracle(m);
        _status();

        console2.log("");
        if (mismatches == 0) {
            console2.log(string.concat(GREEN, "ALL CHECKS PASSED: ", vm.toString(checks), " checks", RESET));
        } else {
            console2.log(
                string.concat(
                    RED, "MISMATCH: ", vm.toString(mismatches), " of ", vm.toString(checks), " checks failed", RESET
                )
            );
        }
    }

    // ---------------- 各部分 ----------------

    function _wiring(TapeSurgeDefaults.Mainnet memory m) internal {
        console2.log("-- wiring");
        _addr("splitter.boardFactory", splitter.boardFactory(), address(factory));
        _addr("factory.splitter", address(factory.splitter()), address(splitter));
        _addr("factory.monthFactory", factory.monthFactory(), address(monthFactory));
        _addr("monthFactory.hub", monthFactory.hub(), address(factory));
        _addr("adapter.registry", address(adapter.registry()), address(factory));
        _addr("transistors.creator", ITransistors(address(factory.transistors())).creator(), address(splitter));
        _addr("factory.passCircuits", factory.passCircuits(), splitter.circuits());
        _uint("transistors.supplyCap", ITransistors(address(factory.transistors())).supplyCap(), 66_666);
        _addr("TapeBoard impl FACTORY", TapeBoard(factory.boardImplementation()).FACTORY(), address(factory));
        _addr("MonthBoard impl HUB", MonthBoard(monthFactory.boardImplementation()).HUB(), address(factory));
        _addr(
            "TapeBoard impl machine beacon", TapeBoard(factory.boardImplementation()).MACHINE_BEACON(), m.circuitsBeacon
        );
        _addr("TapeBoard impl pass beacon", TapeBoard(factory.boardImplementation()).PASS_BEACON(), m.circuitsBeacon);
        address op = factory.operator();
        address expectOp = vm.envOr("EXPECT_OPERATOR", address(0));
        if (expectOp != address(0)) _addr("operator", op, expectOp);
        else console2.log("operator (set EXPECT_OPERATOR to verify)", op);
        _bool("operator is non-zero", op != address(0), true);
    }

    function _splitter(TapeSurgeDefaults.Addresses memory a) internal {
        console2.log("-- splitter (mint revenue)");
        GenesisSplitter.Params memory sp = TapeSurgeDefaults.splitterParams(a);
        _addr("foundation (Safe)", splitter.foundation(), sp.foundation);
        _addr("project (fee Safe)", splitter.project(), sp.project);
        _uint("buybackBps", splitter.buybackBps(), sp.buybackBps);
        _uint("projectBps", splitter.projectBps(), sp.projectBps);
        _uint("foundationBps", splitter.foundationBps(), sp.foundationBps);
        for (uint256 i = 0; i < 5; i++) {
            _uint(string.concat("bucketBps[", vm.toString(i + 1), "]"), splitter.bucketBps(i + 1), sp.bucketBps[i]);
        }
        _uint("mintPrice (wei)", _mintPrice(), sp.mintPrice);
        _addr("bem", address(splitter.bem()), sp.bem);
        _addr("wbnb", splitter.wbnb(), sp.wbnb);
        _addr("router", address(splitter.router()), sp.router);
        _addr("oracle", address(splitter.oracle()), sp.oracle);
        _bytes("swapPath", splitter.swapPath(), sp.swapPath);
        _uint("maxSwapPerCall (wei)", splitter.maxSwapPerCall(), sp.maxSwapPerCall);
        _uint("minSwapInterval (s)", splitter.minSwapInterval(), sp.minSwapInterval);
        _uint("maxSlippageBps", splitter.maxSlippageBps(), sp.maxSlippageBps);
    }

    function _boards(TapeSurgeDefaults.Addresses memory a) internal {
        console2.log("-- standard board config");
        BoardFactory.Params memory p = TapeSurgeDefaults.params(a);
        TapeBoard.Config memory want = p.board;
        want.passCircuits = factory.passCircuits();
        want.splitter = address(splitter);
        TapeBoard.Config memory got = factory.boardConfig();
        _addr("payee foundation", got.foundation, want.foundation);
        _addr("payee feeRecipient", got.feeRecipient, want.feeRecipient);
        _addr("randomSource", got.randomSource, want.randomSource);
        _uint("entryFeeBps", got.entryFeeBps, want.entryFeeBps);
        _uint("recruitDuration", got.recruitDuration, want.recruitDuration);
        _uint("operatorGrace", got.operatorGrace, want.operatorGrace);
        _addr("std positions", got.positions, want.positions);
        _uint("sentinelResumeDelay", got.sentinelResumeDelay, want.sentinelResumeDelay);
        _uint("claimWindow", got.claimWindow, want.claimWindow);
        _bool(
            "full standard config == TapeSurgeDefaults", keccak256(abi.encode(got)) == keccak256(abi.encode(want)), true
        );
        _uint("initialTarget", factory.initialTarget(), p.targets.initialTarget);
        _uint("minTarget", factory.minTarget(), p.targets.minTarget);
        _uint("maxTarget", factory.maxTarget(), p.targets.maxTarget);
        _uint("minStakeBps", factory.minStakeBps(), p.targets.minStakeBps);
        _uint("maxStakeBps", factory.maxStakeBps(), p.targets.maxStakeBps);
        _uint("genesisMintThreshold", factory.genesisMintThreshold(), p.genesisMintThreshold);
        _uint("genesisDelay", factory.genesisDelay(), p.genesisDelay);

        console2.log("-- month board config");
        MonthFactory.Params memory mp = TapeSurgeDefaults.monthParams(a);
        MonthBoard.Config memory mwant = mp.board;
        mwant.passCircuits = factory.passCircuits();
        mwant.splitter = address(splitter);
        mwant.hub = address(factory);
        MonthBoard.Config memory mgot = monthFactory.boardConfig();
        _addr("payee foundation", mgot.foundation, mwant.foundation);
        _addr("payee feeRecipient", mgot.feeRecipient, mwant.feeRecipient);
        _uint("miningDuration", mgot.miningDuration, mwant.miningDuration);
        _uint("month entryFeeBps", mgot.entryFeeBps, mwant.entryFeeBps);
        _uint("month premiumFeeBps", mgot.premiumFeeBps, mwant.premiumFeeBps);
        _addr("month positions", mgot.positions, mwant.positions);
        _addr("month sales", mgot.sales, mwant.sales);
        _addr("month governor", mgot.governor, mwant.governor);
        _bool(
            "full month config == TapeSurgeDefaults", keccak256(abi.encode(mgot)) == keccak256(abi.encode(mwant)), true
        );
        _uint("month initialTarget", monthFactory.initialTarget(), mp.targets.initialTarget);
    }

    /// @dev v2 月局单例：相互引用、不可变参数（和 TapeSurgeDefaults 一致）
    function _monthV2(TapeSurgeDefaults.Mainnet memory m) internal {
        console2.log("-- v2 month singletons");
        _addr("positions.factory", address(positions.factory()), address(monthFactory));
        _addr("positions.stdFactory", address(positions.stdFactory()), address(factory));
        _addr("sales.BEM", address(sales.BEM()), m.bem);
        _addr("sales.FACTORY", address(sales.FACTORY()), address(monthFactory));
        _addr("sales.HUB", address(sales.HUB()), address(factory));
        _addr("sales.GOVERNOR", sales.GOVERNOR(), address(governor));
        _uint("sales.OPERATOR_GRACE", sales.OPERATOR_GRACE(), monthFactory.boardConfig().operatorGrace);
        _uint("sales.PLAN_DECAY", sales.PLAN_DECAY(), TapeSurgeDefaults.MONTH_PLAN_DECAY);
        _addr("governor.FACTORY", address(governor.FACTORY()), address(monthFactory));
        _addr("governor.SALES", address(governor.SALES()), address(sales));
        _uint("governor.MIN_SETTLE_AGE", governor.MIN_SETTLE_AGE(), TapeSurgeDefaults.GOV_MIN_SETTLE_AGE);
        _uint("governor.VOTE_PERIOD", governor.VOTE_PERIOD(), TapeSurgeDefaults.GOV_VOTE_PERIOD);
        _uint("governor.EXECUTION_DELAY", governor.EXECUTION_DELAY(), TapeSurgeDefaults.GOV_EXECUTION_DELAY);
        _uint("governor.EXECUTION_WINDOW", governor.EXECUTION_WINDOW(), TapeSurgeDefaults.GOV_EXECUTION_WINDOW);
        _uint("governor.FAIL_COOLDOWN", governor.FAIL_COOLDOWN(), TapeSurgeDefaults.GOV_FAIL_COOLDOWN);
        _uint("governor.REPRICE_COOLDOWN", governor.REPRICE_COOLDOWN(), TapeSurgeDefaults.GOV_REPRICE_COOLDOWN);
        _addr("exchange.BEM", address(exchange.BEM()), m.bem);
        _addr("exchange.POSITIONS", address(exchange.POSITIONS()), address(positions));
        _addr("exchange.FACTORY", address(exchange.FACTORY()), address(monthFactory));
        _addr("exchange.STD_FACTORY", address(exchange.STD_FACTORY()), address(factory));
        _uint("exchange.MAX_VALIDITY", exchange.MAX_VALIDITY(), 30 days);
        _uint("exchange.TRADE_HISTORY", exchange.TRADE_HISTORY(), 20);
        _uint("exchange.MIN_BID_BUDGET", exchange.MIN_BID_BUDGET(), 1e8);
        _uint("exchange.MAX_OPEN_BIDS", exchange.MAX_OPEN_BIDS(), 20);
        // 买单要记录订单版本号（bidEpoch）。这里用低级调用，读不到就记为不通过
        // bidEpoch 是公开 mapping，不能写成 PositionExchange.bidEpoch 取选择器（编译不过），按签名编码
        (bool hasBidEpoch,) = address(exchange).staticcall(abi.encodeWithSignature("bidEpoch(uint256)", 0));
        _bool("exchange has bidEpoch", hasBidEpoch, true);
        MonthBoard impl = MonthBoard(monthFactory.boardImplementation());
        _addr("month impl POSITIONS", impl.POSITIONS(), address(positions));
        _addr("month impl SALES", impl.SALES(), address(sales));
        _addr("month impl GOVERNOR", impl.GOVERNOR(), address(governor));
        _addr("month impl PRICE_FEED", impl.PRICE_FEED(), address(feed));
        _addr("feed.HUB", address(feed.HUB()), address(factory));
        _uint("feed.maxChangeBps", feed.maxChangeBps(), TapeSurgeDefaults.FEED_MAX_CHANGE_BPS);
        _uint("feed.minInterval", feed.minInterval(), TapeSurgeDefaults.FEED_MIN_INTERVAL);
        _uint("feed.maxStaleness", feed.maxStaleness(), TapeSurgeDefaults.FEED_MAX_STALENESS);
        _uint("feed.abandonAfter", feed.abandonAfter(), TapeSurgeDefaults.FEED_ABANDON_AFTER);
        _uint("feed.buyStepBps", feed.buyStepBps(), TapeSurgeDefaults.FEED_BUY_STEP_BPS);
        _uint("feed.sellStartBps", feed.sellStartBps(), TapeSurgeDefaults.FEED_SELL_START_BPS);
        _uint("feed.sellStepBps", feed.sellStepBps(), TapeSurgeDefaults.FEED_SELL_STEP_BPS);
        _uint("feed.sellStepInterval", feed.sellStepInterval(), TapeSurgeDefaults.FEED_SELL_STEP_INTERVAL);
        // 模板时间锁（第 7 阶段）：管理员 = 手续费 Safe；部署时没有待生效的模板
        _addr("factory.admin", factory.admin(), m.feeSafe);
        _addr("monthFactory.admin", monthFactory.admin(), m.feeSafe);
        _addr("factory.pendingImplementation", factory.pendingImplementation(), address(0));
        _addr("monthFactory.pendingImplementation", monthFactory.pendingImplementation(), address(0));
        _uint("factory.UPGRADE_DELAY", factory.UPGRADE_DELAY(), 7 days);
        _uint("factory.UPGRADE_WINDOW", factory.UPGRADE_WINDOW(), 7 days);
        // 标准局（第 8 阶段）：共用报价、终局卖矿单例
        TapeBoard simpl = TapeBoard(factory.boardImplementation());
        _addr("std impl PRICE_FEED", simpl.PRICE_FEED(), address(feed));
        _addr("std impl SALES", simpl.SALES(), address(stdSales));
        _addr("stdSales.BEM", address(stdSales.BEM()), m.bem);
        _addr("stdSales.HUB", address(stdSales.HUB()), address(factory));
        _uint("stdSales.MARKET_PERIOD", stdSales.MARKET_PERIOD(), TapeSurgeDefaults.STD_MARKET_PERIOD);
        // 第 9 阶段 + rc8：MarketTrader、兑换适配器、MachineRules、MachineLister
        _addr("std impl TRADER", simpl.TRADER(), address(ftrader));
        _addr("month impl TRADER", MonthBoard(monthFactory.boardImplementation()).TRADER(), address(ftrader));
        _addr("trader.BEM", address(ftrader.BEM()), m.bem);
        _addr("trader.HUB", address(ftrader.HUB()), address(factory));
        _addr("trader.ASK_EXCHANGE", ftrader.ASK_EXCHANGE(), m.firstoAskExchange);
        _addr("trader.SIGNED_ASK", ftrader.SIGNED_ASK(), m.firstoSignedAsk);
        _addr("trader.BID_EXCHANGE", ftrader.BID_EXCHANGE(), m.firstoBidExchange);
        _addr("trader.SWAPPER", address(ftrader.SWAPPER()), address(fswapper));
        _addr("trader.ORACLE", address(ftrader.ORACLE()), address(oracle));
        _addr("trader.POD", ftrader.POD(), m.pod);
        _addr("trader.OFFICIAL_MARKET", address(ftrader.OFFICIAL_MARKET()), m.officialMarket);
        _addr("trader.SEAPORT", address(ftrader.SEAPORT()), m.seaport);
        _addr("trader.WBNB", ftrader.WBNB(), m.wbnb);
        _uint("trader.SLIPPAGE_BPS", ftrader.SLIPPAGE_BPS(), TapeSurgeDefaults.FIRSTO_SLIPPAGE_BPS);
        _addr("std impl MACHINE_RULES", address(simpl.MACHINE_RULES()), address(rules));
        _addr(
            "month impl MACHINE_RULES",
            address(MonthBoard(monthFactory.boardImplementation()).MACHINE_RULES()),
            address(rules)
        );
        _addr("rules.POD", rules.POD(), m.pod);
        _addr("rules.TAPEOUT_FACTORY", rules.TAPEOUT_FACTORY(), m.tapeoutFactory);
        _addr("rules.REFERENCE_CIRCUITS", rules.REFERENCE_CIRCUITS(), m.machineCircuits);
        _b32("rules.MACHINE_CODEHASH", rules.MACHINE_CODEHASH(), m.machineCircuits.codehash);
        _bool("rules accepts official machines", rules.isMachineCollection(m.machineCircuits), true);
        _addr("stdSales.LISTER", address(stdSales.LISTER()), address(lister));
        _addr("sales.LISTER", address(sales.LISTER()), address(lister));
        _addr("lister.BEM", address(lister.BEM()), m.bem);
        _addr("lister.HUB", address(lister.HUB()), address(factory));
        _addr("lister.SWAPPER", address(lister.SWAPPER()), address(fswapper));
        _addr("lister.ORACLE", address(lister.ORACLE()), address(oracle));
        _addr("lister.OFFICIAL_MARKET", address(lister.OFFICIAL_MARKET()), m.officialMarket);
        _addr("lister.SEAPORT", address(lister.SEAPORT()), m.seaport);
        _addr("lister.FIRSTO", address(lister.FIRSTO()), m.firstoSignedAsk);
        _addr("lister.SEAPORT_FEE_RECIPIENT", lister.SEAPORT_FEE_RECIPIENT(), TapeSurgeDefaults.TAPEMARKET_FEE_RECIPIENT);
        _uint("lister.SEAPORT_FEE_BPS", lister.SEAPORT_FEE_BPS(), TapeSurgeDefaults.TAPEMARKET_FEE_BPS);
        _uint("lister.SLIPPAGE_BPS", lister.SLIPPAGE_BPS(), TapeSurgeDefaults.FIRSTO_SLIPPAGE_BPS);
        _uint("lister.REPRICE_BPS", lister.REPRICE_BPS(), TapeSurgeDefaults.LISTER_REPRICE_BPS);
        _uint("lister.REPRICE_INTERVAL", lister.REPRICE_INTERVAL(), TapeSurgeDefaults.LISTER_REPRICE_INTERVAL);
        _uint("lister.LISTING_DURATION", lister.LISTING_DURATION(), TapeSurgeDefaults.LISTER_DURATION);
        _bool("lister vault impl has code", lister.VAULT_IMPL().code.length > 0, true);
        _addr("swapper.TRADER", fswapper.TRADER(), address(ftrader));
        _addr("swapper.WBNB", address(fswapper.WBNB()), m.wbnb);
        _addr("swapper.USDT", fswapper.USDT(), m.usdt);
        _addr("swapper.BEM", address(fswapper.BEM()), m.bem);
        _addr("swapper.POOL_WBNB_USDT", address(fswapper.POOL_WBNB_USDT()), m.poolWbnbUsdt);
        _addr("swapper.POOL_USDT_BEM", address(fswapper.POOL_USDT_BEM()), m.poolUsdtBem);
        _addr("swapper.ROUTER", address(fswapper.ROUTER()), m.router);
        _uint("swapper.FEE_WBNB_USDT", fswapper.FEE_WBNB_USDT(), 100);
        _uint("swapper.FEE_USDT_BEM", fswapper.FEE_USDT_BEM(), 10_000);
        _uint("stdSales.DECAY_DURATION", stdSales.DECAY_DURATION(), TapeSurgeDefaults.STD_SELL_DECAY);
        _uint("stdSales.FLOOR_HOLD", stdSales.FLOOR_HOLD(), TapeSurgeDefaults.STD_SELL_FLOOR_HOLD);
        _uint("stdSales.OPERATOR_GRACE", stdSales.OPERATOR_GRACE(), factory.boardConfig().operatorGrace);
        _uint("stdSales.PREMIUM_FEE_BPS", stdSales.PREMIUM_FEE_BPS(), TapeSurgeDefaults.PREMIUM_FEE_BPS);
    }

    function _vrf(TapeSurgeDefaults.Mainnet memory m) internal {
        console2.log("-- VRF");
        _addr("coordinator", address(adapter.coordinator()), m.vrfCoordinator);
        _b32("keyHash", adapter.keyHash(), vm.envOr("VRF_KEY_HASH", m.vrfKeyHash));
        _uint("callbackGasLimit", adapter.callbackGasLimit(), TapeSurgeDefaults.VRF_CALLBACK_GAS);
        _uint(
            "requestConfirmations",
            adapter.requestConfirmations(),
            vm.envOr("VRF_CONFIRMATIONS", uint256(TapeSurgeDefaults.MAINNET_VRF_CONFIRMATIONS))
        );
        _bool("nativePayment", adapter.nativePayment(), vm.envOr("VRF_NATIVE_PAYMENT", true));
        uint256 subId = adapter.subscriptionId();
        console2.log("subscriptionId", subId);
        (uint96 bal, uint96 nativeBal,, address owner, address[] memory consumers) =
            IVRFSubscriptionView(m.vrfCoordinator).getSubscription(subId);
        _addr("subscription owner", owner, vm.envOr("EXPECT_VRF_OWNER", TapeSurgeDefaults.MAINNET_VRF_OWNER));
        console2.log("subscription LINK / native balance", uint256(bal), uint256(nativeBal));
        _bool("subscription native balance >= 0.02 BNB", nativeBal >= TapeSurgeDefaults.MIN_VRF_NATIVE, true);
        bool isConsumer;
        for (uint256 i = 0; i < consumers.length; i++) {
            if (consumers[i] == address(adapter)) isConsumer = true;
        }
        _bool("adapter is a subscription consumer", isConsumer, true);
    }

    function _oracle(TapeSurgeDefaults.Mainnet memory m) internal {
        console2.log("-- TWAP oracle");
        _uint("window (s)", oracle.window(), TapeSurgeDefaults.TWAP_WINDOW);
        _addr("tokens[0]", oracle.tokens(0), m.wbnb);
        _addr("tokens[1]", oracle.tokens(1), m.usdt);
        _addr("tokens[2]", oracle.tokens(2), m.bem);
        _addr("pools[0]", oracle.pools(0), m.poolWbnbUsdt);
        _addr("pools[1]", oracle.pools(1), m.poolUsdtBem);
        console2.log("quote: 1 BNB -> BEM (8 decimals)", oracle.quoteBemOut(1 ether));
        _coverage("pools[0] observation coverage >= 2 TWAP windows", oracle.pools(0));
        _coverage("pools[1] observation coverage >= 2 TWAP windows", oracle.pools(1));
    }

    /// @dev 池子最早一条观测距今多久（环形缓冲区：下一格已初始化就是最早的，否则缓冲区还没写满，最早的是第 0 格）
    function _coverage(string memory name, address pool) internal {
        IPancakeV3PoolView p = IPancakeV3PoolView(pool);
        (,, uint16 index, uint16 cardinality,,,) = p.slot0();
        (uint32 t, , , bool init) = p.observations((uint256(index) + 1) % cardinality);
        if (!init) (t,,,) = p.observations(0);
        uint256 covered = block.timestamp - t;
        console2.log("  cardinality / covered seconds", cardinality, covered);
        _bool(name, covered >= TapeSurgeDefaults.MIN_TWAP_COVERAGE, true);
    }

    function _status() internal {
        console2.log("-- status");
        TapeBoard impl = TapeBoard(factory.boardImplementation());
        _bool("sentinel tripped (standard)", impl.sentinelTripped(), false);
        _bool("sentinel tripped (month)", MonthBoard(monthFactory.boardImplementation()).sentinelTripped(), false);
        _uint("sentinelSince", factory.sentinelSince(), 0);
        uint256 deadline = splitter.mintStart() + factory.genesisDelay();
        ITransistors t = ITransistors(address(factory.transistors()));
        console2.log("genesis started", factory.genesisStarted());
        console2.log("transistors minted", t.minted(), "threshold", factory.genesisMintThreshold());
        console2.log("genesis possible at (unix) / by 7-day rule", deadline);
        if (block.timestamp < deadline) console2.log("  seconds until then", deadline - block.timestamp);
        console2.log("splitter BNB balance (wei)", address(splitter).balance);
        console2.log("buybackPool / bucket1 (wei)", splitter.buybackPool(), splitter.rewardBucket(1));
        console2.log("recruiting standard / month board", factory.recruitingBoard(), monthFactory.recruitingBoard());
        // 开局前必须报过价（全局审计 G-1）。部署后机器人启动、报完第一次价才会变成 true，这里只提示、不计入检查
        console2.log("price feed posted (required before genesis)", feed.updatedAt() != 0);
        console2.log("price feed fresh / catching up", feed.fresh(), feed.catchingUp());
    }

    // ---------------- 小工具 ----------------

    function _mintPrice() internal view returns (uint256 price) {
        (bool ok, bytes memory ret) = address(factory.transistors()).staticcall(abi.encodeWithSignature("mintPrice()"));
        if (ok && ret.length >= 32) price = abi.decode(ret, (uint256));
    }

    function _report(string memory name, bool ok, string memory got, string memory want) internal {
        checks++;
        if (ok) {
            console2.log(string.concat("  ok  ", name, " = ", got));
        } else {
            mismatches++;
            console2.log(string.concat(RED, "  MISMATCH ", name, ": got ", got, ", want ", want, RESET));
        }
    }

    function _uint(string memory name, uint256 got, uint256 want) internal {
        _report(name, got == want, vm.toString(got), vm.toString(want));
    }

    function _addr(string memory name, address got, address want) internal {
        _report(name, got == want, vm.toString(got), vm.toString(want));
    }

    function _bool(string memory name, bool got, bool want) internal {
        _report(name, got == want, got ? "true" : "false", want ? "true" : "false");
    }

    function _b32(string memory name, bytes32 got, bytes32 want) internal {
        _report(name, got == want, vm.toString(got), vm.toString(want));
    }

    function _bytes(string memory name, bytes memory got, bytes memory want) internal {
        _report(name, keccak256(got) == keccak256(want), vm.toString(got), vm.toString(want));
    }
}

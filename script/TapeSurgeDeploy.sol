// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Vm} from "forge-std/Vm.sol";
import {BoardFactory} from "../src/BoardFactory.sol";
import {MonthFactory} from "../src/MonthFactory.sol";
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
import {GenesisSplitter} from "../src/GenesisSplitter.sol";
import {ChainlinkVRFAdapter} from "../src/random/ChainlinkVRFAdapter.sol";
import {PancakeV3TwapOracle} from "../src/oracle/PancakeV3TwapOracle.sol";
import {ITapeOutFactory} from "../src/interfaces/ITapeOut.sol";
import {TapeSurgeDefaults} from "./TapeSurgeDefaults.sol";

/// @title 主网部署逻辑（script/DeployMainnet.s.sol 和 test/E2EForkBSC.t.sol 共用，保证分叉演练测的就是上线的那套参数）
/// @notice 部署顺序（地址按部署者 nonce 预先算好，互相核对）：
///           n     PancakeV3TwapOracle（WBNB → USDT → BEM，30 分钟 TWAP）
///           n + 1 ChainlinkVRFAdapter（registry = 预测的 BoardFactory）
///           n + 2 GenesisSplitter（boardFactory = 预测的 BoardFactory；构造时付 deployFee 调用 createCPU）
///           n + 3 BoardFactory（注册中心 + 标准局实现；monthFactory = 预测的 MonthFactory）
///           n + 4 MonthFactory（月局实现；单例地址 = 下面预测的地址）
///           n + 5 MonthPositions（v2 持仓凭证）
///           n + 6 MonthMachineSales（v2 结算阶段卖矿定价）
///           n + 7 MonthExitGovernor（v2 多数集体清算）
///           n + 8 PositionExchange（v2 持仓挂单簿）
///           n + 9 MarketPriceFeed（两种局按卖一价收购的报价）
///           n + 10 StdMachineSales（标准局终局卖矿，第 8 阶段）
///           n + 11 PancakeFirstoSwapper（MarketTrader 的兑换适配器，第 9 阶段）
///           n + 12 MarketTrader（在 Firsto / 官方矿机市场 / Seaport 上自动买卖矿机，第 9 阶段 + rc8）
///           n + 13 MachineRules（收哪些合集的矿机、计价算力，rc8）
///           n + 14 MachineLister（把主板矿机按公式价挂到官方矿机市场 / Seaport，rc8；两个卖矿合约的构造参数里要用）
/// @dev 内部函数会内联进调用方：在脚本里由 broadcast 的部署者发出 CREATE，在测试里由测试合约发出。
library TapeSurgeDeploy {
    Vm private constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    struct Settings {
        address operator; // 运营地址（主网必须非零）
        uint256 vrfSubscriptionId;
        bytes32 vrfKeyHash;
        uint16 vrfConfirmations;
        bool vrfNativePayment;
    }

    struct Deployment {
        PancakeV3TwapOracle oracle;
        ChainlinkVRFAdapter adapter;
        GenesisSplitter splitter;
        BoardFactory factory;
        MonthFactory monthFactory;
        MonthPositions positions;
        MonthMachineSales sales;
        MonthExitGovernor governor;
        PositionExchange exchange;
        MarketPriceFeed priceFeed;
        StdMachineSales stdSales;
        PancakeFirstoSwapper swapper;
        MarketTrader trader;
        MachineRules rules;
        MachineLister lister;
    }

    /// @notice 主网默认设置（运营地址和订阅号由调用方给）
    function defaultSettings(address operator, uint256 subId) internal pure returns (Settings memory s) {
        s.operator = operator;
        s.vrfSubscriptionId = subId;
        s.vrfKeyHash = TapeSurgeDefaults.mainnetAddresses().vrfKeyHash;
        s.vrfConfirmations = TapeSurgeDefaults.MAINNET_VRF_CONFIRMATIONS;
        s.vrfNativePayment = true;
    }

    /// @notice 预测的地址（部署前打印、部署后核对）
    function predict(address deployer)
        internal
        view
        returns (address oracle, address adapter, address splitter, address factory, address monthFactory)
    {
        uint256 n = vm.getNonce(deployer);
        oracle = vm.computeCreateAddress(deployer, n);
        adapter = vm.computeCreateAddress(deployer, n + 1);
        splitter = vm.computeCreateAddress(deployer, n + 2);
        factory = vm.computeCreateAddress(deployer, n + 3);
        monthFactory = vm.computeCreateAddress(deployer, n + 4);
    }

    /// @notice 报价单例的预测地址（月局实现的构造参数里要用）
    function predictPriceFeed(address deployer) internal view returns (address) {
        return vm.computeCreateAddress(deployer, vm.getNonce(deployer) + 9);
    }

    /// @notice 兑换适配器、MarketTrader、MachineRules、MachineLister 的预测地址
    function predictMarkets(address deployer)
        internal
        view
        returns (address swapper, address trader, address rules, address lister)
    {
        uint256 n = vm.getNonce(deployer);
        swapper = vm.computeCreateAddress(deployer, n + 11);
        trader = vm.computeCreateAddress(deployer, n + 12);
        rules = vm.computeCreateAddress(deployer, n + 13);
        lister = vm.computeCreateAddress(deployer, n + 14);
    }

    /// @notice 标准局卖矿单例的预测地址（标准局实现的构造参数里要用）
    function predictStdSales(address deployer) internal view returns (address) {
        return vm.computeCreateAddress(deployer, vm.getNonce(deployer) + 10);
    }

    /// @notice v2 月局单例的预测地址（月局实现的构造参数里要用）
    function predictMonthV2(address deployer)
        internal
        view
        returns (address positions, address sales, address governor, address exchange)
    {
        uint256 n = vm.getNonce(deployer);
        positions = vm.computeCreateAddress(deployer, n + 5);
        sales = vm.computeCreateAddress(deployer, n + 6);
        governor = vm.computeCreateAddress(deployer, n + 7);
        exchange = vm.computeCreateAddress(deployer, n + 8);
    }

    function deployMainnet(address deployer, Settings memory s) internal returns (Deployment memory d) {
        TapeSurgeDefaults.Mainnet memory m = TapeSurgeDefaults.mainnetAddresses();
        // pred[k] = 部署者第 n + k 笔 CREATE 的地址（顺序见文件开头）
        address[15] memory pred;
        uint256 n = vm.getNonce(deployer);
        for (uint256 k = 0; k < 15; k++) {
            pred[k] = vm.computeCreateAddress(deployer, n + k);
        }

        address[] memory tokens = new address[](3);
        tokens[0] = m.wbnb;
        tokens[1] = m.usdt;
        tokens[2] = m.bem;
        address[] memory pools = new address[](2);
        pools[0] = m.poolWbnbUsdt;
        pools[1] = m.poolUsdtBem;
        d.oracle = new PancakeV3TwapOracle(tokens, pools, TapeSurgeDefaults.TWAP_WINDOW);

        d.adapter = new ChainlinkVRFAdapter(
            m.vrfCoordinator,
            s.vrfKeyHash,
            s.vrfSubscriptionId,
            s.vrfConfirmations,
            TapeSurgeDefaults.VRF_CALLBACK_GAS,
            s.vrfNativePayment,
            pred[3]
        );

        TapeSurgeDefaults.Addresses memory a =
            TapeSurgeDefaults.mainnetAddressesFor(m, address(d.oracle), address(d.adapter));
        a.monthPositions = pred[5];
        a.monthSales = pred[6];
        a.monthGovernor = pred[7];
        a.priceFeed = pred[9];
        a.stdSales = pred[10];
        a.marketTrader = pred[12];
        a.machineRules = pred[13];
        GenesisSplitter.Params memory sp = TapeSurgeDefaults.splitterParams(a);
        sp.boardFactory = pred[3];
        d.splitter = new GenesisSplitter{value: ITapeOutFactory(m.tapeoutFactory).deployFee()}(sp);

        BoardFactory.Params memory p = TapeSurgeDefaults.params(a);
        p.splitter = address(d.splitter);
        p.monthFactory = pred[4];
        p.initialOperator = s.operator;
        d.factory = new BoardFactory(p);
        MonthFactory.Params memory mp = TapeSurgeDefaults.monthParams(a);
        d.monthFactory = new MonthFactory(address(d.factory), mp);
        _deployMonthV2(d, m.bem, mp.board.operatorGrace, [pred[5], pred[6], pred[7], pred[8]], pred[14]);
        d.priceFeed = new MarketPriceFeed(address(d.factory), TapeSurgeDefaults.feedParams(TapeSurgeDefaults.FEED_ABANDON_AFTER));
        d.stdSales = new StdMachineSales(
            m.bem,
            address(d.factory),
            TapeSurgeDefaults.STD_MARKET_PERIOD,
            TapeSurgeDefaults.STD_SELL_DECAY,
            TapeSurgeDefaults.STD_SELL_FLOOR_HOLD,
            p.board.operatorGrace,
            TapeSurgeDefaults.PREMIUM_FEE_BPS,
            pred[14]
        );
        _deployMarkets(d, m, address(d.oracle), pred[12]);
        _checkPredictions(d, pred);
    }

    function _checkPredictions(Deployment memory d, address[15] memory pred) private view {
        require(address(d.splitter) == pred[2], "GenesisSplitter address prediction");
        require(address(d.factory) == pred[3], "BoardFactory address prediction");
        require(address(d.monthFactory) == pred[4], "MonthFactory address prediction");
        require(address(d.priceFeed) == pred[9], "MarketPriceFeed address prediction");
        require(address(d.stdSales) == pred[10], "StdMachineSales address prediction");
        require(address(d.swapper) == pred[11], "PancakeFirstoSwapper address prediction");
        require(address(d.trader) == pred[12], "MarketTrader address prediction");
        require(address(d.rules) == pred[13], "MachineRules address prediction");
        require(address(d.lister) == pred[14], "MachineLister address prediction");
        require(d.splitter.boardFactory() == address(d.factory), "splitter.boardFactory");
        require(address(d.adapter.registry()) == address(d.factory), "adapter.registry");
        require(d.factory.monthFactory() == address(d.monthFactory), "factory.monthFactory");
    }

    /// @dev v2 月局单例：MonthPositions → MonthMachineSales → MonthExitGovernor → PositionExchange（地址按预测核对）
    function _deployMonthV2(Deployment memory d, address bem, uint256 operatorGrace, address[4] memory v2, address lister)
        private
    {
        d.positions = new MonthPositions(address(d.monthFactory), address(d.factory));
        d.sales = new MonthMachineSales(
            bem,
            address(d.monthFactory),
            address(d.factory),
            v2[2],
            operatorGrace,
            TapeSurgeDefaults.MONTH_PLAN_DECAY,
            lister
        );
        d.governor = new MonthExitGovernor(
            address(d.monthFactory),
            address(d.sales),
            TapeSurgeDefaults.GOV_MIN_SETTLE_AGE,
            TapeSurgeDefaults.GOV_VOTE_PERIOD,
            TapeSurgeDefaults.GOV_EXECUTION_DELAY,
            TapeSurgeDefaults.GOV_EXECUTION_WINDOW,
            TapeSurgeDefaults.GOV_FAIL_COOLDOWN,
            TapeSurgeDefaults.GOV_REPRICE_COOLDOWN
        );
        d.exchange = new PositionExchange(bem, address(d.positions), address(d.monthFactory), address(d.factory));
        require(address(d.positions) == v2[0], "MonthPositions address prediction");
        require(address(d.sales) == v2[1], "MonthMachineSales address prediction");
        require(address(d.governor) == v2[2], "MonthExitGovernor address prediction");
        require(address(d.exchange) == v2[3], "PositionExchange address prediction");
    }

    /// @dev 第 9 阶段 + rc8：兑换适配器（PancakeSwap V3，路径同回购）→ MarketTrader → MachineRules → MachineLister
    function _deployMarkets(Deployment memory d, TapeSurgeDefaults.Mainnet memory m, address oracle, address trader)
        private
    {
        d.swapper = new PancakeFirstoSwapper(
            m.wbnb, m.usdt, m.bem, m.poolWbnbUsdt, m.poolUsdtBem, m.router, uint24(100), uint24(10_000), trader
        );
        d.trader = new MarketTrader(
            m.bem,
            address(d.factory),
            MarketTrader.Markets({
                askExchange: m.firstoAskExchange,
                signedAsk: m.firstoSignedAsk,
                bidExchange: m.firstoBidExchange,
                officialMarket: m.officialMarket,
                seaport: m.seaport,
                wbnb: m.wbnb
            }),
            address(d.swapper),
            oracle,
            m.pod,
            TapeSurgeDefaults.FIRSTO_SLIPPAGE_BPS
        );
        d.rules = new MachineRules(m.pod, m.tapeoutFactory, m.machineCircuits);
        d.lister = new MachineLister(
            m.bem,
            address(d.factory),
            MachineLister.Markets({
                officialMarket: m.officialMarket,
                seaport: m.seaport,
                seaportFeeRecipient: payable(TapeSurgeDefaults.TAPEMARKET_FEE_RECIPIENT),
                seaportFeeBps: TapeSurgeDefaults.TAPEMARKET_FEE_BPS,
                firstoSignedAsk: m.firstoSignedAsk
            }),
            address(d.swapper),
            oracle,
            TapeSurgeDefaults.FIRSTO_SLIPPAGE_BPS,
            TapeSurgeDefaults.LISTER_REPRICE_BPS,
            TapeSurgeDefaults.LISTER_REPRICE_INTERVAL,
            TapeSurgeDefaults.LISTER_DURATION
        );
    }
}

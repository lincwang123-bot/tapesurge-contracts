// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script, console2} from "forge-std/Script.sol";
import {BoardFactory} from "../src/BoardFactory.sol";
import {GenesisSplitter} from "../src/GenesisSplitter.sol";
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
import {MockOfficialMarket, MockSeaport, MockWBNB} from "../src/mocks/MockMarkets.sol";
import {MockFirstoAskExchange, MockFirstoBidExchange, MockFirstoSwapper, MockFirstoSignedAsk} from "../src/mocks/MockFirsto.sol";
import {ChainlinkVRFAdapter} from "../src/random/ChainlinkVRFAdapter.sol";
import {MockBEM} from "../src/mocks/MockBEM.sol";
import {MockPoD} from "../src/mocks/MockPoD.sol";
import {MockCircuits, MockBeacon} from "../src/mocks/MockCircuits.sol";
import {MockTapeOutFactory} from "../src/mocks/MockTapeOut.sol";
import {MockRandomSource} from "../src/mocks/MockRandom.sol";
import {MockRouter, MockPriceOracle} from "../src/mocks/MockSwap.sol";
import {TapeSurgeDefaults} from "./TapeSurgeDefaults.sol";

/// @title BSC 测试网部署脚本（模拟的 TapeOut / PoD / BEM 环境 + 真实 Chainlink VRF v2.5）
/// @notice 部署顺序：Mock 环境 →（可选）VRF 适配器 → GenesisSplitter（分账合约）→ BoardFactory（标准局 + 注册中心）
///         → MonthFactory（月局）。后三个的地址按部署者 nonce 预先算好，互相核对。
/// @notice BSC 测试网上没有 TapeOut 和 BEM，所以部署一整套 Mock，再在其上部署 TapeSurge。
///
///         只做本地模拟（不发送任何交易、不需要私钥）：
///             forge script script/DeployTestnet.s.sol
///         真正部署时才加 --rpc-url / --broadcast，并由部署者自己提供签名账户（--account 等）。
///
///         环境变量（都可省略）：
///         - TESTNET_FAST=1：测试网快速参数，所有以天计的时长按同一比例缩短（默认 1 天 → 2 分钟，即 ÷ 720），
///           一块月局约 1–2 小时跑完，标准局半天内跑完。主网参数（TapeSurgeDefaults）不受影响。
///         - TIME_DIVISOR（默认 720，只在 TESTNET_FAST=1 时生效）：时间缩短比例。48 = 1 天 → 30 分钟（标准局招募约 3.5 小时，
///           月局招募 / 准备各约 1.5 小时，挖矿约 15 小时）。VRF 重发 / 安全退出不低于 1 小时（主板构造要求）。
///           MockPoD 的产出速率 = 主网单位产出 × 比例，所以缩短后的"一天"产出和主网一天相当，不需要手动注入
///           （MOCK_YIELD_PER_WEIGHT_DAY 可以直接指定每单位权重每个真实日的产出，0 = 不自动产出）。
///         - GENESIS_DELAY（秒，可选）：覆盖缩短后的开局等待时间（默认 7 天 ÷ 比例）。
///         - WRITE_DEPLOYMENT=1：把部署地址写到 deployments/<chainId>.json（DEPLOYMENT_FILE 可改路径），
///           供 script/TestnetScenario.s.sol 读取。
///         - FOUNDATION / FEE_SAFE：测试网上可以换成你自己能控制的地址（默认是主网两个 Safe 的地址；
///           setOperator 只有 FEE_SAFE 能调用）。FOUNDATION 不设而 TEST_MNEMONIC 有值时，基金会地址取第 99 个玩家地址。
///         - VRF_SUBSCRIPTION_ID：Chainlink VRF v2.5 订阅号。省略或为 0 时用 MockRandomSource（可手动交付随机数）。
///         - VRF_COORDINATOR / VRF_KEY_HASH：默认是 BSC 测试网的 v2.5 协调器与 50 gwei keyHash（2026-10-19 链上只读核实）。
///         - VRF_NATIVE_PAYMENT：true = 订阅用 BNB 付费，false = 用 LINK（默认 true）。
///         - TESTNET_FAST=1 时还会把测试网 mock 的费用降到主网的 1/100：创世晶体管铸造价 0.001 → 0.00001，
///           协议费 0.0001 → 0.000001，流片费 0.0002 → 0.000002，部署费 0.001 → 0.00001（MOCK_FEE_DIVISOR 可改比例）。
///           主网参数（TapeSurgeDefaults）不变。
///         - MINT_PRICE：直接指定创世晶体管的铸造价（wei），优先于上面的比例。
///         只能在 BSC 测试网（chainid 97）或本地内存链（31337）上运行，其他链直接 revert。
contract DeployTestnet is Script {
    address internal constant BSC_TESTNET_VRF_COORDINATOR = 0xDA3b641D438362C440Ac5458c57e00a712b66700;
    bytes32 internal constant BSC_TESTNET_KEY_HASH_50GWEI =
        0x8596b430971ac45bdf6088665b9ad8e8630c9d5049ab54b14dff711bee7c0e26;
    uint256 internal constant MAINNET_VERIFIED_WEIGHT = 1_580_163;
    uint256 internal constant BEM_PER_BNB = 2_193_000_000; // 1 BEM ≈ 0.0456 BNB（主网量级）
    /// @notice 运营地址的初始值。0 表示"使用部署者地址"（测试网阶段的默认做法）；
    ///         上主网前改成项目方的运营地址，或部署后由手续费 Safe 调用 BoardFactory.setOperator 更换。
    ///         也可以用环境变量 OPERATOR 覆盖。
    address internal constant INITIAL_OPERATOR = address(0);
    /// @notice TESTNET_FAST 的默认缩短比例：1 天（86,400 秒）→ 120 秒；TIME_DIVISOR 可改
    uint256 internal constant FAST_DIVISOR = 720;
    /// @notice FOUNDATION 不设时，基金会地址取玩家种子派生的第 99 个玩家地址（fund / mint 只用前 PLAYERS 个，默认 50）
    uint256 internal constant FOUNDATION_PLAYER_INDEX = 99;
    uint256 internal constant SECP256K1_N = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141;

    MockBEM internal bem;
    MockPoD internal pod;
    MockCircuits internal machines;
    MockTapeOutFactory internal tapeout;
    MockRouter internal router;
    MockPriceOracle internal oracle;
    address internal randomSource;
    BoardFactory internal factory;
    MonthFactory internal monthFactory;
    MonthPositions internal monthPositions;
    MonthMachineSales internal monthSales;
    address internal monthGovernorAddr;
    MonthExitGovernor internal monthGovernor;
    PositionExchange internal positionExchange;
    MarketPriceFeed internal priceFeed;
    StdMachineSales internal stdSales;
    MockFirstoAskExchange internal firstoAsk;
    MockFirstoBidExchange internal firstoBid;
    MockFirstoSwapper internal firstoSwapper;
    MarketTrader internal firstoTrader;
    MachineRules internal machineRules;
    MockOfficialMarket internal officialMarket;
    MockSeaport internal seaport;
    MachineLister internal machineLister;
    /// @dev 测试网的 Seaport 出价要一个真的 WBNB（MockWBNB）；分账回购的 mock 路由仍用下面的占位地址
    MockWBNB internal wbnbToken;
    /// @dev 第二个矿机合集（模拟 Behemoth：工厂创建的处理器、同一份电路代码、PoD 处理器倍数 6）
    MockCircuits internal behemoth;
    /// @dev 模拟 Firsto 单笔签名卖单 V2（挂单模块的第三个平台，规则决定 6.30）
    MockFirstoSignedAsk internal firstoSigned;
    // MockRouter 只检查路径两端，WBNB / USDT 用占位地址即可
    address internal constant WBNB = address(uint160(0xBB4C));
    address internal constant USDT = address(uint160(0x55D3));

    function run() public virtual {
        _requireTestnet();
        uint256 subId = vm.envOr("VRF_SUBSCRIPTION_ID", uint256(0));
        vm.startBroadcast();
        (, address deployer,) = vm.readCallers();
        _deployAll(deployer, subId);
        vm.stopBroadcast();
        _log(deployer, subId);
        if (vm.envOr("WRITE_DEPLOYMENT", false)) _writeDeployment();
    }

    /// @dev 在已经开始的 broadcast 里部署全部合约
    function _deployAll(address deployer, uint256 subId) internal {
        _deployMocks();
        _deployRandomSource(deployer, subId);
        _deployFactory(deployer);
        require(factory.monthFactory() == address(monthFactory), "month factory address prediction");
        if (subId != 0) require(ChainlinkVRFAdapter(randomSource).registry() == factory, "factory address prediction");
    }

    /// @dev 测试网私钥只能用在 BSC 测试网；31337 是本地内存链（只做模拟，不连任何网络）
    function _requireTestnet() internal view {
        require(block.chainid == 97 || block.chainid == 31337, "only BSC testnet (97) or local simulation (31337)");
    }

    function _fast() internal view returns (bool) {
        return vm.envOr("TESTNET_FAST", false);
    }

    /// @dev 测试网快速模式下 mock 费用的缩小比例（默认 100）；不是快速模式时为 1，和主网数额一致
    function _feeDivisor() internal view returns (uint256) {
        return _fast() ? vm.envOr("MOCK_FEE_DIVISOR", uint256(100)) : 1;
    }

    /// @dev mock 路由 / 预言机的汇率（BEM 8 位小数 / 1 BNB）
    function _bemPerBnb() internal view returns (uint256) {
        return BEM_PER_BNB * _feeDivisor();
    }

    /// @dev 时间缩短比例：快速模式下为 TIME_DIVISOR（默认 720），否则为 1
    function _timeDivisor() internal view returns (uint256 d) {
        if (!_fast()) return 1;
        d = vm.envOr("TIME_DIVISOR", FAST_DIVISOR);
        require(d >= 1, "TIME_DIVISOR must be >= 1");
    }

    /// @dev 时长按 _timeDivisor() 缩短（至少 1 秒）
    function _s(uint256 t) internal view returns (uint256) {
        uint256 r = t / _timeDivisor();
        return r == 0 ? 1 : r;
    }

    /// @dev 主板构造要求 VRF 重发间隔 ≥ 1 小时（内审 F3）；快速模式下这两个时长不低于 1 小时（测试网用 Mock 随机数，不受影响）
    /// @dev 治理时长：快速模式按 timeDivisor 缩短（投票期等至少 1 分钟）
    function _g(uint256 t) internal view returns (uint256) {
        if (!_fast()) return t;
        uint256 v = _s(t);
        return v < 1 minutes ? 1 minutes : v;
    }

    function _atLeastHour(uint256 t) internal pure returns (uint256) {
        return t < 1 hours ? 1 hours : t;
    }

    function _applyFast(BoardFactory.Params memory p) internal view {
        p.board.recruitDuration = _s(p.board.recruitDuration);
        p.board.buyStepInterval = _s(p.board.buyStepInterval);
        p.board.buyRoundDuration = _s(p.board.buyRoundDuration);
        p.board.minMachineAge = _s(p.board.minMachineAge);
        p.board.maxDuration = _s(p.board.maxDuration);
        p.board.vrfRetryDelay = _atLeastHour(_s(p.board.vrfRetryDelay));
        p.board.vrfSafeExitDelay = _atLeastHour(_s(p.board.vrfSafeExitDelay));
        p.board.operatorGrace = _s(p.board.operatorGrace);
        p.board.claimWindow = _s(p.board.claimWindow);
        p.board.sentinelResumeDelay = _s(p.board.sentinelResumeDelay);
        p.targets.fastFillWindow = _s(p.targets.fastFillWindow);
        p.genesisDelay = vm.envOr("GENESIS_DELAY", _s(p.genesisDelay));
    }

    function _applyFastMonth(MonthFactory.Params memory mp) internal view {
        mp.board.recruitDuration = _s(mp.board.recruitDuration);
        mp.board.buyStepInterval = _s(mp.board.buyStepInterval);
        mp.board.prepDuration = _s(mp.board.prepDuration);
        mp.board.minMachineAge = _s(mp.board.minMachineAge);
        mp.board.miningDuration = _s(mp.board.miningDuration);
        mp.board.vrfRetryDelay = _atLeastHour(_s(mp.board.vrfRetryDelay));
        mp.board.vrfSafeExitDelay = _atLeastHour(_s(mp.board.vrfSafeExitDelay));
        mp.board.operatorGrace = _s(mp.board.operatorGrace);
        mp.board.claimWindow = _s(mp.board.claimWindow);
        mp.board.sentinelResumeDelay = _s(mp.board.sentinelResumeDelay);
        mp.targets.fastFillWindow = _s(mp.targets.fastFillWindow);
    }

    function _writeDeployment() internal {
        string memory o = "deployment";
        vm.serializeAddress(o, "bem", address(bem));
        vm.serializeAddress(o, "pod", address(pod));
        vm.serializeAddress(o, "machines", address(machines));
        vm.serializeAddress(o, "tapeout", address(tapeout));
        vm.serializeAddress(o, "router", address(router));
        vm.serializeAddress(o, "oracle", address(oracle));
        vm.serializeAddress(o, "randomSource", randomSource);
        vm.serializeAddress(o, "factory", address(factory));
        vm.serializeAddress(o, "monthFactory", address(monthFactory));
        vm.serializeAddress(o, "monthPositions", address(monthPositions));
        vm.serializeAddress(o, "monthSales", address(monthSales));
        vm.serializeAddress(o, "monthGovernor", address(monthGovernor));
        vm.serializeAddress(o, "positionExchange", address(positionExchange));
        vm.serializeAddress(o, "priceFeed", address(priceFeed));
        vm.serializeAddress(o, "stdSales", address(stdSales));
        vm.serializeAddress(o, "firstoAskExchange", address(firstoAsk));
        vm.serializeAddress(o, "firstoBidExchange", address(firstoBid));
        vm.serializeAddress(o, "firstoSwapper", address(firstoSwapper));
        vm.serializeAddress(o, "marketTrader", address(firstoTrader));
        vm.serializeAddress(o, "machineRules", address(machineRules));
        vm.serializeAddress(o, "machineLister", address(machineLister));
        vm.serializeAddress(o, "officialMarket", address(officialMarket));
        vm.serializeAddress(o, "seaport", address(seaport));
        vm.serializeAddress(o, "wbnb", address(wbnbToken));
        vm.serializeAddress(o, "behemoth", address(behemoth));
        vm.serializeAddress(o, "firstoSignedAsk", address(firstoSigned));
        vm.serializeAddress(o, "splitter", address(factory.splitter()));
        vm.serializeAddress(o, "transistors", address(factory.transistors()));
        vm.serializeAddress(o, "passCircuits", factory.passCircuits());
        vm.serializeBool(o, "mockRandom", vm.envOr("VRF_SUBSCRIPTION_ID", uint256(0)) == 0);
        vm.serializeUint(o, "timeDivisor", _timeDivisor());
        vm.serializeUint(o, "bemPerBnb", oracle.bemPerBnb());
        string memory json = vm.serializeBool(o, "fast", _fast());
        string memory path =
            vm.envOr("DEPLOYMENT_FILE", string.concat("deployments/", vm.toString(block.chainid), ".json"));
        vm.writeJson(json, path);
        console2.log("deployment written to", path);
    }

    /// @dev 模拟的外部环境：BEM、PoD、官方矿机电路、TapeOut 工厂（含共用信标）、路由、预言机
    function _deployMocks() internal {
        bem = new MockBEM();
        pod = new MockPoD(address(bem));
        pod.setTotalVerifWeight(MAINNET_VERIFIED_WEIGHT);
        // 快速模式下按时间自动产出：每单位权重每个真实日 = 主网单位产出（currentRate × 1 天 × 99% ÷ 已验证总权重）× 比例
        uint256 unitPerDay = pod.currentRate() * 1 days * 9_900 / 10_000 / MAINNET_VERIFIED_WEIGHT;
        uint256 rate = vm.envOr("MOCK_YIELD_PER_WEIGHT_DAY", _fast() ? unitPerDay * _timeDivisor() : 0);
        if (rate > 0) pod.setRate(rate);
        machines = new MockCircuits("TapeOut Circuits (mock)", "CIRC", address(0), 0.0002 ether / _feeDivisor());
        tapeout = new MockTapeOutFactory(_feeDivisor());
        tapeout.registerCPU(address(machines)); // 模拟官方矿机电路合约是工厂创建的处理器（rc8 主板按 isCPU 收矿机）
        behemoth = new MockCircuits("Behemoth (mock)", "BEH", address(0), 0.0002 ether / _feeDivisor());
        tapeout.registerCPU(address(behemoth));
        pod.setMultiplier(address(behemoth), 6);
        wbnbToken = new MockWBNB();
        firstoSigned = new MockFirstoSignedAsk(_foundation()); // 手续费收款地址随便一个普通钱包即可
        // mock 费用（tBNB）缩小了 _feeDivisor() 倍，汇率同比放大：BEM 计的数额（回购、矿机价、Firsto 订单折合的 BEM）
        // 和主网同一量级，1 台 10 单位的矿机在模拟 Firsto 上约 0.006 tBNB
        router = new MockRouter(WBNB, address(bem), _bemPerBnb());
        oracle = new MockPriceOracle(_bemPerBnb());
    }

    function _deployRandomSource(address deployer, uint256 subId) internal {
        if (subId == 0) {
            randomSource = address(new MockRandomSource());
            return;
        }
        address coordinator = vm.envOr("VRF_COORDINATOR", BSC_TESTNET_VRF_COORDINATOR);
        bytes32 keyHash = vm.envOr("VRF_KEY_HASH", BSC_TESTNET_KEY_HASH_50GWEI);
        bool nativePayment = vm.envOr("VRF_NATIVE_PAYMENT", true);
        // 适配器只认本协议的主板（BoardFactory 注册中心同时认标准局和月局）：
        // 先预测 BoardFactory 的地址（适配器之后依次部署分账合约、BoardFactory）
        address predicted = vm.computeCreateAddress(deployer, vm.getNonce(deployer) + 2);
        randomSource = address(
            new ChainlinkVRFAdapter(
                coordinator, keyHash, subId, 3, TapeSurgeDefaults.VRF_CALLBACK_GAS, nativePayment, predicted
            )
        );
    }

    /// @dev 依次部署分账合约（nonce n）、BoardFactory（n + 1）、MonthFactory（n + 2）；地址提前算好，互相核对
    function _deployFactory(address deployer) internal {
        TapeSurgeDefaults.Addresses memory a = _addresses();
        GenesisSplitter.Params memory sp = TapeSurgeDefaults.splitterParams(a);
        BoardFactory.Params memory p = TapeSurgeDefaults.params(a);
        MonthFactory.Params memory mp = TapeSurgeDefaults.monthParams(a);
        if (_fast()) {
            _applyFast(p);
            _applyFastMonth(mp);
            sp.minSwapInterval = _s(sp.minSwapInterval);
        }
        sp.mintPrice = vm.envOr("MINT_PRICE", sp.mintPrice / _feeDivisor());
        sp.maxSlippageBps = TapeSurgeDefaults.TESTNET_MAX_SLIPPAGE_BPS; // 测试网参数不变（主网默认 2%，见外部审计 #6）
        uint256 n = vm.getNonce(deployer);
        sp.boardFactory = vm.computeCreateAddress(deployer, n + 1);
        p.monthFactory = vm.computeCreateAddress(deployer, n + 2);
        // v2 月局单例：MonthPositions（n + 3）、MonthMachineSales（n + 4）、MonthExitGovernor（n + 5）、
        // PositionExchange（n + 6）、MarketPriceFeed（n + 7，两种局共用）、StdMachineSales（n + 8）
        mp.board.priceFeed = vm.computeCreateAddress(deployer, n + 7);
        p.board.priceFeed = mp.board.priceFeed;
        p.board.sales = vm.computeCreateAddress(deployer, n + 8);
        // 第 9 阶段（Firsto 不在测试网上，用 mock）：卖单合约（n + 9）、统一买单合约（n + 10）、兑换适配器（n + 11）、
        // MarketTrader（n + 12，两种局的模板都要知道它）；rc8：MachineRules（n + 13，两种局的模板都要知道它）、
        // 模拟官方矿机市场（n + 14）、模拟 Seaport（n + 15）、MachineLister（n + 16，两个卖矿合约要知道它）
        p.board.trader = vm.computeCreateAddress(deployer, n + 12);
        mp.board.trader = p.board.trader;
        p.board.machineRules = vm.computeCreateAddress(deployer, n + 13);
        mp.board.machineRules = p.board.machineRules;
        address listerAddr = vm.computeCreateAddress(deployer, n + 16);
        mp.board.positions = vm.computeCreateAddress(deployer, n + 3);
        p.board.positions = mp.board.positions; // 持仓凭证两种局共用（规则决定 6.23）
        mp.board.sales = vm.computeCreateAddress(deployer, n + 4);
        mp.board.governor = vm.computeCreateAddress(deployer, n + 5);
        monthGovernorAddr = mp.board.governor;
        address op = vm.envOr("OPERATOR", INITIAL_OPERATOR);
        p.initialOperator = op == address(0) ? deployer : op;
        GenesisSplitter splitter = new GenesisSplitter{value: tapeout.deployFee()}(sp);
        p.splitter = address(splitter);
        factory = new BoardFactory(p);
        monthFactory = new MonthFactory(address(factory), mp);
        monthPositions = new MonthPositions(address(monthFactory), address(factory));
        monthSales = new MonthMachineSales(
            address(bem),
            address(monthFactory),
            address(factory),
            mp.board.governor,
            mp.board.operatorGrace,
            _fast() ? _s(TapeSurgeDefaults.MONTH_PLAN_DECAY) : TapeSurgeDefaults.MONTH_PLAN_DECAY,
            listerAddr
        );
        monthGovernor = new MonthExitGovernor(
            address(monthFactory),
            address(monthSales),
            _g(TapeSurgeDefaults.GOV_MIN_SETTLE_AGE),
            _g(TapeSurgeDefaults.GOV_VOTE_PERIOD),
            _g(TapeSurgeDefaults.GOV_EXECUTION_DELAY),
            _g(TapeSurgeDefaults.GOV_EXECUTION_WINDOW),
            _g(TapeSurgeDefaults.GOV_FAIL_COOLDOWN),
            _g(TapeSurgeDefaults.GOV_REPRICE_COOLDOWN)
        );
        positionExchange =
            new PositionExchange(address(bem), address(monthPositions), address(monthFactory), address(factory));
        require(address(monthPositions) == mp.board.positions, "MonthPositions address prediction");
        require(address(monthSales) == mp.board.sales, "MonthMachineSales address prediction");
        require(address(monthGovernor) == mp.board.governor, "MonthExitGovernor address prediction");
        // 报价的时间参数不随 TIME_DIVISOR 缩短：机器人按真实时间每小时报价
        // 停运时间（7 天）随 TIME_DIVISOR 缩短，但不能短于过期时间（3 小时，报价合约的构造检查）
        uint256 abandon = _g(TapeSurgeDefaults.FEED_ABANDON_AFTER);
        if (abandon < TapeSurgeDefaults.FEED_MAX_STALENESS) abandon = TapeSurgeDefaults.FEED_MAX_STALENESS;
        priceFeed = new MarketPriceFeed(address(factory), TapeSurgeDefaults.feedParams(abandon));
        require(address(priceFeed) == mp.board.priceFeed, "MarketPriceFeed address prediction");
        // 市价期 / 拍卖时长和报价的"停运 7 天"随 TIME_DIVISOR 缩短；报价的 50 分钟间隔和 3 小时过期按真实时间
        stdSales = new StdMachineSales(
            address(bem),
            address(factory),
            _g(TapeSurgeDefaults.STD_MARKET_PERIOD),
            _g(TapeSurgeDefaults.STD_SELL_DECAY),
            _g(TapeSurgeDefaults.STD_SELL_FLOOR_HOLD),
            p.board.operatorGrace,
            TapeSurgeDefaults.PREMIUM_FEE_BPS,
            listerAddr
        );
        require(address(stdSales) == p.board.sales, "StdMachineSales address prediction");
        firstoAsk = new MockFirstoAskExchange(deployer);
        firstoBid = new MockFirstoBidExchange(address(pod), mp.board.verifiedShareBps, deployer);
        firstoSwapper = new MockFirstoSwapper(address(bem), address(oracle));
        _deployMarkets(deployer, p.board.trader, p.board.machineRules, listerAddr);
        firstoSwapper.setTrader(address(firstoTrader));
        // mock 兑换适配器的 BNB 流动性（买入时先垫 BNB；卖出时还回来的 BNB 会补回）。FIRSTO_SWAPPER_FUND 可改
        uint256 fund = vm.envOr("FIRSTO_SWAPPER_FUND", uint256(0.005 ether));
        if (fund > 0) {
            (bool ok,) = address(firstoSwapper).call{value: fund}("");
            require(ok, "fund swapper");
        }
    }

    /// @dev MarketTrader（n + 12）→ MachineRules（n + 13）→ 模拟官方矿机市场（n + 14）→ 模拟 Seaport（n + 15）→ MachineLister（n + 16）
    function _deployMarkets(address deployer, address traderAddr, address rulesAddr, address listerAddr) internal {
        officialMarket = MockOfficialMarket(vm.computeCreateAddress(deployer, vm.getNonce(deployer) + 2));
        seaport = MockSeaport(vm.computeCreateAddress(deployer, vm.getNonce(deployer) + 3));
        firstoTrader = new MarketTrader(
            address(bem),
            address(factory),
            MarketTrader.Markets({
                askExchange: address(firstoAsk),
                signedAsk: address(firstoSigned),
                bidExchange: address(firstoBid),
                officialMarket: address(officialMarket),
                seaport: address(seaport),
                wbnb: address(wbnbToken)
            }),
            address(firstoSwapper),
            address(oracle),
            address(pod),
            TapeSurgeDefaults.FIRSTO_SLIPPAGE_BPS
        );
        require(address(firstoTrader) == traderAddr, "MarketTrader address prediction");
        machineRules = new MachineRules(address(pod), address(tapeout), address(machines));
        require(address(machineRules) == rulesAddr, "MachineRules address prediction");
        require(address(new MockOfficialMarket(address(tapeout), deployer)) == address(officialMarket), "official market");
        require(address(new MockSeaport()) == address(seaport), "seaport");
        machineLister = new MachineLister(
            address(bem),
            address(factory),
            MachineLister.Markets({
                officialMarket: address(officialMarket),
                seaport: address(seaport),
                seaportFeeRecipient: payable(deployer),
                seaportFeeBps: TapeSurgeDefaults.TAPEMARKET_FEE_BPS,
                firstoSignedAsk: address(firstoSigned)
            }),
            address(firstoSwapper),
            address(oracle),
            TapeSurgeDefaults.FIRSTO_SLIPPAGE_BPS,
            TapeSurgeDefaults.LISTER_REPRICE_BPS,
            TapeSurgeDefaults.LISTER_REPRICE_INTERVAL,
            _atLeastTwoDays(_g(TapeSurgeDefaults.LISTER_DURATION))
        );
        require(address(machineLister) == listerAddr, "MachineLister address prediction");
    }

    function _atLeastTwoDays(uint256 t) internal pure returns (uint256) {
        return t < 2 days ? 2 days : t;
    }

    /// @dev 基金会地址：FOUNDATION 优先；否则有玩家种子（TEST_MNEMONIC）时取第 FOUNDATION_PLAYER_INDEX 个玩家地址
    ///      （派生规则和 TestnetScenario._player 相同）；都没有时用主网基金会 Safe 的地址
    function _foundation() internal view returns (address) {
        address f = vm.envOr("FOUNDATION", address(0));
        if (f != address(0)) return f;
        string memory seed = vm.envOr("TEST_MNEMONIC", string(""));
        bytes memory m = bytes(seed);
        if (m.length == 0) return TapeSurgeDefaults.FOUNDATION_SAFE;
        uint256 i = FOUNDATION_PLAYER_INDEX + 1;
        uint256 pk;
        if (m.length == 66 && m[0] == "0" && (m[1] == "x" || m[1] == "X")) {
            pk = uint256(keccak256(abi.encode(vm.parseBytes32(seed), i))) % SECP256K1_N;
        } else if (m.length == 64 && _isHex(m)) {
            pk = uint256(keccak256(abi.encode(vm.parseBytes32(string.concat("0x", seed)), i))) % SECP256K1_N;
        } else {
            pk = vm.deriveKey(seed, uint32(i));
        }
        return vm.addr(pk);
    }

    function _isHex(bytes memory b) internal pure returns (bool) {
        for (uint256 k = 0; k < b.length; k++) {
            bytes1 c = b[k];
            if (!((c >= "0" && c <= "9") || (c >= "a" && c <= "f") || (c >= "A" && c <= "F"))) return false;
        }
        return true;
    }

    function _addresses() internal view returns (TapeSurgeDefaults.Addresses memory) {
        // 主网上官方电路与创世电路共用一个信标；这里也让两者共用
        address beacon = address(tapeout.circuitsBeacon());
        return (TapeSurgeDefaults.Addresses({
                tapeoutFactory: address(tapeout),
                bem: address(bem),
                pod: address(pod),
                machineCircuits: address(machines),
                circuitsBeacon: beacon,
                passBeacon: beacon,
                randomSource: randomSource,
                wbnb: WBNB,
                usdt: USDT,
                router: address(router),
                oracle: address(oracle),
                foundation: _foundation(),
                feeSafe: vm.envOr("FEE_SAFE", TapeSurgeDefaults.FEE_SAFE),
                monthPositions: address(0),
                monthSales: address(0),
                monthGovernor: address(0),
                priceFeed: address(0),
                stdSales: address(0),
                marketTrader: address(0),
                machineRules: address(0)
            }));
    }

    function _log(address deployer, uint256 subId) internal view {
        console2.log("deployer", deployer);
        console2.log("MockBEM", address(bem));
        console2.log("MockPoD", address(pod));
        console2.log("MockCircuits (machines)", address(machines));
        console2.log("MockTapeOutFactory", address(tapeout));
        console2.log("Circuits beacon", address(tapeout.circuitsBeacon()));
        console2.log("MockRouter", address(router));
        console2.log("MockPriceOracle", address(oracle));
        console2.log(subId == 0 ? "MockRandomSource" : "ChainlinkVRFAdapter", randomSource);
        console2.log("BoardFactory", address(factory));
        console2.log("Operator", factory.operator());
        console2.log("Foundation", _foundation());
        console2.log("GenesisSplitter", address(factory.splitter()));
        console2.log("Genesis transistors", address(factory.transistors()));
        console2.log("Genesis circuits (passes)", factory.passCircuits());
        console2.log("TapeBoard implementation", factory.boardImplementation());
        console2.log("MonthFactory", address(monthFactory));
        console2.log("MonthBoard implementation", monthFactory.boardImplementation());
    }
}

// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {MarketPriceFeed} from "../src/MarketPriceFeed.sol";
import {BoardFactory} from "../src/BoardFactory.sol";
import {GenesisSplitter} from "../src/GenesisSplitter.sol";
import {TapeBoard} from "../src/TapeBoard.sol";
import {MonthBoard} from "../src/MonthBoard.sol";
import {MonthFactory} from "../src/MonthFactory.sol";

/// @title TapeSurge 默认部署参数（测试、测试网部署脚本、README 共用这一份）
/// @notice 已定稿的规则（白皮书 V4）直接写在这里；附录 D 的待定参数是测试网默认值，见 README「默认参数」。
library TapeSurgeDefaults {
    uint256 internal constant BEM_1 = 1e8; // BEM 8 位小数
    uint256 internal constant MINT_PRICE = 0.001 ether; // 创世晶体管每颗铸造价（不含 TapeOut 协议费）
    /// @dev 规则决定 6.32：项目方部署后按公开价格铸造 66 张通行证（330 颗 NAND）用于社区空投
    uint256 internal constant RESERVE_TRANSISTORS = 330;
    address internal constant FOUNDATION_SAFE = 0x04B649076a11819EF7AdA36e02DD55e0923550Ee;
    address internal constant FEE_SAFE = 0x6ea5FfB01378a1E5ce55C8A119A90a87e542C995;
    /// @notice Chainlink VRF 回调 gas 上限（主网、测试网部署都用这个默认值）。主网分叉实测标准局回调最高约 35.8 万
    ///         （选人、记账、推送 105%、真实电路合约 transferFrom 退通行证）；Chainlink 按实际用量收费，上限调高不多花钱。
    uint32 internal constant VRF_CALLBACK_GAS = 750_000;
    /// @notice v2 月局多数集体清算（规格第 7、8 节；项目方 2026-10-22 选项 4a、6a）
    uint256 internal constant MONTH_PLAN_DECAY = 7 days; // 计划价从起价线性降到底价
    uint256 internal constant GOV_MIN_SETTLE_AGE = 7 days; // 结算开始满 7 天才能开启投票
    uint256 internal constant GOV_VOTE_PERIOD = 24 hours;
    uint256 internal constant GOV_EXECUTION_DELAY = 24 hours;
    uint256 internal constant GOV_EXECUTION_WINDOW = 48 hours;
    uint256 internal constant GOV_FAIL_COOLDOWN = 14 days;
    uint256 internal constant GOV_REPRICE_COOLDOWN = 7 days; // 已在清算中、再次改价失败后的冷却
    /// @notice 矿机市场报价与买卖定价（MarketPriceFeed，两种局共用；规则决定 6.17 / 6.18）
    uint256 internal constant FEED_MAX_CHANGE_BPS = 500; // 每次报价 bid / ask 各自最多变动 5%
    uint256 internal constant FEED_MIN_INTERVAL = 50 minutes; // 两次报价至少间隔 50 分钟
    uint256 internal constant FEED_MAX_STALENESS = 3 hours; // 超过 3 小时没更新：过期（暂停收购和卖出）
    uint256 internal constant FEED_ABANDON_AFTER = 7 days; // 超过 7 天没更新：停运（月局按成本价兜底）
    uint256 internal constant FEED_BUY_STEP_BPS = 50; // 规则决定 6.37 起不再使用（收购上限 = min(卖一, 一年产出)），保留部署参数不变
    uint256 internal constant FEED_SELL_START_BPS = 9_900; // 卖价 = max(买一, 卖一 × (99% − 0.5% × h))
    uint256 internal constant FEED_SELL_STEP_BPS = 50; // 每 6 小时降卖一的 0.5%（规则决定 6.21）
    uint256 internal constant FEED_SELL_STEP_INTERVAL = 6 hours;
    /// @notice 标准局终局卖矿（StdMachineSales）：30 天市价期，之后降价拍卖
    uint256 internal constant STD_MARKET_PERIOD = 30 days;
    uint256 internal constant STD_SELL_DECAY = 14 days; // 拍卖从起价线性降到底价
    uint256 internal constant STD_SELL_FLOOR_HOLD = 7 days; // 底价停 7 天后循环
    /// @notice MarketTrader / MachineLister：BEM ↔ BNB 兑换相对 30 分钟 TWAP 的滑点上限（规则决定 6.22，F-4 a）
    uint256 internal constant FIRSTO_SLIPPAGE_BPS = 200;
    /// @notice MachineLister（规则决定 6.26 / 6.29）：价格变了、离上次改价满 30 分钟才改（涨 ≥ 0.5% 随时可改）；
    ///         Seaport 单有效期 30 天
    uint256 internal constant LISTER_REPRICE_BPS = 50;
    uint256 internal constant LISTER_REPRICE_INTERVAL = 30 minutes;
    uint256 internal constant LISTER_DURATION = 30 days;
    /// @notice tapeout.market 的 Seaport 卖单都带一项 1% 的买方手续费（2026-10-24 API 读到的收款地址）
    address internal constant TAPEMARKET_FEE_RECIPIENT = 0xf0972A5ee0FD4054159A8c7177e59126ef478dA9;
    uint256 internal constant TAPEMARKET_FEE_BPS = 100;
    /// @notice 回购 / 回馈兑换相对 TWAP 的最大滑点。主网 2%（外部审计 #6，原为 3%）；测试网仍用 3%（DeployTestnet）。
    uint256 internal constant MAINNET_MAX_SLIPPAGE_BPS = 200;
    uint256 internal constant TESTNET_MAX_SLIPPAGE_BPS = 300;
    /// @dev 白皮书附录 B：Surge Pass · HA1
    bytes32 internal constant PASS_NETLIST_HASH = 0xfffa29f1e30fa6438ba0e6ebd40ef157b53d0eff3f21cc4bc46942e27cb32ca0;

    /// @notice 报价单例的参数。abandonAfter（7 天）可以按测试网的时间倍率缩短，其余按真实时间
    function feedParams(uint256 abandonAfter) internal pure returns (MarketPriceFeed.Params memory p) {
        p.maxChangeBps = FEED_MAX_CHANGE_BPS;
        p.minInterval = FEED_MIN_INTERVAL;
        p.maxStaleness = FEED_MAX_STALENESS;
        p.abandonAfter = abandonAfter;
        p.buyStepBps = FEED_BUY_STEP_BPS;
        p.sellStartBps = FEED_SELL_START_BPS;
        p.sellStepBps = FEED_SELL_STEP_BPS;
        p.sellStepInterval = FEED_SELL_STEP_INTERVAL;
    }

    struct Addresses {
        address tapeoutFactory;
        address bem;
        address pod;
        address machineCircuits;
        address circuitsBeacon; // 主网：官方电路与创世电路共用信标 0xf8D6…8156（分叉测试确认）
        address passBeacon;
        address randomSource;
        address wbnb;
        address usdt;
        address router;
        address oracle;
        address foundation;
        address feeSafe;
        // v2 月局单例（部署时按 nonce 预测后填入）
        address monthPositions;
        address monthSales;
        address monthGovernor;
        address priceFeed; // MarketPriceFeed（两种局共用）
        address stdSales; // StdMachineSales
        address marketTrader; // MarketTrader（两种局的模板都要知道它）
        address machineRules; // MachineRules（两种局的模板都要知道它）
    }

    // =====================================================================
    // BSC 主网地址（2026-10-19 / 10-20 在主网分叉上只读核实；DeployMainnet、CheckMainnet、E2EForkBSC 共用）
    // =====================================================================

    struct Mainnet {
        address tapeoutFactory; // TapeOut 处理器工厂（createCPU）
        address pod; // PoD 挖矿合约
        address machineCircuits; // 官方矿机电路合约
        address circuitsBeacon; // 电路合约信标（官方矿机与创世通行证共用，升级哨兵监控它）
        address bem;
        address wbnb;
        address usdt;
        address router; // PancakeSwap V3 SwapRouter
        address poolWbnbUsdt; // WBNB / USDT 0.01% 池
        address poolUsdtBem; // USDT / BEM 1% 池（BEM 最深的池子）
        address vrfCoordinator; // Chainlink VRF v2.5 协调器
        bytes32 vrfKeyHash; // 200 gwei 档
        address foundationSafe;
        address feeSafe;
        address firstoAskExchange; // Firsto 卖单合约（不可升级，可暂停）
        address firstoBidExchange; // Firsto 统一买单合约（UUPS 代理，带时间锁）
        address firstoSignedAsk; // Firsto 单笔签名卖单 V2（UUPS 代理；挂单模块的第三个平台，规则决定 6.30）
        address officialMarket; // TapeOut 官方矿机市场（UUPS 代理，Safe 管理，没有暂停）
        address seaport; // Seaport 1.6（不可升级、无管理员）
    }

    /// @notice VRF 请求确认数：BSC 每块约 0.75 秒，10 个确认只多等约 8 秒，比快速终局需要的块数多出足够余量
    uint16 internal constant MAINNET_VRF_CONFIRMATIONS = 10;
    /// @notice TWAP 窗口（PancakeV3TwapOracle 的下限也是 30 分钟）
    uint32 internal constant TWAP_WINDOW = 30 minutes;
    /// @notice 部署后核对（CheckMainnet，全局审计 G-4）：两个池子的观测记录至少要覆盖 2 个 TWAP 窗口
    ///         （2026-10-25 实测：USDT/BEM 2048 条约 80 小时，WBNB/USDT 4500 条约 14 小时，不需要扩容，审计 L-4）
    uint256 internal constant MIN_TWAP_COVERAGE = 2 * uint256(TWAP_WINDOW);
    /// @notice VRF 订阅所有者：留在项目方钱包，不转给手续费 Safe（项目方决定，已在文档披露；所有者能停掉订阅，
    ///         合约有 24 小时重发、7 天安全退出兜底）。CheckMainnet 强制核对（EXPECT_VRF_OWNER 可改）
    address internal constant MAINNET_VRF_OWNER = 0x13B0bec94e3Eb84e380Cbde99d70684193e2a17d;
    /// @notice VRF 订阅原生币余额下限：低于它 CheckMainnet 判为不通过（机器人另有 MIN_VRF_BNB 告警）
    uint256 internal constant MIN_VRF_NATIVE = 0.02 ether;
    /// @notice 卖矿溢价分成（两种局同一个比例：月局 6.24，标准局 6.25）：超过成本的部分 10% 给手续费地址
    uint256 internal constant PREMIUM_FEE_BPS = 1_000;

    function mainnetAddresses() internal pure returns (Mainnet memory m) {
        m.tapeoutFactory = 0x68224F668083c29e9800Be2a646d42d18cedF7e2;
        m.pod = 0x7E2E0DC66a3bD9103E69b766afA62d9f7b697b46;
        m.machineCircuits = 0xb1024b89886B9a34Aa4ff5F31C411D708b20a14C;
        m.circuitsBeacon = 0xf8D6d8EB894d6971c8976Ad8b4971cbEFE028156;
        m.bem = 0x5ce033B2bFCa3Af30b3e8C8457DeaF776A8b695a;
        m.wbnb = 0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c;
        m.usdt = 0x55d398326f99059fF775485246999027B3197955;
        m.router = 0x1b81D678ffb9C0263b24A97847620C99d213eB14;
        m.poolWbnbUsdt = 0x172fcD41E0913e95784454622d1c3724f546f849;
        m.poolUsdtBem = 0x3098D7A051045000d68eC0360753A40C8cABEa31;
        m.vrfCoordinator = 0xd691f04bc0C9a24Edb78af9E005Cf85768F694C9;
        m.vrfKeyHash = 0x130dba50ad435d4ecc214aad0d5820474137bd68e7e77724144f27c3c377d3d4;
        m.foundationSafe = FOUNDATION_SAFE;
        m.feeSafe = FEE_SAFE;
        m.firstoAskExchange = 0x3F58C9cbce933c76158B2A29B0d612c46546Dc43;
        m.firstoBidExchange = 0x9273d46b77B67Ba9B24177C25EC25fcbADf27040;
        m.firstoSignedAsk = 0x33423244F9a5bF81b12B1a018aF6F4e079B97f29;
        m.officialMarket = 0x6feEbbEbC07BcB90bd1Ac8b0CF9BaA4f0fF2B46f;
        m.seaport = 0x0000000000000068F116a894984e2DB1123eB395;
    }

    /// @notice 主网的 Addresses：预言机和随机数源由部署脚本先部署，再填进来
    function mainnetAddressesFor(Mainnet memory m, address oracle, address randomSource)
        internal
        pure
        returns (Addresses memory a)
    {
        a.tapeoutFactory = m.tapeoutFactory;
        a.bem = m.bem;
        a.pod = m.pod;
        a.machineCircuits = m.machineCircuits;
        a.circuitsBeacon = m.circuitsBeacon;
        a.passBeacon = m.circuitsBeacon; // 主网：创世电路与官方电路共用信标（分叉测试确认）
        a.randomSource = randomSource;
        a.wbnb = m.wbnb;
        a.usdt = m.usdt;
        a.router = m.router;
        a.oracle = oracle;
        a.foundation = m.foundationSafe;
        a.feeSafe = m.feeSafe;
    }

    /// @notice 分账合约参数。boardFactory（预先算好的 BoardFactory 地址）由部署方填入。
    function splitterParams(Addresses memory a) internal pure returns (GenesisSplitter.Params memory sp) {
        // ---- 分账合约（白皮书第 7 节）----
        sp.tapeoutFactory = a.tapeoutFactory;
        sp.cpuName = "TapeSurge Genesis";
        sp.cpuSymbol = "SURGE";
        sp.cpuStory = "5 transistors, one half adder: your pass to the board.";
        sp.transistorSupply = 66_666; // 最多 13,333 张通行证（2026-10-21 项目方决定由 666,666 改回）
        sp.mintPrice = MINT_PRICE;
        sp.foundation = a.foundation;
        sp.project = a.feeSafe;
        sp.buybackBps = 4_000; // 40% 回购销毁
        sp.projectBps = 1_000; // 10% 项目方（手续费 Safe）
        sp.foundationBps = 2_000; // 20% 基金会
        sp.bucketBps = [uint256(1_000), 800, 500, 400, 300]; // 30% 回馈：10 / 8 / 5 / 4 / 3
        sp.bem = a.bem;
        sp.wbnb = a.wbnb;
        sp.router = a.router;
        // WBNB →（0.01% 档）→ USDT →（1% 档，BEM/USDT 最深池）→ BEM
        sp.swapPath = abi.encodePacked(a.wbnb, uint24(100), a.usdt, uint24(10_000), a.bem);
        sp.oracle = a.oracle;
        sp.maxSwapPerCall = 0.5 ether; // 每次最多 0.5 BNB
        sp.minSwapInterval = 1 hours;
        sp.maxSlippageBps = MAINNET_MAX_SLIPPAGE_BPS; // 相对 30 分钟 TWAP 最多少拿 2%（含 1% 池费；外部审计 #6，原为 3%）
    }

    /// @notice 标准局工厂（注册中心）参数。splitter（先部署的分账合约地址）、monthFactory 由部署方填入。
    function params(Addresses memory a) internal pure returns (BoardFactory.Params memory p) {
        // ---- 主板（白皮书第 5 节 + 附录 D 测试网默认值）----
        TapeBoard.Config memory c;
        c.bem = a.bem;
        c.pod = a.pod;
        c.machineRules = a.machineRules;
        c.machineBeacon = a.circuitsBeacon;
        c.passBeacon = a.passBeacon;
        c.passNetlistHash = PASS_NETLIST_HASH;
        c.foundation = a.foundation;
        c.feeRecipient = a.feeSafe;
        c.randomSource = a.randomSource;
        c.entryFeeBps = 100; // 1%（规则决定 6.25：恢复 1%，改收矿机溢价分成）
        c.recruitDuration = 7 days;
        c.minStartBps = 6_000; // 到期达到 60% 按实际金额开局
        c.buyStartBps = 5_000; // 采购起始价 = 上限 × 50%
        c.buyStepBps = 500; // 每 6 小时 + 上限 × 5%，60 小时涨到上限
        c.buyStepInterval = 6 hours;
        c.buyCapDays = 365; // 上限 = 每单位权重 365 天的产出（≈ 1.65 BEM）
        c.buyMaxPrice = 3 * BEM_1; // 绝对上限 3 BEM / 单位权重
        c.buyRoundDuration = 7 days;
        c.verifiedShareBps = 9_900; // PoD 产出 99% 给已验证矿机
        c.minMachineWeight = 10;
        c.maxMachineWeight = 300; // 单台算力上限
        c.maxMachines = 100;
        c.minMachineAge = 7 days; // 只收已运行满 7 天的矿机
        c.sellStartBps = 15_000; // 没有有效报价时的拍卖起价 = 采购均价 × 150%
        c.sellFloorBps = 6_000; // 底价 = 采购均价 × 60%
        c.priceFeed = a.priceFeed;
        c.sales = a.stdSales;
        c.trader = a.marketTrader;
        c.positions = a.monthPositions; // 持仓凭证两种局共用（规则决定 6.23）
        c.maxDuration = 730 days; // 最长期限 2 年
        c.vrfRetryDelay = 1 days;
        c.vrfSafeExitDelay = 7 days;
        c.operatorGrace = 3 days; // 运营地址 3 天没执行，本局参与者可以兜底
        c.claimWindow = 365 days;
        c.sentinelResumeDelay = 30 days; // 升级哨兵冷静期：登记满 30 天后恢复加入、开新主板、矿机收购和出售（外部审计 #2）
        p.board = c;

        // ---- 主板金额自动调整（白皮书 5.2）----
        p.targets.initialTarget = 500 * BEM_1;
        p.targets.minTarget = 100 * BEM_1;
        p.targets.maxTarget = 1_000 * BEM_1;
        p.targets.rounding = BEM_1;
        p.targets.minStakeBps = 20; // 0.2% → 500 BEM 时 1 BEM
        p.targets.maxStakeBps = 400; // 4% → 500 BEM 时 20 BEM
        p.targets.fastFillWindow = 2 days;
        p.targets.growBps = 12_500;
        p.targets.partialBps = 7_500;
        p.targets.failBps = 5_000;

        // ---- 开局（白皮书第 4 节）----
        p.genesisMintThreshold = 10_000;
        p.genesisDelay = 7 days;
    }

    /// @notice 月局默认参数（白皮书第 6 节、规则文档 §8、附录 D）
    function monthParams(Addresses memory a) internal pure returns (MonthFactory.Params memory p) {
        MonthBoard.Config memory c;
        c.bem = a.bem;
        c.pod = a.pod;
        c.machineRules = a.machineRules;
        c.machineBeacon = a.circuitsBeacon;
        c.passBeacon = a.passBeacon;
        c.passNetlistHash = PASS_NETLIST_HASH;
        c.foundation = a.foundation;
        c.feeRecipient = a.feeSafe;
        c.randomSource = a.randomSource;
        c.entryFeeBps = 100; // 1%
        c.premiumFeeBps = PREMIUM_FEE_BPS; // 卖矿溢价分成 10%（规则决定 6.24）
        c.recruitDuration = 3 days;
        c.minStartBps = 6_000;
        c.buyStartBps = 5_000; // 收购规则同标准局
        c.buyStepBps = 500;
        c.buyStepInterval = 6 hours;
        c.buyCapDays = 365;
        c.buyMaxPrice = 3 * BEM_1;
        c.verifiedShareBps = 9_900;
        c.prepDuration = 3 days; // 收购期最多 3 天
        c.minMachineWeight = 10;
        c.maxMachineWeight = 300;
        c.maxMachines = 100;
        c.minMachineAge = 7 days;
        c.miningDuration = 30 days;
        c.positions = a.monthPositions;
        c.sales = a.monthSales;
        c.governor = a.monthGovernor;
        c.priceFeed = a.priceFeed;
        c.trader = a.marketTrader;
        c.vrfRetryDelay = 1 days;
        c.vrfSafeExitDelay = 7 days;
        c.operatorGrace = 3 days;
        c.claimWindow = 365 days;
        c.sentinelResumeDelay = 30 days; // 升级哨兵冷静期：登记满 30 天后恢复加入、开新主板、矿机收购和出售（外部审计 #2）
        p.board = c;

        p.targets.initialTarget = 100 * BEM_1;
        p.targets.minTarget = 100 * BEM_1;
        p.targets.maxTarget = 1_000 * BEM_1;
        p.targets.rounding = BEM_1;
        p.targets.minStakeBps = 20; // 100 BEM 时 0.2 BEM
        p.targets.maxStakeBps = 400; // 100 BEM 时 4 BEM
        p.targets.fastFillWindow = 1 days;
        p.targets.growBps = 12_500;
        p.targets.partialBps = 7_500;
        p.targets.failBps = 5_000;
    }
}

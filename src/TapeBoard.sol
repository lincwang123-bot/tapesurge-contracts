// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {ICircuits, IBeacon} from "./interfaces/ITapeOut.sol";
import {MachineRules} from "./MachineRules.sol";
import {IPoD} from "./interfaces/IPoD.sol";
import {IRandomSource, IRandomConsumer} from "./interfaces/IRandomSource.sol";
import {BoardState, SettleMode, ITapeBoard, IBoardFactory, IRewardTarget, IBoardHub} from "./interfaces/ITapeBoard.sol";
import {EjectionTree} from "./libraries/EjectionTree.sol";
import {PoDReader} from "./libraries/PoDReader.sol";
import {IMarketPriceFeed} from "./interfaces/IMarketPriceFeed.sol";
import {IMonthPositions} from "./interfaces/IMonthV2.sol";

/// @title TapeBoard（主板，每局一个）
/// @notice 不可升级，没有能改规则、参数或资金去向的管理员。唯一的特权角色是运营地址（只能开奖、自动发放、报收购价、
///         终局挂单，3 天不执行由本局参与者兜底或自动转入拍卖），由手续费 Safe 通过 BoardFactory.setOperator 更换。
///         由 BoardFactory 用 EIP-1167 最小代理部署（代理固定指向开局时的实现合约，
///         没有任何升级入口；工厂换模板只影响之后新开的局）。各局共用的参数在实现合约构造时写死；每块主板自己的目标金额和投入范围
///         由 BoardFactory 在开出时传入（initialize），之后不可更改。
///
/// 一局的流程（白皮书第 5 节）：
///   1. 招募（Recruiting，7 天）：持创世通行证的地址投入"目标金额的 0.2%–4%"（支持小数），另付 1% 入场费；
///      通行证锁进主板。招满即开局；7 天到期时达到目标 60% 按实际金额开局；不到 60% 全员退款、退还通行证。
///   2. 开局（Active）：入场费转给手续费地址；本金作为采购预算，由运营地址经 MarketTrader 在市场上从最便宜的挂单往上买矿机
///      （sellMachine 只认 MarketTrader，按实际花费记账，规则决定 6.37）。每单位 PoD 权重的花费上限由 MarketPriceFeed 决定：
///      min(卖一, 一年产出)；断线 3 小时暂停，停运也暂停；没报过价时按"价格逐步上涨"的默认曲线，但开局前必须报过价，
///      全局审计 G-1。一年产出 = 当前每单位权重产出 × 365 天（设计审计 H3）。矿机产出进入脉冲池。
///   3. 脉冲（pulse）：脉冲池 ≥ 在局最大投入 × 105% ÷ 95% 时请求随机数，按权重 S − wⱼ 抽出一人出局；
///      出局者拿投入的 105%（= 脉冲总额 95%），基金会 3%，手续费地址 2%（没有调用者奖励）。
///      只剩 1 人时他是硅王，脉冲池够付他的 105% 时照常发放，然后进入终局。
///   4. 终局（Liquidating）：卖矿机由 StdMachineSales 定价（规则决定 6.14）：头 30 天运营地址按略低于卖一挂单，
///      之后（或 3 天没挂单的矿机提前）进入降价拍卖，底价 = 采购均价 × 60%；成交时由 StdMachineSales 调用
///      releaseMachine 交割。还没卖掉的矿机继续挖（设计审计 H2）。
///      底池 = 卖矿机所得 + 脉冲池剩余 + 未用完的采购预算 + 拍卖期产出；
///      65% 按投入分给硅王以外的人、30% 硅王、3% 基金会、2% 手续费地址；通行证退还。
///   异常：VRF 24 小时未响应可重新请求，7 天进入安全退出；超过最长期限、首轮收购一台没买到、
///         或升级哨兵触发后由未出局者发起退出。三种异常结局统一用保底公式（设计审计 H5）：
///         先收 2% 手续费（规则决定 6.37；不收基金会 3%），再退未出局者的投入（不够按比例），剩余部分按投入分给所有参与者；
///         不发硅王奖，没有调用者奖励；卖矿溢价分成照收（StdMachineSales）。
///
/// 发放（设计审计 H4）：出局时 105% 直接推送、通行证直接退还（transferFrom）；推送失败时改为记账、通行证留待本人
/// returnPass，不会让 VRF 回调失败。其余款项记账，由运营地址分批 distribute 推送（单次只处理一段插槽），本人也可以
/// 随时自领；任何人都可以替别人触发 withdraw / returnPass，钱和通行证只会给应得的人。
/// 领取期限默认 365 天，过期未领的 BEM 转到黑洞地址 0x…dEaD 销毁（设计审计 M3；规则决定 6.13）。
contract TapeBoard is ITapeBoard, IRewardTarget, IRandomConsumer, ReentrancyGuard {
    using SafeERC20 for IERC20;
    using EjectionTree for EjectionTree.Tree;

    // ============ 白皮书写死的比例 ============

    uint256 public constant BPS = 10_000;
    /// @notice 出局者（和硅王）拿投入的 105%
    uint256 public constant EJECT_PAYOUT_BPS = 10_500;
    /// @notice 出局者所得 = 脉冲总额的 95%
    uint256 public constant PULSE_PLAYER_BPS = 9_500;
    /// @notice 脉冲总额 / 底池的 3% 给基金会
    uint256 public constant FOUNDATION_BPS = 300;
    /// @notice 脉冲总额 / 底池的 2% 给手续费地址
    uint256 public constant FEE_BPS = 200;
    /// @notice 正常终局：底池 30% 给硅王，其余 65% 按投入分给硅王以外的人
    uint256 public constant POT_KING_BPS = 3_000;
    uint256 internal constant ACC_SCALE = 1e18;
    /// @dev 构造参数里任何时长的上限（10 年）
    uint256 internal constant MAX_DURATION_PARAM = 3650 days;

    // ============ 构造参数（各局共用）============

    struct Config {
        // 外部合约
        address bem;
        address pod;
        address machineRules; // MachineRules（收哪些合集的矿机、计价算力，单例；规则决定 6.26）
        address machineBeacon; // 矿机电路合约的信标（升级哨兵）
        address passCircuits; // 创世处理器的电路合约（由 BoardFactory 填入）
        address passBeacon; // 创世电路合约的信标（升级哨兵）；0 = 不监控
        bytes32 passNetlistHash; // 标准通行证网表哈希（附录 B）
        address foundation;
        address feeRecipient;
        address randomSource;
        address splitter; // 由 BoardFactory 填入
        address priceFeed; // MarketPriceFeed（按卖一价收购的报价，两种局共用）
        address sales; // StdMachineSales（终局挂单 / 降价拍卖定价，单例）
        address trader; // FirstoTrader（从 Firsto 吃单买矿机；0 = 不用）
        address positions; // 持仓凭证（MonthPositions，两种局共用一个合集；规则决定 6.23）
        // 招募
        uint256 entryFeeBps; // 入场费（200 = 2%）
        uint256 recruitDuration; // 招募期（7 天），从主板开出时计时
        uint256 minStartBps; // 到期时达到目标的这个比例就按实际金额开局（6000 = 60%）
        // 采购拍卖（价格逐步上涨），价格都以"上限"为基准
        uint256 buyStartBps; // 起始价 = 上限 × buyStartBps
        uint256 buyStepBps; // 每次上涨 上限 × buyStepBps，最高涨到上限
        uint256 buyStepInterval; // 多久涨一次（秒）
        uint256 buyCapDays; // 上限 = 当前每单位权重每天的产出 × buyCapDays（365）
        uint256 buyMaxPrice; // 另设一个绝对上限（每单位权重多少 BEM 最小单位）
        uint256 buyRoundDuration; // 一轮收购持续多久
        uint256 verifiedShareBps; // PoD 产出中分给已验证矿机的比例（9900 = 99%）
        uint256 minMachineWeight;
        uint256 maxMachineWeight; // 单台算力上限
        uint256 maxMachines; // 一块主板最多持有几台矿机（控制 harvest 的 gas）
        uint256 minMachineAge; // 矿机至少已运行多久（秒，设计审计 M2）；0 = 不检查
        // 终局拍卖（价格逐步下降），以本局采购均价为基准；时长和挂单规则在 StdMachineSales
        uint256 sellStartBps; // 没有有效报价时的拍卖起价 = 采购均价 × sellStartBps
        uint256 sellFloorBps; // 底价 = 采购均价 × sellFloorBps（6000 = 60%）
        // 保底与运行
        uint256 maxDuration; // 从开局算起的最长期限
        uint256 vrfRetryDelay; // VRF 多久没响应可以重新请求（24 小时）
        uint256 vrfSafeExitDelay; // VRF 从首次请求起多久没响应进入安全退出（7 天）
        uint256 operatorGrace; // 运营地址多久没执行，本局参与者可以兜底（3 天）
        uint256 claimWindow; // 领取期限（365 天），过期未领的 BEM 转到黑洞地址销毁
        uint256 sentinelResumeDelay; // 升级哨兵冷静期：登记满这么久后恢复加入、开新主板、矿机收购和出售（30 天，外部审计 #2）
    }

    // 关键地址公开；数值参数为 internal（节省合约体积），可通过 BoardFactory.boardConfig() 读取
    IERC20 public immutable BEM;
    address public immutable POD;
    /// @notice 收哪些合集的矿机、计价算力（rc8，规则决定 6.26）
    MachineRules public immutable MACHINE_RULES;
    address public immutable MACHINE_BEACON;
    address internal immutable MACHINE_IMPL_AT_DEPLOY;
    address public immutable PASS_CIRCUITS;
    address public immutable PASS_BEACON;
    address internal immutable PASS_IMPL_AT_DEPLOY;
    bytes32 public immutable PASS_NETLIST_HASH;
    address public immutable FOUNDATION;
    address public immutable FEE_RECIPIENT;
    address public immutable RANDOM_SOURCE;
    address public immutable SPLITTER;
    address public immutable FACTORY;
    address public immutable PRICE_FEED;
    address public immutable TRADER;
    address public immutable SALES;
    address public immutable POSITIONS;

    /// @notice 入场费比例（StdMachineSales.owed 算招募失败的退款要用）
    uint256 public immutable ENTRY_FEE_BPS;
    uint256 internal immutable RECRUIT_DURATION;
    uint256 internal immutable MIN_START_BPS;
    uint256 internal immutable BUY_START_BPS;
    uint256 internal immutable BUY_STEP_BPS;
    uint256 internal immutable BUY_STEP_INTERVAL;
    uint256 internal immutable BUY_CAP_DAYS;
    uint256 internal immutable BUY_MAX_PRICE;
    uint256 internal immutable BUY_ROUND_DURATION;
    uint256 internal immutable VERIFIED_SHARE_BPS;
    uint256 internal immutable MIN_MACHINE_WEIGHT;
    uint256 internal immutable MAX_MACHINE_WEIGHT;
    uint256 internal immutable MAX_MACHINES;
    uint256 internal immutable MIN_MACHINE_AGE;
    uint256 internal immutable SELL_START_BPS;
    uint256 internal immutable SELL_FLOOR_BPS;
    uint256 internal immutable MAX_DURATION;
    uint256 internal immutable VRF_RETRY_DELAY;
    uint256 internal immutable VRF_SAFE_EXIT_DELAY;
    uint256 internal immutable OPERATOR_GRACE;
    uint256 internal immutable CLAIM_WINDOW;
    uint256 internal immutable SENTINEL_RESUME_DELAY;

    // ============ 存储 ============

    struct Socket {
        address owner; // 当前持有人（持仓凭证的持有人；规则决定 6.23）
        uint96 stake;
        uint256 passId;
        uint128 potClaimed; // 已领取（或转让时结转给卖方）的底池份额
        bool ejected;
        bool refunded;
        bool passReturned;
        uint32 version; // 每次转让 +1（盘口的旧卖单随之失效）
    }

    struct Machine {
        bytes32 key;
        uint256 circuitId;
        address collection; // 电路合约（工厂创建的处理器，规则决定 6.26）
        uint64 weight; // 收购时的计价算力（PoDReader：min(基础算力 × 倍数, 已验证池权重)）
        bool active; // 仍在挖（未被撤销 / 停止）
        bool sold; // 终局拍卖已卖出
    }

    BoardState public state;
    SettleMode public settleMode;

    // 本块主板的参数（开出时由 BoardFactory 传入）
    uint256 public number;
    uint256 public target;
    uint256 public minStake;
    uint256 public maxStake;
    uint256 public openedAt;
    uint256 public recruitDeadline;
    uint256 public startedAt;

    // 参与者
    uint256 public socketCount;
    mapping(uint256 => Socket) internal _sockets;
    /// @notice 地址持有本局几份持仓（加入时 1；转让时随之增减）。加入时要求为 0（一个地址一局只能加入一次），
    ///         兜底权限按它判断。
    mapping(address => uint256) public holderCount;
    /// @notice 局交易版本号：每次出局、进入终局时 +1，盘口里此前挂的卖单全部失效（持仓价值骤变）
    uint64 public tradeEpoch;
    uint256 public totalStake;
    uint256 public totalEntryFees;

    // 抽签
    EjectionTree.Tree internal _tree;
    uint256 public aliveCount;
    uint256 public aliveStake;
    uint256 public kingSocket;
    bool public kingPaid;
    bool public drawPending;
    uint256 public pendingRequestId;
    /// @dev 审计 M-3：本局第几次开奖；同一次开奖重发的所有请求（_requestRound 相同）都有效，先到先用
    uint256 internal _drawRound;
    mapping(uint256 => uint256) internal _requestRound;
    uint256 public lastPulseAt; // 开局或上一次出局的时间：参与者兜底推进脉冲的计时起点
    uint256 public lastRequestAt;
    uint256 public firstRequestAt;

    // 资金池
    uint256 public pool; // 脉冲池
    uint256 public budget; // 采购预算（本金 + 回馈补贴 − 已花费）
    uint256 internal _roundCap; // 本轮收购开始时的收购价上限快照（外部审计 #3），见 buyPriceCap
    uint256 public totalSubsidy;

    // 采购拍卖
    uint256 public buyRoundStart;
    uint256 public buyRoundEnd;
    uint256 public initialBuyEnd;
    Machine[] internal _machines;
    uint256 public totalWeightBought;
    uint256 public totalSpent;
    uint256 public activeWeight;
    uint256 public unsoldMachines;

    // 记账：所有已经记在某人名下、还没被领走的 BEM
    mapping(address => uint256) public credit;
    uint256 public liabilities;

    // 终局
    uint256 public liquidationStart;
    uint256 public sellStartPrice;
    uint256 public sellFloorPrice;
    uint256 public proRataStake; // 参与"按投入比例分配"的投入总额
    uint256 public priorityStake; // 保底：享有"优先取回投入"的投入总额（未出局者）
    uint256 public priorityRemaining;
    uint256 public accProRata; // 每单位投入累计可分得的底池（× 1e18）
    uint256 public accPriority; // 每单位投入累计可优先取回的本金（× 1e18）
    uint256 public kingPot; // 硅王累计应得的 30%
    uint256 public potAllocated;

    // 领取期限
    uint256 public finishedAt; // 招募失败时刻，或终局拍卖卖完最后一台矿机的时刻
    bool public claimsClosed;

    // ============ 事件 ============

    event Initialized(uint256 indexed number, uint256 target, uint256 minStake, uint256 maxStake, uint256 deadline);
    event Joined(address indexed player, uint256 indexed slot, uint256 passId, uint256 stake, uint256 fee);
    event Started(uint256 totalStake, uint256 entryFees, bool full, uint256 elapsed);
    event RecruitmentFailed(uint256 totalStake, uint256 participants);
    event BuyRoundStarted(uint256 start, uint256 end, uint256 budget);
    event MachineBought(
        uint256 indexed index,
        uint256 indexed circuitId,
        address indexed seller,
        uint256 weight,
        uint256 price,
        uint256 paid,
        address collection
    );
    event MachineStatus(uint256 indexed index, bool active);
    event Harvested(uint256 amount);
    event SubsidyDeposited(uint256 amount);
    event DrawRequested(uint256 indexed requestId, address indexed requester, uint256 pool, uint256 threshold);
    event StaleRandomness(uint256 indexed requestId);
    event Pulse(
        uint256 indexed slot, address indexed player, uint256 payout, uint256 toFoundation, uint256 toFee, bool king
    );
    event KingCrowned(uint256 indexed slot, address indexed player);
    event LiquidationStarted(SettleMode mode, uint256 sellStartPrice, uint256 sellFloorPrice);
    event PotAllocated(uint256 amount, uint256 priority);
    event MachineSold(
        uint256 indexed index, uint256 indexed circuitId, address indexed buyer, uint256 weight, uint256 cost
    );
    event Withdrawn(address indexed account, uint256 amount);
    event PassReturned(address indexed player, uint256 passId);
    event ClaimsClosed(uint256 amountToFoundation);
    event PositionTransferred(uint256 indexed slot, address indexed from, address indexed to, uint256 carriedOver);

    // ============ 错误 ============

    error BadConfig();
    error OnlyFactory();
    error OnlySplitter();
    error OnlyRandomSource();
    error AlreadyInitialized();
    error WrongState();
    error RecruitmentClosed();
    error UpgradeSentinelTripped();
    error AlreadyJoined();
    error BadAmount();
    error NotPassOwner();
    error NotStandardPass();
    error CannotClose();
    error BuyRoundInactive();
    error PriceUnavailable();
    error TooManyMachines();
    error NotMachineOwner();
    error MachineNotEligible();
    error InsufficientBudget();
    error DrawAlreadyPending();
    error BelowThreshold();
    error NoPendingDraw();
    error TooEarly();
    error NotExpired();
    error SentinelNotTripped();
    error NotAliveParticipant();
    error AlreadySold();
    error PriceAboveMaximum();
    error NothingToWithdraw();
    error NotParticipant();
    error PassAlreadyReturned();
    error ClaimsAreClosed();
    error NotAuthorized();
    error TransferLocked();

    // ============ 构造 / 初始化 ============

    constructor(Config memory c) {
        if (
            c.bem == address(0) || c.pod == address(0) || c.machineRules == address(0)
                || c.passCircuits == address(0) || c.foundation == address(0) || c.feeRecipient == address(0)
                || c.randomSource == address(0) || c.splitter == address(0) || c.priceFeed == address(0)
                || c.sales == address(0) || c.positions == address(0)
        ) revert BadConfig();
        if (c.entryFeeBps > 1_000 || c.minStartBps == 0 || c.minStartBps > BPS) revert BadConfig();
        if (c.buyStepInterval == 0 || c.buyStartBps > BPS || c.buyCapDays == 0 || c.verifiedShareBps > BPS) {
            revert BadConfig();
        }
        // TapeCode 第三轮 #12：起始收购价不能为 0；基金会和手续费地址必须不同（只在构造时检查，不占运行时字节）
        if (c.buyStartBps == 0 || c.foundation == c.feeRecipient) revert BadConfig();
        if (c.maxMachineWeight < c.minMachineWeight || c.maxMachines == 0) revert BadConfig();
        if (c.sellFloorBps > c.sellStartBps || c.sellFloorBps == 0) revert BadConfig();
        if (c.vrfSafeExitDelay < c.vrfRetryDelay) revert BadConfig();
        // 时长类参数（内审 F3）：VRF 重发至少隔 1 小时（防止在交付交易还在 mempool 时抢先重发）；招募期和收购期不能为 0；
        // 全部不超过 10 年（避免 since + 时长溢出）
        if (c.vrfRetryDelay < 1 hours || c.recruitDuration == 0 || c.buyRoundDuration == 0) revert BadConfig();
        if (
            c.recruitDuration > MAX_DURATION_PARAM || c.buyStepInterval > MAX_DURATION_PARAM
                || c.buyRoundDuration > MAX_DURATION_PARAM || c.minMachineAge > MAX_DURATION_PARAM
                || c.maxDuration > MAX_DURATION_PARAM || c.vrfSafeExitDelay > MAX_DURATION_PARAM
                || c.operatorGrace > MAX_DURATION_PARAM || c.claimWindow > MAX_DURATION_PARAM
                || c.sentinelResumeDelay > MAX_DURATION_PARAM
        ) revert BadConfig();

        BEM = IERC20(c.bem);
        POD = c.pod;
        MACHINE_RULES = MachineRules(c.machineRules);
        MACHINE_BEACON = c.machineBeacon;
        MACHINE_IMPL_AT_DEPLOY = c.machineBeacon == address(0) ? address(0) : IBeacon(c.machineBeacon).implementation();
        PASS_CIRCUITS = c.passCircuits;
        PASS_BEACON = c.passBeacon;
        PASS_IMPL_AT_DEPLOY = c.passBeacon == address(0) ? address(0) : IBeacon(c.passBeacon).implementation();
        PASS_NETLIST_HASH = c.passNetlistHash;
        FOUNDATION = c.foundation;
        FEE_RECIPIENT = c.feeRecipient;
        RANDOM_SOURCE = c.randomSource;
        SPLITTER = c.splitter;
        FACTORY = msg.sender;
        PRICE_FEED = c.priceFeed;
        TRADER = c.trader;
        SALES = c.sales;
        POSITIONS = c.positions;

        ENTRY_FEE_BPS = c.entryFeeBps;
        RECRUIT_DURATION = c.recruitDuration;
        MIN_START_BPS = c.minStartBps;
        BUY_START_BPS = c.buyStartBps;
        BUY_STEP_BPS = c.buyStepBps;
        BUY_STEP_INTERVAL = c.buyStepInterval;
        BUY_CAP_DAYS = c.buyCapDays;
        BUY_MAX_PRICE = c.buyMaxPrice;
        BUY_ROUND_DURATION = c.buyRoundDuration;
        VERIFIED_SHARE_BPS = c.verifiedShareBps;
        MIN_MACHINE_WEIGHT = c.minMachineWeight;
        MAX_MACHINE_WEIGHT = c.maxMachineWeight;
        MAX_MACHINES = c.maxMachines;
        MIN_MACHINE_AGE = c.minMachineAge;
        SELL_START_BPS = c.sellStartBps;
        SELL_FLOOR_BPS = c.sellFloorBps;
        MAX_DURATION = c.maxDuration;
        VRF_RETRY_DELAY = c.vrfRetryDelay;
        VRF_SAFE_EXIT_DELAY = c.vrfSafeExitDelay;
        OPERATOR_GRACE = c.operatorGrace;
        CLAIM_WINDOW = c.claimWindow;
        SENTINEL_RESUME_DELAY = c.sentinelResumeDelay;
    }

    /// @notice 由 BoardFactory 在创建代理的同一笔交易里调用。实现合约本身永远不会被初始化。
    /// @param target_ 本块目标金额；minStake_ / maxStake_ 本块单人投入范围（目标的 0.2% / 4%）
    function initialize(uint256 number_, uint256 target_, uint256 minStake_, uint256 maxStake_) external {
        if (msg.sender != FACTORY) revert OnlyFactory();
        if (state != BoardState.Uninitialized) revert AlreadyInitialized();
        if (minStake_ == 0 || maxStake_ < minStake_ || target_ <= maxStake_) revert BadConfig();
        state = BoardState.Recruiting;
        number = number_;
        target = target_;
        minStake = minStake_;
        maxStake = maxStake_;
        openedAt = block.timestamp;
        recruitDeadline = block.timestamp + RECRUIT_DURATION;
        // 每笔投入（除了补满的最后一笔）都 ≥ minStake，所以人数 ≤ target / minStake + 1
        _tree.init(target_ / minStake_ + 1);
        emit Initialized(number_, target_, minStake_, maxStake_, recruitDeadline);
    }

    // ============ 1. 招募 ============

    /// @notice 加入本局。需要事先授权：通行证 NFT 给本合约、amount × (1 + 入场费) 的 BEM 给本合约。
    /// @param passId 创世处理器电路合约上的通行证编号（必须是标准半加器网表）
    /// @param amount 投入本金（BEM 最小单位，支持小数），范围 [minStake, maxStake]，入场费另收。
    ///        超出剩余额度时只接受到恰好满额（多出的部分不收）；剩余额度小于 minStake 时，
    ///        也可以直接投入恰好等于剩余额度的金额。
    function join(uint256 passId, uint256 amount) external nonReentrant {
        if (state != BoardState.Recruiting) revert WrongState();
        if (block.timestamp >= recruitDeadline) revert RecruitmentClosed();
        if (sentinelPaused()) revert UpgradeSentinelTripped();
        if (holderCount[msg.sender] != 0) revert AlreadyJoined(); // 一个地址一局只能加入一次（转让在开局之后）

        uint256 remaining = target - totalStake;
        if (amount > maxStake || (amount < minStake && amount != remaining) || amount == 0) revert BadAmount();
        uint256 stake = amount > remaining ? remaining : amount;

        // 通行证校验：必须是创世处理器电路合约上的、本人持有的、标准网表的电路
        if (ICircuits(PASS_CIRCUITS).ownerOf(passId) != msg.sender) revert NotPassOwner();
        if (keccak256(ICircuits(PASS_CIRCUITS).netlist(passId)) != PASS_NETLIST_HASH) revert NotStandardPass();

        uint256 fee = stake * ENTRY_FEE_BPS / BPS;
        uint256 slot = ++socketCount;
        _sockets[slot] = Socket({
            owner: msg.sender,
            stake: uint96(stake),
            passId: passId,
            potClaimed: 0,
            ejected: false,
            refunded: false,
            passReturned: false,
            version: 0
        });
        holderCount[msg.sender] = 1;
        totalStake += stake;
        totalEntryFees += fee;
        _tree.insert(slot, stake);
        aliveCount += 1;
        aliveStake += stake;

        // 锁定通行证；本金和入场费一起转入（入场费先留在主板里，开局后才转给手续费地址）
        ICircuits(PASS_CIRCUITS).transferFrom(msg.sender, address(this), passId);
        _bemIn(stake + fee);
        IMonthPositions(POSITIONS).mint(msg.sender, slot); // 持仓凭证（开局后可转让，规则决定 6.23）
        emit Joined(msg.sender, slot, passId, stake, fee);

        if (totalStake == target) _start(true);
    }

    /// @notice 招募期满（或处于升级哨兵冷静期）后，任何人都可以结束招募：
    ///         - 达到目标的 minStartBps（60%）且不在冷静期：按实际金额开局；
    ///         - 否则招募失败：全员可以 withdraw 取回本金 + 入场费、returnPass 取回通行证，
    ///           BoardFactory 自动重开同一编号的主板（冷静期内不重开，满 30 天后由 reopen() 重开）。
    function closeRecruitment() external nonReentrant {
        if (state != BoardState.Recruiting) revert WrongState();
        bool tripped = sentinelPaused(); // 冷静期内可以立即结束招募、全额退款
        if (block.timestamp < recruitDeadline && !tripped) revert CannotClose();
        if (!tripped && aliveCount >= 2 && totalStake * BPS >= target * MIN_START_BPS) {
            _start(false);
            return;
        }
        state = BoardState.Failed;
        finishedAt = block.timestamp;
        liabilities = totalStake + totalEntryFees;
        emit RecruitmentFailed(totalStake, socketCount);
        IBoardFactory(FACTORY).onBoardFailed();
    }

    function _start(bool full) internal {
        state = BoardState.Active;
        startedAt = block.timestamp;
        lastPulseAt = block.timestamp;
        budget = totalStake;
        buyRoundStart = block.timestamp;
        buyRoundEnd = block.timestamp + BUY_ROUND_DURATION;
        initialBuyEnd = buyRoundEnd;
        _roundCap = _liveCap();
        // 开局后入场费才转给手续费地址（固定的 Safe 地址，一次转账，不是循环推送）
        if (totalEntryFees > 0) _bemOut(FEE_RECIPIENT, totalEntryFees);
        uint256 elapsed = block.timestamp - openedAt;
        emit Started(totalStake, totalEntryFees, full, elapsed);
        emit BuyRoundStarted(buyRoundStart, buyRoundEnd, budget);
        IBoardFactory(FACTORY).onBoardStarted(full, elapsed);
    }

    // ============ 2. 采购矿机（价格逐步上涨的荷兰式拍卖）============

    function isPurchasing() public view returns (bool) {
        return state == BoardState.Active && block.timestamp < buyRoundEnd;
    }

    /// @notice 本轮的收购价上限：本轮收购开始时的快照，本轮内不随 PoD 的即时状态变化（外部审计 #3）。
    ///         快照 = min(每单位权重每天的产出 × buyCapDays, 绝对上限)。快照时读不到 PoD 产出速率则为 0
    ///         （暂停收购，而不是按未知价格买）；本轮第一次有人卖矿机时会再快照一次。
    function buyPriceCap() public view returns (uint256) {
        return _roundCap;
    }

    function _liveCap() internal view returns (uint256) {
        (bool ok, uint256 perDay) = PoDReader.tryUnitYieldPerDay(POD, VERIFIED_SHARE_BPS);
        if (!ok) return 0;
        uint256 cap = perDay * BUY_CAP_DAYS;
        return cap > BUY_MAX_PRICE ? BUY_MAX_PRICE : cap;
    }

    /// @notice 当前收购价上限：每单位 PoD 权重最多付多少 BEM 最小单位，由 MarketPriceFeed.buyQuote 决定（报价有效时 = min(卖一, 上限)，
    ///        规则决定 6.37；报价无效（过期、追价、运营地址为 0、停运）时为 0，暂停收购；从没报过价时按默认曲线，开局前必须报过价，
    ///        实际用不到，全局审计 G-1）。没有进行中的收购轮时为 0。
    function buyPrice() public view returns (uint256) {
        if (!isPurchasing()) return 0;
        uint256 bps = BUY_START_BPS + ((block.timestamp - buyRoundStart) / BUY_STEP_INTERVAL) * BUY_STEP_BPS;
        if (bps > BPS) bps = BPS;
        uint256 cap = buyPriceCap();
        return IMarketPriceFeed(PRICE_FEED).buyQuote(cap, cap * bps / BPS, buyRoundStart);
    }

    /// @notice 收购一台 PoD 已验证、正在挖、已运行足够久的矿机。只认 MarketTrader（规则决定 6.37）：主板不再按报价公开收购，
    ///         由运营地址经 MarketTrader 在市场上从最便宜的挂单往上买，按实际花费记账、付 BEM（实际花费 ≤ 计价算力 × 收购价上限，
    ///         上限 = min(卖一, 一年产出)）。这样外部的人没法按报价把矿机卖给主板，也就没法在协议自己的卖价和收购价之间套利。
    ///         合集：任何由 TapeOut 处理器工厂创建的处理器的电路合约（isCPU），并且运行时代码和官方矿机电路合约相同
    ///         （同一个信标，升级哨兵覆盖得到；规则决定 6.26）。计价算力见 PoDReader（不含最优加成）。
    ///         MarketTrader 必须是矿机当前持有者，并事先把矿机 NFT 授权给本合约。成交前先调用 PoD claim 领走此前的产出。
    /// @param spent MarketTrader 在市场上的实际花费（BEM）
    function sellMachine(address collection, uint256 circuitId, uint256 spent)
        external
        nonReentrant
        returns (uint256 paid)
    {
        if (msg.sender != TRADER) revert NotAuthorized();
        if (!isPurchasing()) revert BuyRoundInactive();
        if (sentinelPaused()) revert UpgradeSentinelTripped();
        if (_machines.length >= MAX_MACHINES) revert TooManyMachines();
        // 合集和 PoD 资格（MachineRules，先核对合集再调用它）；不合格时回滚 MachineNotEligible
        (bytes32 key, uint256 weight) =
            MACHINE_RULES.check(collection, circuitId, MIN_MACHINE_WEIGHT, MAX_MACHINE_WEIGHT, MIN_MACHINE_AGE);
        if (ICircuits(collection).ownerOf(circuitId) != msg.sender) revert NotMachineOwner();

        if (_roundCap == 0) _roundCap = _liveCap(); // 本轮开始时没快照成功，补一次
        uint256 price = buyPrice();
        if (price == 0) revert PriceUnavailable();
        // 按实价记账，不得超过 权重 × 收购价上限（规则决定 6.22 / 6.37）
        if (spent > weight * price) revert PriceAboveMaximum();
        paid = spent;
        if (paid > budget) revert InsufficientBudget();

        budget -= paid;
        totalSpent += paid;
        totalWeightBought += weight;
        activeWeight += weight;
        unsoldMachines += 1;
        // forge-lint: disable-next-line(unsafe-typecast)
        _machines.push(
            Machine({
                key: key,
                circuitId: circuitId,
                collection: collection,
                weight: uint64(weight),
                active: true,
                sold: false
            })
        );

        // 先把旧产出发给卖家（PoD 付给当前持有者），再收入矿机。
        // 主网分叉测试显示 pending() 只是下限（claim 时 PoD 先把累计量更新到当前时间），所以总是调用一次；
        // claim 失败（例如没有可领的产出时 revert）不影响成交。
        try IPoD(POD).claim(key) {} catch {}
        ICircuits(collection).transferFrom(msg.sender, address(this), circuitId);
        _bemOut(msg.sender, paid);
        emit MachineBought(_machines.length - 1, circuitId, msg.sender, weight, price, paid, collection);
    }

    /// @notice 只接受 GenesisSplitter 的回馈资金：并入采购预算；没有进行中的收购轮时开启新一轮。
    /// @notice 首批回馈：采购 / 运行中（Active）可以接收补贴
    function acceptsSubsidy() external view returns (bool) {
        return state == BoardState.Active;
    }

    /// @notice 首批回馈：进入终局（或招募失败）即视为结束
    function rewardEnded() external view returns (bool) {
        return state == BoardState.Liquidating || state == BoardState.Failed;
    }

    function depositSubsidy(uint256 amount) external override(ITapeBoard, IRewardTarget) nonReentrant {
        if (msg.sender != SPLITTER) revert OnlySplitter();
        if (state != BoardState.Active) revert WrongState();
        _bemIn(amount);
        budget += amount;
        totalSubsidy += amount;
        emit SubsidyDeposited(amount);
        if (block.timestamp >= buyRoundEnd) {
            buyRoundStart = block.timestamp;
            buyRoundEnd = block.timestamp + BUY_ROUND_DURATION;
            _roundCap = _liveCap();
            emit BuyRoundStarted(buyRoundStart, buyRoundEnd, budget);
        }
    }

    // ============ 3. 产出与脉冲 ============

    /// @notice 领取全部在挖矿机的 PoD 产出。开局后进入脉冲池；终局阶段直接并入底池。任何人可调。
    function harvest() external nonReentrant returns (uint256 got) {
        if (state != BoardState.Active && state != BoardState.Liquidating) revert WrongState();
        if (claimsClosed) revert ClaimsAreClosed();
        got = _claimYield();
    }

    /// @notice 重新读取矿机在 PoD 的状态。被撤销 / 停止的矿机不再计入（不再领取产出），恢复后重新计入。
    function syncMachine(uint256 index) external nonReentrant {
        if (state != BoardState.Active && state != BoardState.Liquidating) revert WrongState();
        Machine storage m = _machines[index];
        if (m.sold) revert AlreadySold();
        bool live = MACHINE_RULES.live(m.key, m.collection, m.circuitId);
        if (live == m.active) return;
        _claimOne(m.key);
        if (state == BoardState.Liquidating) _sweep();
        m.active = live;
        if (live) activeWeight += m.weight;
        else activeWeight -= m.weight;
        emit MachineStatus(index, live);
    }

    /// @notice 推进一次脉冲（即 requestDraw）：先 harvest；在局 ≥ 2 人且脉冲池够门槛时请求随机数；
    ///         只剩硅王且脉冲池够付他的 105% 时直接发放并进入终局。
    ///         运营地址专属；距开局或上一次出局超过 operatorGrace（3 天）后，本局参与者也可以调用（兜底）。
    function pulse() external nonReentrant {
        if (state != BoardState.Active) revert WrongState();
        _auth(lastPulseAt);
        _claimYield();
        if (aliveCount >= 2) {
            if (drawPending) revert DrawAlreadyPending();
            uint256 threshold = pulseGross(_tree.maxStake());
            if (pool < threshold) revert BelowThreshold();
            firstRequestAt = block.timestamp;
            ++_drawRound;
            _requestDraw(threshold);
        } else {
            uint256 kingStake = _sockets[kingSocket].stake;
            if (pool < pulseGross(kingStake)) revert BelowThreshold();
            kingPaid = true;
            _payPulse(kingSocket, true);
            _startLiquidation(SettleMode.Normal);
        }
    }

    /// @notice 随机数回调：按出局权重 S − wⱼ 抽出一人。接受这一次开奖发出的任何一个请求（重发不作废已在路上的结果，
    ///         审计 M-3），先到先用；别的开奖的、重复的回调直接忽略（不 revert）。
    function onRandomness(uint256 requestId, uint256 randomWord) external nonReentrant {
        if (msg.sender != RANDOM_SOURCE) revert OnlyRandomSource();
        if (state != BoardState.Active || !drawPending || _requestRound[requestId] != _drawRound) {
            emit StaleRandomness(requestId);
            return;
        }
        drawPending = false;
        uint256 s = aliveStake;
        uint256 r = randomWord % ((aliveCount - 1) * s);
        _eject(_tree.selectEject(s, r));
    }

    /// @notice VRF 超过 vrfRetryDelay（24 小时）没响应，运营地址可以重新请求（再过 3 天参与者也可以）；
    ///         旧请求仍然有效（谁先到用谁，审计 M-3）。没超时不允许重发。
    function retryDraw() external nonReentrant {
        if (state != BoardState.Active || !drawPending) revert NoPendingDraw();
        if (block.timestamp < lastRequestAt + VRF_RETRY_DELAY) revert TooEarly();
        _auth(lastRequestAt + VRF_RETRY_DELAY);
        _requestDraw(pulseGross(_tree.maxStake()));
    }

    /// @notice VRF 从第一次请求起超过 vrfSafeExitDelay（7 天）仍未响应：进入安全退出，按保底公式分配
    ///         （先收 2% 手续费，再退未出局者投入，剩余按投入分给所有参与者；不收基金会 3%，不发硅王奖，规则决定 6.37）。
    function triggerSafeExit() external nonReentrant {
        if (state != BoardState.Active || !drawPending) revert NoPendingDraw();
        if (block.timestamp < firstRequestAt + VRF_SAFE_EXIT_DELAY) revert TooEarly();
        _startLiquidation(SettleMode.SafeExit);
    }

    /// @notice 超过最长期限仍未全部出局（或首轮收购结束时一台矿机都没买到）：进入保底分配
    ///         （先收 2% 手续费，再退未出局者投入，剩余按投入分给所有参与者；不收基金会 3%，不发硅王奖，规则决定 6.37）。
    function expire() external nonReentrant {
        if (state != BoardState.Active) revert WrongState();
        bool timeUp = block.timestamp >= startedAt + MAX_DURATION;
        bool noMachines = _machines.length == 0 && block.timestamp >= initialBuyEnd;
        if (!timeUp && !noMachines) revert NotExpired();
        _startLiquidation(SettleMode.Fallback);
    }

    /// @notice 升级哨兵冷静期内（触发后登记满 30 天之前），未出局持仓（slot）的持有人可以让已开局的主板退出，按保底规则分配。
    ///         冷静期过后不能再用（审计 M-1：否则信标升级一次之后，每一局都能被任何一个人单方面结束）。
    function emergencyExit(uint256 slot) external nonReentrant {
        if (state != BoardState.Active) revert WrongState();
        if (!sentinelPaused()) revert SentinelNotTripped();
        IBoardHub(FACTORY).noteSentinel(); // 顺带登记触发时间
        if (_sockets[slot].owner != msg.sender || _sockets[slot].ejected) revert NotAliveParticipant();
        _startLiquidation(SettleMode.Fallback);
    }

    function _requestDraw(uint256 threshold) internal {
        drawPending = true;
        lastRequestAt = block.timestamp;
        uint256 id = IRandomSource(RANDOM_SOURCE).requestRandomness();
        pendingRequestId = id;
        _requestRound[id] = _drawRound;
        emit DrawRequested(id, msg.sender, pool, threshold);
    }

    function _eject(uint256 slot) internal {
        Socket storage s = _sockets[slot];
        uint256 stake = s.stake;
        _tree.remove(slot, stake);
        aliveCount -= 1;
        aliveStake -= stake;
        s.ejected = true;
        lastPulseAt = block.timestamp;
        ++tradeEpoch;
        _payPulse(slot, false);
        _tryReturnPass(slot); // 出局即退还通行证（失败的话本人之后可以 returnPass）
        if (aliveCount == 1) {
            kingSocket = _tree.findByCount(1);
            emit KingCrowned(kingSocket, _sockets[kingSocket].owner);
        }
    }

    /// @dev 一次脉冲：出局者得投入的 105%（= 总额 95%，直接推送给他），基金会 3%，手续费地址拿剩下的约 2%
    ///      （两者记账，任何人可以 withdraw 给它们）。
    function _payPulse(uint256 slot, bool isKing) internal {
        Socket storage s = _sockets[slot];
        uint256 payout = uint256(s.stake) * EJECT_PAYOUT_BPS / BPS;
        uint256 gross = _ceilDiv(payout * BPS, PULSE_PLAYER_BPS);
        uint256 toFoundation = gross * FOUNDATION_BPS / BPS;
        uint256 toFee = gross - payout - toFoundation;
        pool -= gross;
        credit[FOUNDATION] += toFoundation;
        credit[FEE_RECIPIENT] += toFee;
        liabilities += toFoundation + toFee;
        _push(s.owner, payout);
        emit Pulse(slot, s.owner, payout, toFoundation, toFee, isKing);
    }

    /// @dev 推送 BEM；万一转账失败（BEM 是普通 ERC20，正常不会发生），改为记账由本人领取，不让 VRF 回调失败。
    function _push(address to, uint256 amount) internal {
        (bool ok, bytes memory ret) = address(BEM).call(abi.encodeCall(IERC20.transfer, (to, amount)));
        if (ok && (ret.length == 0 || abi.decode(ret, (bool)))) return;
        credit[to] += amount;
        liabilities += amount;
    }

    /// @dev 退还通行证（transferFrom，不触发回调）；失败时保留记录，本人之后可以 returnPass。
    function _tryReturnPass(uint256 slot) internal {
        Socket storage s = _sockets[slot];
        if (s.passReturned) return;
        (bool ok,) = PASS_CIRCUITS.call(abi.encodeCall(ICircuits.transferFrom, (address(this), s.owner, s.passId)));
        if (!ok) return;
        s.passReturned = true;
        emit PassReturned(s.owner, s.passId);
    }

    /// @dev 运营地址专属；运营地址在 since 之后 operatorGrace 内没执行，本局持仓的持有人可以执行；
    ///      运营地址为 0 时参与者随时可以执行。其他地址始终不行。
    function _auth(uint256 since) internal view {
        address op = IBoardHub(FACTORY).operator();
        if (op != address(0) && msg.sender == op) return;
        if (holderCount[msg.sender] == 0) revert NotAuthorized();
        if (op != address(0) && block.timestamp < since + OPERATOR_GRACE) revert NotAuthorized();
    }

    /// @dev 领取全部在挖、未卖出矿机的产出。claimMany 失败时逐台领取，跳过失败的矿机。
    function _claimYield() internal returns (uint256 got) {
        uint256 n = _machines.length;
        bytes32[] memory keys = new bytes32[](n);
        uint256 k;
        for (uint256 i = 0; i < n; i++) {
            Machine storage m = _machines[i];
            if (m.active && !m.sold) keys[k++] = m.key;
        }
        if (k == 0) return 0;
        // 把内存数组的长度改成实际填入的 k 个（k ≤ 原长度 n，只缩短，不越界；TapeCode 第二轮 B21）
        assembly {
            mstore(keys, k)
        }
        uint256 before = _bemBalance();
        try IPoD(POD).claimMany(keys) {}
        catch {
            for (uint256 j = 0; j < k; j++) {
                try IPoD(POD).claim(keys[j]) {} catch {}
            }
        }
        got = _bemBalance() - before;
        if (got > 0) {
            emit Harvested(got);
            if (state == BoardState.Active) pool += got;
            else _sweep();
        }
    }

    /// @dev 领取单台矿机的产出；Active 状态计入脉冲池，终局阶段由调用方 _sweep。
    function _claimOne(bytes32 key) internal {
        uint256 before = _bemBalance();
        try IPoD(POD).claim(key) {} catch {}
        uint256 got = _bemBalance() - before;
        if (got > 0) {
            emit Harvested(got);
            if (state == BoardState.Active) pool += got;
        }
    }

    // ============ 4. 终局（价格逐步下降的荷兰式拍卖）与底池分配 ============

    function _startLiquidation(SettleMode mode) internal {
        state = BoardState.Liquidating;
        settleMode = mode;
        liquidationStart = block.timestamp;
        drawPending = false;
        ++tradeEpoch;
        if (buyRoundEnd > block.timestamp) buyRoundEnd = block.timestamp;
        if (totalWeightBought > 0) {
            uint256 avg = totalSpent / totalWeightBought;
            sellStartPrice = avg * SELL_START_BPS / BPS;
            sellFloorPrice = avg * SELL_FLOOR_BPS / BPS;
        }
        if (mode == SettleMode.Normal) {
            proRataStake = totalStake - _sockets[kingSocket].stake;
        } else {
            // 异常结局（最长期限 / VRF 安全退出 / 升级哨兵）统一用保底公式
            proRataStake = totalStake;
            priorityStake = aliveStake;
            priorityRemaining = aliveStake;
        }
        if (unsoldMachines == 0) finishedAt = block.timestamp;
        // 脉冲池剩余和未用完的采购预算都并入底池
        pool = 0;
        budget = 0;
        emit LiquidationStarted(mode, sellStartPrice, sellFloorPrice);
        _claimYield();
        _sweep();
    }

    /// @notice 终局卖出一台矿机。只认 StdMachineSales（它负责挂单 / 降价拍卖定价、计价权重和收款）：
    ///         从卖矿合约收 cost 个 BEM（并入底池），先领这台矿机卖出前的产出，再把矿机转给买家。升级哨兵冷静期内暂停。
    function releaseMachine(uint256 index, address to, uint256 weight, uint256 cost) external nonReentrant {
        if (msg.sender != SALES) revert NotAuthorized();
        if (state != BoardState.Liquidating) revert WrongState();
        if (sentinelPaused()) revert UpgradeSentinelTripped();
        Machine storage m = _machines[index];
        if (m.sold) revert AlreadySold();
        m.sold = true;
        unsoldMachines -= 1;
        if (unsoldMachines == 0) finishedAt = block.timestamp;
        if (m.active) {
            m.active = false;
            activeWeight -= m.weight;
        }
        // 卖出前的产出归主板（并入底池；寄售中的矿机产出付给挂单库，由它转回主板）
        _claimOne(m.key);
        if (cost > 0) _bemIn(cost);
        // to = 0：寄售在挂单模块的矿机已经在市场上成交交给买家（MachineLister 结算），这里只记账
        if (to != address(0)) ICircuits(m.collection).transferFrom(address(this), to, m.circuitId);
        if (!claimsClosed) _sweep();
        emit MachineSold(index, m.circuitId, to, weight, cost);
    }

    /// @notice 寄售（只认 StdMachineSales，规则决定 6.26）：把还没卖出的第 index 台矿机转给挂单模块的挂单库，由它按公式价
    ///         挂到 TapeOut 官方矿机市场 / Seaport。账上仍是本局的矿机（继续挖，产出由挂单库转回）；成交时经卖矿合约按
    ///         成交那一刻的公式价结算（releaseMachine 的 to = 0），撤单时挂单库把矿机还回来。
    function consign(uint256 index, address to) external nonReentrant {
        if (msg.sender != SALES) revert NotAuthorized();
        if (state != BoardState.Liquidating) revert WrongState();
        Machine storage m = _machines[index];
        if (m.sold) revert AlreadySold();
        ICircuits(m.collection).transferFrom(address(this), to, m.circuitId);
    }

    /// @notice 把合约里尚未分配的 BEM（卖矿机所得、产出、捐赠等）按本局的分配方式记入各人名下。任何人可调。
    function sweep() external nonReentrant {
        if (state != BoardState.Liquidating) revert WrongState();
        if (claimsClosed) revert ClaimsAreClosed();
        _sweep();
    }

    function _sweep() internal {
        uint256 bal = _bemBalance();
        if (bal > liabilities) _allocate(bal - liabilities);
    }

    /// @dev 底池分配（累加器，可以分多次进行）。
    ///      正常终局（Normal）：3% 基金会、2% 手续费地址、30% 硅王，
    ///        其余 65% 按投入分给硅王以外的人。
    ///      异常结局（Fallback / SafeExit，设计审计 H5）：先收 2% 给手续费地址（规则决定 6.37；不收基金会 3%），其余：
    ///        1. 先填"未出局者取回投入"：填满之前，到账多少就按未出局者的投入比例分多少（不够就按比例）；
    ///        2. 填满后剩下的部分全部按投入分给所有参与者（包括已出局的人）；
    ///        没有调用者奖励，没有硅王奖。
    function _allocate(uint256 amount) internal {
        liabilities += amount;
        potAllocated += amount;
        if (settleMode != SettleMode.Normal) {
            uint256 fee = amount * FEE_BPS / BPS;
            credit[FEE_RECIPIENT] += fee;
            amount -= fee;
            uint256 priority;
            if (priorityRemaining > 0) {
                priority = amount < priorityRemaining ? amount : priorityRemaining;
                priorityRemaining -= priority;
                accPriority += priority * ACC_SCALE / priorityStake;
            }
            accProRata += (amount - priority) * ACC_SCALE / proRataStake;
            emit PotAllocated(amount, priority);
            return;
        }
        uint256 toFoundation = amount * FOUNDATION_BPS / BPS;
        uint256 toFee = amount * FEE_BPS / BPS;
        uint256 toKing = amount * POT_KING_BPS / BPS;
        credit[FOUNDATION] += toFoundation;
        credit[FEE_RECIPIENT] += toFee;
        uint256 rest = amount - toFoundation - toFee - toKing;
        kingPot += toKing;
        if (proRataStake == 0) kingPot += rest;
        else accProRata += rest * ACC_SCALE / proRataStake;
        emit PotAllocated(amount, 0);
    }

    function _potEntitlement(uint256 slot) internal view returns (uint256 ent) {
        Socket storage s = _sockets[slot];
        if (settleMode == SettleMode.Normal) {
            if (slot == kingSocket) return kingPot;
            return uint256(s.stake) * accProRata / ACC_SCALE;
        }
        ent = uint256(s.stake) * accProRata / ACC_SCALE;
        if (!s.ejected) ent += uint256(s.stake) * accPriority / ACC_SCALE;
    }

    // ============ 持仓转让（规则决定 6.23）============

    /// @notice 持仓现在能否转让：开局且首轮收购结束后（开奖已请求、随机数还没交付时锁定），以及终局阶段；
    ///         领取期限关闭后不能。
    function transferable() public view returns (bool) {
        if (claimsClosed) return false;
        if (state == BoardState.Liquidating) return true;
        return state == BoardState.Active && block.timestamp >= initialBuyEnd && !drawPending;
    }

    /// @notice 持仓转移钩子（只认持仓凭证合约：直接转账、授权转账、盘口成交都经过这里）。
    ///         1. 锁：不可转让时整笔回滚（transferable）；
    ///         2. 结转：终局阶段先 sweep，把卖方已经累计的底池份额记入 credit[卖方]（卖方之后 withdrawCredit），买方只拿之后的；
    ///            已经推送 / 记账给卖方的款项（出局的 105% 等）本来就在卖方名下，不随持仓转移；
    ///         3. 通行证：还没退的立刻退给原持有人（第一次转让时的卖方就是加入者）；退不出去则不允许转让；
    ///         4. 更新持有人、持有计数和持仓版本号（旧卖单失效）。之后出局的 105%、硅王的 105% + 底池 30%、
    ///            终局份额、保底退款都按插槽付给当时的持有人。
    function onPositionTransfer(uint256 slot, address from, address to) external nonReentrant {
        if (msg.sender != POSITIONS) revert NotAuthorized();
        if (!transferable()) revert TransferLocked();
        Socket storage s = _sockets[slot];
        uint256 carried;
        if (state == BoardState.Liquidating) {
            _sweep();
            carried = _potEntitlement(slot) - s.potClaimed;
            // forge-lint: disable-next-line(unsafe-typecast)
            s.potClaimed += uint128(carried); // 底池总额远小于 2^128
            credit[from] += carried;
        }
        _tryReturnPass(slot);
        if (!s.passReturned) revert TransferLocked();
        s.owner = to;
        holderCount[from] -= 1;
        holderCount[to] += 1;
        s.version += 1;
        emit PositionTransferred(slot, from, to, carried);
    }

    // ============ 领取（按持仓，pull 模式）============
    // 查询可领金额（owed）、一次领完（claimAll）和运营地址分批发放（distribute）在 StdMachineSales（节省主板字节，和月局的做法一样）。

    /// @notice 把第 slot 份持仓应得的 BEM 打给它当前的持有人。任何人可调（方便代领），钱只会打给持有人。
    function withdraw(uint256 slot) external nonReentrant returns (uint256 amount) {
        amount = _withdraw(slot, true);
        if (amount == 0) revert NothingToWithdraw();
    }

    /// @notice 把记在 account 名下的 BEM 打给 account。任何人可调。
    function withdrawCredit(address account) external nonReentrant returns (uint256 amount) {
        if (state == BoardState.Liquidating && !claimsClosed) _sweep();
        amount = _withdrawCredit(account);
        if (amount == 0) revert NothingToWithdraw();
    }

    /// @notice 招募失败、进入终局或已出局后，把第 slot 份持仓的通行证原样退还给加入者（transferFrom）。任何人可调。
    function returnPass(uint256 slot) external nonReentrant {
        if (!_returnPass(slot)) revert PassAlreadyReturned();
    }

    /// @notice 领取期限（招募失败或终局卖完全部矿机后 claimWindow）已过：把合约里剩下的全部 BEM
    ///         （过期未领的资金和取整尘埃）转到黑洞地址 0x…dEaD 销毁（规则决定 6.13），此后不再接受领取。
    ///         通行证仍可随时退还。任何人可调。
    function closeClaims() external nonReentrant {
        if (finishedAt == 0 || block.timestamp < finishedAt + CLAIM_WINDOW) revert TooEarly();
        claimsClosed = true;
        liabilities = 0;
        uint256 bal = _bemBalance();
        if (bal > 0) _bemOut(0x000000000000000000000000000000000000dEaD, bal);
        emit ClaimsClosed(bal);
    }

    function _withdraw(uint256 slot, bool doSweep) internal returns (uint256 amount) {
        if (claimsClosed) revert ClaimsAreClosed();
        Socket storage s = _sockets[slot];
        if (s.owner == address(0)) return 0;
        if (state == BoardState.Failed) {
            if (s.refunded) return 0;
            s.refunded = true;
            amount = uint256(s.stake) + uint256(s.stake) * ENTRY_FEE_BPS / BPS;
        } else if (state == BoardState.Liquidating) {
            if (doSweep) _sweep();
            amount = _potEntitlement(slot) - s.potClaimed;
            // forge-lint: disable-next-line(unsafe-typecast)
            s.potClaimed += uint128(amount); // 底池总额远小于 2^128
        }
        _pay(s.owner, amount);
    }

    function _withdrawCredit(address account) internal returns (uint256 amount) {
        if (claimsClosed) revert ClaimsAreClosed();
        amount = credit[account];
        credit[account] = 0;
        _pay(account, amount);
    }

    function _pay(address to, uint256 amount) internal {
        if (amount == 0) return;
        liabilities -= amount;
        _bemOut(to, amount);
        emit Withdrawn(to, amount);
    }

    function _returnPass(uint256 slot) internal returns (bool) {
        Socket storage s = _sockets[slot];
        if (s.owner == address(0)) revert NotParticipant();
        if (state != BoardState.Failed && state != BoardState.Liquidating && !s.ejected) revert WrongState();
        if (s.passReturned) return false;
        s.passReturned = true;
        ICircuits(PASS_CIRCUITS).transferFrom(address(this), s.owner, s.passId);
        emit PassReturned(s.owner, s.passId);
        return true;
    }

    // ============ 升级哨兵 ============

    /// @notice 电路合约（矿机 / 通行证）的信标实现地址与部署时记录的不同，或信标无法读取，即视为触发（sentinelTripped）。
    ///         触发后进入 30 天冷静期（sentinelPaused）：冷静期内招募中的主板可以立即结束招募并退款；
    ///         已开局的主板照常领取产出、开奖，未出局的参与者可以 emergencyExit 按保底规则退出。
    /// @notice 升级哨兵的冷静期（外部审计 #2）：哨兵已触发，且注册中心的登记（`sentinelSince`，两种局共用）不满
    ///         sentinelResumeDelay（30 天）时为真。冷静期内暂停加入和矿机收购 / 出售，工厂也不开新主板；
    ///         参与者仍可提前退出 / 提前结算，开奖照常。没人登记时一直处于冷静期。
    function sentinelPaused() public view returns (bool) {
        if (!sentinelTripped()) return false;
        uint256 since = IBoardHub(FACTORY).sentinelSince();
        return since == 0 || block.timestamp < since + SENTINEL_RESUME_DELAY;
    }

    function sentinelTripped() public view returns (bool) {
        return
            _beaconChanged(MACHINE_BEACON, MACHINE_IMPL_AT_DEPLOY) || _beaconChanged(PASS_BEACON, PASS_IMPL_AT_DEPLOY);
    }

    function _beaconChanged(address beacon, address implAtDeploy) internal view returns (bool) {
        if (beacon == address(0)) return false;
        (bool ok, bytes memory ret) = beacon.staticcall(abi.encodeWithSelector(IBeacon.implementation.selector));
        if (!ok || ret.length < 32) return true;
        return abi.decode(ret, (address)) != implAtDeploy;
    }

    // ============ 只读 ============

    /// @notice 一次脉冲的总额：付给出局者 stake × 105%，总额 = 它 ÷ 95%（向上取整）。
    function pulseGross(uint256 stake) public pure returns (uint256) {
        uint256 payout = stake * EJECT_PAYOUT_BPS / BPS;
        return _ceilDiv(payout * BPS, PULSE_PLAYER_BPS);
    }

    /// @notice 在局参与者中的最大投入。
    function maxAliveStake() external view returns (uint256) {
        return _tree.maxStake();
    }

    /// @notice 下一次脉冲需要的脉冲池余额：剩余参与者中最大投入 × 105% ÷ 95%。
    function drawThreshold() external view returns (uint256) {
        if (state != BoardState.Active) return 0;
        if (aliveCount >= 2) return pulseGross(_tree.maxStake());
        if (aliveCount == 1 && !kingPaid) return pulseGross(_sockets[kingSocket].stake);
        return 0;
    }

    function socket(uint256 slot) external view returns (Socket memory) {
        return _sockets[slot];
    }

    function machine(uint256 index) external view returns (Machine memory) {
        return _machines[index];
    }

    function machineCount() external view returns (uint256) {
        return _machines.length;
    }

    /// @notice 给定随机数，当前会抽中哪个插槽（供前端 / 审计复核）。
    function previewEject(uint256 randomWord) external view returns (uint256 slot) {
        if (aliveCount < 2) return 0;
        return _tree.selectEject(aliveStake, randomWord % ((aliveCount - 1) * aliveStake));
    }

    /// @dev 从调用者收 BEM / 把 BEM 转出（多处使用，收成函数节省字节）
    function _bemIn(uint256 amount) internal {
        BEM.safeTransferFrom(msg.sender, address(this), amount);
    }

    function _bemOut(address to, uint256 amount) internal {
        BEM.safeTransfer(to, amount);
    }

    /// @dev 本合约的 BEM 余额（多处使用，收成一个函数节省字节）
    function _bemBalance() internal view returns (uint256) {
        return BEM.balanceOf(address(this));
    }

    function _ceilDiv(uint256 a, uint256 b) private pure returns (uint256) {
        return a == 0 ? 0 : (a - 1) / b + 1;
    }
}

// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IMarketPriceFeed} from "./interfaces/IMarketPriceFeed.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {ICircuits, IBeacon} from "./interfaces/ITapeOut.sol";
import {MachineRules} from "./MachineRules.sol";
import {IPoD} from "./interfaces/IPoD.sol";
import {IRandomSource, IRandomConsumer} from "./interfaces/IRandomSource.sol";
import {IRewardTarget, IBoardHub} from "./interfaces/ITapeBoard.sol";
import {MonthState, IMonthFactory} from "./interfaces/IMonthBoard.sol";
import {IMonthBoardV2, IMonthPositions} from "./interfaces/IMonthV2.sol";
import {EjectionTree} from "./libraries/EjectionTree.sol";
import {PoDReader} from "./libraries/PoDReader.sol";
import {PrizeDraw} from "./libraries/PrizeDraw.sol";


/// @title MonthBoard（月局 v2，每局一个）
/// @notice 不可升级，没有能改规则、参数或资金去向的管理员。唯一的特权角色是运营地址（只能开奖、自动发放、
///         通过 MonthMachineSales 挂单 / 交接，3 天不执行由本局持仓持有人兜底），由手续费 Safe 通过
///         BoardFactory.setOperator 更换。
///
///         v2（V2-DESIGN.md）：每个插槽是一份持仓，凭证是 MonthPositions 的 ERC-721（编号 = 主板地址 << 96 | slot）。
///         持仓只在结算阶段可以整份转让，所有转移路径都经过 onPositionTransfer（锁、结转、退通行证、版本号）。
///         结算阶段的卖矿定价（挂单、交接、清算计划）在单例 MonthMachineSales；主板只负责交割和记账：
///         没有清算计划时成交价不得低于成本价（releaseMachine 里再查一次）。多数集体清算由 MonthExitGovernor 发起。
///         由 MonthFactory 用 EIP-1167 最小代理部署，参数在实现合约构造时写死；
///         每块月局的目标金额与投入范围由 MonthFactory 在开出时传入（initialize）。
///
/// 一局的流程（白皮书第 6 节、规则文档 §8）：
///   1. 招募（3 天）：投入目标的 0.2%–4%，另付 1% 入场费（开局后转出，失败时退还），通行证锁进主板。
///      招满即开局；到期 ≥ 60% 按实际金额开局；< 60% 全员退款并重招。
///   2. 准备矿机（Preparing，最多 3 天）：运营地址经 MarketTrader 在市场上从最便宜的挂单往上买（sellMachine，规则同标准局，
///      规则决定 6.37）；正在结算的旧月局也可以把矿机交接进来（relayOut → sellMachine），按本局当时的收购价上限成交，
///      旧局要求不低于它的成本价。买满（100 台，或剩余预算按当前收购价上限连一台最小算力的矿机都买不下）就提前开始挖矿。
///      买不满的 BEM 留在主板，局终原样退还。
///   3. 挖矿 30 天（Mining）：产出全部进入奖金池。
///   4. 开奖（drawPrizes → VRF 回调 onRandomness 只记下随机数 → finalizePrizes）：奖金池不扣 3% / 2%（月局只收入场费，
///      规则决定 6.15；没有调用者奖励）。一半按投入比例分给所有持仓（记账领取），另一半用一个 VRF 随机数派生
///      5 次独立抽取（60 / 15 / 15 / 5 / 5，规则决定 6.20），每次都按"个人投入 ÷ 总投入"抽，可重复中奖；奖金直接推送。
///   5. 收回本金（Settling）：矿机经 MonthMachineSales 按公式价出售（max(买一, 卖一 × (99% − 0.5% × 小时数))，
///      整台不低于成本价；报价过期时暂停，停运 7 天后按成本价可买）或交接给正在准备矿机的月局（按对方的收购价，
///      不低于成本价）。卖不出的矿机继续挖，产出按投入比例分给本局持仓。多数清算计划执行后，才可以按计划价
///      （可以低于成本价）卖出。
///      收回的资金按顺序：先退参与者的本金（按投入比例）→ 再收回回馈部分（转入月局工厂，滚给下一块开局的月局）
///      → 超出成本的部分按投入比例分给参与者。
///   异常：VRF 24 小时可重发（只认最新请求）；停摆超过 7 天不抽奖，奖金池按投入比例分给所有人（不收 3% / 2%，
///         没有调用者奖励），本金照常收回；升级哨兵触发后进入 30 天冷静期（暂停加入、矿机收购 / 出售 / 交接，
///         见 sentinelPaused），参与者可以对还没到期的局发起提前结算（同停摆）。
///
/// 发放：开奖时奖金直接推送；其余款项按持仓记账，任何人都可以 withdraw / claimAll 某份持仓（付给它的持有人）；
///       运营地址经 MonthMachineSales.distribute 分批推送并退还通行证（3 天后持有人兜底）。
/// 领取期限 365 天（从招募失败或卖完最后一台矿机起算），过期未领的 BEM 销毁（转到 0x…dEaD；事件 ClaimsClosed 的参数名
///       amountToFoundation 是历史命名，实际是销毁的数额）。
contract MonthBoard is IRewardTarget, IRandomConsumer, ReentrancyGuard {
    using SafeERC20 for IERC20;
    using EjectionTree for EjectionTree.Tree;

    uint256 public constant BPS = 10_000;
    uint256 internal constant ACC_SCALE = 1e18;
    /// @dev 构造参数里任何时长的上限（10 年）
    uint256 internal constant MAX_DURATION_PARAM = 3650 days;

    struct Config {
        // 外部合约
        address bem;
        address pod;
        address machineRules; // MachineRules（收哪些合集的矿机、计价算力，单例；规则决定 6.26）
        address machineBeacon;
        address passCircuits; // 由 MonthFactory 从 BoardFactory 读取
        address passBeacon;
        bytes32 passNetlistHash;
        address foundation;
        address feeRecipient;
        address randomSource;
        address splitter; // 由 MonthFactory 从 BoardFactory 读取
        address hub; // BoardFactory（注册中心，存放运营地址），由 MonthFactory 填入
        address positions; // MonthPositions（持仓凭证，单例）
        address sales; // MonthMachineSales（结算阶段卖矿定价，单例）
        address governor; // MonthExitGovernor（多数集体清算，单例）
        address priceFeed; // MarketPriceFeed（按卖一价收购的报价，单例，两种局共用）
        address trader; // FirstoTrader（从 Firsto 吃单买矿机；0 = 不用）
        // 招募
        uint256 entryFeeBps; // 1%
        uint256 premiumFeeBps; // 卖矿溢价分成（1000 = 10%，规则决定 6.24）：成交额超过成本价的部分按这个比例给手续费地址
        uint256 recruitDuration; // 3 天
        uint256 minStartBps; // 60%
        // 准备矿机（收购拍卖规则同标准局，以"每单位权重 365 天产出"为上限）
        uint256 buyStartBps;
        uint256 buyStepBps;
        uint256 buyStepInterval;
        uint256 buyCapDays;
        uint256 buyMaxPrice;
        uint256 verifiedShareBps;
        uint256 prepDuration; // 收购期最多 3 天
        uint256 minMachineWeight;
        uint256 maxMachineWeight;
        uint256 maxMachines;
        uint256 minMachineAge;
        // 挖矿
        uint256 miningDuration; // 30 天
        // 随机数与领取
        uint256 vrfRetryDelay;
        uint256 vrfSafeExitDelay;
        uint256 operatorGrace; // 运营地址多久没执行，本局参与者可以兜底（3 天）
        uint256 claimWindow; // 365 天
        uint256 sentinelResumeDelay; // 升级哨兵冷静期：登记满这么久后恢复加入、开新主板、矿机收购和出售（30 天，外部审计 #2）
    }

    // 关键地址公开；数值参数为 internal，可通过 MonthFactory.boardConfig() 读取
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
    address public immutable HUB;
    address public immutable POSITIONS;
    address public immutable SALES;
    address public immutable GOVERNOR;
    address public immutable PRICE_FEED;
    address public immutable TRADER;

    uint256 internal immutable ENTRY_FEE_BPS;
    /// @notice 卖矿溢价分成比例（FirstoTrader 卖出时多出来的 BEM 也按它扣）
    uint256 public immutable PREMIUM_FEE_BPS;
    uint256 internal immutable RECRUIT_DURATION;
    uint256 internal immutable MIN_START_BPS;
    uint256 internal immutable BUY_START_BPS;
    uint256 internal immutable BUY_STEP_BPS;
    uint256 internal immutable BUY_STEP_INTERVAL;
    uint256 internal immutable BUY_CAP_DAYS;
    uint256 internal immutable BUY_MAX_PRICE;
    uint256 internal immutable VERIFIED_SHARE_BPS;
    uint256 internal immutable PREP_DURATION;
    uint256 internal immutable MIN_MACHINE_WEIGHT;
    uint256 internal immutable MAX_MACHINE_WEIGHT;
    uint256 internal immutable MAX_MACHINES;
    uint256 internal immutable MIN_MACHINE_AGE;
    uint256 internal immutable MINING_DURATION;
    uint256 internal immutable VRF_RETRY_DELAY;
    uint256 internal immutable VRF_SAFE_EXIT_DELAY;
    uint256 internal immutable OPERATOR_GRACE;
    uint256 internal immutable CLAIM_WINDOW;
    uint256 internal immutable SENTINEL_RESUME_DELAY;

    // ============ 存储 ============

    struct Socket {
        address owner;
        uint96 stake;
        uint256 passId;
        uint128 claimed; // 已领取的按比例份额
        bool refunded;
        bool passReturned;
        uint32 version; // 持仓版本号：每次转让 +1，旧订单随之失效
    }

    struct Machine {
        bytes32 key;
        uint256 circuitId;
        address collection; // 电路合约（工厂创建的处理器，规则决定 6.26）
        uint64 weight; // 收购时的计价算力（PoDReader：min(基础算力 × 倍数, 已验证池权重)）
        bool active;
        bool sold;
        uint128 cost; // 成本价：买入时付的 BEM
    }

    MonthState public state;
    uint256 public number;
    uint256 public target;
    uint256 public minStake;
    uint256 public maxStake;
    uint256 internal openedAt;
    uint256 public recruitDeadline;
    uint256 public startedAt;

    uint256 public socketCount;
    mapping(uint256 => Socket) internal _sockets;
    /// @notice 每个地址在本局持有几份持仓（招募时每个地址最多加入一次；结算阶段可以通过转让持有多份）
    mapping(address => uint256) public holderCount;
    /// @notice 转让时退通行证失败的插槽：通行证归这个地址（加入者），之后 returnPass 退给它
    mapping(uint256 => address) public passOwner;
    uint256 public totalStake;
    uint256 public totalEntryFees;
    EjectionTree.Tree internal _tree;

    // 资本：本金（totalStake）+ 回馈（splitter 补贴与上一批月局滚存过来的资金）
    uint256 public budget; // 还没花掉的资本
    uint256 internal _roundCap; // 收购开始时的收购价上限快照（外部审计 #3），见 buyPriceCap
    uint256 public subsidyCapital;

    uint256 public prepEnd;
    uint256 public miningStart;
    uint256 public miningEnd;
    Machine[] internal _machines;
    uint256 public unsoldMachines;
    uint256 public totalSpent;
    uint256 public activeWeight;

    // 开奖
    uint256 public prizePool;
    bool public drawPending;
    uint256 public pendingRequestId;
    /// @dev 审计 M-3：本局发出的随机数请求（只开一次奖，重发的请求都有效，先到先用）
    mapping(uint256 => bool) internal _ourRequest;
    uint256 internal wordReceivedAt;
    uint256 internal lastRequestAt;
    uint256 internal firstRequestAt;
    bool public wordReceived; // VRF 已交付随机数，等待 finalizePrizes
    uint256 internal drawWord;
    bool public prizesDrawn;
    uint256[5] public winnerSlots;
    uint256[5] public prizeAmounts;

    // 结算
    uint256 public settleStart;
    uint256 public principalRemaining; // 还没退还的参与者本金
    uint256 public subsidyRemaining; // 还没收回的回馈资本
    uint256 public rolledOver; // 已转入月局工厂（滚给下一块月局）的回馈资本
    uint256 internal accShare; // 每单位投入累计可领取的金额（× 1e18）：本金、超出成本的部分、局终后的产出

    mapping(address => uint256) public credit; // 持仓转让时结转给卖方的已累计款项（按地址领取）
    uint256 public liabilities;
    uint256 public finishedAt;
    bool public claimsClosed;

    // v2：持仓交易与清算
    uint64 public tradeEpoch; // 局交易版本号：进入结算、卖出 / 交接矿机、治理锁变化、开始清算时 +1
    bool public governanceLocked; // 清算正式投票与执行等待期间锁定转让
    bool public liquidating; // 多数清算计划已执行：允许按计划价低于成本价卖出

    // ============ 事件 ============

    event Initialized(uint256 indexed number, uint256 target, uint256 minStake, uint256 maxStake, uint256 deadline);
    event Joined(address indexed player, uint256 indexed slot, uint256 passId, uint256 stake, uint256 fee);
    event Started(uint256 totalStake, uint256 entryFees, bool full, uint256 elapsed, uint256 rolloverIn);
    event RecruitmentFailed(uint256 totalStake, uint256 participants);
    event MachineBought(
        uint256 indexed index,
        uint256 indexed circuitId,
        address indexed seller,
        uint256 weight,
        uint256 cost,
        address collection
    );
    event MachineRelayedOut(uint256 indexed index, uint256 indexed circuitId, address indexed toBoard, uint256 price);
    event MachineSold(uint256 indexed index, uint256 indexed circuitId, address indexed buyer, uint256 price);
    event SubsidyDeposited(uint256 amount);
    event MiningStarted(uint256 start, uint256 end, uint256 machines, uint256 weight);
    event Harvested(uint256 amount);
    event DrawRequested(uint256 indexed requestId, address indexed requester, uint256 prizePool);
    event StaleRandomness(uint256 indexed requestId);
    event RandomnessReceived(uint256 indexed requestId, uint256 randomWord);
    event PrizesDrawn(uint256 prizePool, uint256[5] slots, uint256[5] amounts, uint256 toFoundation, uint256 toFee);
    event NoDrawSettlement(uint256 prizePoolSharedProRata);
    event SettlementStarted(uint256 idleCapital);
    event CapitalReturned(uint256 principal, uint256 subsidyRolledOver, uint256 premium);
    event Withdrawn(address indexed account, uint256 amount);
    event PassReturned(address indexed player, uint256 passId);
    event ClaimsClosed(uint256 amountToFoundation);
    event PositionTransferred(uint256 indexed slot, address indexed from, address indexed to, uint256 carriedOver);
    event TradeEpochBumped(uint64 epoch);
    event GovernanceLockSet(bool locked);
    event LiquidationStarted();

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
    error PriceBelowMinimum();
    error InsufficientBudget();
    error NotMonthBoard();
    error RelayUnpaid();
    error NotYet();
    error NoPendingDraw();
    error TooEarly();
    error SentinelNotTripped();
    error NotParticipant();
    error AlreadySold();
    error NotAuthorized();
    error BelowCost();
    error NothingToWithdraw();
    error PassAlreadyReturned();
    error ClaimsAreClosed();
    error TransferLocked();

    // ============ 构造 / 初始化 ============

    constructor(Config memory c) {
        if (
            c.bem == address(0) || c.pod == address(0) || c.machineRules == address(0)
                || c.passCircuits == address(0) || c.foundation == address(0) || c.feeRecipient == address(0)
                || c.randomSource == address(0) || c.splitter == address(0)
        ) revert BadConfig();
        if (c.entryFeeBps > 1_000 || c.minStartBps == 0 || c.minStartBps > BPS) revert BadConfig();
        if (c.buyStepInterval == 0 || c.buyStartBps > BPS || c.buyCapDays == 0 || c.verifiedShareBps > BPS) {
            revert BadConfig();
        }
        // TapeCode 第三轮 #12：起始收购价不能为 0；基金会和手续费地址必须不同（只在构造时检查，不占运行时字节）
        if (c.buyStartBps == 0 || c.foundation == c.feeRecipient || c.premiumFeeBps > 5_000) revert BadConfig();
        if (c.maxMachineWeight < c.minMachineWeight || c.maxMachines == 0 || c.miningDuration == 0) revert BadConfig();
        if (c.vrfSafeExitDelay < c.vrfRetryDelay || c.hub == address(0)) revert BadConfig();
        if (c.positions == address(0) || c.sales == address(0) || c.governor == address(0) || c.priceFeed == address(0)) {
            revert BadConfig();
        }
        // 时长类参数（内审 F3）：VRF 重发至少隔 1 小时；招募期和准备期不能为 0；全部不超过 10 年
        if (c.vrfRetryDelay < 1 hours || c.recruitDuration == 0 || c.prepDuration == 0) revert BadConfig();
        if (
            c.recruitDuration > MAX_DURATION_PARAM || c.buyStepInterval > MAX_DURATION_PARAM
                || c.prepDuration > MAX_DURATION_PARAM || c.minMachineAge > MAX_DURATION_PARAM
                || c.miningDuration > MAX_DURATION_PARAM || c.vrfSafeExitDelay > MAX_DURATION_PARAM
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
        HUB = c.hub;
        POSITIONS = c.positions;
        SALES = c.sales;
        GOVERNOR = c.governor;
        PRICE_FEED = c.priceFeed;
        TRADER = c.trader;

        ENTRY_FEE_BPS = c.entryFeeBps;
        PREMIUM_FEE_BPS = c.premiumFeeBps;
        RECRUIT_DURATION = c.recruitDuration;
        MIN_START_BPS = c.minStartBps;
        BUY_START_BPS = c.buyStartBps;
        BUY_STEP_BPS = c.buyStepBps;
        BUY_STEP_INTERVAL = c.buyStepInterval;
        BUY_CAP_DAYS = c.buyCapDays;
        BUY_MAX_PRICE = c.buyMaxPrice;
        VERIFIED_SHARE_BPS = c.verifiedShareBps;
        PREP_DURATION = c.prepDuration;
        MIN_MACHINE_WEIGHT = c.minMachineWeight;
        MAX_MACHINE_WEIGHT = c.maxMachineWeight;
        MAX_MACHINES = c.maxMachines;
        MIN_MACHINE_AGE = c.minMachineAge;
        MINING_DURATION = c.miningDuration;
        VRF_RETRY_DELAY = c.vrfRetryDelay;
        VRF_SAFE_EXIT_DELAY = c.vrfSafeExitDelay;
        OPERATOR_GRACE = c.operatorGrace;
        CLAIM_WINDOW = c.claimWindow;
        SENTINEL_RESUME_DELAY = c.sentinelResumeDelay;
    }

    /// @notice 由 MonthFactory 在创建代理的同一笔交易里调用。
    function initialize(uint256 number_, uint256 target_, uint256 minStake_, uint256 maxStake_) external {
        if (msg.sender != FACTORY) revert OnlyFactory();
        if (state != MonthState.Uninitialized) revert AlreadyInitialized();
        if (minStake_ == 0 || maxStake_ < minStake_ || target_ <= maxStake_) revert BadConfig();
        state = MonthState.Recruiting;
        number = number_;
        target = target_;
        minStake = minStake_;
        maxStake = maxStake_;
        openedAt = block.timestamp;
        recruitDeadline = block.timestamp + RECRUIT_DURATION;
        _tree.init(target_ / minStake_ + 1);
        emit Initialized(number_, target_, minStake_, maxStake_, recruitDeadline);
    }

    // ============ 1. 招募（规则同标准局，招募期 3 天）============

    /// @notice 加入本局。投入范围 [minStake, maxStake]，支持小数；超出剩余额度时只接受到恰好满额；
    ///         剩余额度小于 minStake 时也可以投恰好等于剩余额度的金额。入场费另收。
    function join(uint256 passId, uint256 amount) external nonReentrant {
        if (state != MonthState.Recruiting) revert WrongState();
        if (block.timestamp >= recruitDeadline) revert RecruitmentClosed();
        if (sentinelPaused()) revert UpgradeSentinelTripped();
        if (holderCount[msg.sender] != 0) revert AlreadyJoined();

        uint256 remaining = target - totalStake;
        if (amount > maxStake || (amount < minStake && amount != remaining) || amount == 0) revert BadAmount();
        uint256 stake = amount > remaining ? remaining : amount;

        if (ICircuits(PASS_CIRCUITS).ownerOf(passId) != msg.sender) revert NotPassOwner();
        if (keccak256(ICircuits(PASS_CIRCUITS).netlist(passId)) != PASS_NETLIST_HASH) revert NotStandardPass();

        uint256 fee = stake * ENTRY_FEE_BPS / BPS;
        uint256 slot = ++socketCount;
        _sockets[slot] = Socket({
            owner: msg.sender,
            stake: uint96(stake),
            passId: passId,
            claimed: 0,
            refunded: false,
            passReturned: false,
            version: 0
        });
        holderCount[msg.sender] = 1;
        totalStake += stake;
        totalEntryFees += fee;
        _tree.insert(slot, stake);
        IMonthPositions(POSITIONS).mint(msg.sender, slot); // 持仓凭证（_mint，不回调接收方）

        ICircuits(PASS_CIRCUITS).transferFrom(msg.sender, address(this), passId);
        BEM.safeTransferFrom(msg.sender, address(this), stake + fee);
        emit Joined(msg.sender, slot, passId, stake, fee);

        if (totalStake == target) _start(true);
    }

    /// @notice 招募期满（或升级哨兵触发）后结束招募：≥ 60% 按实际金额开局；否则全员退款，工厂重开。
    function closeRecruitment() external nonReentrant {
        if (state != MonthState.Recruiting) revert WrongState();
        bool tripped = sentinelPaused(); // 冷静期内可以立即结束招募、全额退款
        if (block.timestamp < recruitDeadline && !tripped) revert CannotClose();
        if (!tripped && socketCount > 0 && totalStake * BPS >= target * MIN_START_BPS) {
            _start(false);
            return;
        }
        state = MonthState.Failed;
        finishedAt = block.timestamp;
        liabilities = totalStake + totalEntryFees;
        emit RecruitmentFailed(totalStake, socketCount);
        IMonthFactory(FACTORY).onBoardFailed();
    }

    function _start(bool full) internal {
        state = MonthState.Preparing;
        startedAt = block.timestamp;
        prepEnd = block.timestamp + PREP_DURATION;
        budget = totalStake;
        _roundCap = _liveCap();
        if (totalEntryFees > 0) BEM.safeTransfer(FEE_RECIPIENT, totalEntryFees);
        uint256 elapsed = block.timestamp - openedAt;
        // 工厂登记开局顺序、开出下一块，并把滚存的回馈资金转进来（作为本局的回馈资本）
        uint256 rollover = IMonthFactory(FACTORY).onBoardStarted(full, elapsed);
        if (rollover > 0) {
            budget += rollover;
            subsidyCapital += rollover;
        }
        emit Started(totalStake, totalEntryFees, full, elapsed, rollover);
    }

    // ============ 2. 准备矿机 ============

    function isPurchasing() public view returns (bool) {
        return state == MonthState.Preparing && block.timestamp < prepEnd;
    }

    /// @notice 收购价上限：收购开始（开局）时的快照，整个准备期内不随 PoD 的即时状态变化（外部审计 #3）。
    ///         快照 = min(每单位权重日产出 × buyCapDays, 绝对上限)；快照时读不到 PoD 产出速率则为 0（暂停收购），
    ///         之后第一次有人卖矿机或交接进来时会再快照一次。
    function buyPriceCap() public view returns (uint256) {
        return _roundCap;
    }

    function _liveCap() internal view returns (uint256) {
        (bool ok, uint256 perDay) = PoDReader.tryUnitYieldPerDay(POD, VERIFIED_SHARE_BPS);
        if (!ok) return 0;
        uint256 cap = perDay * BUY_CAP_DAYS;
        return cap > BUY_MAX_PRICE ? BUY_MAX_PRICE : cap;
    }

    /// @notice 当前收购价上限（每单位权重），由报价单例决定（MarketPriceFeed.buyQuote）：报价有效时 = min(卖一, 上限)（规则决定 6.37），
    ///        报价无效（过期、追价、运营地址为 0、停运）时为 0（暂停收购，全局审计 G-1）；从没报过价时按默认曲线（开局前必须报过价，
    ///        实际用不到）：
    ///         从上限 × buyStartBps 起逐步上涨到上限。
    function buyPrice() public view returns (uint256) {
        if (!isPurchasing()) return 0;
        uint256 bps = BUY_START_BPS + ((block.timestamp - startedAt) / BUY_STEP_INTERVAL) * BUY_STEP_BPS;
        if (bps > BPS) bps = BPS;
        uint256 cap = buyPriceCap();
        return IMarketPriceFeed(PRICE_FEED).buyQuote(cap, cap * bps / BPS, startedAt);
    }

    /// @notice 收购拍卖：把一台已验证、在挖、运行足够久的矿机卖给本局（规则同标准局；合集和计价算力见 TapeBoard.sellMachine）。
    function sellMachine(address collection, uint256 circuitId, uint256 minPricePerWeight)
        external
        nonReentrant
        returns (uint256 paid)
    {
        // 规则决定 6.37：只认 MarketTrader（运营地址在市场上买的真实挂单）和同一工厂的旧月局（交接）
        bool fromTrader = msg.sender == TRADER;
        if (!fromTrader && !IMonthFactory(FACTORY).isBoard(msg.sender)) revert NotAuthorized();
        if (!isPurchasing()) revert BuyRoundInactive();
        if (sentinelPaused()) revert UpgradeSentinelTripped();
        if (_machines.length >= MAX_MACHINES) revert TooManyMachines();
        // 合集和 PoD 资格（MachineRules，先核对合集再调用它）；不合格时回滚 MachineNotEligible
        (bytes32 key, uint256 weight) =
            MACHINE_RULES.check(collection, circuitId, MIN_MACHINE_WEIGHT, MAX_MACHINE_WEIGHT, MIN_MACHINE_AGE);
        if (ICircuits(collection).ownerOf(circuitId) != msg.sender) revert NotMachineOwner();
        if (_roundCap == 0) _roundCap = _liveCap(); // 开局时没快照成功，补一次
        uint256 price = buyPrice();
        if (price == 0) revert PriceUnavailable();
        paid = weight * price;
        // MarketTrader（规则决定 6.22）：第二个参数是它在市场上的实际花费（BEM），按实价记账，不得超过 权重 × 收购价上限；
        // 旧月局交接：第二个参数是它要求的最低单价（不低于成本价）
        if (fromTrader) {
            if (minPricePerWeight > paid) revert PriceBelowMinimum();
            paid = minPricePerWeight;
        } else if (price < minPricePerWeight) {
            revert PriceBelowMinimum();
        }
        if (paid > budget) revert InsufficientBudget();
        _addMachine(key, collection, circuitId, weight, paid);
        // 先把旧产出发给卖家，再收入矿机
        try IPoD(POD).claim(key) {} catch {}
        ICircuits(collection).transferFrom(msg.sender, address(this), circuitId);
        BEM.safeTransfer(msg.sender, paid);
        emit MachineBought(_machines.length - 1, circuitId, msg.sender, weight, paid, collection);
        _sync(); // 买满就开始挖矿（规则决定 6.37）
    }

    /// @notice 首批回馈：开局后、局终结算前可以接收补贴。准备阶段可以继续买矿机；之后到账的留到局终，
    ///         和其他回馈资本一起转给下一块月局。
    function acceptsSubsidy() public view returns (bool) {
        return state == MonthState.Preparing || state == MonthState.Mining || state == MonthState.Drawing;
    }

    function rewardEnded() external view returns (bool) {
        return state == MonthState.Settling || state == MonthState.Failed;
    }

    function depositSubsidy(uint256 amount) external nonReentrant {
        if (msg.sender != SPLITTER) revert OnlySplitter();
        if (!acceptsSubsidy()) revert WrongState();
        BEM.safeTransferFrom(msg.sender, address(this), amount);
        budget += amount;
        subsidyCapital += amount;
        emit SubsidyDeposited(amount);
    }

    function _addMachine(bytes32 key, address collection, uint256 circuitId, uint256 weight, uint256 cost) internal {
        budget -= cost;
        totalSpent += cost;
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
                sold: false,
                cost: uint128(cost)
            })
        );
    }

    // ============ 3. 挖矿与开奖 ============

    /// @notice 推进阶段：准备期结束或买满后开始 30 天挖矿（一台矿机都没有时直接结算、原样退还）。任何人可调。
    function sync() external nonReentrant {
        _sync();
    }

    function _sync() internal {
        if (state == MonthState.Preparing && (block.timestamp >= prepEnd || _boughtOut())) {
            if (block.timestamp < prepEnd) prepEnd = block.timestamp; // 买满提前结束准备期
            if (_machines.length == 0) {
                _beginSettlement();
            } else {
                state = MonthState.Mining;
                miningStart = prepEnd;
                miningEnd = prepEnd + MINING_DURATION;
                emit MiningStarted(miningStart, miningEnd, _machines.length, activeWeight);
            }
        }
    }

    /// @dev 买满（规则决定 6.37）：已经有矿机，并且 100 台上限已满，或者剩余预算按当前收购价上限连一台最小算力的矿机都买不下
    function _boughtOut() internal view returns (bool) {
        uint256 n = _machines.length;
        if (n == 0) return false;
        if (n >= MAX_MACHINES) return true;
        uint256 p = buyPrice();
        return p > 0 && budget < p * MIN_MACHINE_WEIGHT;
    }

    /// @notice 领取全部在挖矿机的产出：请求开奖前进入奖金池；请求开奖后（奖金池已定死）和结算阶段按投入比例分给参与者。
    ///         任何人可调。
    function harvest() external nonReentrant returns (uint256 got) {
        _sync();
        if (state < MonthState.Preparing) revert WrongState();
        if (claimsClosed) revert ClaimsAreClosed();
        got = _claimYield();
    }

    /// @notice 30 天到期后开奖：先领取产出，再请求随机数；奖金池从此定死。奖金池为 0 时直接进入结算。
    ///         运营地址专属；到期 3 天后本局参与者也可以调用。
    function drawPrizes() external nonReentrant {
        _sync();
        if (state != MonthState.Mining) revert WrongState();
        if (block.timestamp < miningEnd) revert NotYet();
        _auth(miningEnd);
        _claimYield();
        if (prizePool == 0) {
            _beginSettlement();
            return;
        }
        state = MonthState.Drawing;
        firstRequestAt = block.timestamp;
        _requestDraw();
    }

    /// @notice VRF 回调：只记下随机数（回调 gas 很少，不会因为超出 callbackGasLimit 失败）。
    ///         本局发出的任何一个请求都有效（重发不作废已在路上的结果，审计 M-3），先到先用；重复的回调直接忽略。
    function onRandomness(uint256 requestId, uint256 randomWord) external nonReentrant {
        if (msg.sender != RANDOM_SOURCE) revert OnlyRandomSource();
        if (state != MonthState.Drawing || !drawPending || !_ourRequest[requestId]) {
            emit StaleRandomness(requestId);
            return;
        }
        drawPending = false;
        wordReceived = true;
        wordReceivedAt = block.timestamp;
        drawWord = randomWord;
        emit RandomnessReceived(requestId, randomWord);
    }

    /// @notice 用已交付的随机数完成开奖：5 次独立抽取，奖金直接推送给中奖者，然后进入收回本金阶段。
    ///         运营地址专属；随机数到账 3 天后本局参与者也可以调用。
    function finalizePrizes() external nonReentrant {
        if (state != MonthState.Drawing || !wordReceived) revert NotYet();
        _auth(wordReceivedAt);
        _payPrizes(drawWord);
        _beginSettlement();
    }

    /// @notice VRF 超过 24 小时没响应，运营地址可以重新请求（再过 3 天参与者也可以）；旧请求仍然有效（审计 M-3）。
    function retryDraw() external nonReentrant {
        if (state != MonthState.Drawing || !drawPending) revert NoPendingDraw();
        if (block.timestamp < lastRequestAt + VRF_RETRY_DELAY) revert TooEarly();
        _auth(lastRequestAt + VRF_RETRY_DELAY);
        _requestDraw();
    }

    /// @notice VRF 从首次请求起停摆超过 7 天：不抽奖，奖金池按投入比例分给所有人（不收 3% / 2%），本金照常收回。
    function triggerSafeSettle() external nonReentrant {
        if (state != MonthState.Drawing || !drawPending) revert NoPendingDraw();
        if (block.timestamp < firstRequestAt + VRF_SAFE_EXIT_DELAY) revert TooEarly();
        _noDrawSettle();
    }

    /// @notice 升级哨兵冷静期内，参与者可以对还没到期的局发起提前结算（规则同 VRF 停摆）；已到期的局照常开奖。
    ///         冷静期过后不能再用（审计 M-1）。
    function emergencySettle() external nonReentrant {
        _sync();
        if (!sentinelPaused()) revert SentinelNotTripped();
        IBoardHub(HUB).noteSentinel(); // 顺带登记触发时间
        if (holderCount[msg.sender] == 0) revert NotParticipant();
        bool early = state == MonthState.Preparing || (state == MonthState.Mining && block.timestamp < miningEnd);
        if (!early) revert WrongState();
        _claimYield();
        _noDrawSettle();
    }

    function _requestDraw() internal {
        drawPending = true;
        lastRequestAt = block.timestamp;
        uint256 id = IRandomSource(RANDOM_SOURCE).requestRandomness();
        pendingRequestId = id;
        _ourRequest[id] = true;
        emit DrawRequested(id, msg.sender, prizePool);
    }

    /// @dev 奖金池不扣 3% / 2%（规则决定 6.15）。一半（向上取整）按原始投入比例记给所有持仓（和 VRF 停摆、开奖后到账的
    ///      产出同一套 accShare 记账，规则决定 6.20），另一半按 60 / 15 / 15 / 5 / 5 直接推送给 5 次独立抽出的中奖者
    ///      （取整余数并入头奖）。PrizesDrawn 的 prizePool 是整个奖金池，amounts 合计为抽奖的一半；
    ///      toFoundation / toFee 字段保留，恒为 0。
    function _payPrizes(uint256 word) internal {
        uint256 pot = prizePool;
        prizePool = 0;
        uint256 net = pot / 2;
        _shareIncome(pot - net);
        uint256[5] memory slots = PrizeDraw.winners(_tree, totalStake, word);
        uint256[5] memory amounts;
        uint256 paid;
        for (uint256 k = 1; k < PrizeDraw.PRIZES; k++) {
            amounts[k] = net * PrizeDraw.prizeBps(k) / BPS;
            paid += amounts[k];
        }
        amounts[0] = net - paid;
        for (uint256 k = 0; k < PrizeDraw.PRIZES; k++) {
            BEM.safeTransfer(_sockets[slots[k]].owner, amounts[k]);
        }
        winnerSlots = slots;
        prizeAmounts = amounts;
        prizesDrawn = true;
        emit PrizesDrawn(pot, slots, amounts, 0, 0);
    }

    function _noDrawSettle() internal {
        drawPending = false;
        uint256 pot = prizePool;
        prizePool = 0;
        emit NoDrawSettlement(pot);
        _shareIncome(pot);
        _beginSettlement();
    }

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
            if (state == MonthState.Settling) _sweep();
            // 请求开奖后奖金池定死（TapeCode 第二轮 A1，用户选 (b)）：Drawing 期间到账的产出留在合约里，
            // 进入结算时由 _beginSettlement 的 _sweep 按投入比例分给所有参与者（不收 3% / 2%）
            else if (state < MonthState.Drawing) prizePool += got;
        }
    }

    /// @dev 领取单台矿机的产出：请求开奖前进入奖金池；之后由调用方 / 结算时的 _sweep 按投入比例分配。
    function _claimOne(bytes32 key) internal {
        uint256 before = _bemBalance();
        try IPoD(POD).claim(key) {} catch {}
        uint256 got = _bemBalance() - before;
        if (got > 0) {
            emit Harvested(got);
            if (state < MonthState.Drawing) prizePool += got;
        }
    }

    // ============ 4. 收回本金 ============

    function _beginSettlement() internal {
        state = MonthState.Settling;
        settleStart = block.timestamp;
        principalRemaining = totalStake;
        subsidyRemaining = subsidyCapital;
        uint256 idle = budget;
        budget = 0;
        emit SettlementStarted(idle);
        // 买不满的 BEM 原样退还（同样按"本金 → 回馈 → 超额"的顺序）
        if (idle > 0) _returnCapital(idle);
        // 请求开奖之后到账的产出（以及其他未记账的 BEM）按投入比例分给所有参与者
        _sweep();
        _bumpEpoch();
        if (unsoldMachines == 0) finishedAt = block.timestamp;
    }

    /// @notice 交割（只认 MonthMachineSales）：从卖矿合约收 price 个 BEM，把第 index 台矿机转给 to，按"本金 → 回馈 →
    ///         溢价"记账。定价在卖矿合约；这里再查一次：没有执行多数清算计划时，成交价不得低于成本价。升级哨兵冷静期内暂停。
    function releaseMachine(uint256 index, address to, uint256 price) external nonReentrant {
        if (msg.sender != SALES) revert NotAuthorized();
        if (state != MonthState.Settling) revert WrongState();
        if (sentinelPaused()) revert UpgradeSentinelTripped();
        Machine storage m = _sellOff(index);
        if (price < m.cost && !liquidating) revert BelowCost();
        BEM.safeTransferFrom(msg.sender, address(this), price);
        // to = 0：寄售在挂单模块的矿机已经在市场上成交交给买家（MachineLister 结算），这里只记账
        if (to != address(0)) ICircuits(m.collection).transferFrom(address(this), to, m.circuitId);
        _returnCapital(_takePremiumFee(price, m.cost));
        _sweep();
        _bumpEpoch();
        emit MachineSold(index, m.circuitId, to, price);
    }

    /// @notice 交接（只认 MonthMachineSales）：在另一块正在准备矿机的月局（同一个 MonthFactory）的收购拍卖里当普通卖家，
    ///         按对方当前的收购价卖出；最低单价 = ⌈成本价 ÷ 算力⌉，所以成交额不低于成本价，否则整笔回滚。
    function relayOut(uint256 index, address newBoard) external nonReentrant returns (uint256 paid) {
        if (msg.sender != SALES) revert NotAuthorized();
        if (state != MonthState.Settling) revert WrongState();
        if (sentinelPaused()) revert UpgradeSentinelTripped();
        if (newBoard == address(this) || !IMonthFactory(FACTORY).isBoard(newBoard)) revert NotMonthBoard();
        Machine storage m = _sellOff(index);
        uint256 cost = m.cost;
        uint256 before = _bemBalance();
        ICircuits(m.collection).approve(newBoard, m.circuitId);
        paid = IMonthBoardV2(newBoard).sellMachine(m.collection, m.circuitId, (cost + m.weight - 1) / m.weight);
        if (paid < cost || _bemBalance() - before < paid) revert RelayUnpaid();
        _returnCapital(_takePremiumFee(paid, cost));
        _sweep();
        _bumpEpoch();
        emit MachineRelayedOut(index, m.circuitId, newBoard, paid);
    }

    /// @notice 寄售（只认 MonthMachineSales，规则决定 6.26）：把还没卖出的第 index 台矿机转给挂单模块的挂单库，由它按公式价
    ///         挂到 TapeOut 官方矿机市场 / Seaport。账上仍是本局的矿机（继续挖，产出由挂单库转回）；成交时经卖矿合约按
    ///         成交那一刻的要价结算（releaseMachine 的 to = 0），撤单时挂单库把矿机还回来。
    function consign(uint256 index, address to) external nonReentrant {
        if (msg.sender != SALES) revert NotAuthorized();
        if (state != MonthState.Settling) revert WrongState();
        Machine storage m = _machines[index];
        if (m.sold) revert AlreadySold();
        ICircuits(m.collection).transferFrom(address(this), to, m.circuitId);
    }

    /// @notice 清算治理锁（只认 MonthExitGovernor）：正式投票和执行等待期间锁定持仓转让。
    function setGovernanceLock(bool locked) external {
        if (msg.sender != GOVERNOR) revert NotAuthorized();
        governanceLocked = locked;
        _bumpEpoch();
        emit GovernanceLockSet(locked);
    }

    /// @notice 多数清算计划已执行（只认 MonthExitGovernor）：之后允许按计划价（可以低于成本价）卖出。
    function startLiquidation() external {
        if (msg.sender != GOVERNOR || state != MonthState.Settling) revert NotAuthorized();
        liquidating = true;
        _bumpEpoch();
        emit LiquidationStarted();
    }

    function _bumpEpoch() internal {
        emit TradeEpochBumped(++tradeEpoch);
    }

    // ============ 持仓转让（只在结算阶段）============

    /// @notice 持仓转移钩子（只认 MonthPositions：直接转账、授权转账、交易所成交都经过这里）。
    ///         1. 锁：只在结算阶段、领取期限内、没有清算投票 / 执行等待时可以转让；
    ///         2. 结转：先 sweep，再把卖方已经累计的份额记入 credit[卖方]（卖方之后 withdrawCredit），买方只拿之后的；
    ///         3. 通行证：还没退的立刻退给原持有人（失败不影响转让，记在 passOwner，之后 returnPass）；
    ///         4. 更新持有人、持有计数和持仓版本号（旧订单失效）。
    function onPositionTransfer(uint256 slot, address from, address to) external nonReentrant {
        if (msg.sender != POSITIONS) revert NotAuthorized();
        if (state != MonthState.Settling || claimsClosed || governanceLocked) revert TransferLocked();
        Socket storage s = _sockets[slot];
        _sweep();
        uint256 share = uint256(s.stake) * accShare / ACC_SCALE - s.claimed;
        if (share > 0) {
            // forge-lint: disable-next-line(unsafe-typecast)
            s.claimed += uint128(share);
            credit[from] += share;
        }
        if (!s.passReturned) {
            address back = passOwner[slot];
            if (back == address(0)) back = from;
            (bool ok,) = PASS_CIRCUITS.call(abi.encodeCall(ICircuits.transferFrom, (address(this), back, s.passId)));
            if (ok) {
                s.passReturned = true;
                emit PassReturned(back, s.passId);
            } else {
                passOwner[slot] = back;
            }
        }
        s.owner = to;
        holderCount[from] -= 1;
        holderCount[to] += 1;
        s.version += 1;
        emit PositionTransferred(slot, from, to, share);
    }

    /// @notice 把合约里尚未分配的 BEM（卖不出的矿机继续挖的产出、捐赠等）按投入比例记给参与者。任何人可调。
    function sweep() external nonReentrant {
        if (state != MonthState.Settling) revert WrongState();
        if (claimsClosed) revert ClaimsAreClosed();
        _sweep();
    }

    /// @dev 标记卖出，并先把这台矿机尚未领取的产出领回本局（结算阶段的产出归参与者）。
    function _sellOff(uint256 index) internal returns (Machine storage m) {
        if (claimsClosed) revert ClaimsAreClosed();
        m = _machines[index];
        if (m.sold) revert AlreadySold();
        m.sold = true;
        unsoldMachines -= 1;
        if (unsoldMachines == 0) finishedAt = block.timestamp;
        if (m.active) {
            m.active = false;
            activeWeight -= m.weight;
        }
        _claimOne(m.key);
    }

    /// @dev 卖矿溢价分成（规则决定 6.24）：成交额超过成本价的部分 × PREMIUM_FEE_BPS 直接转给手续费地址，返回其余金额。
    ///      ≤ 成本价（含多数清算计划的低价卖出）不收。
    function _takePremiumFee(uint256 amount, uint256 cost) internal returns (uint256) {
        if (amount <= cost) return amount;
        uint256 fee = (amount - cost) * PREMIUM_FEE_BPS / BPS;
        if (fee > 0) BEM.safeTransfer(FEE_RECIPIENT, fee);
        return amount - fee;
    }

    /// @dev 收回的资本按顺序：先退参与者本金（按投入比例）→ 再收回回馈资本（转入月局工厂，滚给下一块开局的月局）
    ///      → 超出成本的部分按投入比例分给参与者。
    function _returnCapital(uint256 amount) internal {
        uint256 principal = amount < principalRemaining ? amount : principalRemaining;
        principalRemaining -= principal;
        uint256 rest = amount - principal;
        uint256 toRollover = rest < subsidyRemaining ? rest : subsidyRemaining;
        subsidyRemaining -= toRollover;
        _shareIncome(amount - toRollover);
        if (toRollover > 0) {
            rolledOver += toRollover;
            BEM.safeTransfer(FACTORY, toRollover);
        }
        emit CapitalReturned(principal, toRollover, rest - toRollover);
    }

    function _shareIncome(uint256 amount) internal {
        if (amount == 0) return;
        liabilities += amount;
        accShare += amount * ACC_SCALE / totalStake;
    }

    function _sweep() internal {
        uint256 bal = _bemBalance();
        if (bal > liabilities) _shareIncome(bal - liabilities);
    }

    // ============ 领取（按持仓）============

    /// @notice 第 slot 份持仓当前可以领取的 BEM（结算阶段不含尚未 sweep 的新到账；withdraw 会先 sweep，所以只会少报）。
    ///         转让时结转给卖方的款项不在这里，见 credit(address)。
    function owed(uint256 slot) public view returns (uint256 amount) {
        if (claimsClosed || slot == 0 || slot > socketCount) return 0;
        Socket storage s = _sockets[slot];
        if (state == MonthState.Failed) {
            if (!s.refunded) amount = uint256(s.stake) + uint256(s.stake) * ENTRY_FEE_BPS / BPS;
            return amount;
        }
        amount = uint256(s.stake) * accShare / ACC_SCALE - s.claimed;
    }

    /// @notice 把第 slot 份持仓可领的 BEM 付给它当前的持有人。任何人可调。
    function withdraw(uint256 slot) external nonReentrant returns (uint256 amount) {
        amount = _withdraw(slot, true);
        if (amount == 0) revert NothingToWithdraw();
    }

    /// @notice 把转让时结转给 account 的款项付给它。任何人可调。
    function withdrawCredit(address account) external nonReentrant returns (uint256 amount) {
        if (claimsClosed) revert ClaimsAreClosed();
        amount = credit[account];
        if (amount == 0) revert NothingToWithdraw();
        credit[account] = 0;
        liabilities -= amount;
        BEM.safeTransfer(account, amount);
        emit Withdrawn(account, amount);
    }

    function returnPass(uint256 slot) external nonReentrant {
        if (!_returnPass(slot)) revert PassAlreadyReturned();
    }

    /// @notice 领取第 slot 份持仓可领的 BEM，并在可以时退还通行证。任何人可调。
    function claimAll(uint256 slot) external nonReentrant returns (uint256 amount) {
        if (!claimsClosed) amount = _withdraw(slot, true);
        if (state == MonthState.Failed || state == MonthState.Settling) {
            if (!_sockets[slot].passReturned) _returnPass(slot);
        }
    }

    /// @notice 领取期限已过：剩下的 BEM（过期未领与取整尘埃）转到黑洞地址 0x…dEaD 销毁（规则决定 6.13）。通行证不过期。
    function closeClaims() external nonReentrant {
        if (finishedAt == 0 || block.timestamp < finishedAt + CLAIM_WINDOW) revert TooEarly();
        claimsClosed = true;
        liabilities = 0;
        uint256 bal = _bemBalance();
        if (bal > 0) BEM.safeTransfer(0x000000000000000000000000000000000000dEaD, bal);
        emit ClaimsClosed(bal);
    }

    /// @dev 运营地址专属；运营地址在 since 之后 operatorGrace 内没执行，本局持仓的持有人可以执行；
    ///      运营地址为 0 时持有人随时可以执行。其他地址始终不行。
    function _auth(uint256 since) internal view {
        address op = IBoardHub(HUB).operator();
        if (op != address(0) && msg.sender == op) return;
        if (holderCount[msg.sender] == 0) revert NotAuthorized();
        if (op != address(0) && block.timestamp < since + OPERATOR_GRACE) revert NotAuthorized();
    }

    function _withdraw(uint256 slot, bool doSweep) internal returns (uint256 amount) {
        if (claimsClosed) revert ClaimsAreClosed();
        if (slot == 0 || slot > socketCount) revert NotParticipant();
        Socket storage s = _sockets[slot];
        if (state == MonthState.Failed) {
            if (s.refunded) return 0;
            s.refunded = true;
            amount = uint256(s.stake) + uint256(s.stake) * ENTRY_FEE_BPS / BPS;
        } else {
            if (doSweep && state == MonthState.Settling) _sweep();
            amount = uint256(s.stake) * accShare / ACC_SCALE - s.claimed;
            // forge-lint: disable-next-line(unsafe-typecast)
            s.claimed += uint128(amount);
        }
        if (amount == 0) return 0;
        liabilities -= amount;
        BEM.safeTransfer(s.owner, amount);
        emit Withdrawn(s.owner, amount);
    }

    function _returnPass(uint256 slot) internal returns (bool) {
        if (state != MonthState.Failed && state != MonthState.Settling) revert WrongState();
        if (slot == 0 || slot > socketCount) revert NotParticipant();
        Socket storage s = _sockets[slot];
        if (s.passReturned) return false;
        s.passReturned = true;
        address back = _passRecipient(slot);
        ICircuits(PASS_CIRCUITS).transferFrom(address(this), back, s.passId);
        emit PassReturned(back, s.passId);
        return true;
    }

    /// @dev 通行证退给谁：转让时退失败的，记在 passOwner（原持有人）；否则是当前持有人（从没转让过 = 加入者）。
    function _passRecipient(uint256 slot) internal view returns (address back) {
        back = passOwner[slot];
        if (back == address(0)) back = _sockets[slot].owner;
    }

    // ============ 升级哨兵 ============

    /// @notice 升级哨兵的冷静期（外部审计 #2）：哨兵已触发，且注册中心的登记（`sentinelSince`，两种局共用）不满
    ///         sentinelResumeDelay（30 天）时为真。冷静期内暂停加入和矿机收购 / 出售，工厂也不开新主板；
    ///         参与者仍可提前退出 / 提前结算，开奖照常。没人登记时一直处于冷静期。
    function sentinelPaused() public view returns (bool) {
        if (!sentinelTripped()) return false;
        uint256 since = IBoardHub(HUB).sentinelSince();
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

    function socket(uint256 slot) external view returns (Socket memory) {
        return _sockets[slot];
    }

    function machine(uint256 index) external view returns (Machine memory) {
        return _machines[index];
    }

    function machineCount() external view returns (uint256) {
        return _machines.length;
    }

    /// @dev 本合约的 BEM 余额（多处使用，收成一个函数节省字节）
    function _bemBalance() internal view returns (uint256) {
        return BEM.balanceOf(address(this));
    }
}

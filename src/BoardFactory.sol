// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {ITransistors, IBeacon} from "./interfaces/ITapeOut.sol";
import {IBoardFactory, ITapeBoard} from "./interfaces/ITapeBoard.sol";
import {IMonthFactory} from "./interfaces/IMonthBoard.sol";
import {IBoardRegistry} from "./interfaces/IRandomSource.sol";
import {IMarketPriceFeed} from "./interfaces/IMarketPriceFeed.sol";
import {GenesisSplitter} from "./GenesisSplitter.sol";
import {TapeBoard} from "./TapeBoard.sol";
import {TemplateTimelock} from "./TemplateTimelock.sol";

/// @title BoardFactory（主板工厂）
/// @notice 本合约不可升级。手续费 Safe（admin）有两项特权：① setOperator 更换运营地址（运营地址只能开奖、自动发放、
///         月局交接 / 挂单 / 报价）；② 经 7 天时间锁更换标准局模板（TemplateTimelock，只影响之后新开的局；
///         已开局的主板没有任何升级入口）。部署顺序：
///         1. 先单独部署 GenesisSplitter（构造参数里是预先算好的本合约地址；它在构造里调用 TapeOut 工厂 createCPU，
///            成为创世处理器的 creator）。分账合约不放在本合约的构造函数里，是因为那样初始化代码加构造参数
///            会超过 EIP-3860 的 49,152 字节上限（2026-10-19 测试网部署时发现）；
///         2. 部署本合约：核对 splitter.boardFactory() == 本合约，再用创世处理器的电路合约地址部署 TapeBoard
///            实现合约（各局共用的参数全部写死在实现里）。
///         之后：
///         - startGenesis()：任何人可调，创世晶体管已铸 ≥ 门槛（10,000 颗）或距开始铸造满 7 天时，
///           先分账一次，再开出第 1 块主板（目标 500 BEM）；
///         - 同一时间只有一块主板在招募。上一块开局时自动开出下一块；招募失败时自动重开同一编号；
///         - 主板编号从 1 开始，只有真正开局的主板才占用编号（GenesisSplitter 按编号认前 5 块领回馈）；
///         - 主板金额按上一块的招募速度自动调整（白皮书 5.2），范围 [minTarget, maxTarget]，向下取整到 1 BEM：
///             fastFillWindow（2 天）内招满 → × growBps（1.25）
///             之后、7 天内招满            → 不变
///             7 天到期、达到 60% 按实际开局 → × partialBps（0.75）
///             7 天到期、不到 60% 退款重开  → × failBps（0.5）
///         - 每块主板的单人投入范围 = 本块目标 × [minStakeBps, maxStakeBps]（0.2%–4%），开出时固定。
///         每块主板是一个 EIP-1167 最小代理，固定指向开局时的实现合约，不能升级。
///
///         本合约同时是两种局的**注册中心**（IBoardHub）：
///         - 月局由独立的 MonthFactory 管理（月局实现合约放不进本合约的 49 KB 初始化代码上限）。
///           MonthFactory 的地址在部署前预测好，作为构造参数传入；MonthFactory 构造时会反过来校验。
///         - startGenesis 同时开出第 1 块标准局和第 1 块月局；
///         - 两种局合计、按真正开局的先后排出开局顺序（rank），GenesisSplitter 按 rank 给前 5 块发回馈；
///         - isBoard 同时认两种局（VRF 适配器用它防止别人消耗订阅）。
contract BoardFactory is IBoardFactory, IBoardRegistry, TemplateTimelock {
    uint256 public constant BPS = 10_000;

    struct TargetRules {
        uint256 initialTarget; // 第 1 块的目标金额（500 BEM）
        uint256 minTarget; // 100 BEM
        uint256 maxTarget; // 1,000 BEM
        uint256 rounding; // 取整单位（1 BEM = 1e8）
        uint256 minStakeBps; // 单人最少投入 = 目标 × 0.2%
        uint256 maxStakeBps; // 单人最多投入 = 目标 × 4%
        uint256 fastFillWindow; // 2 天
        uint256 growBps; // 12500
        uint256 partialBps; // 7500
        uint256 failBps; // 5000
    }

    struct Params {
        address splitter; // 预先部署的 GenesisSplitter（它的 boardFactory 必须是本合约）
        TapeBoard.Config board; // passCircuits / splitter 由本合约填入
        TargetRules targets;
        uint256 genesisMintThreshold; // 10,000 颗
        uint256 genesisDelay; // 7 天
        address monthFactory; // 预测的 MonthFactory 地址；0 = 不开月局
        address initialOperator; // 初始运营地址（测试网用部署者地址；可以为 0）
    }

    GenesisSplitter public immutable splitter;
    ITransistors public immutable transistors;
    address public immutable passCircuits;
    /// @notice 手续费 Safe：更换运营地址、提议新模板
    address internal immutable ADMIN;
    uint256 public immutable genesisMintThreshold;
    uint256 public immutable genesisDelay;
    /// @notice 月局工厂（0 = 不开月局）
    address public immutable monthFactory;

    uint256 public immutable initialTarget;
    uint256 public immutable minTarget;
    uint256 public immutable maxTarget;
    uint256 public immutable targetRounding;
    uint256 public immutable minStakeBps;
    uint256 public immutable maxStakeBps;
    uint256 public immutable fastFillWindow;
    uint256 public immutable growBps;
    uint256 public immutable partialBps;
    uint256 public immutable failBps;

    /// @dev 主板共用参数的副本（主板合约里的数值参数是 internal immutable，在这里统一公开）
    TapeBoard.Config internal _boardConfig;

    bool public genesisStarted;
    /// @notice 下一块（或当前招募中这一块）主板的目标金额
    uint256 public nextTarget;
    /// @notice 当前招募中的主板编号与地址
    uint256 public currentNumber;
    address public recruitingBoard;
    /// @notice 编号 → 该编号最新的一块主板（招募失败重开后指向新的那块）
    mapping(uint256 => address) public boardByNumber;
    /// @notice 主板地址 → 编号（0 表示不是本工厂创建的）
    mapping(address => uint256) public numberOf;
    address[] public allBoards;
    /// @notice 每个编号开过几次（招募失败会重开）
    mapping(uint256 => uint256) public attemptsOf;
    /// @notice 两种局合计已开局的主板数；rank → 主板；主板 → rank
    uint256 public startCount;
    mapping(uint256 => address) public rewardBoard;
    mapping(address => uint256) public rankOf;
    /// @notice 运营地址（两种局共用，只存这一处）。只有手续费 Safe 可以更换，可以设成 0。
    address public operator;
    /// @dev 升级哨兵的登记（见 noteSentinel / sentinelSince）：登记时间，以及登记时各信标 implementation 的指纹
    uint256 internal _sentinelSince;
    bytes32 internal _sentinelFingerprint;

    event GenesisStarted(uint256 minted, uint256 elapsed);
    event BoardOpened(
        uint256 indexed number,
        address indexed board,
        uint256 attempt,
        uint256 target,
        uint256 minStake,
        uint256 maxStake
    );
    event TargetAdjusted(uint256 oldTarget, uint256 newTarget);
    event BoardStarted(uint256 indexed rank, address indexed board, bool monthBoard);
    event OperatorChanged(address indexed previous, address indexed current);
    event SentinelNoted(uint256 since);

    error BadParams();
    error GenesisAlreadyStarted();
    error GenesisConditionNotMet();
    error OnlyRecruitingBoard();
    error SentinelTripped();
    error OnlyMonthFactory();
    error OnlyFeeSafe();
    error NothingToReopen();
    error FeedNotPosted();

    constructor(Params memory p) {
        TargetRules memory t = p.targets;
        if (
            t.rounding == 0 || t.minTarget == 0 || t.minTarget > t.initialTarget || t.initialTarget > t.maxTarget
                || t.minStakeBps == 0 || t.maxStakeBps < t.minStakeBps
        ) revert BadParams();
        // 按 60% 开局时至少要有 2 个人；最小投入至少 1 个最小单位
        if (t.maxStakeBps * 2 > p.board.minStartBps || t.minTarget * t.minStakeBps < BPS) revert BadParams();
        initialTarget = t.initialTarget;
        minTarget = t.minTarget;
        maxTarget = t.maxTarget;
        targetRounding = t.rounding;
        minStakeBps = t.minStakeBps;
        maxStakeBps = t.maxStakeBps;
        fastFillWindow = t.fastFillWindow;
        growBps = t.growBps;
        partialBps = t.partialBps;
        failBps = t.failBps;
        nextTarget = t.initialTarget;
        genesisMintThreshold = p.genesisMintThreshold;
        genesisDelay = p.genesisDelay;
        monthFactory = p.monthFactory;

        GenesisSplitter s = GenesisSplitter(payable(p.splitter));
        if (p.splitter == address(0) || s.boardFactory() != address(this)) revert BadParams();
        splitter = s;
        transistors = s.transistors();
        passCircuits = s.circuits();

        TapeBoard.Config memory c = p.board;
        c.passCircuits = passCircuits;
        c.splitter = address(s);
        _setInitialImplementation(address(new TapeBoard(c)));
        _boardConfig = c;
        ADMIN = c.feeRecipient;
        operator = p.initialOperator;
        emit OperatorChanged(address(0), p.initialOperator);
    }

    /// @notice 手续费 Safe（部署时模板的 feeRecipient）
    function admin() public view override returns (address) {
        return ADMIN;
    }

    /// @notice 部署时模板（implementationHistory(0)）的参数（含创世电路合约与分账合约地址）。之后经时间锁换上的模板，
    ///         参数见它的构造参数（proposeImplementation 交易里的创建代码）。
    function boardConfig() external view returns (TapeBoard.Config memory) {
        return _boardConfig;
    }

    /// @notice 开局：已铸晶体管 ≥ 门槛，或距开始铸造满 genesisDelay。先分账一次，再开出第 1 块主板。
    ///         矿机报价合约必须已经报过价（全局审计 G-1）：否则第一块标准局和月局会按默认曲线收购，市价低时按几倍市价买矿机。
    function startGenesis() external returns (address board) {
        if (genesisStarted) revert GenesisAlreadyStarted();
        uint256 minted = transistors.minted();
        uint256 elapsed = block.timestamp - splitter.mintStart();
        if (minted < genesisMintThreshold && elapsed < genesisDelay) revert GenesisConditionNotMet();
        if (TapeBoard(_boardImplementation).sentinelPaused()) revert SentinelTripped();
        if (IMarketPriceFeed(_boardConfig.priceFeed).updatedAt() == 0) revert FeedNotPosted();
        genesisStarted = true;
        emit GenesisStarted(minted, elapsed);
        splitter.distribute();
        board = _open(1);
        if (monthFactory != address(0)) IMonthFactory(monthFactory).openFirst();
    }

    /// @notice 由招募中的主板在开局时调用：调整金额，开出下一块主板。
    function onBoardStarted(bool full, uint256 elapsed) external {
        if (msg.sender != recruitingBoard) revert OnlyRecruitingBoard();
        _registerStart(msg.sender, false);
        if (!full) _adjust(partialBps);
        else if (elapsed < fastFillWindow) _adjust(growBps);
        _open(currentNumber + 1);
    }

    /// @notice 由招募中的主板在招募失败时调用：金额 × failBps，重开同一编号（升级哨兵冷静期内不重开，见 reopen）。
    function onBoardFailed() external {
        if (msg.sender != recruitingBoard) revert OnlyRecruitingBoard();
        recruitingBoard = address(0);
        _adjust(failBps);
        if (!TapeBoard(_boardImplementation).sentinelPaused()) _open(currentNumber);
    }

    /// @notice 冷静期内招募失败、没有重开的标准局，在冷静期结束（登记满 30 天或信标恢复）后由任何人调用重开。
    function reopen() external returns (address board) {
        if (!genesisStarted || recruitingBoard != address(0)) revert NothingToReopen();
        if (TapeBoard(_boardImplementation).sentinelPaused()) revert SentinelTripped();
        board = _open(currentNumber);
    }

    /// @notice 登记升级哨兵第一次被观察到触发的时间（外部审计 #2）。任何人可调，参与者提前退出 / 提前结算时也会
    ///         顺带调用；两种局共用这一个记录，任一种局的电路信标被升级都算触发。信标恢复后再调用会清零。
    ///         链上读不到信标升级的时刻，所以 30 天冷静期从第一次登记算起；冷静期内两种局暂停加入、矿机收购 / 出售
    ///         和开新主板，参与者仍可提前退出 / 提前结算，开奖照常。
    ///         登记时同时记下各信标当时的 implementation（指纹）；之后信标又换了 implementation（例如恢复后再次升级），
    ///         旧登记自动作废（sentinelSince 返回 0，重新进入冷静期），再调用本函数会从这时重新计 30 天。
    function noteSentinel() external {
        address monthImpl = monthFactory == address(0) ? address(0) : IMonthFactory(monthFactory).boardImplementation();
        bool tripped = TapeBoard(_boardImplementation).sentinelTripped()
            || (monthImpl != address(0) && ITapeBoard(monthImpl).sentinelTripped());
        bytes32 fp = _fingerprint(monthImpl);
        uint256 since = _sentinelSince;
        if (!tripped) {
            since = 0;
            fp = bytes32(0);
        } else if (since == 0 || fp != _sentinelFingerprint) {
            since = block.timestamp;
        }
        if (since != _sentinelSince || fp != _sentinelFingerprint) {
            _sentinelSince = since;
            _sentinelFingerprint = fp;
            emit SentinelNoted(since);
        }
    }

    /// @notice 第一次登记到升级哨兵触发的时间（两种局共用；0 = 未登记、已恢复，或登记之后信标又换了 implementation）。
    ///         主板的 sentinelPaused() 用它计算 30 天冷静期。
    function sentinelSince() external view returns (uint256) {
        uint256 since = _sentinelSince;
        if (since == 0) return 0;
        address monthImpl = monthFactory == address(0) ? address(0) : IMonthFactory(monthFactory).boardImplementation();
        return _fingerprint(monthImpl) == _sentinelFingerprint ? since : 0;
    }

    /// @dev 两种局监控的全部信标当前的 implementation（读不出来记为 address(1)）
    function _fingerprint(address monthImpl) internal view returns (bytes32) {
        ITapeBoard s = ITapeBoard(_boardImplementation);
        bytes memory impls = abi.encode(_beaconImpl(s.MACHINE_BEACON()), _beaconImpl(s.PASS_BEACON()));
        if (monthImpl != address(0)) {
            ITapeBoard m = ITapeBoard(monthImpl);
            impls = abi.encode(impls, _beaconImpl(m.MACHINE_BEACON()), _beaconImpl(m.PASS_BEACON()));
        }
        return keccak256(impls);
    }

    function _beaconImpl(address beacon) internal view returns (address) {
        if (beacon == address(0)) return address(0);
        (bool ok, bytes memory ret) = beacon.staticcall(abi.encodeWithSelector(IBeacon.implementation.selector));
        if (!ok || ret.length < 32) return address(1);
        return abi.decode(ret, (address));
    }

    /// @notice 任命或更换运营地址。只有手续费 Safe（admin）可以调用；可以设成 0。
    function setOperator(address newOperator) external {
        if (msg.sender != ADMIN) revert OnlyFeeSafe();
        emit OperatorChanged(operator, newOperator);
        operator = newOperator;
    }

    /// @notice 由月局工厂在月局开局时调用，登记两种局合计的开局顺序。
    function registerStart(address board) external returns (uint256 rank) {
        if (msg.sender != monthFactory) revert OnlyMonthFactory();
        return _registerStart(board, true);
    }

    /// @notice 是否为本协议创建的主板（标准局或月局）
    function isBoard(address account) external view override(IBoardFactory, IBoardRegistry) returns (bool) {
        if (numberOf[account] != 0) return true;
        return monthFactory != address(0) && IMonthFactory(monthFactory).isBoard(account);
    }

    function _registerStart(address board, bool monthBoard) internal returns (uint256 rank) {
        rank = ++startCount;
        rewardBoard[rank] = board;
        rankOf[board] = rank;
        emit BoardStarted(rank, board, monthBoard);
    }

    function boardCount() external view returns (uint256) {
        return allBoards.length;
    }

    /// @notice 给定目标金额时的单人投入范围。
    function stakeRange(uint256 target) public view returns (uint256 minStake, uint256 maxStake) {
        minStake = target * minStakeBps / BPS;
        maxStake = target * maxStakeBps / BPS;
    }

    function _adjust(uint256 factorBps) internal {
        uint256 old = nextTarget;
        uint256 t = old * factorBps / BPS;
        t -= t % targetRounding;
        if (t < minTarget) t = minTarget;
        if (t > maxTarget) t = maxTarget;
        nextTarget = t;
        if (t != old) emit TargetAdjusted(old, t);
    }

    function _open(uint256 number) internal returns (address board) {
        uint256 target = nextTarget;
        (uint256 minStake, uint256 maxStake) = stakeRange(target);
        board = Clones.clone(_boardImplementation);
        _recordImplementation(board);
        numberOf[board] = number;
        boardByNumber[number] = board;
        currentNumber = number;
        recruitingBoard = board;
        allBoards.push(board);
        uint256 attempt = ++attemptsOf[number];
        TapeBoard(board).initialize(number, target, minStake, maxStake);
        emit BoardOpened(number, board, attempt, target, minStake, maxStake);
    }

    /// @dev 新的标准局模板必须由本工厂部署（FACTORY = 本合约）、用同一个分账合约和创世电路合约，并实现升级哨兵查询
    function _checkTemplate(address impl) internal view override {
        TapeBoard t = TapeBoard(impl);
        if (t.FACTORY() != address(this) || t.SPLITTER() != address(splitter) || t.PASS_CIRCUITS() != passCircuits) {
            revert BadTemplate();
        }
        t.sentinelTripped();
    }
}

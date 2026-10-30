// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IBoardHub} from "./interfaces/ITapeBoard.sol";
import {IMonthFactory} from "./interfaces/IMonthBoard.sol";
import {BoardFactory} from "./BoardFactory.sol";
import {MonthBoard} from "./MonthBoard.sol";
import {TemplateTimelock} from "./TemplateTimelock.sol";

/// @title MonthFactory（月局工厂）
/// @notice 本合约不可升级。唯一的特权：手续费 Safe（BoardFactory.admin()）经 7 天时间锁更换月局模板
///         （TemplateTimelock，只影响之后新开的月局；已开局的月局没有任何升级入口）。运营地址存在 BoardFactory。和 BoardFactory 分开部署（月局实现合约放不进 BoardFactory 的初始化代码上限）：
///         - 部署前先预测本合约地址，作为 BoardFactory 的构造参数；本合约构造时校验 hub.monthFactory() == 本合约；
///         - 构造时部署 MonthBoard 实现合约（创世电路合约、分账合约地址从 BoardFactory 读取）；
///         - BoardFactory.startGenesis 调用 openFirst 开出第 1 块月局（100 BEM，3 天招募）；
///         - 同一时间只有一块月局在招募；上一块开局时开出下一块；招募失败时重开同一编号；
///         - 金额按招募速度自动调整：1 天内招满 × 1.25；1–3 天内不变；到期 ≥ 60% 按实际开局 × 0.75；
///           到期 < 60% 退款重开 × 0.5；范围 100–1,000 BEM，向下取整到 1 BEM；投入范围 = 目标 × 0.2%–4%；
///         - 月局开局时向 BoardFactory 登记开局顺序（两种局合计，用于首批回馈）；
///         - 局终收回的回馈资本转到本合约，下一块月局开局时全部转给它，作为它的回馈资本。
contract MonthFactory is IMonthFactory, TemplateTimelock {
    using SafeERC20 for IERC20;

    uint256 public constant BPS = 10_000;

    struct Params {
        MonthBoard.Config board; // passCircuits / splitter 由本合约从 BoardFactory 读取
        BoardFactory.TargetRules targets;
    }

    address public immutable hub;
    IERC20 public immutable bem;
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

    MonthBoard.Config internal _boardConfig;

    uint256 public nextTarget;
    uint256 public currentNumber;
    address public recruitingBoard;
    mapping(uint256 => address) public boardByNumber;
    mapping(address => uint256) public numberOf;
    mapping(uint256 => uint256) public attemptsOf;
    address[] public allBoards;
    uint256 public totalRolloverPaid;

    event BoardOpened(
        uint256 indexed number,
        address indexed board,
        uint256 attempt,
        uint256 target,
        uint256 minStake,
        uint256 maxStake
    );
    event TargetAdjusted(uint256 oldTarget, uint256 newTarget);
    event RolloverPaid(address indexed board, uint256 amount);

    error NothingToReopen();
    error SentinelPaused();
    error BadParams();
    error BadHub();
    error OnlyHub();
    error AlreadyOpened();
    error OnlyRecruitingBoard();

    constructor(address hub_, Params memory p) {
        if (hub_ == address(0) || IBoardHub(hub_).monthFactory() != address(this)) revert BadHub();
        BoardFactory.TargetRules memory t = p.targets;
        if (
            t.rounding == 0 || t.minTarget == 0 || t.minTarget > t.initialTarget || t.initialTarget > t.maxTarget
                || t.minStakeBps == 0 || t.maxStakeBps < t.minStakeBps || t.maxStakeBps * 2 > p.board.minStartBps
                || t.minTarget * t.minStakeBps < BPS
        ) revert BadParams();
        hub = hub_;
        bem = IERC20(p.board.bem);
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

        MonthBoard.Config memory c = p.board;
        c.passCircuits = IBoardHub(hub_).passCircuits();
        c.splitter = IBoardHub(hub_).splitter();
        c.hub = hub_;
        _setInitialImplementation(address(new MonthBoard(c)));
        _boardConfig = c;
    }

    /// @notice 由 BoardFactory.startGenesis 调用：开出第 1 块月局。
    function openFirst() external returns (address board) {
        if (msg.sender != hub) revert OnlyHub();
        if (currentNumber != 0) revert AlreadyOpened();
        board = _open(1);
    }

    /// @notice 由招募中的月局在开局时调用：登记开局顺序、调整金额、开出下一块，并把滚存的回馈资金转给它。
    function onBoardStarted(bool full, uint256 elapsed) external returns (uint256 rollover) {
        address board = msg.sender;
        if (board != recruitingBoard) revert OnlyRecruitingBoard();
        IBoardHub(hub).registerStart(board);
        if (!full) _adjust(partialBps);
        else if (elapsed < fastFillWindow) _adjust(growBps);
        _open(currentNumber + 1);
        rollover = bem.balanceOf(address(this));
        if (rollover > 0) {
            totalRolloverPaid += rollover;
            bem.safeTransfer(board, rollover);
            emit RolloverPaid(board, rollover);
        }
    }

    /// @notice 由招募中的月局在招募失败时调用：金额 × failBps，重开同一编号（升级哨兵冷静期内不重开，见 reopen）。
    function onBoardFailed() external {
        if (msg.sender != recruitingBoard) revert OnlyRecruitingBoard();
        recruitingBoard = address(0);
        _adjust(failBps);
        if (!MonthBoard(_boardImplementation).sentinelPaused()) _open(currentNumber);
    }

    /// @notice 冷静期内招募失败、没有重开的月局，在冷静期结束（登记满 30 天或信标恢复）后由任何人调用重开。
    function reopen() external returns (address board) {
        if (currentNumber == 0 || recruitingBoard != address(0)) revert NothingToReopen();
        if (MonthBoard(_boardImplementation).sentinelPaused()) revert SentinelPaused();
        board = _open(currentNumber);
    }

    function isBoard(address account) external view returns (bool) {
        return numberOf[account] != 0;
    }

    function boardCount() external view returns (uint256) {
        return allBoards.length;
    }

    function boardImplementation() public view override(IMonthFactory, TemplateTimelock) returns (address) {
        return _boardImplementation;
    }

    /// @notice 手续费 Safe（和 BoardFactory 同一个）
    function admin() public view override returns (address) {
        return BoardFactory(hub).admin();
    }

    /// @notice 部署时模板（implementationHistory(0)）的参数。之后经时间锁换上的模板，参数见它的构造参数
    ///         （proposeImplementation 交易里的创建代码）。
    function boardConfig() external view returns (MonthBoard.Config memory) {
        return _boardConfig;
    }

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
        MonthBoard(board).initialize(number, target, minStake, maxStake);
        emit BoardOpened(number, board, attempt, target, minStake, maxStake);
    }

    /// @dev 新的月局模板必须由本工厂部署（FACTORY = 本合约）、用同一个注册中心、分账合约和创世电路合约，
    ///      并实现升级哨兵查询。持仓凭证、卖矿、清算、报价单例可以是新版本（旧局继续用旧版本，V2-DESIGN.md 12.3）
    function _checkTemplate(address impl) internal view override {
        MonthBoard t = MonthBoard(impl);
        if (
            t.FACTORY() != address(this) || t.HUB() != hub || t.SPLITTER() != _boardConfig.splitter
                || t.PASS_CIRCUITS() != _boardConfig.passCircuits
        ) revert BadTemplate();
        t.sentinelTripped();
    }
}

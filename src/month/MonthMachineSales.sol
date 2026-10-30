// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IBoardHub} from "../interfaces/ITapeBoard.sol";
import {MonthState, IMonthFactory} from "../interfaces/IMonthBoard.sol";
import {IMonthBoardV2} from "../interfaces/IMonthV2.sol";
import {IMarketPriceFeed} from "../interfaces/IMarketPriceFeed.sol";
import {ICircuits} from "../interfaces/ITapeOut.sol";
import {IMachineLister} from "../interfaces/IMachineLister.sol";

/// @title MonthMachineSales（v2 月局结算阶段的卖矿定价，所有月局共用一个）
/// @notice 只管定价和收款，矿机和账本在各块月局主板里：
///         - 要价（规则决定 6.17 / 6.18）：整台 = max(收购时权重 × 卖价公式, 成本价)，卖价公式由这块月局的报价单例给出
///           （MarketPriceFeed.sellQuote：max(买一, 卖一 × (99% − 0.5% × 结算开始后整小时数))）；不再由运营地址挂单；
///         - 报价过期（≥ 3 小时）：暂停卖出；停运（从没报过价，或 7 天没有有效报价；运营地址设为 0 后同样满 7 天才算）：任何人按成本价可买；
///         - 购买：任何人按当前要价付 BEM，主板 releaseMachine 交割（主板再检查一次不低于成本价）；
///         - 交接：运营地址（结算开始 3 天后本局持仓的持有人兜底）让旧月局在新月局的收购拍卖里按不低于成本价卖出；
///         - 清算计划（多数集体清算执行后）：要价按计划曲线（7 天从起价线性降到底价，之后保持），可以低于成本价；
///         - 分批推送：运营地址（3 天后持有人兜底）把一段插槽的可领款项推送给持有人并退还通行证
///           （底下调用的是主板任何人都能调的 withdraw / returnPass，这里只负责批量和权限）。
///         没有管理员，不可升级，不托管任何人的资金（收到的 BEM 在同一笔交易里交给主板）。
contract MonthMachineSales is ReentrancyGuard {
    using SafeERC20 for IERC20;

    IERC20 public immutable BEM;
    IMonthFactory public immutable FACTORY;
    IBoardHub public immutable HUB;
    address public immutable GOVERNOR;
    uint256 public immutable OPERATOR_GRACE;
    uint256 public immutable PLAN_DECAY; // 清算计划：从起价线性降到底价的时长（7 天）
    uint256 internal constant BPS = 10_000;
    /// @dev 规则决定 6.33："保持排序第一"的目标价最低按公式价的 95% 采用（审计 H-1）；清算计划价不低于买一 × 算力 × 95%（审计 H-2）
    uint256 internal constant MIN_BPS = 9_500;
    /// @notice 挂单模块（MachineLister，规则决定 6.26）：把矿机寄售到 TapeOut 官方矿机市场 / Seaport 按公式价挂单
    IMachineLister public immutable LISTER;

    struct PlanPrice {
        uint128 start;
        uint128 floor;
    }

    /// @notice 清算计划开始的时间（0 = 没有生效的计划）；每次执行新计划时重置
    mapping(address => uint256) public planStart;
    /// @notice 清算计划价格：board → 矿机序号 → 起价 / 底价（整台，BEM 最小单位）
    mapping(address => mapping(uint256 => PlanPrice)) public planPrice;

    event MachineBought(address indexed board, uint256 indexed index, address indexed buyer, uint256 price);
    event MachineRelayed(address indexed board, uint256 indexed index, address indexed newBoard, uint256 price);
    event PlanInstalled(address indexed board, uint256 machines, uint256 start);

    error BadConfig();
    error NotMonthBoard();
    error NotAuthorized();
    error WrongState();
    error AlreadySold();
    error BelowCost();
    error PriceAboveMaximum();
    error NotForSale();
    error PaymentMismatch();
    error UpgradeSentinelTripped();

    constructor(
        address bem,
        address monthFactory,
        address hub,
        address governor,
        uint256 operatorGrace,
        uint256 planDecay,
        address lister
    ) {
        if (
            bem == address(0) || monthFactory == address(0) || hub == address(0) || governor == address(0)
                || lister == address(0)
        ) {
            revert BadConfig();
        }
        if (operatorGrace > 3650 days) revert BadConfig();
        if (planDecay == 0 || planDecay > 3650 days) revert BadConfig();
        BEM = IERC20(bem);
        FACTORY = IMonthFactory(monthFactory);
        HUB = IBoardHub(hub);
        GOVERNOR = governor;
        OPERATOR_GRACE = operatorGrace;
        PLAN_DECAY = planDecay;
        LISTER = IMachineLister(lister);
    }

    modifier onlyBoard(address board) {
        if (!FACTORY.isBoard(board)) revert NotMonthBoard();
        _;
    }

    // ============ 要价 ============

    /// @notice 当前要价（整台）：
    ///         - 停运（从没报过价，或 7 天没有有效报价；运营地址设为 0 后同样满 7 天才算）→ 成本价；
    ///         - 报价有效 → max(收购时权重 × 卖价公式, 成本价)；
    ///         - 报价过期（3 小时–7 天）→ 0（暂停卖出）。
    ///         然后（规则决定 6.29）：运营地址报的"保持排序第一"目标价（最低按上面价格的 95% 算，规则决定 6.33）× 收购时权重
    ///         ≥ 成本价时，取它和上面的较小者。
    ///         多数清算计划生效后，再和计划价比较，取较低的那个（计划价可以低于成本价；正常卖价暂停时按计划价）。计划价不低于
    ///         当时买一 × 收购时权重 × 95%，报价无效时计划价暂停（规则决定 6.33，审计 H-2：多数票能止损，不能低于市价甩卖）。
    function askPrice(address board, uint256 index) public view returns (uint256 price) {
        IMonthBoardV2 b = IMonthBoardV2(board);
        if (b.state() != MonthState.Settling) return 0;
        IMonthBoardV2.MachineView memory m = b.machine(index);
        if (m.sold) return 0;
        IMarketPriceFeed feed = IMarketPriceFeed(b.PRICE_FEED());
        if (feed.abandoned()) {
            price = m.cost;
        } else {
            uint256 q = feed.sellQuote(b.settleStart());
            if (q > 0) {
                price = q * m.weight;
                if (price < m.cost) price = m.cost;
            }
        }
        // 规则决定 6.29（保持排序第一）：目标价不低于成本价时，按 min(原公式卖价, 目标价)；低于成本价不追
        if (price > 0) {
            uint256 target = feed.floorQuote() * m.weight;
            if (target > 0 && target < price) {
                uint256 lo = price * MIN_BPS / BPS;
                if (target < lo) target = lo;
                if (target >= m.cost) price = target;
            }
        }
        uint256 p = planAsk(board, index);
        if (p > 0 && feed.fresh()) {
            uint256 market = feed.bid() * m.weight * MIN_BPS / BPS;
            if (p < market) p = market;
            if (price == 0 || p < price) price = p;
        }
    }

    /// @notice 清算计划价：start − (start − floor) × min(t, PLAN_DECAY) ÷ PLAN_DECAY，到底价后保持；没有计划时为 0。
    function planAsk(address board, uint256 index) public view returns (uint256) {
        uint256 t0 = planStart[board];
        PlanPrice memory p = planPrice[board][index];
        if (t0 == 0 || p.floor == 0) return 0;
        uint256 elapsed = block.timestamp - t0;
        if (elapsed > PLAN_DECAY) elapsed = PLAN_DECAY;
        return uint256(p.start) - (uint256(p.start) - p.floor) * elapsed / PLAN_DECAY;
    }

    /// @notice 写入多数批准的清算计划（只认清算治理合约）：只包含仍未卖出的矿机，降价从现在开始。
    function installPlan(address board, uint256[] calldata indexes, uint128[] calldata start, uint128[] calldata floor)
        external
    {
        if (msg.sender != GOVERNOR) revert NotAuthorized();
        planStart[board] = block.timestamp;
        for (uint256 i = 0; i < indexes.length; i++) {
            planPrice[board][indexes[i]] = PlanPrice(start[i], floor[i]);
        }
        emit PlanInstalled(board, indexes.length, block.timestamp);
    }

    /// @notice 现在买走第 index 台矿机要付的总价（= askPrice；0 = 现在不能买）。挂单模块按它定挂单价（和标准局同名接口）。
    function quote(address board, uint256 index) external view returns (uint256) {
        return askPrice(board, index);
    }

    /// @notice 只认挂单模块：把一台现在可以卖的矿机转给它的挂单库寄售（账上仍是主板的矿机，规则决定 6.26）。
    function consign(address board, uint256 index, address vault) external nonReentrant onlyBoard(board) {
        if (msg.sender != address(LISTER)) revert NotAuthorized();
        if (IMonthBoardV2(board).sentinelPaused()) revert UpgradeSentinelTripped();
        if (askPrice(board, index) == 0) revert NotForSale();
        IMonthBoardV2(board).consign(index, vault);
    }

    /// @notice 任何人按当前要价买走一台矿机（需要事先授权本合约 BEM）。价格超过 maxPrice 时拒绝。
    ///         矿机正寄售在挂单模块时：普通买家（包括 MarketTrader）先由挂单模块撤单、把矿机还给主板，再照常成交
    ///         （公式价成交照常开着，规则决定 6.22 F-3）；挂单模块自己调用表示矿机已经在市场上成交交给了买家，
    ///         这里按成交这一刻的要价收款记账，不再转矿机。
    function buyMachine(address board, uint256 index, uint256 maxPrice)
        external
        nonReentrant
        onlyBoard(board)
        returns (uint256 price)
    {
        if (IMonthBoardV2(board).sentinelPaused()) revert UpgradeSentinelTripped(); // 主板交割时还会再查
        price = askPrice(board, index);
        if (price == 0) revert NotForSale();
        if (price > maxPrice) revert PriceAboveMaximum();
        address to = _reclaim(board, index);
        uint256 before = BEM.balanceOf(address(this));
        BEM.safeTransferFrom(msg.sender, address(this), price);
        if (BEM.balanceOf(address(this)) - before != price) revert PaymentMismatch();
        BEM.forceApprove(board, price);
        IMonthBoardV2(board).releaseMachine(index, to, price);
        emit MachineBought(board, index, msg.sender, price);
    }

    /// @dev 矿机不在主板（寄售中）时：挂单模块自己来结算 → 交货地址 0；其他人 → 先让挂单模块撤单还回主板
    function _reclaim(address board, uint256 index) internal returns (address to) {
        to = msg.sender;
        IMonthBoardV2.MachineView memory m = IMonthBoardV2(board).machine(index);
        if (!m.sold && ICircuits(m.collection).ownerOf(m.circuitId) != board) {
            if (msg.sender == address(LISTER)) to = address(0);
            else LISTER.recall(board, index);
        }
    }

    // ============ 分批推送 ============

    /// @notice 运营地址分批把月局插槽 [fromSlot, fromSlot + count) 的可领款项推送给各自的持有人，并退还通行证。
    ///         结算阶段从结算开始、招募失败从失败时起，运营地址 operatorGrace（3 天）内没执行，本局持有人也可以调用。
    ///         逐个插槽调用主板的 withdraw / returnPass（没有可领款项或通行证已退的跳过），与自领共用记账，不会重复支付。
    function distribute(address board, uint256 fromSlot, uint256 count) external nonReentrant onlyBoard(board) {
        IMonthBoardV2 b = IMonthBoardV2(board);
        MonthState st = b.state();
        uint256 since;
        if (st == MonthState.Settling) since = b.settleStart();
        else if (st == MonthState.Failed) since = b.finishedAt();
        else revert WrongState();
        if (b.claimsClosed()) revert WrongState();
        _auth(b, since);
        uint256 n = b.socketCount();
        if (fromSlot == 0) fromSlot = 1;
        if (fromSlot > n) return;
        uint256 end = count > n ? n + 1 : fromSlot + count; // 不会溢出：fromSlot ≤ n，count ≤ n
        if (end > n + 1) end = n + 1;
        for (uint256 slot = fromSlot; slot < end; slot++) {
            try b.withdraw(slot) {} catch {}
            try b.returnPass(slot) {} catch {}
        }
    }

    /// @dev 运营地址专属；运营地址在 since 之后 operatorGrace 内没执行，本局持仓的持有人可以执行；
    ///      运营地址为 0 时持有人随时可以执行。
    function _auth(IMonthBoardV2 b, uint256 since) internal view {
        address op = HUB.operator();
        if (op != address(0) && msg.sender == op) return;
        if (b.holderCount(msg.sender) == 0) revert NotAuthorized();
        if (op != address(0) && block.timestamp < since + OPERATOR_GRACE) revert NotAuthorized();
    }

    // ============ 交接 ============

    /// @notice 交接：旧月局在新月局（同一个 MonthFactory、正在准备矿机）的收购拍卖里按新局当前收购价卖出，
    ///         成交额必须不低于成本价，否则整笔回滚。运营地址专属；结算开始 operatorGrace（3 天）后旧局持仓的持有人也可以；
    ///         运营地址为 0 时持有人随时可以。
    function relay(address oldBoard, uint256 index, address newBoard)
        external
        nonReentrant
        onlyBoard(oldBoard)
        returns (uint256 paid)
    {
        _auth(IMonthBoardV2(oldBoard), IMonthBoardV2(oldBoard).settleStart());
        _reclaim(oldBoard, index); // 调用者不会是挂单模块：寄售中的先撤回
        paid = IMonthBoardV2(oldBoard).relayOut(index, newBoard);
        emit MachineRelayed(oldBoard, index, newBoard, paid);
    }
}

// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {BoardState, SettleMode, IBoardHub} from "./interfaces/ITapeBoard.sol";
import {IMarketPriceFeed} from "./interfaces/IMarketPriceFeed.sol";
import {PoDReader} from "./libraries/PoDReader.sol";
import {ICircuits} from "./interfaces/ITapeOut.sol";
import {IMachineLister} from "./interfaces/IMachineLister.sol";

/// @dev StdMachineSales 用到的标准局接口（TapeBoard 的公开函数）
interface IStdBoard {
    struct Machine {
        bytes32 key;
        uint256 circuitId;
        address collection;
        uint64 weight;
        bool active;
        bool sold;
    }

    /// @dev 与 TapeBoard.Socket 的字段顺序和类型完全相同（socket(slot) 的返回值）
    struct Position {
        address owner;
        uint96 stake;
        uint256 passId;
        uint128 potClaimed;
        bool ejected;
        bool refunded;
        bool passReturned;
        uint32 version;
    }

    function state() external view returns (BoardState);
    function settleMode() external view returns (SettleMode);
    function socket(uint256 slot) external view returns (Position memory);
    function socketCount() external view returns (uint256);
    function holderCount(address account) external view returns (uint256);
    function startedAt() external view returns (uint256);
    function finishedAt() external view returns (uint256);
    function claimsClosed() external view returns (bool);
    function kingSocket() external view returns (uint256);
    function kingPot() external view returns (uint256);
    function accProRata() external view returns (uint256);
    function accPriority() external view returns (uint256);
    function ENTRY_FEE_BPS() external view returns (uint256);
    function FEE_RECIPIENT() external view returns (address);
    function totalSpent() external view returns (uint256);
    function totalWeightBought() external view returns (uint256);
    function withdraw(uint256 slot) external returns (uint256);
    function withdrawCredit(address account) external returns (uint256);
    function returnPass(uint256 slot) external;
    function liquidationStart() external view returns (uint256);
    function sellStartPrice() external view returns (uint256);
    function sellFloorPrice() external view returns (uint256);
    function machine(uint256 index) external view returns (Machine memory);
    function SALES() external view returns (address);
    function PRICE_FEED() external view returns (address);
    function POD() external view returns (address);
    function releaseMachine(uint256 index, address to, uint256 weight, uint256 cost) external;
    function consign(uint256 index, address to) external;
    function sentinelPaused() external view returns (bool);
}

/// @title StdMachineSales（标准局终局卖矿定价，单例；规则决定 6.17 / 6.18，V2-DESIGN.md 第 16 节）
/// @notice 标准局进入终局（Liquidating）后矿机的出售规则；卖出款进底池按本局规则分配（TapeBoard.releaseMachine）：
///         - **市价期**（进入终局后 30 天内）：每单位权重的卖价 = MarketPriceFeed.sellQuote（max(买一, 卖一 × (99% −
///           0.5% × 进入终局后的整小时数))），由合约按公式算，没有成本价底线。报价过期时暂停（NotForSale）。
///         - **降价拍卖**（第 30 天起，不依赖报价）：起价 = 第 30 天后第一次有人调用 startAuction（或买家购买时自动触发）
///           时的买一（报价无效时 = 采购均价 × 150%），不低于底价；时钟从第 30 天整算（P-4 a）：14 天线性降到
///           底价 = 采购均价 × 60%，底价停 7 天后循环。
///         - 计价权重 = min(收购时权重, PoD 当前权重)；PoD 读不到时用收购时权重；PoD 上暂时未验证的矿机按收购时权重计价，
///           拍卖期按底价（审计 #4）。
///         报价单例取自主板（PRICE_FEED），以后换模板就能换定价来源。没有管理员，参数不可改。
contract StdMachineSales is ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint256 internal constant BPS = 10_000;
    /// @dev 规则决定 6.33（审计 H-1）："保持排序第一"的目标价最低按公式价的 95% 采用
    uint256 internal constant TARGET_MIN_BPS = 9_500;
    uint256 internal constant ACC_SCALE = 1e18; // 和 TapeBoard 的累加器精度相同

    IERC20 public immutable BEM;
    IBoardHub public immutable HUB;
    uint256 public immutable MARKET_PERIOD; // 30 天
    uint256 public immutable DECAY_DURATION; // 14 天
    uint256 public immutable FLOOR_HOLD; // 7 天
    uint256 public immutable OPERATOR_GRACE; // 3 天：运营地址多久没分批发放，本局持仓的持有人可以代为执行
    /// @notice 卖矿溢价分成（规则决定 6.25，和月局同一个比例，1000 = 10%；6.37 起保底结局也收）：成交额超过这台矿机成本
    ///         （本局平均每单位算力成本 × 收购时算力）的部分按这个比例转给主板的手续费地址
    uint256 public immutable PREMIUM_FEE_BPS;
    /// @notice 挂单模块（MachineLister，规则决定 6.26）：把矿机寄售到 TapeOut 官方矿机市场 / Seaport 按公式价挂单
    IMachineLister public immutable LISTER;

    /// @notice 每块标准局的拍卖起价（每单位权重，0 = 还没开始拍卖）
    mapping(address => uint256) public auctionStartPrice;

    event AuctionStarted(address indexed board, uint256 startPricePerWeight, uint256 auctionStart);
    event MachineBought(address indexed board, uint256 indexed index, address indexed buyer, uint256 weight, uint256 cost);
    event PremiumFeePaid(address indexed board, uint256 indexed index, uint256 amount);

    error BadConfig();
    error NotStandardBoard();
    error WrongState();
    error AlreadySold();
    error NotForSale();
    error NotYet();
    error PriceAboveMaximum();
    error NotAuthorized();
    error PaymentMismatch();

    constructor(
        address bem,
        address hub,
        uint256 marketPeriod,
        uint256 decayDuration,
        uint256 floorHold,
        uint256 operatorGrace,
        uint256 premiumFeeBps,
        address lister
    ) {
        if (bem == address(0) || hub == address(0) || decayDuration == 0 || lister == address(0)) revert BadConfig();
        if (marketPeriod > 3650 days || decayDuration > 3650 days || floorHold > 3650 days) revert BadConfig();
        if (operatorGrace > 3650 days || premiumFeeBps > 5_000) revert BadConfig();
        OPERATOR_GRACE = operatorGrace;
        PREMIUM_FEE_BPS = premiumFeeBps;
        LISTER = IMachineLister(lister);
        BEM = IERC20(bem);
        HUB = IBoardHub(hub);
        MARKET_PERIOD = marketPeriod;
        DECAY_DURATION = decayDuration;
        FLOOR_HOLD = floorHold;
    }

    // ============ 拍卖 ============

    /// @notice 第 30 天起任何人可调：快照拍卖起价（当时的买一；报价无效时 = 采购均价 × 150%；不低于底价）。
    ///         已开始的不重复。买家购买时也会自动触发。
    function startAuction(address board) external {
        IStdBoard b = _board(board);
        if (block.timestamp < b.liquidationStart() + MARKET_PERIOD) revert NotYet();
        if (auctionStartPrice[board] == 0) _startAuction(b, board);
    }

    // ============ 读取 ============

    /// @notice 当前要价（每单位权重，和 buyMachine 同一个算法）和阶段：0 = 现在不能买（市价期报价无效 / 已卖出 / 不在终局），
    ///         1 = 市价，2 = 拍卖。拍卖期还没快照起价时按"现在快照"计算。
    function askPrice(address board, uint256 index) public view returns (uint256 pricePerWeight, uint8 phase) {
        IStdBoard b = IStdBoard(board);
        if (b.state() != BoardState.Liquidating || b.machine(index).sold) return (0, 0);
        (pricePerWeight,, phase) = _price(b, board, index, auctionStartPrice[board]);
    }

    /// @notice 现在买走第 index 台矿机要付的总价（BEM，= 计价权重 × 要价，和 buyMachine 的算法相同；0 = 现在不能买）。
    ///         挂单模块按它定挂单价。
    function quote(address board, uint256 index) external view returns (uint256 total) {
        IStdBoard b = IStdBoard(board);
        if (b.state() != BoardState.Liquidating || b.machine(index).sold) return 0;
        (uint256 price, uint256 w, uint8 phase) = _price(b, board, index, auctionStartPrice[board]);
        if (phase != 0) total = w * price;
    }

    // ============ 寄售（规则决定 6.26）============

    /// @notice 只认挂单模块：把一台现在可以按公式价卖的矿机转给它的挂单库寄售（账上仍是主板的矿机）。
    function consign(address board, uint256 index, address vault) external nonReentrant {
        if (msg.sender != address(LISTER)) revert NotAuthorized();
        IStdBoard b = _board(board);
        if (b.sentinelPaused()) revert NotForSale();
        (, uint8 phase) = askPrice(board, index);
        if (phase == 0) revert NotForSale();
        b.consign(index, vault);
    }

    // ============ 购买 ============

    /// @notice 按当前要价买走一台矿机：费用 = 计价权重 × 要价。需要事先授权本合约 BEM。maxPricePerWeight 防止价格变化。
    ///         矿机正寄售在挂单模块时：普通买家（包括 MarketTrader）先由挂单模块撤单、把矿机还给主板，再照常成交
    ///         （公式价成交照常开着，规则决定 6.22 F-3）；挂单模块自己调用表示矿机已经在市场上成交交给了买家，
    ///         这里按成交这一刻的要价收款记账，不再转矿机。
    function buyMachine(address board, uint256 index, uint256 maxPricePerWeight)
        external
        nonReentrant
        returns (uint256 cost)
    {
        IStdBoard b = _board(board);
        IStdBoard.Machine memory m = b.machine(index);
        if (m.sold) revert AlreadySold();
        address to = msg.sender;
        if (ICircuits(m.collection).ownerOf(m.circuitId) != board) {
            if (msg.sender == address(LISTER)) to = address(0);
            else LISTER.recall(board, index);
        }
        uint256 start = auctionStartPrice[board];
        if (start == 0 && block.timestamp >= b.liquidationStart() + MARKET_PERIOD) start = _startAuction(b, board);
        (uint256 price, uint256 w, uint8 phase) = _price(b, board, index, start);
        if (phase == 0) revert NotForSale();
        if (price > maxPricePerWeight) revert PriceAboveMaximum();
        cost = w * price;
        if (cost > 0) {
            uint256 before = BEM.balanceOf(address(this));
            BEM.safeTransferFrom(msg.sender, address(this), cost);
            // TapeCode 预审第 17 条：和月局一致，实际到账额不等于 cost 就回滚（BEM 是标准 ERC20，正常不会触发）
            if (BEM.balanceOf(address(this)) - before != cost) revert PaymentMismatch();
        }
        // 溢价分成（规则决定 6.25；6.37 起保底结局也收）：其余（cost − fee）进主板底池
        uint256 fee;
        uint256 basis = machineCost(board, index);
        if (cost > basis) fee = (cost - basis) * PREMIUM_FEE_BPS / BPS;
        if (fee > 0) {
            BEM.safeTransfer(b.FEE_RECIPIENT(), fee);
            emit PremiumFeePaid(board, index, fee);
        }
        if (cost > fee) BEM.forceApprove(board, cost - fee);
        b.releaseMachine(index, to, w, cost - fee);
        emit MachineBought(board, index, msg.sender, w, cost);
    }

    /// @notice 第 index 台矿机的成本：本局平均每单位算力成本（totalSpent ÷ 总收购算力）× 收购时算力（溢价分成的基准）
    function machineCost(address board, uint256 index) public view returns (uint256) {
        IStdBoard b = IStdBoard(board);
        uint256 tw = b.totalWeightBought();
        if (tw == 0) return 0;
        return b.totalSpent() * b.machine(index).weight / tw;
    }

    // ============ 领取辅助（主板放不下，规则决定 6.23 之后标准局按持仓领取）============

    /// @notice 第 slot 份持仓当前可以领取的 BEM（不含持有人名下的记账款 credit(address)，也不含尚未 sweep 的新资金）：
    ///         招募失败时 = 本金 + 入场费（没退过的）；终局阶段 = 底池份额 − 已领 / 已结转；其他阶段为 0。
    function owed(address board, uint256 slot) public view returns (uint256 amount) {
        IStdBoard b = _std(board);
        if (b.claimsClosed()) return 0;
        IStdBoard.Position memory p = b.socket(slot);
        if (p.owner == address(0)) return 0;
        BoardState st = b.state();
        if (st == BoardState.Failed) {
            if (!p.refunded) amount = uint256(p.stake) + uint256(p.stake) * b.ENTRY_FEE_BPS() / BPS;
        } else if (st == BoardState.Liquidating) {
            // 和 TapeBoard._potEntitlement 相同的公式
            uint256 ent;
            if (b.settleMode() == SettleMode.Normal) {
                ent = slot == b.kingSocket() ? b.kingPot() : uint256(p.stake) * b.accProRata() / ACC_SCALE;
            } else {
                ent = uint256(p.stake) * b.accProRata() / ACC_SCALE;
                if (!p.ejected) ent += uint256(p.stake) * b.accPriority() / ACC_SCALE;
            }
            amount = ent - p.potClaimed;
        }
    }

    /// @notice 一次领完第 slot 份持仓：持仓的款项和持有人名下的记账款打给持有人，能退的通行证退给加入者。任何人可调。
    function claimAll(address board, uint256 slot) external nonReentrant {
        _settle(_std(board), slot);
    }

    /// @notice 运营地址分批把标准局插槽 [fromSlot, fromSlot + count) 的可领款项推送给各自的持有人，并退还通行证。
    ///         开局 / 终局 / 招募失败后，运营地址 operatorGrace（3 天）内没执行，本局持仓的持有人也可以调用。
    ///         逐个插槽调用主板的 withdraw / withdrawCredit / returnPass（没有可领的跳过），与自领共用记账，不会重复支付。
    function distribute(address board, uint256 fromSlot, uint256 count) external nonReentrant {
        IStdBoard b = _std(board);
        BoardState st = b.state();
        uint256 since;
        if (st == BoardState.Active) since = b.startedAt();
        else if (st == BoardState.Liquidating) since = b.liquidationStart();
        else if (st == BoardState.Failed) since = b.finishedAt();
        else revert WrongState();
        if (b.claimsClosed()) revert WrongState();
        address op = HUB.operator();
        if (op == address(0) || msg.sender != op) {
            if (b.holderCount(msg.sender) == 0) revert NotAuthorized();
            if (op != address(0) && block.timestamp < since + OPERATOR_GRACE) revert NotAuthorized();
        }
        uint256 n = b.socketCount();
        if (fromSlot == 0) fromSlot = 1;
        if (fromSlot > n) return;
        uint256 end = count > n ? n + 1 : fromSlot + count; // 不会溢出：fromSlot ≤ n，count ≤ n
        if (end > n + 1) end = n + 1;
        for (uint256 slot = fromSlot; slot < end; slot++) {
            _settle(b, slot);
        }
    }

    function _settle(IStdBoard b, uint256 slot) internal {
        try b.withdraw(slot) {} catch {}
        try b.withdrawCredit(b.socket(slot).owner) {} catch {}
        try b.returnPass(slot) {} catch {}
    }

    // ============ 内部 ============

    /// @dev 本合约服务的标准局（不限阶段）
    function _std(address board) internal view returns (IStdBoard b) {
        if (!HUB.isBoard(board)) revert NotStandardBoard();
        b = IStdBoard(board);
        if (b.SALES() != address(this)) revert NotStandardBoard();
    }

    function _board(address board) internal view returns (IStdBoard b) {
        if (!HUB.isBoard(board)) revert NotStandardBoard();
        b = IStdBoard(board);
        if (b.SALES() != address(this)) revert NotStandardBoard();
        if (b.state() != BoardState.Liquidating) revert WrongState();
    }

    /// @dev 第 index 台的要价（每单位权重）、计价权重、阶段（0 = 不能买，1 = 市价，2 = 拍卖）。start = 拍卖起价（0 = 现在快照）。
    ///      - 市价期：MarketPriceFeed.sellQuote（报价无效 → 不能买），不低于拍卖底价 sellFloorPrice（规则决定 6.31）；拍卖期：_auctionPrice。
    ///      - 计价权重 = min(收购时权重, PoD 当前计价算力)；PoD 上暂时未验证的矿机按收购时权重、拍卖期按底价（审计 #4），不追第一。
    ///      - 规则决定 6.29（保持排序第一）：目标价（MarketPriceFeed.floorQuote，最低按原公式价的 95% 算，规则决定 6.33）×
    ///        计价权重 ≥ 这台的买入成本（machineCost）时，要价 = min(原公式价, 目标价)；低于成本不追。
    function _price(IStdBoard b, address board, uint256 index, uint256 start)
        internal
        view
        returns (uint256 p, uint256 w, uint8 phase)
    {
        IStdBoard.Machine memory m = b.machine(index);
        uint256 t0 = b.liquidationStart();
        IMarketPriceFeed feed = IMarketPriceFeed(b.PRICE_FEED());
        if (block.timestamp < t0 + MARKET_PERIOD) {
            p = feed.sellQuote(t0);
            if (p == 0) return (0, 0, 0);
            // 规则决定 6.31（TapeCode rc10 第 2 份报告 C3）：市价期也不低于拍卖底价（采购均价 × 60%），
            // 运营地址被盗、报价被压低时损失有上限
            uint256 fl = b.sellFloorPrice();
            if (p < fl) p = fl;
            phase = 1;
        } else {
            if (start == 0) start = _snapshot(b);
            p = _auctionPrice(b, start, t0 + MARKET_PERIOD);
            phase = 2;
        }
        w = _saleWeight(b, m);
        if (w == 0) {
            w = m.weight;
            if (phase == 2) p = b.sellFloorPrice();
            return (p, w, phase);
        }
        uint256 f = feed.floorQuote();
        if (f > 0 && f < p) {
            uint256 lo = p * TARGET_MIN_BPS / BPS; // 规则决定 6.33：目标价最多比公式价低 5%
            if (f < lo) f = lo;
            if (f * w >= machineCost(board, index)) p = f;
        }
    }

    function _startAuction(IStdBoard b, address board) internal returns (uint256 p) {
        p = _snapshot(b);
        auctionStartPrice[board] = p;
        emit AuctionStarted(board, p, b.liquidationStart() + MARKET_PERIOD);
    }

    /// @dev 拍卖起价 = 买一（报价无效时 = 采购均价 × 150%），不低于底价；底价为 0（没买过矿机）时至少 1
    function _snapshot(IStdBoard b) internal view returns (uint256 p) {
        IMarketPriceFeed feed = IMarketPriceFeed(b.PRICE_FEED());
        p = feed.fresh() ? feed.bid() : b.sellStartPrice();
        uint256 floor = b.sellFloorPrice();
        if (p < floor) p = floor;
        if (p == 0) p = 1;
    }

    function _auctionPrice(IStdBoard b, uint256 start, uint256 t1) internal view returns (uint256) {
        uint256 floor = b.sellFloorPrice();
        if (start <= floor) return floor;
        uint256 e = (block.timestamp - t1) % (DECAY_DURATION + FLOOR_HOLD);
        if (e >= DECAY_DURATION) return floor;
        return start - (start - floor) * e / DECAY_DURATION;
    }

    /// @dev 计价权重：取收购时权重与 PoD 当前权重的较小者；读取失败时用收购时权重；未验证的矿机返回 0
    function _saleWeight(IStdBoard b, IStdBoard.Machine memory m) internal view returns (uint256) {
        (bool ok, PoDReader.MinerView memory v) = PoDReader.tryRead(b.POD(), m.key, m.collection, m.circuitId);
        if (!ok) return m.weight;
        if (!v.verified) return 0;
        return v.weight < m.weight ? v.weight : m.weight;
    }
}

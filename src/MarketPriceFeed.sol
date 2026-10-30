// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IBoardHub} from "./interfaces/ITapeBoard.sol";

/// @title MarketPriceFeed（矿机市场报价与买卖定价，单例，标准局和月局共用；规则决定 6.17 / 6.18，V2-DESIGN.md 第 16 节）
/// @notice 运营地址每小时同时报 Firsto 的买一（bid）和卖一（ask），单位都是每单位算力（PoD 权重）的 BEM 价。
///         两种局的收购价和卖价都在这里按公式算（以后切到 Firsto 时换模板和这个单例即可）：
///         - 收购价上限 = min(ask, 一年产出上限)（规则决定 6.37：主板只经 MarketTrader 由运营地址在市场上从最便宜的挂单往上买，
///           按实际花费付款；原来从买一每小时 +0.5% 往上爬的规则 6.19 不再使用）。报价过期、追价中、运营地址为 0 或停运 → 0
///           （暂停收购，全局审计 G-1 / 规则决定 6.36）；
///           只有从没报过价时用主板自己的默认曲线（从半年产出起步）。BoardFactory.startGenesis 要求开局前已经报过价，
///           所以已开局的主板实际用不到默认曲线；
///         - 卖价 = max(bid, ask × (99% − 0.5% × n))，n = 卖出阶段开始后已过的整 6 小时数（规则决定 6.21；降到买一后
///           跟着买一）。
///           报价过期 → 0（暂停卖出，具体兜底由卖矿合约决定）。
///         报价保护：bid ≤ ask；bid、ask 各自相对上一次变动 ≤ 5%（任何时候都限，第三方审计 H-1 / 规则决定 6.33：
///         停报再久也不能一步报到任意价）；两次报价至少间隔 50 分钟；超过 3 小时没更新算过期；超过 7 天没更新算"停运"
///         （abandoned，只按时间判断，月局按成本价兜底；运营地址设为 0 只是暂停，不会立刻停运，审计 M-4）。
///         市价离上一次报价超过 5% 时用 postCatchUp 分步追，追价期间不算有效报价（复核 N-1）。
///         规则决定 6.29（保持排序第一）：运营地址另外随时报一个"同类最低挂单"目标价（floorPrice，每单位权重、主板净得的
///         BEM），卖矿合约按 min(原公式卖价, max(目标价, 原公式卖价 × 95%)) 卖（规则决定 6.33），并且不低于这台矿机的买入成本；
///         超过 3 小时没更新就不用。
///         没有管理员，参数不可改；要改参数，部署新的报价合约并经模板升级让新局使用。
contract MarketPriceFeed {
    uint256 public constant BPS = 10_000;

    struct Params {
        uint256 maxChangeBps; // 500：每次报价 bid / ask 各自最多变动 5%
        uint256 minInterval; // 50 分钟：两次报价至少间隔
        uint256 maxStaleness; // 3 小时：超过算过期
        uint256 abandonAfter; // 7 天：超过算停运
        uint256 buyStepBps; // 规则决定 6.37 起不再使用（原：收购价每小时在买一上加 0.5%），保留是为了部署参数和接口不变
        uint256 sellStartBps; // 9900：卖价从卖一 × 99% 起
        uint256 sellStepBps; // 50：卖价每个 sellStepInterval 降卖一的 0.5%
        uint256 sellStepInterval; // 6 小时
    }

    IBoardHub public immutable HUB;
    uint256 public immutable maxChangeBps;
    uint256 public immutable minInterval;
    uint256 public immutable maxStaleness;
    uint256 public immutable abandonAfter;
    uint256 public immutable buyStepBps;
    uint256 public immutable sellStartBps;
    uint256 public immutable sellStepBps;
    uint256 public immutable sellStepInterval;

    /// @notice 最近一次报价（每单位权重的 BEM 最小单位数）和时间（0 = 从没报过价）
    uint256 public bid;
    uint256 public ask;
    uint256 public updatedAt;
    /// @notice 规则决定 6.29：保持排序第一的目标价（每单位权重、主板净得的 BEM）和报价时间（0 = 没报过 / 已撤销）
    uint256 public floorPrice;
    uint256 public floorAt;
    /// @notice 追价中（复核 N-1）：最近一次报价是 postCatchUp 报的，价格还在分步追市价，不算有效报价（两种局暂停按报价买卖）
    bool public catchingUp;
    /// @notice 最近一次有效报价（post，或第一次报价）的时间。停运按它算：一直追价也会在 7 天后停运（第二次复核 N-2）
    uint256 public liveAt;

    event FloorPosted(uint256 price, uint256 time);
    event PricesPosted(uint256 bid, uint256 ask, uint256 previousBid, uint256 previousAsk, uint256 time);
    /// @notice 这次报价是追价中的一步（同时发 PricesPosted）
    event CatchUpPosted(uint256 bid, uint256 ask, uint256 time);

    error BadConfig();
    error NotOperator();
    error BadPrices();
    error TooSoon();
    error ChangeTooLarge();

    constructor(address hub, Params memory p) {
        if (
            hub == address(0) || p.maxChangeBps == 0 || p.maxChangeBps >= BPS || p.maxStaleness == 0
                || p.minInterval >= p.maxStaleness || p.abandonAfter < p.maxStaleness || p.sellStartBps > BPS
                || p.buyStepBps > BPS || p.sellStepInterval == 0
        ) revert BadConfig();
        HUB = IBoardHub(hub);
        maxChangeBps = p.maxChangeBps;
        minInterval = p.minInterval;
        maxStaleness = p.maxStaleness;
        abandonAfter = p.abandonAfter;
        buyStepBps = p.buyStepBps;
        sellStartBps = p.sellStartBps;
        sellStepBps = p.sellStepBps;
        sellStepInterval = p.sellStepInterval;
    }

    // ============ 报价 ============

    /// @notice 运营地址报价：Firsto 的买一和卖一（每单位权重的 BEM 价）。0 < bid ≤ ask。表示这就是当前市价，报价随即有效。
    function post(uint256 newBid, uint256 newAsk) external {
        _post(newBid, newAsk, false);
    }

    /// @notice 追价（复核 N-1，规则决定 6.34）：市价离上一次报价超过 5% 时，运营地址每 50 分钟按 ±5% 往市价走一步；
    ///         这期间报价不算有效（fresh() 为假），两种局暂停按报价买卖，免得按偏离市价的价格成交。追到市价的最后一步用 post。
    ///         限制和 post 相同（间隔 ≥ 50 分钟、每次 ±5%）；停运按最后一次有效报价（post）的时间算，所以一直追价 7 天
    ///         也会停运、月局按成本价兜底（第二次复核 N-2）。
    function postCatchUp(uint256 newBid, uint256 newAsk) external {
        _post(newBid, newAsk, true);
    }

    function _post(uint256 newBid, uint256 newAsk, bool catchUp) internal {
        address op = HUB.operator();
        if (op == address(0) || msg.sender != op) revert NotOperator();
        if (newBid == 0 || newBid > newAsk) revert BadPrices();
        uint256 lastBid = bid;
        uint256 lastAsk = ask;
        uint256 t = updatedAt;
        if (t != 0) {
            if (block.timestamp < t + minInterval) revert TooSoon();
            // 审计 H-1：上一次报价过期也照样限幅（行情跳空时分几次追上）
            if (!_within(newBid, lastBid) || !_within(newAsk, lastAsk)) revert ChangeTooLarge();
        }
        bid = newBid;
        ask = newAsk;
        updatedAt = block.timestamp;
        catchingUp = catchUp;
        if (!catchUp || t == 0) liveAt = block.timestamp;
        emit PricesPosted(newBid, newAsk, lastBid, lastAsk, block.timestamp);
        if (catchUp) emit CatchUpPosted(newBid, newAsk, block.timestamp);
    }

    /// @notice 运营地址报"保持排序第一"的目标价（规则决定 6.29）：所有平台同类挂单（已验证、在挖、算力 10–300、工厂处理器的
    ///         矿机）里买家实付的最低日产能价再低 0.1%，由机器人按挂单模块的定价（挂单价 = 主板净得 ÷ 98%，再加市场手续费）
    ///         折回"主板净得的每单位权重 BEM 价"后报来；0 = 撤销。不限频率、不限变动幅度：卖矿合约只在
    ///         [买入成本, 原公式卖价] 之间采用它，最坏按成本价卖出。超过 maxStaleness（3 小时）没更新就不用。
    function postFloor(uint256 price) external {
        address op = HUB.operator();
        if (op == address(0) || msg.sender != op) revert NotOperator();
        floorPrice = price;
        floorAt = price == 0 ? 0 : block.timestamp;
        emit FloorPosted(price, block.timestamp);
    }

    /// @notice 当前有效的目标价（每单位权重）；没报过、已撤销、过期（≥ 3 小时）或运营地址为 0 时为 0
    function floorQuote() external view returns (uint256) {
        uint256 t = floorAt;
        if (t == 0 || block.timestamp >= t + maxStaleness || HUB.operator() == address(0)) return 0;
        return floorPrice;
    }

    // ============ 状态 ============

    /// @notice 报价有效：报过、没过期（< 3 小时）、运营地址非 0、不在追价中（复核 N-1）
    function fresh() public view returns (bool) {
        uint256 t = updatedAt;
        return !catchingUp && t != 0 && block.timestamp < t + maxStaleness && HUB.operator() != address(0);
    }

    /// @notice 停运：从没报过价，或超过 7 天没有有效报价（只按时间判断，追价不算有效报价，第二次复核 N-2；运营地址为 0 时
    ///         fresh() 为假，即暂停，审计 M-4）
    function abandoned() public view returns (bool) {
        return updatedAt == 0 || block.timestamp >= liveAt + abandonAfter;
    }

    // ============ 定价 ============

    /// @notice 主板的收购价上限（每单位权重）。cap = 主板快照的一年产出上限；curvePrice = 主板默认曲线的当前价。
    ///         报价有效 → min(ask, cap)（规则决定 6.37：开局就按卖一往下扫，不再从买一每小时 +0.5% 往上爬；主板只经 MarketTrader
    ///         由运营地址在市场上买真实挂单、按实际花费付款，这只是上限）；从没报过价 → curvePrice；报过价之后无效（过期、追价、
    ///         运营地址为 0、停运）→ 0（暂停，全局审计 G-1）。第三个参数（本轮收购开始时间）不再使用，保留是为了接口不变。
    function buyQuote(uint256 cap, uint256 curvePrice, uint256) external view returns (uint256 p) {
        if (updatedAt == 0) return curvePrice;
        if (!fresh()) return 0;
        p = ask < cap ? ask : cap;
    }

    /// @notice 卖价（每单位权重）= max(bid, ask × (99% − 0.5% × n))，n = 卖出阶段开始（since）后已过的整 6 小时数。
    ///         报价无效（过期 / 没报过 / 运营地址为 0）时返回 0。
    function sellQuote(uint256 since) external view returns (uint256 p) {
        if (!fresh()) return 0;
        uint256 n = block.timestamp > since ? (block.timestamp - since) / sellStepInterval : 0;
        uint256 drop = sellStepBps * n;
        if (drop < sellStartBps) p = ask * (sellStartBps - drop) / BPS;
        if (p < bid) p = bid;
    }

    function _within(uint256 v, uint256 last) internal view returns (bool) {
        return v * BPS >= last * (BPS - maxChangeBps) && v * BPS <= last * (BPS + maxChangeBps);
    }
}

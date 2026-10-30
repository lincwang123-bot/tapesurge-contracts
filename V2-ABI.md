# TapeSurge v2 月局：ABI 变化（第 2 阶段：持仓凭证 + 主板拆分 + 卖矿合约）

对照基准：`audit-v1.5`。dApp 和运营机器人以 `out/` 里编译出的 ABI 为准；本文由编译产物自动列出，再加了说明。

**标准局（TapeBoard / BoardFactory / GenesisSplitter / ChainlinkVRFAdapter / PancakeV3TwapOracle）的 ABI 和字节码都没有变**（字节码逐字节相同，连元数据一起）。

## 要点

- **领取改成按持仓编号（slot）**：`owed(slot)`、`withdraw(slot)`、`claimAll(slot)`、`returnPass(slot)`。任何人都可以调用，钱付给这份持仓当前的持有人。持仓转让时结转给卖方的款项按地址领：`credit(address)`、`withdrawCredit(address)`。
- **地址 → 持仓：** v1.5 的 `socketOf(address)` 没有了，因为一个地址可以持有多份持仓。
  - 前端：用 `MonthPositions` 的 ERC-721 `Transfer` 事件建索引，或者遍历 `socket(i).owner`。
  - 持仓编号：`MonthPositions.idOf(board, slot)`；反查用 `boardOf(id)` / `slotOf(id)`。
  - `holderCount(address)`：这个地址在本局持有几份。
- **挂单、购买、交接、分批推送都移到了 `MonthMachineSales`（单例）**，第一个参数是月局地址：
  - `setListing(board, index, price)`
  - `askPrice(board, index)`
  - `buyMachine(board, index, maxPrice)`：买家要授权 **MonthMachineSales**，不再授权月局
  - `relay(oldBoard, index, newBoard)`
  - `distribute(board, fromSlot, count)`
- **`socket(slot)` 多了 `version` 字段**（持仓版本号，每次转让 +1）；**`machine(index)` 去掉了 `listPrice`、`listedAt`**（挂单价改为 `MonthMachineSales.listPrice(board, index)`）。
- **交易版本号：** `tradeEpoch()`。进入结算、卖出 / 交接一台矿机、治理锁变化、开始清算时 +1，每次都发 `TradeEpochBumped`。
- **能不能转让：** 结算阶段（`state() == Settling`），并且 `!claimsClosed()`、`!governanceLocked()`。其他时候任何转移都会以 `TransferLocked()` revert。
- **`MonthFactory.boardConfig()`** 返回的 `Config` 结构体变了：去掉 `autoListDelay`、`listingMaxAge`；在 `hub` 后面加了 `positions`、`sales`、`governor`。"1 天没挂单按成本价可买"的时长改为 `MonthMachineSales.AUTO_LIST_DELAY()`。
- **事件：**
  - 卖出：主板 `MachineSold(index, circuitId, buyer, price)`，卖矿合约 `MachineBought(board, index, buyer, price)`；
  - 交接：主板 `MachineRelayedOut(index, circuitId, toBoard, price)`（最后一个字段改成实际成交价），卖矿合约 `MachineRelayed`；
  - 接手方：v1.5 的 `MachineRelayedIn` 没有了。旧局在新局里就是普通卖家，新局发普通的 `MachineBought(index, circuitId, seller = 旧局地址, weight, cost)`；
  - 转让：凭证合约发 ERC-721 `Transfer`，主板发 `PositionTransferred(slot, from, to, carriedOver)`；
  - 通行证：`PassReturned(holder, passId)`（转让时立刻退给原持有人）。

## 和设计不一致的地方

1. **`distribute` 从主板移到了 `MonthMachineSales`**（设计第 3.2 节的后备方案）：主板编译后比估算大，超出上限 743 字节。规则不变：运营地址分批推送，3 天后持有人兜底。卖矿合约逐个调用主板任何人都能调的 `withdraw(slot)` / `returnPass(slot)`。
2. **主板没有 `tradeState(slot)`、`positionId(slot)`**（同样为了大小）。交易所和前端改用 `socket(slot)`（持有人、投入、版本号）+ `tradeEpoch()` + `state()` / `claimsClosed()` / `governanceLocked()`，以及 `MonthPositions.idOf`。
3. **分批推送的 `count` 先截到插槽数**，`count = 2²⁵⁶ − 1` 也不再溢出回滚（v1.5 会回滚；对应第一轮审计 TC13 的测试已更新）。
4. **`buyMachine` 先检查升级哨兵**，冷静期内直接返回 `UpgradeSentinelTripped()`，不先收款再回滚。主板交割时还会再查一次。

## 自动列出的签名

## MonthBoard: removed vs audit-v1.5
- error NotForSale()
- error PriceAboveMaximum()
- error PriceLocked()
- error RelayAboveCap()
- error RelayNotReceived()
- event MachineListed(uint256 indexed index,uint256 price)
- event MachineRelayedIn(uint256 indexed index,uint256 indexed circuitId,address indexed fromBoard,uint256 cost)
- event MachineRelayedOut(uint256 indexed index,uint256 indexed circuitId,address indexed toBoard,uint256 cost)
- function acceptRelay(bytes32 key,uint256 circuitId,uint256 cost)
- function askPrice(uint256 index) returns (uint256) [view]
- function buyMachine(uint256 index,uint256 maxPrice) returns (uint256)
- function claimAll(address account) returns (uint256)
- function distribute(uint256 fromSlot,uint256 count)
- function machine(uint256 index) returns ((bytes32,uint256,uint128,uint128,uint128,uint64,bool,bool)) [view]
- function owed(address account) returns (uint256) [view]
- function priceLocked(uint256 index) returns (bool) [view]
- function relayMachine(uint256 index,address receiver)
- function returnPass(address account)
- function setListing(uint256 index,uint256 price)
- function socket(uint256 slot) returns ((address,uint96,uint256,uint128,bool,bool)) [view]
- function socketOf(address) returns (uint256) [view]
- function withdraw(address account) returns (uint256)
## MonthBoard: added vs audit-v1.5
+ error TransferLocked()
+ event GovernanceLockSet(bool locked)
+ event LiquidationStarted()
+ event MachineRelayedOut(uint256 indexed index,uint256 indexed circuitId,address indexed toBoard,uint256 price)
+ event PositionTransferred(uint256 indexed slot,address indexed from,address indexed to,uint256 carriedOver)
+ event TradeEpochBumped(uint64 epoch)
+ function GOVERNOR() returns (address) [view]
+ function POSITIONS() returns (address) [view]
+ function SALES() returns (address) [view]
+ function claimAll(uint256 slot) returns (uint256)
+ function governanceLocked() returns (bool) [view]
+ function holderCount(address) returns (uint256) [view]
+ function liquidating() returns (bool) [view]
+ function machine(uint256 index) returns ((bytes32,uint256,uint128,uint128,bool,bool)) [view]
+ function onPositionTransfer(uint256 slot,address from,address to)
+ function owed(uint256 slot) returns (uint256) [view]
+ function passOwner(uint256) returns (address) [view]
+ function relayOut(uint256 index,address newBoard) returns (uint256)
+ function releaseMachine(uint256 index,address to,uint256 price)
+ function returnPass(uint256 slot)
+ function setGovernanceLock(bool locked)
+ function socket(uint256 slot) returns ((address,uint96,uint256,uint128,bool,bool,uint32)) [view]
+ function startLiquidation()
+ function tradeEpoch() returns (uint64) [view]
+ function withdraw(uint256 slot) returns (uint256)
+ function withdrawCredit(address account) returns (uint256)
## MonthPositions (new)
  error BadConfig()
  error ERC721IncorrectOwner(address sender,uint256 tokenId,address owner)
  error ERC721InsufficientApproval(address operator,uint256 tokenId)
  error ERC721InvalidApprover(address approver)
  error ERC721InvalidOperator(address operator)
  error ERC721InvalidOwner(address owner)
  error ERC721InvalidReceiver(address receiver)
  error ERC721InvalidSender(address sender)
  error ERC721NonexistentToken(uint256 tokenId)
  error NotMonthBoard()
  event Approval(address indexed owner,address indexed approved,uint256 indexed tokenId)
  event ApprovalForAll(address indexed owner,address indexed operator,bool approved)
  event Transfer(address indexed from,address indexed to,uint256 indexed tokenId)
  function approve(address to,uint256 tokenId)
  function balanceOf(address owner) returns (uint256) [view]
  function boardOf(uint256 id) returns (address) [pure]
  function factory() returns (address) [view]
  function getApproved(uint256 tokenId) returns (address) [view]
  function idOf(address board,uint256 slot) returns (uint256) [pure]
  function isApprovedForAll(address owner,address operator) returns (bool) [view]
  function mint(address to,uint256 slot)
  function name() returns (string) [view]
  function ownerOf(uint256 tokenId) returns (address) [view]
  function safeTransferFrom(address from,address to,uint256 tokenId)
  function safeTransferFrom(address from,address to,uint256 tokenId,bytes data)
  function setApprovalForAll(address operator,bool approved)
  function slotOf(uint256 id) returns (uint256) [pure]
  function supportsInterface(bytes4 interfaceId) returns (bool) [view]
  function symbol() returns (string) [view]
  function tokenURI(uint256 tokenId) returns (string) [view]
  function transferFrom(address from,address to,uint256 tokenId)
## MonthMachineSales (new)
  error AlreadySold()
  error BadConfig()
  error BelowCost()
  error NotAuthorized()
  error NotForSale()
  error NotMonthBoard()
  error PaymentMismatch()
  error PriceAboveMaximum()
  error ReentrancyGuardReentrantCall()
  error SafeERC20FailedOperation(address token)
  error UpgradeSentinelTripped()
  error WrongState()
  event MachineBought(address indexed board,uint256 indexed index,address indexed buyer,uint256 price)
  event MachineListed(address indexed board,uint256 indexed index,uint256 price)
  event MachineRelayed(address indexed board,uint256 indexed index,address indexed newBoard,uint256 price)
  function AUTO_LIST_DELAY() returns (uint256) [view]
  function BEM() returns (address) [view]
  function FACTORY() returns (address) [view]
  function GOVERNOR() returns (address) [view]
  function HUB() returns (address) [view]
  function OPERATOR_GRACE() returns (uint256) [view]
  function askPrice(address board,uint256 index) returns (uint256) [view]
  function buyMachine(address board,uint256 index,uint256 maxPrice) returns (uint256)
  function distribute(address board,uint256 fromSlot,uint256 count)
  function listPrice(address,uint256) returns (uint256) [view]
  function relay(address oldBoard,uint256 index,address newBoard) returns (uint256)
  function setListing(address board,uint256 index,uint256 price)

## PositionExchange（第 6 阶段：链上挂单簿，卖单 + 买单）

第 3 阶段的 EIP-712 签名卖单和单份持仓买单**全部删除**：`Ask` 结构体、`ASK_TYPEHASH`、`askHash`、`fillAsk`、`cancelAskNonce`、`cancelAllAsks`、`minNonce`、`nonceUsed`、`Bid` 结构体、`createFundedBid`、`acceptFundedBid`、`cancelFundedBid`、`releaseInvalidBid`、`bidStillValid`、`bid(uint256)`（返回结构改了）、`bidCount()`（改成按局 `bidCount(address)`）、`marketWithdrawable`、`totalWithdrawable`、`withdrawMarketBalance`、`eip712Domain`，以及事件 `AskFilled`、`AskNonceCancelled`、`AllAsksCancelled`、`BidCreated`、`BidAccepted`、`BidCancelled`、`BidReleased`、`MarketCredited`、`MarketWithdrawn`。构造参数不变（`bem, positions, monthFactory`），`BEM()` / `POSITIONS()` / `FACTORY()` 不变。

**没有"市场余额"要领取**：吃卖单时成交款由买家直接转给卖方；卖给买单时从托管预算直接转给持有人；撤单 / 退款直接退回买家。交易所只托管未关闭买单的剩余预算（`totalEscrow()`）。

**报价**：`unitPrice` = 每 1e8 本金单位（1 BEM 原始本金）的 BEM 最小单位数；总价 `quote(stake, unitPrice) = ⌈stake × unitPrice ÷ 1e8⌉`（向上取整）。页面"本金的 X%" = unitPrice ÷ 1e6。

| 签名 | 选择器 | 说明 |
|---|---|---|
| `listAsk(address board, uint256 slot, uint256 unitPrice, uint64 deadline)` | 5f3cd023 | 持有人挂单 / 改价。要先 `MonthPositions.setApprovalForAll(exchange, true)`（或单份 `approve`）。只在 `Settling` 且 `!claimsClosed`；治理锁期间可挂不可成交。`0 < deadline − now ≤ 30 天` |
| `cancelAsk(address board, uint256 slot)` | 40b80746 | 挂单人或当前持有人撤单 |
| `pruneAsks(address board, uint256[] slots)` | ac07d46e | 任何人清理已失效的卖单（有效的跳过） |
| `buyAsk(address board, uint256 slot, uint256 maxUnitPrice) → uint256 cost` | 02f278db | 吃一张卖单；买家要先授权交易所 BEM |
| `buyBest(address board, uint256[] slots, uint256 maxUnitPrice, uint256 maxTotalCost) → (uint256 filled, uint256 spent)` | 8e8b4dcd | 按单价从低到高（同价按插槽）吃 slots 里的卖单；**失效 / 超价 / 自己的 / 超总额的跳过**，一张都没成交时 `NothingFilled()` 回滚 |
| `book(address board, uint256 depth) → (AskView[] asks, BidView[] bids)` | 03efb5c4 | 只含有效订单：卖单单价从低到高（同价按插槽），买单从高到低（同价先挂的在前），各取前 depth 档（0 = 全部） |
| `placeBid(address board, uint256 unitPrice, uint256 budget, uint256 minStake, uint256 maxStake, uint64 deadline) → uint256 bidId` | c33afe76 | 本局通用买单，托管 budget（≥ 1 BEM，且至少够一份 minStake）；买家先授权交易所 BEM。minStake = 0 视为 1。每个地址每局最多 20 张未关闭，最长 30 天；只在 `Settling` 且 `!claimsClosed` |
| `sellToBid(uint256 bidId, uint256 slot, uint256 minUnitPrice) → uint256 cost` | 0f944370 | 持有人卖给买单（持仓大小要在 [minStake, maxStake]，总价 ≤ 剩余预算）；持有人要授权交易所持仓。剩余预算不够最小一份时买单自动关闭、退款 |
| `cancelBid(uint256 bidId)` | 9703ef35 | 买家撤单，剩余预算直接退回 |
| `refundBid(uint256 bidId)` | 26d29ce0 | 过期或领取期限关闭后任何人可调，钱只退给买家 |
| `bidsOf(address board, uint256 offset, uint256 limit) → BidView[]` | b1f224c9 | 分页读取未关闭买单（看 `valid`），顺序不固定 |
| `bidCount(address board)` | 4e22b965 | 未关闭买单数 |
| `bid(uint256 bidId) → BidOrder` | 454a2ab3 | `{bidder, unitPrice, board, deadline, remaining, minStake, maxStake}`；bidder = 0 表示已关闭 |
| `bidValid(uint256 bidId)` | c4b22ee4 | 未关闭、未过期、领取期限没关闭、剩余预算够最小一份（不看治理锁：锁定期间买单仍有效，只是不能成交） |
| `openBidsOf(address board, address bidder)` | e457b50b | 这个地址在本局的未关闭买单数 |
| `lastBidId()` / `totalEscrow()` | ef78e28b / a3d89844 | 最新买单号；全部托管余额（= 交易所 BEM 余额） |
| `asksOf(address board, uint256 offset, uint256 limit) → AskView[]` | 5d0e8631 | 分页原始列表（含已失效的，看 `valid`），顺序不固定；limit = 0 表示到末尾 |
| `askCount(address board)` | 763dad0e | 有卖单记录的插槽数（含已失效、未清理的） |
| `ask(address board, uint256 slot) → AskOrder` | d16f3bbf | `{maker, unitPrice, positionVersion, tradeEpoch, deadline}`；maker = 0 表示没有卖单 |
| `askValid(address board, uint256 slot)` | af93ed40 | 未过期、持有人 / 持仓版本号 / 局交易版本号没变、仍授权、领取期限没关闭 |
| `recentTrades(address board) → Trade[]` | 6a48376e | 最近 20 笔成交，从新到旧；`Trade = {uint96 unitPrice, uint96 stake, uint40 time, uint24 slot}` |
| `tradeCount(address board)` | 1b831e7d | 累计成交笔数 |
| `tradable(address board)` | a0f3ac36 | 现在能否成交：`Settling && !governanceLocked && !claimsClosed` |
| `quote(uint256 stake, uint256 unitPrice)` | 315f1a41 | 总价 |
| 常量 | | `MAX_VALIDITY() = 30 days`、`TRADE_HISTORY() = 20`、`STAKE_UNIT() = 1e8`、`MIN_BID_BUDGET() = 1e8`、`MAX_OPEN_BIDS() = 20` |

`AskView = {uint256 slot, address maker, uint256 unitPrice, uint256 stake, uint256 cost, uint64 deadline, bool valid}`；`BidView = {uint256 bidId, address bidder, uint256 unitPrice, uint256 remaining, uint256 minStake, uint256 maxStake, uint64 deadline, bool valid}`。

**事件**：`AskListed(board indexed, slot indexed, maker indexed, unitPrice, deadline)`、`AskCancelled(board indexed, slot indexed, by indexed)`（撤单或清理；成交不发这个）、`BidPlaced(bidId indexed, board indexed, bidder indexed, unitPrice, budget, minStake, maxStake, deadline)`、`BidClosed(bidId indexed, board indexed, refund, reason)`（reason 1 撤单、2 过期或领取关闭后退款、3 剩余预算不够自动关闭）、`PositionTraded(board indexed, slot indexed, seller indexed, buyer, unitPrice, stake, cost, bidId)`（bidId = 0 表示吃卖单）。

**错误**：`NotMonthBoard`、`NotListable`、`BadDeadline`、`ZeroPrice`、`NotOwner`、`NotApproved`、`NoAsk`、`AskNotValid`、`PriceAbove`、`SelfTrade`、`NotTransferable`、`PaymentMismatch`、`NothingFilled`、`PriceBelow`、`BudgetTooSmall`、`BadStakeRange`、`TooManyBids`、`BidClosedAlready`、`BidExpired`、`NotBidder`、`BidStillValid`、`StakeOutOfRange`、`BudgetExceeded`。

**注意**：治理锁的加锁和解锁、卖出 / 交接一台矿机、开始清算都会让 `tradeEpoch` +1，所以这些事件之后**全部旧卖单失效**，持有人（或机器人提醒持有人）要重新挂单。买单不受局交易版本号影响。


## 第 7 阶段（`v2.0-rc2`）：模板时间锁 + 按卖一价收购

### MonthBuyPriceFeed（新单例，`deployments/*.json` 的 `monthPriceFeed`）

| 签名 | 说明 |
|---|---|
| `post(uint256 price)` | **运营地址**报价：每单位权重的 BEM 最小单位数（和 `MonthBoard.buyPrice()` 同单位）。price > 0；距上一次 ≥ `minInterval()`（50 分钟）；上一次报价没过期（< 3 小时）时变动不超过 ±`maxChangeBps()`（5%，边界含），过期后第一次不限 |
| `price()` / `updatedAt()` | 最近一次报价和时间（`updatedAt == 0` = 从没报过） |
| `fresh()` | 报过、没过期、运营地址非 0 |
| `quote(uint256 cap, uint256 curvePrice) → uint256` | 月局内部调用：从没报过价或运营地址为 0 → `curvePrice`；过期 → 0；否则 `clamp(price × (1 + markupBps), cap × floorBps, cap)` |
| 不可变参数 | `HUB()`（BoardFactory，读运营地址）、`maxChangeBps()` 500、`minInterval()` 3000 秒、`maxStaleness()` 10800 秒、`floorBps()` 5000、`markupBps()` 0、常量 `MAX_MARKUP_BPS()` 300、`BPS()` |
| 事件 | `PricePosted(uint256 price, uint256 previous, uint256 time)` |
| 错误 | `NotOperator`、`ZeroPrice`、`TooSoon`、`ChangeTooLarge`、`BadConfig` |

**机器人每小时报价**：`price = Firsto 卖一的日产能价（BNB）× BEM/BNB（链上 TWAP）÷ 每单位权重日产出`，按 BEM 8 位小数取整；最好 3 个价的中位数。发送前自己检查：距上次 ≥ 50 分钟、变动 ≤ 5%（超过就分几次、每次间隔 ≥ 50 分钟逐步靠近，或先等上一次过期 3 小时）。月局的 `buyPrice()` 已经包含上下限和加价，dApp 直接显示它即可。测试网的 50 分钟 / 3 小时**不随 TIME_DIVISOR 缩短**。

### MonthBoard

- `Config` 在 `governor` 后面加了 `address priceFeed`（`MonthFactory.boardConfig()` 返回的结构体随之变化）。
- 新增 `PRICE_FEED()`。
- `buyPrice()`：语义见上（报价过期时为 0，`sellMachine` / 交接会以 `PriceUnavailable()` 回滚）。其他接口不变。

### BoardFactory / MonthFactory（两个工厂相同）

| 签名 | 说明 |
|---|---|
| `admin()` | 手续费 Safe（月局工厂读 BoardFactory 的） |
| `boardImplementation()` | 当前模板（之后新开的局克隆它）。原来是 immutable，现在可以经时间锁更换 |
| `implementationOf(address board)` | 这块主板开局时用的模板 |
| `implementationHistory(uint256 i)` / `implementationCount()` | 历次生效的模板，第 0 个是部署时的 |
| `pendingImplementation()` / `pendingEta()` | 待生效的模板和最早生效时间（0 = 没有） |
| `proposeImplementation(bytes creationCode) → address` | 只有 admin；工厂用创建代码（含构造参数）部署新模板并公示 7 天 |
| `cancelImplementation()` | 只有 admin |
| `activateImplementation()` | 任何人，`[eta, eta + 7 天)` 内 |
| 常量 | `UPGRADE_DELAY()` = `UPGRADE_WINDOW()` = 7 天 |
| 事件 | `ImplementationProposed(address indexed impl, bytes32 codehash, uint256 eta)`、`ImplementationCancelled(address indexed impl)`、`ImplementationActivated(address indexed previous, address indexed impl, uint256 version)` |
| 错误 | `OnlyAdmin`、`NoPendingImplementation`、`TooEarly`、`ProposalExpired`、`DeployFailed`、`BadTemplate` |

`boardConfig()` 返回的是**部署时模板**的参数；之后换上的模板参数见提议交易里的构造参数。dApp 建议在加入页面显示 `implementationOf(board)`，机器人可以监听 `ImplementationProposed` 报警。

`setOperator` 的权限检查改成 `admin()`（同一个地址，行为不变）。


## 第 8 阶段（`v2.0-rc3`）：两种局按 Firsto 买一 / 卖一由合约公式买卖矿机；月局只收入场费

### 部署文件的键

- `monthPriceFeed` **改名为 `priceFeed`**（合约 `MarketPriceFeed`，两种局共用）。
- 新增 `stdSales`（`StdMachineSales`）。

### MarketPriceFeed（取代 MonthBuyPriceFeed）

| 签名 | 说明 |
|---|---|
| `post(uint256 bid, uint256 ask)` | **运营地址**每小时报 Firsto 买一 / 卖一（每单位权重的 BEM 最小单位）。`0 < bid ≤ ask`（`BadPrices`）；距上次 ≥ 50 分钟（`TooSoon`）；上一次没过期（< 3 小时）时 bid、ask 各自变动 ≤ ±5%（`ChangeTooLarge`，边界含），过期后第一次不限 |
| `bid()` / `ask()` / `updatedAt()` | 最近一次报价（`updatedAt == 0` = 从没报过） |
| `fresh()` | 报过、< 3 小时、运营地址非 0 |
| `abandoned()` | 从没报过、运营地址为 0、或 ≥ 7 天没更新（测试网随 `TIME_DIVISOR` 缩短） |
| `buyQuote(uint256 cap, uint256 curvePrice, uint256 since) → uint256` | 主板内部用：收购价 = `min(ask, bid × (1 + 0.5% × (h + 1)), cap)`（没有下限，规则决定 6.19），h = since 后的整小时；过期 → 0；没报过 / 运营地址 0 → curvePrice |
| `sellQuote(uint256 since) → uint256` | 卖价（每单位权重）= `max(bid, ask × (99% − 0.5% × h))`；报价无效 → 0 |
| 不可变参数 | `HUB()`、`maxChangeBps()` 500、`minInterval()` 3000 秒、`maxStaleness()` 10800 秒、`abandonAfter()` 604800 秒、`buyStepBps()` 50、`sellStartBps()` 9900、`sellStepBps()` 50 |
| 事件 | `PricesPosted(uint256 bid, uint256 ask, uint256 previousBid, uint256 previousAsk, uint256 time)` |
| 错误 | `NotOperator`、`BadPrices`、`TooSoon`、`ChangeTooLarge`、`BadConfig` |

**机器人**：每小时 `post(买一, 卖一)`（都折成每单位算力的 BEM 价，最好各取 3 个价的中位数）。发送前检查距上次 ≥ 50 分钟、各自变动 ≤ 5%（超过就分几次靠近，或等上一次过期）。主板的 `buyPrice()` 和卖矿合约的 `askPrice` 已经是最终价格，dApp / 机器人直接读。**不再有任何挂单操作。**

### TapeBoard

- 删除：`buyMachine(uint256,uint256)`、`sellPrice()`。终局买矿机走 `StdMachineSales.buyMachine`（买家授权 **StdMachineSales** 的 BEM）。
- 新增：`PRICE_FEED()`、`SALES()`、`releaseMachine(uint256 index, address to, uint256 weight, uint256 cost)`（只认 `SALES`）。
- `buyPrice()`：见上（h 从本轮收购 `buyRoundStart` 起算）。
- `Config`：在 `splitter` 后面加 `priceFeed`、`sales`；删 `sellDecayDuration`、`sellFloorHold`（移到 `StdMachineSales`）。`sellStartBps` 现在是"拍卖时报价无效的起价"。
- `MachineSold(index, circuitId, buyer, weight, cost)` 事件不变（由 `releaseMachine` 发出）。

### MonthBoard

- `buyPrice()`：见上（h 从开局 `startedAt` 起算）。
- 删除常量 `FOUNDATION_BPS()`、`FEE_BPS()`；开奖不再给基金会 / 手续费 Safe 转账。`PrizesDrawn(pot, slots, amounts, toFoundation, toFee)` 签名不变，后两个字段恒为 0，`pot` 全部开奖。

### MonthMachineSales

- 删除：`setListing`、`listPrice`、`AUTO_LIST_DELAY()`、事件 `MachineListed`。构造参数少了 `autoListDelay`。
- `askPrice(board, index)`（整台）：报价停运 → 成本价；报价有效 → `max(收购时权重 × sellQuote(settleStart), 成本价)`；过期 → 0（`buyMachine` 回滚 `NotForSale`）。清算计划生效后取 `min(正常价, planAsk)`，正常价暂停时按 `planAsk`。
- `buyMachine` / `relay` / `distribute` / `installPlan` / `planAsk` 不变。

### StdMachineSales（新单例，`stdSales`）

| 签名 | 说明 |
|---|---|
| `askPrice(address board, uint256 index) → (uint256 pricePerWeight, uint8 phase)` | phase 0 = 现在不能买（市价期报价无效 / 已卖出 / 不在终局），1 = 市价（前 30 天，`sellQuote(liquidationStart)`），2 = 拍卖 |
| `buyMachine(address board, uint256 index, uint256 maxPricePerWeight) → uint256 cost` | 任何人；cost = 计价权重 × 要价；拍卖期首次购买会先快照起价 |
| `startAuction(address board)` | 第 30 天起任何人：快照拍卖起价（报价有效 = 买一，否则采购均价 × 150%，不低于底价）；`NotYet` / 已开始则不重复 |
| `auctionStartPrice(address board)` | 0 = 还没开始拍卖 |
| 不可变参数 | `BEM()`、`HUB()`、`MARKET_PERIOD()` 30 天、`DECAY_DURATION()` 14 天、`FLOOR_HOLD()` 7 天（测试网随 `TIME_DIVISOR` 缩短） |
| 事件 | `AuctionStarted(address indexed board, uint256 startPricePerWeight, uint256 auctionStart)`、`MachineBought(address indexed board, uint256 indexed index, address indexed buyer, uint256 weight, uint256 cost)` |
| 错误 | `NotStandardBoard`、`WrongState`、`AlreadySold`、`NotForSale`、`NotYet`、`PriceAboveMaximum`、`BadConfig` |

**机器人**：标准局进入终局满 30 天时调用一次 `startAuction(board)`（用当时的买一做起价）。


## `v2.0-rc4`：月局奖金池一半按比例、一半抽奖；卖价每 6 小时降 0.5%

- `MonthBoard`：开奖时奖金池的 ⌈一半⌉ 按原始投入比例记给所有持仓（用 `owed(slot)` / `withdraw(slot)` 领取，和结算款同一个账），⌊一半⌋ 抽 5 个奖直接推送。`PrizesDrawn(prizePool, slots, amounts, 0, 0)`：`prizePool` 是整个奖金池，`amounts` 合计为抽奖的一半。接口不变。
- `MarketPriceFeed`：新增 `sellStepInterval()`（6 小时，测试网**不**随 `TIME_DIVISOR` 缩短，和每小时的真实报价一致）；`sellQuote(since)` = `max(bid, ask × (99% − 0.5% × 整 6 小时数))`。构造参数结构体多了 `sellStepInterval`。


## 第 9 阶段（`v2.0-rc5`）：FirstoTrader（在 Firsto 上自动买卖矿机）

### 部署文件的键

新增 `firstoTrader`、`firstoSwapper`，以及 `firstoAskExchange`、`firstoBidExchange`（主网是 Firsto 的真合约；测试网是 mock，调用格式相同）。

### 订单结构（`src/firsto/IFirsto.sol`）

```solidity
struct AskHeader { address maker; bytes32 merkleRoot; uint256 batchNonce; uint256 expiry; address payoutRecipient;
                   uint256 feeBps; uint256 feeEpoch; uint256 schemaVersion; }
struct AskLeaf   { address maker; address collection; uint256 tokenId; uint256 priceWei; address payoutRecipient;
                   uint256 feeBps; uint256 feeEpoch; uint256 batchNonce; uint256 leafIndex; uint256 schemaVersion; }
struct AskOrder  { AskHeader header; AskLeaf leaf; bytes32[] merkleProof; bytes signature; }
struct BidOrder  { uint256 orderId; uint256 dailyCapacityPriceWei; uint16 feeBps; uint256 minNetProceedsWei; }
```

`AskOrder` 的每个字段都直接取自 Firsto API `bestAsk.execution`（`header` 和 `leaf` 里 maker / batchNonce / feeBps / feeEpoch / schemaVersion / payoutRecipient 用同一组值；`leafIndex`、`merkleProof`、`signature` 原样）。`BidOrder` 取自 `/v1/circuit/capacity-bids`：`orderId`、`dailyCapacityPriceWei`、`feeBps`；`minNetProceedsWei` 由机器人按"日产能价 × 这台的预计日产出 ÷ 1e8 × 99%"再留一点余量算。

### FirstoTrader

| 签名 | 选择器 | 说明 |
|---|---|---|
| `buyFromAsk(address board, AskOrder o) → uint256 bemPaid` | 4db4e27e | 任何人。吃 Firsto 卖单把矿机卖给 board。主板照常检查收购期、资格、预算、100 台，并要求 实际花费（BEM）≤ 权重 × `buyPrice()`；兑换的 BEM ≤ TWAP × 1.02。返回主板实际付出的 BEM |
| `sellToBid(address board, uint256 index, BidOrder b, uint256 bemAdvance) → uint256 bemToBoard` | 8e71ce59 | 任何人。把 board 第 index 台卖给 Firsto 统一买单。`bemAdvance` ≥ 卖矿合约当前要价（月局：`MonthMachineSales.askPrice(board, index)`，整台；标准局：`StdMachineSales.askPrice` 的每单位价 × 计价权重），多借的原样回到主板。返回主板总共收到的 BEM（要价 + 卖价高出部分换成的 BEM） |
| `askCost(AskOrder o) → uint256` | b6e30d7c | 卖单的含费总价（BNB）= priceWei × (1 + feeBps / 10000)，等于 API 的 `buyerCostWei` |
| 常量 / 不可变参数 | | `BEM()`、`HUB()`、`ASK_EXCHANGE()`、`BID_EXCHANGE()`、`SWAPPER()`、`ORACLE()`、`POD()`、`CIRCUITS()`、`SLIPPAGE_BPS()` = 200、`ASK_BUY_SELECTOR()` = 0x20b36528、`BID_SELL_SELECTOR()` = 0x4c67242f |
| 事件 | | `BoughtFromFirsto(address indexed board, uint256 indexed tokenId, address indexed caller, address maker, uint256 bnbCost, uint256 bemPaid)`、`SoldToFirsto(address indexed board, uint256 indexed tokenId, address indexed caller, uint256 orderId, uint256 bnbNet, uint256 bemToBoard)` |
| 错误 | | `NotBoard`、`BadOrder`、`SlippageTooHigh`、`InsufficientProceeds`（买单到手的 BNB 不够还兑换）、`NotDelivered`、`FirstoCallFailed(bytes)`（Firsto 合约回滚，原因原样带出）、`NotSwapper`、`TransferFailed`；主板 / 卖矿合约自己的错误（如 `PriceBelowMinimum` = 超过公式价、`PriceUnavailable` = 报价过期、`MachineNotEligible`、`BuyRoundInactive`、`NotForSale`）原样冒泡 |

`onFlash` / `onERC721Received` 只供兑换适配器和 Firsto 卖单合约在操作进行中回调。

### 主板

- `TapeBoard` / `MonthBoard`：`Config` 加 `address trader`（在 `priceFeed` / `sales` 之后），新增 `TRADER()`。`sellMachine(circuitId, x)`：调用者是 `TRADER` 时 `x` = 实际总价（BEM），否则仍是最低单价。事件不变。

### 测试网（Firsto 不在测试网上）

- `firstoAskExchange` = `MockFirstoAskExchange`：买入函数和主网同一个选择器、同样的参数；**不校验签名和 Merkle 证明**，只检查 maker 仍持有并授权了它、没过期、没撤销、没成交过、正好付含费总价。挂单方式：矿机持有人对它 `setApprovalForAll`，机器人按主网字段组一张 `AskOrder`（`signature` 可以是空字节，`merkleProof` 空数组），然后调 `FirstoTrader.buyFromAsk`。撤单：`cancel(batchNonce)`。
- `firstoBidExchange` = `MockFirstoBidExchange`：卖出函数和主网同一个选择器、同样的参数；建买单 `createBid(uint256 dailyCapacityPriceWei, uint256 minH, uint256 maxH, address nftRecipient)`（附带 tBNB 预算，返回 `orderId`，大小范围按 PoD 权重，0 / 0 = 不限）；`grossFor(orderId, collection, tokenId)` 查毛价；`bid(orderId)`、`bidCount()`、`cancelBid(orderId)`。手续费 1%。
- `firstoSwapper` = `MockFirstoSwapper`：按测试网的 mock 预言机汇率兑换（另加 0.5%），BEM 直接铸造；部署时打进 0.005 tBNB 作为 BNB 流动性（`FIRSTO_SWAPPER_FUND` 可改）。

## `v2.0-rc6`：标准局持仓可转让（规则决定 6.23）、标准局入场费 2% 和月局卖矿溢价分成 10%（6.24）

### 持仓凭证 `monthPositions`（两种局共用）

- 构造参数 `(monthFactory, boardFactory)`；新增 `stdFactory()`。名字改为 "TapeSurge Position" / "TSP"，编号规则不变：`idOf(board, slot) = board << 96 | slot`，`boardOf(id)`、`slotOf(id)`。
- 标准局加入时也铸造给加入者。转让走标准 ERC-721（`transferFrom` / `safeTransferFrom` / 授权），每次都回调主板的 `onPositionTransfer`，不能转时整笔回滚（`TransferLocked`）。

### TapeBoard（标准局）

| 变化 | 说明 |
|---|---|
| `Config` 加 `address positions`（在 `trader` 之后），新增 `POSITIONS()` | 持仓凭证合集地址 |
| 删除 `socketOf(address)` | 改用 `holderCount(address)`（持有几份本局持仓）；按插槽查持有人用 `socket(slot).owner` 或持仓 NFT 的 `ownerOf` |
| `socket(slot)` 结构体末尾加 `uint32 version` | `Socket { address owner; uint96 stake; uint256 passId; uint128 potClaimed; bool ejected; bool refunded; bool passReturned; uint32 version; }`，`owner` = 当前持有人 |
| 新增 `transferable() → bool` | 开局且首轮收购结束（`now ≥ initialBuyEnd`）、没有等待中的开奖（`!drawPending`）的 `Active`，或 `Liquidating`；领取期限关闭后为 false |
| 新增 `tradeEpoch() → uint64` | 每次出局、进入终局 +1（盘口旧卖单失效） |
| 新增 `onPositionTransfer(slot, from, to)` | 只认持仓合集 |
| 新事件 `PositionTransferred(uint256 indexed slot, address indexed from, address indexed to, uint256 carriedOver)` | `carriedOver` = 终局阶段转让时结转给卖方的底池份额（记在 `credit[from]`） |
| 新错误 `TransferLocked()` | |
| `withdraw(address)` → `withdraw(uint256 slot)` | 把这份持仓的款项（招募失败的退款，或终局的底池份额）打给**当前持有人**；没有可领的 `NothingToWithdraw` |
| 新增 `withdrawCredit(address account)` | 地址上的记账款：基金会 / 手续费地址的份额、出局推送失败的 105%、转让时结转给卖方的份额。原来 `withdraw(FOUNDATION)` / `withdraw(FEE_RECIPIENT)` 改成它 |
| `returnPass(address)` → `returnPass(uint256 slot)` | 退给加入者 |
| `emergencyExit()` → `emergencyExit(uint256 slot)` | 调用者必须是这份未出局持仓的持有人 |
| 删除 `owed(address)`、`claimAll(address)`、`distribute(from, count)` | 挪到 `StdMachineSales`（见下） |
| 新增 `ENTRY_FEE_BPS()`（公开） | 标准局默认 200（2%） |
| 运营地址兜底（`pulse` / `retryDraw` 的参与者兜底） | 判断条件改为 `holderCount(msg.sender) > 0` |

### StdMachineSales（`stdSales`）

- 构造参数多了最后一个 `operatorGrace`（3 天，测试网随 `TIME_DIVISOR` 缩短），新增 `OPERATOR_GRACE()`。
- `owed(address board, uint256 slot) → uint256`：这份持仓当前可领（招募失败：本金 + 入场费；终局：底池份额 − 已领 / 已结转；不含地址记账款 `TapeBoard.credit(address)`，也不含还没 sweep 的新资金）。
- `claimAll(address board, uint256 slot)`：任何人，一次把这份持仓的款项、持有人名下的记账款打给持有人，能退的通行证退给加入者。
- `distribute(address board, uint256 fromSlot, uint256 count)`：运营地址；开局 / 终局 / 招募失败后 `operatorGrace` 内没执行，本局持仓的持有人也可以；错误 `NotAuthorized`、`WrongState`。原来的 `TapeBoard.distribute` 改成它（和月局的 `MonthMachineSales.distribute` 一样）。

### PositionExchange（`positionExchange`，两种局共用）

- 构造参数多了最后一个 `boardFactory`，新增 `STD_FACTORY()`。
- 标准局：开局 / 终局阶段（领取期限关闭前）可以挂卖单、买单；`tradable(board)` = `TapeBoard.transferable()`，只有这时能成交（首轮收购期间、开奖等待随机数期间不能）。出局或进入终局后 `tradeEpoch` 变化，此前的卖单全部失效，需要重挂；买单不受影响。报价单位（每 1 BEM 原始本金）、30 天有效期、托管、0 手续费、`book / asksOf / bidsOf / recentTrades` 都和月局一样。

### MonthBoard

- `Config` 加 `uint256 premiumFeeBps`（在 `entryFeeBps` 之后，默认 1000 = 10%，上限 5000），新增 `PREMIUM_FEE_BPS()`。
- 卖矿合约按要价卖出（`releaseMachine`）、交接（`relayOut`）时，成交额超过成本价的部分 × 10% 直接转给手续费地址，其余照旧按"本金 → 回馈 → 溢价"记账。≤ 成本价（含多数清算的计划价）不收。事件不变（`CapitalReturned` 的金额是扣费后的）。

### FirstoTrader

- `sellToBid` 卖给月局时，多出来的 BEM 先扣溢价分成给月局的手续费地址：新事件 `PremiumFeePaid(address indexed board, uint256 amount)`；`SoldToFirsto.bemToBoard` 是扣费后主板实际收到的。标准局不扣。

### 测试网脚本

- `bash script/testnet.sh firsto`：模拟 Firsto 市场（见 `deployments/README.md`）。测试网 mock 汇率 = 主网量级 × 100（`deployments/97-v2.json` 的 `bemPerBnb`）。
- 标准局分批发放改用 `StdMachineSales.distribute`，基金会 / 手续费地址的份额用 `withdrawCredit`。

## `v2.0-rc7`：标准局入场费恢复 1%，标准局也收卖矿溢价分成 10%（规则决定 6.25）

- 标准局 `entryFeeBps` 默认值改回 100（rc6 一节里的 200 作废）；月局不变。
- `StdMachineSales`：构造参数最后多一个 `premiumFeeBps`（默认 1000，上限 5000），新增 `PREMIUM_FEE_BPS()`、`machineCost(address board, uint256 index) → uint256`（本局平均每单位算力成本 × 这台收购时的算力）、事件 `PremiumFeePaid(address indexed board, uint256 indexed index, uint256 amount)`。正常终局（`settleMode = Normal`）卖出时，成交额超过 `machineCost` 的部分 × 10% 转给主板的手续费地址，其余进底池；不高于成本、保底 / VRF 安全退出结局不收。`buyMachine` 的返回值和 `MachineBought.cost` 仍是买家付的全额；`TapeBoard.MachineSold.cost` 是扣费后进底池的金额。
- `FirstoTrader.sellToBid` 卖标准局（正常终局）时，多出来的 BEM 按同样的成本口径扣分成（`PremiumFeePaid(board, amount)`）。
- `TapeBoard` 没有变化。

## `v2.0-rc8`：多来源自动买卖矿机、收所有工厂处理器的矿机（规则决定 6.26），PoD 字段改正

**这一版改了主板收矿入口、矿机结构和部署文件的键，机器人 / dApp 都要跟着改。**

### 部署文件的键

| 键 | 说明 |
|---|---|
| `marketTrader`（取代 `firstoTrader`） | `MarketTrader`：在 Firsto / TapeOut 官方矿机市场 / Seaport 上买矿机给主板，把主板矿机卖给 Firsto 统一买单 / Seaport 出价 |
| `machineLister`（新） | `MachineLister`：把主板矿机按公式价挂到官方矿机市场和 Seaport，随公式改价 |
| `machineRules`（新） | `MachineRules`：收哪些合集的矿机、按多少算力计价 |
| `officialMarket`、`seaport`（新，主网） | 主网 `0x6feEbbEbC07BcB90bd1Ac8b0CF9BaA4f0fF2B46f`、`0x0000000000000068F116a894984e2DB1123eB395`；测试网是 mock（见下） |
| `firstoSwapper`（不变） | 兑换适配器；`swapBnbForBem` 改为任何人可调（挂单模块结算时也用） |

### PoD 字段（机器人自己读 `getMiner` 筛矿机时必须改）

`getMiner(key)` 返回 22 个字：[2] 已验证任务号（0 = 在未验证池）、[3] 基础算力、[7] **处理器倍数**（官方 1、Behemoth 6）、[8] 开挖时间、[9] **状态**（1 = 在挖，3 = 已停）、[14] 最优加成、[19] **已验证池里分产出的权重** = (基础 + 加成) × 倍数（停挖 / 未验证池时为 0）、[20] 未验证池权重。rc7 以前当成"在挖"的 [7]、当成"已验证"的 [9] ≠ 0 都是错的。

合格 = 状态 1 且 [19] > 0、运行满 7 天；**计价算力 = min([3] × [7], [19])**（不含最优加成），10–300。tapeout.market API 的 `hashrate` = [19]（有最优加成时比计价算力大）。

### 主板（两种局相同）

| 变化 | 说明 |
|---|---|
| `sellMachine(uint256)`、`sellMachine(uint256, uint256)` → `sellMachine(address collection, uint256 circuitId, uint256 minPricePerWeight)`（e947a18d） | 多了合集参数；一个参数的重载删除。`MarketTrader` 调用时第三个参数仍是实际总价（BEM） |
| `machine(index)` 结构 | 标准局 `Machine { bytes32 key; uint256 circuitId; address collection; uint64 weight; bool active; bool sold; }`；月局 `Machine { bytes32 key; uint256 circuitId; address collection; uint64 weight; bool active; bool sold; uint128 cost; }`。`weight` 是收购时的计价算力 |
| `Config.machineCircuits` → `Config.machineRules`；删除 `MACHINE_CIRCUITS()`，新增 `MACHINE_RULES()` | 官方矿机电路合约地址改从 `MachineRules.REFERENCE_CIRCUITS()` 读 |
| 新增 `consign(uint256 index, address to)`（8e4e3c26） | 只认卖矿合约：把矿机转给挂单库寄售 |
| `releaseMachine(..., to, ...)` | `to = 0` 表示寄售的矿机已在市场成交交给买家，只记账 |
| 事件 `MachineBought` 末尾加 `address collection` | 标准局 `MachineBought(index, circuitId, seller, weight, price, paid, collection)`；月局 `MachineBought(index, circuitId, seller, weight, cost, collection)` |
| 错误 | 合集或资格不合格时回滚的是 `MachineRules.MachineNotEligible()`（选择器和原来的主板错误相同） |

### MachineRules（`machineRules`）

| 签名 | 说明 |
|---|---|
| `isMachineCollection(address) → bool` | 工厂 `isCPU` 为真，且运行时代码和官方矿机电路合约相同（同一个信标，升级哨兵覆盖得到）。主网 Behemoth `0x1F5Cb4aeaE1807Bf60c3b9C0D8aDBCC14e91f12C` 为真；创世通行证合集代码不同，为假 |
| `check(collection, circuitId, minWeight, maxWeight, minAge) → (bytes32 key, uint256 weight)` | 主板收购前调用；不合格回滚 `MachineNotEligible` |
| `live(key, collection, circuitId) → bool` | 标准局 `syncMachine` 用 |
| `POD()`、`TAPEOUT_FACTORY()`、`REFERENCE_CIRCUITS()`、`MACHINE_CODEHASH()` | |

### 卖矿合约（`stdSales`、`monthSales`）

- 构造参数最后多一个 `lister`，新增 `LISTER()`。
- 新增 `quote(address board, uint256 index) → uint256`（8f79306e）：现在买走这台要付的**整台**总价（BEM），0 = 现在不能买（月局 = `askPrice`；标准局 = 计价权重 × `askPrice` 的每单位价，和 `buyMachine` 同一个算法）。
- 新增 `consign(board, index, vault)`（只认挂单模块）。
- `buyMachine`：矿机寄售在挂单库时，普通买家（包括 `MarketTrader`）先自动撤单把矿机拿回主板再成交（多花约 10 万 gas）；`relay`（月局交接）同样先撤回。

### MarketTrader（`marketTrader`，取代 FirstoTrader）

| 签名 | 选择器 | 说明 |
|---|---|---|
| `buyFromAsk(address board, AskOrder o) → uint256` | 4db4e27e | 不变（Firsto 卖单）；合集不再限于官方矿机 |
| `buyFromOfficial(address board, uint256 listingId) → uint256` | e8c320c9 | 买 TapeOut 官方矿机市场的挂单（正好付挂单价，`listingView(listingId)` 的 price）。主板的检查同上 |
| `buyFromSeaport(address board, AdvancedOrder order) → uint256` | f5f85388 | 买 Seaport 卖单（tapeout.market `GET /api/v1/listings/<orderHash>` 的 `parameters` + `signature`；`numerator` / `denominator` 随便填，合约按 1/1）。只收"一台 ERC721 换原生币、金额不随时间变"的单；付款 = 全部对价项之和（含 1% 手续费项） |
| `sellToBid(address board, uint256 index, BidOrder b, uint256 bemAdvance) → uint256` | 8e71ce59 | 不变（Firsto 统一买单） |
| `sellToOffer(address board, uint256 index, AdvancedOrder offer, CriteriaResolver[] cr, uint256 bemAdvance) → uint256` | 214a6417 | 接受 Seaport 上的 WBNB 出价（offer 只能是 WBNB）；整合集出价用 `cr = [(0, 1, 0, 这台的编号, [])]`；出价单要卖方付的 WBNB 手续费项从收到的 WBNB 里付 |
| `askCost(AskOrder) → uint256` | b6e30d7c | 不变 |
| 不可变参数 | | `BEM`、`HUB`、`ASK_EXCHANGE`、`BID_EXCHANGE`、`OFFICIAL_MARKET`、`SEAPORT`、`WBNB`、`SWAPPER`、`ORACLE`、`POD`、`SLIPPAGE_BPS` = 200（`CIRCUITS()` 删除） |
| 事件 | | `BoughtMachine(address indexed board, address indexed collection, uint256 indexed tokenId, uint8 venue, address caller, uint256 bnbCost, uint256 bemPaid)`；`SoldMachine(address indexed board, uint256 indexed index, address indexed caller, uint8 venue, uint256 bnbNet, uint256 bemToBoard)`；`PremiumFeePaid(address indexed board, uint256 amount)`。venue：买入 1 Firsto / 2 官方市场 / 3 Seaport；卖出 1 Firsto 统一买单 / 3 Seaport 出价。（取代 `BoughtFromFirsto` / `SoldToFirsto`） |
| 错误 | | `FirstoCallFailed(bytes)` → `MarketCallFailed(bytes)`；其余同 rc7 |

Seaport 结构（`src/market/IMarkets.sol`，和 Seaport 1.6 相同，枚举按 uint8）：`AdvancedOrder { OrderParameters parameters; uint120 numerator; uint120 denominator; bytes signature; bytes extraData; }`，`OrderParameters { offerer, zone, OfferItem[] offer, ConsiderationItem[] consideration, uint8 orderType, startTime, endTime, zoneHash, salt, conduitKey, totalOriginalConsiderationItems }`，`CriteriaResolver { orderIndex, uint8 side, index, identifier, bytes32[] criteriaProof }`。

### MachineLister（`machineLister`）

| 签名 | 选择器 | 说明 |
|---|---|---|
| `list(address board, uint256 index)` | 77c6212b | 任何人。卖矿合约 `quote > 0` 时，把矿机寄售到它的挂单库（`vaultOf`），同时挂到官方市场（`list`）和 Seaport（链上 `validate`，不用签名）。一边挂不上不影响另一边；两边都挂不上整笔回滚 |
| `reprice(address board, uint256 index)` | 9f14ba0b | 任何人。按最新公式价改价：新价和现价相差 ≥ 0.5%、或 Seaport 单 1 天内到期、或官方市场那边没挂上时才改，否则 `NoChange`。官方市场 `setPrice`；Seaport 撤旧单（`cancel`）挂新单（salt + 1，**订单哈希会变**） |
| `recall(address board, uint256 index)` | 1f035c7a | 撤掉两边的单、矿机和挂单库里的产出还给主板。卖矿合约随时；其他人只能在 `quote = 0`（报价过期等现在不能卖）时，否则 `NotAuthorized` |
| `prices(address board, uint256 index) → (bemQuote, net, official, seaportFee)` | bbc492c0 | 按现在的要价算出的挂单价：`net` = 挂单库每笔应收的 BNB = ⌈要价 ÷ TWAP⌉ ÷ 98%；`official` = 官方市场挂单价 = `net` ÷ (1 − 市场手续费 1%)；`seaportFee` = `net` × 1% |
| `vaultOf(address board, uint256 index) → address` | fd7c75fc | 这台矿机的挂单库地址（固定，`list` 时创建） |
| `listings(address vault) → (board, index, approved, net, officialId, officialPrice, salt, seaportStart, seaportEnd, seaportFee)` | 65d96c82 | 当前挂单；`officialId = 0` / `seaportEnd = 0` 表示那边没挂 |
| 不可变参数 | | `BEM`、`HUB`、`SWAPPER`、`ORACLE`、`OFFICIAL_MARKET`、`SEAPORT`、`SEAPORT_FEE_RECIPIENT`（主网 `0xf0972A5ee0FD4054159A8c7177e59126ef478dA9`）、`SEAPORT_FEE_BPS` = 100、`SLIPPAGE_BPS` = 200、`REPRICE_BPS` = 50、`LISTING_DURATION` = 30 天、`VAULT_IMPL` |
| 事件 | | `Listed(address indexed board, uint256 indexed index, address indexed vault, uint256 bemQuote, uint256 net)`；`OfficialListed(address indexed vault, uint256 listingId, uint256 price)`；`SeaportListed(address indexed vault, uint256 salt, uint256 startTime, uint256 endTime, uint256 net, uint256 fee)`；`Recalled(board, index, vault)`；`Sold(address indexed board, uint256 indexed index, address indexed vault, uint256 bnbIn, uint256 bemOut, uint256 paid)`；`PremiumFeePaid(board, amount)` |
| 错误 | | `NotBoard`、`NotOurSales`、`AlreadyListed`、`NotListed`、`NotForSale`、`NoChange`、`NotAuthorized`、`ListingFailed`、`NotSold`、`NotVault`、`BelowFormula(uint256 got, uint256 price)`（成交那一刻换出的 BEM 低于要价：买家的成交整笔回滚，需要 `reprice`） |

**Seaport 挂单的完整订单**（机器人提交给 tapeout.market 时按这个组；订单在链上已 validate，`signature` 用空字节）：
`offerer = vault`、`zone = 0`、`offer = [(2, 合集, 编号, 1, 1)]`、`consideration = [(0, 0, 0, net, net, vault), (0, 0, 0, fee, fee, 0xf0972A5e…8dA9)]`（`fee = 0` 时只有第一项）、`orderType = 0`、`startTime` / `endTime` / `salt` 取 `SeaportListed` 事件、`zoneHash = 0`、`conduitKey = 0`、`counter = 0`、`totalOriginalConsiderationItems = 2`。

**成交**：买家在官方市场 `buy` 或在 Seaport 成交时，卖款推给挂单库，挂单库在同一笔交易里交给 `MachineLister` 结算（换 BEM、按成交那一刻的要价经卖矿合约记账、多出的扣溢价分成后转主板）。买家的 gas 约多 40–50 万。结算不过（要价涨了、兑换比 TWAP 差 2% 以上、报价过期、哨兵冷静期）时买家的交易回滚。

### 测试网

测试网没有官方矿机市场，`officialMarket` = `MockOfficialMarket`（`list` / `setPrice` / `delist` / `delistStale` / `buy` / `listingView` / `feeBps`，行为按主网实测：只有持有人能挂、正好付价、卖款带全部 gas 推给卖方、回滚则整笔回滚）；`seaport` = `MockSeaport`（只支持 offerer 本人 `validate` / `cancel`、`fulfillAdvancedOrder` 整单成交，没有签名）。`MockTapeOutFactory.registerCPU(address)` 把模拟矿机合集登记成工厂处理器。部署顺序：`MarketTrader`（n + 12）→ `MachineRules` → `MockOfficialMarket` → `MockSeaport` → `MachineLister`（n + 16）。

## `v2.0-rc9`：卖矿机在各平台保持排序第一（规则决定 6.29），TapeCode 预审第 17、18 条

### MarketPriceFeed（`priceFeed`）

| 函数 / 事件 | 说明 |
|---|---|
| `postFloor(uint256 price)` | 只有运营地址。"保持排序第一"的目标价：**每单位权重、主板净得的 BEM（8 位小数）**；0 = 撤销。不限频率、不限幅度 |
| `floorQuote() → uint256` | 当前有效的目标价；没报过、已撤销、超过 3 小时没更新、运营地址为 0 时为 0 |
| `floorPrice()`、`floorAt()` | 最近一次报的价和时间 |
| 事件 `FloorPosted(uint256 price, uint256 time)` | |

卖矿合约只在 **[这台的买入成本, 原公式价]** 之间采用目标价：月局 = `floorQuote() × 收购时权重 ≥ cost` 时取较小者；标准局 = `floorQuote() × 计价权重 ≥ StdMachineSales.machineCost(board, index)` 时取较小者（市价期和拍卖期都适用）。主板直接购买价（`askPrice` / `quote` / `buyMachine`）和挂单模块的挂单价都用同一个结果。

**机器人怎么算 `postFloor` 的值**（每 5 分钟一次）：
1. 在所有平台的同类挂单（已验证、在挖、算力 10–300、工厂处理器的矿机；Firsto、官方市场、Seaport）里取买家实付的最低日产能价 `D`（BNB wei / 每天 1 BEM 产出，= 买家实付 × 1e8 ÷ 预计日产出；tapeout.market 的 `capacityPriceWei`、Firsto 的 `listingReference.dailyCapacityPriceWei` 都是这个口径），自己挂的单除外。
2. 目标买家实付日产能价 = `D × 0.999`。
3. 折回主板净得：挂单模块的买家实付最高是官方市场那边（`净价 ÷ 99%`；Seaport 是 `净价 × 101%`），而 `净价 = ⌈BEM 要价 ÷ TWAP⌉ ÷ 98%`。所以
   `floorPrice = D × 0.999 × 0.99 × 0.98 × u × R ÷ 1e26`（向下取整），
   其中 `u` = 每单位权重的预计日产出（BEM 8 位小数，= 任一同类矿机的预计日产出 ÷ 它的计价算力；也可以直接算 `PoD.currentRate() × 86400 × 99% ÷ PoD.totalVerifWeight()`，和主板收购价上限同一口径），`R` = `oracle.quoteBemOut(1e18)`（1 BNB 按 TWAP 换多少 BEM，8 位小数）。权重会约掉，所以一个值适用于所有矿机。
4. 算出来的值即使低于某台的成本也照常报：低于成本的那台合约自动不追。最低价本来就是自己的挂单时可以不报（或报 0 撤销）。
5. 报完对每台挂着的矿机调 `MachineLister.reprice(board, index)`：价格变了且离上次改价满 30 分钟才会改（`NoChange` 表示还不能改），涨价 ≥ 0.5% 随时可改。

### MachineLister（`machineLister`）

- 构造参数在 `repriceBps` 之后多了 `repriceInterval`（30 分钟，主网 / 测试网相同），新增 `REPRICE_INTERVAL()`；`Listing` 结构体在 `approved` 之后多了 `uint64 lastPriced`。
- `reprice(board, index)`：任何人；改价条件见上。其余（`list` / `recall` / `prices` / `vaultOf` / `pullOfficialProceeds`）不变。

### StdMachineSales

- 新错误 `PaymentMismatch()`：`buyMachine` 实际到账额不等于要价时回滚（TapeCode 预审第 17 条，和月局一致）。
- `askPrice` / `quote` / `buyMachine` 的结果都带上目标价（见上）。

### 测试网

- 部署记录新增 `wbnb`（`MockWBNB`，Seaport 出价用；`MarketTrader` 的 WBNB 指向它）和 `behemoth`（第二个模拟矿机合集，工厂处理器，PoD 处理器倍数 6）。
- `bash script/testnet.sh markets`：模拟 tapeout.market 的两个来源，输出 `deployments/97-v2-tape-feed.json`、`97-v2-tape-listings.json`、`97-v2-seaport-offers.json`（格式同主网接口），见 `deployments/README.md`。

## `v2.0-rc10`：挂单模块的第三个平台 Firsto 单笔签名卖单 V2（规则决定 6.30）

### MachineLister（`machineLister`）

- 构造参数 `Markets` 结构体末尾多了 `address firstoSignedAsk`（主网 `0x33423244F9a5bF81b12B1a018aF6F4e079B97f29`；0 = 不挂 Firsto），新增 `FIRSTO()`。
- `list(board, index)` / `reprice(board, index)` 同时在 Firsto 挂单：挂单库 `approve(V2, tokenId)`，每次挂单 / 改价用新 nonce；改价时先 `cancelSignedAskNonce(旧 nonce)`。改价条件多了一条：Firsto 单 1 天内到期。三个平台任何一个挂不上都不影响其他两个（全都挂不上 `list` 才回滚 `ListingFailed`）。
- 订单字段：`maker` = `payoutRecipient` = 挂单库（`vaultOf(board, index)`），`collection` / `tokenId` = 这台矿机，`price` = `prices()` 的 `net`（BNB wei，卖方到手；买方另付 1%），`expiry` = 挂单时间 + 30 天，`feeBps` / `feeEpoch` / `schemaVersion` 读自 V2（现在 100 / 1 / 2）。
- **机器人提交用**：
  - 事件 `FirstoListed(address indexed vault, SignedAsk ask, bytes32 digest)`；
  - 或 view `firstoAsk(address board, uint256 index) → (SignedAsk ask, bytes32 digest)`（`digest = 0` 表示现在没挂）；
  - `digest` 就是 Firsto 的 `askHash`。提交 `POST /v1/circuit-asks`：`{"envelope": {"domain": {"name": "Firsto Circuit Signed Ask", "version": "2", "chainId": 56, "verifyingContract": "0x3342…7f29"}, "primaryType": "SignedAsk", "message": ask（整数字段用十进制字符串）, "signature": "0x01"}}`。签名内容不被检查（挂单库的 `isValidSignature` 只认摘要），填任意非空字节即可。测试网的 `chainId` 是 97，`verifyingContract` 是 `firstoSignedAsk`。
  - 改价后要提交新单（新 nonce、新摘要）；旧单在链上已经撤销，接口那边会显示无效。
- `listings(vault)` 返回的 `Listing` 结构体末尾多了 `firstoDigest`、`firstoNonce`、`firstoPrice`、`firstoExpiry`、`firstoFeeBps`、`firstoSchema`、`firstoFeeEpoch`；`firstoDigestOf(vault)` 只返回摘要。
- 成交：买家在 Firsto 上 `fillSignedAsk(ask, signature, nftRecipient)`，付 `price × 1.01`；卖款推给挂单库，同一笔交易里按成交那一刻的公式价结算（不够整笔回滚），其他两个平台的单撤掉，事件 `Sold`。

### ListingVault

- 新增 `isValidSignature(bytes32 hash, bytes) → bytes4`：`hash` 等于挂单模块登记的当前 Firsto 单摘要时返回 `0x1626ba7e`，否则 `0xffffffff`。

### 测试网

- 部署记录新增 `firstoSignedAsk`（`MockFirstoSignedAsk`：函数和主网相同；行为按主网实测——合约卖家走 `isValidSignature`、只认按编号授权、先交货后推款并转发全部 gas、nonce 用过或撤销后失效）。

## `v2.0-audit.1`：标准局市价期底价（规则决定 6.31）

- `StdMachineSales.askPrice` / `quote` / `buyMachine`：市价期（阶段 1）的每单位价格不低于主板的 `sellFloorPrice()`。接口和事件不变。

## `v2.0-audit.2`：第三方预审修复（规则决定 6.33）

- `MarketPriceFeed.post`：任何时候 ±5%（上一次过期也一样，超了回滚 `ChangeTooLarge`）。`abandoned()` 只看时间（从没报过或 ≥ 7 天没报价）；运营地址为 0 时 `fresh()` 为假。`buyQuote`：停运 → `curvePrice`；过期 / 运营地址 0 → 0。
- `MonthMachineSales.askPrice` / `quote` / `buyMachine`：目标价按 `max(目标价, 正常价 × 95%)`；清算计划价只在 `fresh()` 时生效，且不低于 `bid × 收购时权重 × 95%`。`StdMachineSales` 目标价同样最多比公式价低 5%。
- `MonthExitGovernor.publishPlan`：每台 `start ≥ machine(i).cost`，否则 `BadPlan`。
- `TapeBoard.emergencyExit(slot)`、`MonthBoard.emergencySettle()`：只在 `sentinelPaused()`（冷静期内）时可用，否则 `SentinelNotTripped`。
- `TapeBoard.onRandomness` / `MonthBoard.onRandomness`：接受本次开奖发出的任何请求编号（`pendingRequestId` 仍是最近一次请求，供查询）。
- `PositionExchange.sellToBid`：标准局已出局的持仓回滚，新错误 `PositionEjected()`。
- `MachineLister.onProceeds`：矿机已在主板时回滚 `NotSold`。
- 机器人：报价每次最多 5%，任何时候都分步追（`bot/src/tasks/pricefeed.js` `nextPost`）。

## `v2.0-audit.3`：追价模式（复核 N-1，规则决定 6.34）

- `MarketPriceFeed.postCatchUp(uint256 bid, uint256 ask)`：只有运营地址；检查同 `post`（0 < bid ≤ ask、间隔 ≥ 50 分钟、每次 ±5%）。新状态 `catchingUp()`（最近一次是追价时为 true），新事件 `CatchUpPosted(uint256 bid, uint256 ask, uint256 time)`（同时发 `PricesPosted`）。
- `fresh()` 在 `catchingUp` 时为假：收购价为 0、两个卖矿合约暂停出售（不按成本价兜底，因为 `abandoned()` 只看最后一次报价的时间）。`post` 恢复有效。
- 机器人：没追到目标的步用 `postCatchUp`，到达目标的那一步用 `post`；ABI 里没有 `postCatchUp` 的旧部署一律用 `post`。

## `v2.0-audit.4`：停运按最后一次有效报价（第二次复核 N-2，规则决定 6.35）

- `MarketPriceFeed.liveAt()`：最后一次有效报价（`post`，或第一次报价）的时间。`abandoned() = updatedAt == 0 || now ≥ liveAt + abandonAfter`；`postCatchUp` 不刷新 `liveAt`。

## `v2.0-audit.5`：停运后暂停收购、开局前必须报过价（全局审计 G-1，规则决定 6.36）

- `MarketPriceFeed.buyQuote(cap, curvePrice, since)`：`updatedAt == 0` → `curvePrice`；否则 `!fresh()` → 0（过期、追价、运营地址为 0、停运都暂停收购）。卖价接口不变。
- `IMarketPriceFeed` 增加 `updatedAt()`（合约本来就有这个公开变量）。
- `BoardFactory.startGenesis()`：报价合约从没报过价时回滚新错误 `FeedNotPosted()`（检查顺序：开局条件 → 升级哨兵 → 报价）。前端把它显示为"机器人还没报第一次价"。

## `v2.0-audit.6`：收购只经 MarketTrader、签名卖单买入、月局提前开挖（规则决定 6.37）

- `MarketPriceFeed.buyQuote(cap, curvePrice, uint256)`：报价有效 → `min(ask, cap)`；第三个参数不再使用（接口不变）。`buyStepBps` 保留但不再使用。
- `TapeBoard.sellMachine(collection, circuitId, spent)`：只认 `TRADER`（否则 `NotAuthorized`）；`spent` = MarketTrader 的实际花费，须 ≤ 计价算力 × `buyPrice()`（否则 `PriceAboveMaximum`）。删除错误 `PriceBelowMinimum`。
- `MonthBoard.sellMachine(collection, circuitId, x)`：只认 `TRADER`（x = 实际花费）和同一工厂的月局（交接，x = 最低单价）；成交后调用 `_sync`，买满就开始挖矿（`prepEnd` 改成当下）。
- `MarketTrader`：`Markets` 结构增加 `signedAsk`；新增 `SIGNED_ASK()`、`buyFromSignedAsk(board, SignedAsk, signature)`、错误 `NotOperator`；四个买入函数只认 `HUB.operator()`。卖出函数不变。
- `StdMachineSales.buyMachine` / `SaleSettlement`：卖矿溢价 10% 在所有结局都收。`TapeBoard` 保底结局 `credit[FEE_RECIPIENT]` 每笔加 2%。


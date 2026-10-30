// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {IBoardHub} from "../interfaces/ITapeBoard.sol";
import {IBemPriceOracle} from "../interfaces/ISwap.sol";
import {IFirstoSwapper} from "../firsto/IFirsto.sol";
import {IMachineLister, IMachineSales} from "../interfaces/IMachineLister.sol";
import {
    IOfficialMarket,
    ISeaport,
    Order,
    OrderParameters,
    OrderComponents,
    OfferItem,
    ConsiderationItem
} from "./IMarkets.sol";
import {SaleSettlement} from "./SaleSettlement.sol";
import {SignedAsk, IFirstoSignedAsk, FirstoSignedAskLib} from "./FirstoSignedAsk.sol";

/// @title ListingVault（挂单库：每台寄售矿机一个，EIP-1167 最小代理）
/// @notice 只替 MachineLister 持有一台矿机、在 TapeOut 官方矿机市场 / Seaport / Firsto 签名卖单 V2 当卖方。三个市场都是
///         成交时把卖款（带全部 gas）推给卖方，推款时矿机已经交给买家；挂单库收到 BNB 就交给 MachineLister 结算，结算不过
///         （低于成交那一刻的公式价）就回滚，整笔成交随之回滚（MARKET-PROBE.md 第 2、3 节、FIRSTO-PROBE.md 第 7 节实测）。
///         Firsto 卖单的签名走 EIP-1271：isValidSignature 只认 MachineLister 为这个挂单库登记的当前那张单的摘要。
contract ListingVault {
    address public immutable LISTER;

    error NotLister();

    constructor() {
        LISTER = msg.sender;
    }

    /// @notice 只认 MachineLister：替它调用市场 / 矿机合约 / BEM
    function exec(address target, bytes calldata data) external returns (bytes memory ret) {
        if (msg.sender != LISTER) revert NotLister();
        bool ok;
        (ok, ret) = target.call(data);
        if (!ok) {
            assembly {
                revert(add(ret, 32), mload(ret))
            }
        }
    }

    /// @notice EIP-1271（Firsto 签名卖单 V2 验签，给 10 万 gas）：摘要等于 MachineLister 登记的当前 Firsto 单
    ///         （登记时价格 = 当时的挂单价；改价、成交、撤单时旧摘要立即作废）才返回 0x1626ba7e；签名字节不看
    function isValidSignature(bytes32 hash, bytes calldata) external view returns (bytes4) {
        bytes32 d = MachineLister(payable(LISTER)).firstoDigestOf(address(this));
        return d != bytes32(0) && d == hash ? bytes4(0x1626ba7e) : bytes4(0xffffffff);
    }

    /// @notice 卖款：全部交给 MachineLister 结算（它会核对矿机确实已经被买走、价格不低于公式价，否则回滚）。
    ///         msg.sender（推款的市场）一并告诉它：成交的那一边不用再撤单。
    receive() external payable {
        MachineLister(payable(LISTER)).onProceeds{value: msg.value}(msg.sender);
    }
}

/// @title MachineLister（把主板的矿机按公式价挂到 TapeOut 官方矿机市场 / Seaport / Firsto，单例；规则决定 6.26、6.30）
/// @notice 任何人都可以调用（F-2 a），机器人是主力：
///         - list：把一台现在可以按公式价卖的矿机（标准局终局、月局结算阶段，卖矿合约 quote > 0）经卖矿合约寄售到它自己的
///           挂单库（每台矿机一个，地址固定），同时挂到官方市场（链上 list）和 Seaport（链上 validate，带 tapeout.market 的
///           1% 买方手续费项）。寄售期间账上仍是主板的矿机，继续挖，产出领到挂单库，结算 / 撤单时转回主板。
///         - reprice：公式价变了（变化 ≥ 0.5%）或 Seaport 单快到期时，按最新公式价改价（官方市场 setPrice；Seaport 撤旧单挂新单）。
///         - recall：撤掉两边的挂单，把矿机和产出还给主板。卖矿合约随时可调（有人按公式价直接向主板买、或月局交接时，
///           先拿回矿机，F-3 a 公式价成交照常开着）；其他人只能在这台矿机现在不能卖时调用。
///         - 成交（onProceeds，由挂单库在收到卖款时调用）：核对矿机已被买走 → 挂单库里的产出转回主板 → BNB 按 TWAP − 2% 以上
///           换成 BEM（F-4 a）→ 按成交这一刻的要价经卖矿合约记账（主板交割时 to = 0，只记账）→ 换出的 BEM 必须 ≥ 要价，
///           否则整笔回滚（买家的成交也回滚）→ 多出的部分扣溢价分成后转给主板。
///         挂单价 = 要价按 TWAP 折成 BNB ÷ (1 − 2%)（保证兑换不差过 F-4 的上限时主板至少拿到要价），官方市场再 ÷ (1 − 市场手续费)
///         （手续费从卖方扣），Seaport 另加 1% 买方手续费项，Firsto 签名卖单的 price = 同一个净价（买方另付 Firsto 的 1%）。
///         Firsto（规则决定 6.30）：挂单库 approve(V2, tokenId)，每次挂单 / 改价用新 nonce 登记这张单的 EIP-712 摘要
///         （事件 FirstoListed / firstoAsk 给出机器人提交 envelope 要的全部字段），改价先 cancelSignedAskNonce 旧 nonce；
///         任何一个平台挂不上都不影响其他平台。价格规则、维护费、F-2 / F-3 / F-4 都和 MarketTrader 相同。
///         没有管理员，不可升级。
contract MachineLister is SaleSettlement, ReentrancyGuard, IMachineLister {
    using SafeERC20 for IERC20;

    IBoardHub public immutable HUB;
    IFirstoSwapper public immutable SWAPPER;
    IBemPriceOracle public immutable ORACLE;
    IOfficialMarket public immutable OFFICIAL_MARKET;
    ISeaport public immutable SEAPORT;
    /// @notice Firsto 单笔签名卖单 V2（0 = 不挂 Firsto）
    IFirstoSignedAsk public immutable FIRSTO;
    /// @notice Seaport 单里的买方手续费项（tapeout.market：1% 给 0xf0972A5e…8dA9；0 = 不加）
    address payable public immutable SEAPORT_FEE_RECIPIENT;
    uint256 public immutable SEAPORT_FEE_BPS;
    uint256 public immutable SLIPPAGE_BPS;
    /// @notice 改价节奏（规则决定 6.29：每台最多 30 分钟改一次）：价格变了、离上次改价满 REPRICE_INTERVAL 才改；
    ///         涨幅 ≥ REPRICE_BPS 时随时可改（挂单价低于成交时的公式价会让买家成交回滚，要尽快跟上）。
    ///         防止有人反复撤单挂单让 tapeout.market 的索引失效。
    uint256 public immutable REPRICE_BPS;
    uint256 public immutable REPRICE_INTERVAL;
    /// @notice Seaport 单的有效期（到期前 1 天起可以续挂）
    uint256 public immutable LISTING_DURATION;
    address public immutable VAULT_IMPL;

    struct Listing {
        address board;
        uint64 index;
        bool approved; // 挂单库已授权两个市场
        uint64 lastPriced; // 上次挂单 / 改价的时间
        uint256 net; // 挂单库每成交一笔应收的 BNB（Seaport 的卖方对价；官方市场挂单价 × (1 − 手续费)）
        uint256 officialId; // 官方市场挂单号（0 = 没挂）
        uint256 officialPrice;
        uint256 salt; // Seaport 单的 salt（每次挂新单 +1）
        uint256 seaportStart; // 当前 Seaport 单的开始 / 结束时间（0 = 没挂）
        uint256 seaportEnd;
        uint256 seaportFee; // 当前 Seaport 单的手续费项金额
        // Firsto 签名卖单（maker = payoutRecipient = 挂单库）
        bytes32 firstoDigest; // 当前那张单的 EIP-712 摘要（0 = 没挂；挂单库的 isValidSignature 只认它）
        uint256 firstoNonce; // 当前 / 上一张单的 nonce（每次挂新单 +1）
        uint128 firstoPrice;
        uint64 firstoExpiry;
        uint16 firstoFeeBps;
        uint16 firstoSchema;
        uint256 firstoFeeEpoch;
    }

    /// @dev 挂单库 → 它寄售的矿机和当前挂单
    mapping(address => Listing) internal _listings;

    event Listed(address indexed board, uint256 indexed index, address indexed vault, uint256 bemQuote, uint256 net);
    event OfficialListed(address indexed vault, uint256 listingId, uint256 price);
    /// @notice Seaport 单的全部可变字段（其余：offerer = vault，zone 0，FULL_OPEN，conduitKey 0，counter 0；
    ///         offer = 这台矿机；对价 = [net 原生币给 vault, fee 原生币给 SEAPORT_FEE_RECIPIENT（fee 为 0 时没有这一项）]）
    event SeaportListed(
        address indexed vault, uint256 salt, uint256 startTime, uint256 endTime, uint256 net, uint256 fee
    );
    /// @notice Firsto 签名卖单：机器人按 ask 组 envelope（domain = "Firsto Circuit Signed Ask" / "2" / chainId / FIRSTO）
    ///         提交 POST /v1/circuit-asks，签名字段填任意非空字节（例如 0x01）；digest = askHash
    event FirstoListed(address indexed vault, SignedAsk ask, bytes32 digest);
    event Recalled(address indexed board, uint256 indexed index, address indexed vault);
    event Sold(
        address indexed board, uint256 indexed index, address indexed vault, uint256 bnbIn, uint256 bemOut, uint256 paid
    );

    error BadConfig();
    error NotBoard();
    error NotOurSales();
    error AlreadyListed();
    error NotListed();
    error NotForSale();
    error NoChange();
    error NotSold();
    error NotVault();
    error NotAuthorized();
    error BelowFormula(uint256 got, uint256 price);
    error ListingFailed();

    struct Markets {
        address officialMarket;
        address seaport;
        address payable seaportFeeRecipient;
        uint256 seaportFeeBps;
        address firstoSignedAsk; // 0 = 不挂 Firsto
    }

    constructor(
        address bem,
        address hub,
        Markets memory mk,
        address swapper,
        address oracle,
        uint256 slippageBps,
        uint256 repriceBps,
        uint256 repriceInterval,
        uint256 listingDuration
    ) SaleSettlement(bem) {
        if (
            bem == address(0) || hub == address(0) || mk.officialMarket == address(0) || mk.seaport == address(0)
                || swapper == address(0) || oracle == address(0) || slippageBps == 0 || slippageBps >= BPS
                || mk.seaportFeeBps > 1_000 || (mk.seaportFeeBps > 0 && mk.seaportFeeRecipient == address(0))
                || repriceBps >= BPS || repriceInterval > 1 days || listingDuration < 2 days || listingDuration > 365 days
        ) revert BadConfig();
        HUB = IBoardHub(hub);
        SWAPPER = IFirstoSwapper(swapper);
        ORACLE = IBemPriceOracle(oracle);
        OFFICIAL_MARKET = IOfficialMarket(mk.officialMarket);
        SEAPORT = ISeaport(mk.seaport);
        FIRSTO = IFirstoSignedAsk(mk.firstoSignedAsk);
        SEAPORT_FEE_RECIPIENT = mk.seaportFeeRecipient;
        SEAPORT_FEE_BPS = mk.seaportFeeBps;
        SLIPPAGE_BPS = slippageBps;
        REPRICE_BPS = repriceBps;
        REPRICE_INTERVAL = repriceInterval;
        LISTING_DURATION = listingDuration;
        VAULT_IMPL = address(new ListingVault());
    }

    // ============ 读取 ============

    /// @notice 挂单库 → 它寄售的矿机和当前挂单（三个平台）
    function listings(address vault) external view returns (Listing memory) {
        return _listings[vault];
    }

    /// @notice 挂单库现在有效的 Firsto 单的摘要（0 = 没有）；挂单库的 isValidSignature 用
    function firstoDigestOf(address vault) external view returns (bytes32) {
        return _listings[vault].firstoDigest;
    }

    /// @notice board 第 index 台矿机现在挂在 Firsto 上的那张签名卖单和它的摘要（askHash）；digest = 0 表示没挂
    function firstoAsk(address board, uint256 index) external view returns (SignedAsk memory ask, bytes32 digest) {
        address vault = vaultOf(board, index);
        Listing storage l = _listings[vault];
        digest = l.firstoDigest;
        if (digest == bytes32(0)) return (ask, digest);
        (address collection, uint256 id) = _machineOf(board, index);
        ask = _firstoAskOf(vault, l, collection, id);
    }

    /// @notice 第 index 台矿机的挂单库地址（固定，第一次挂单时创建）
    function vaultOf(address board, uint256 index) public view returns (address) {
        return Clones.predictDeterministicAddress(VAULT_IMPL, _salt(board, index));
    }

    /// @notice 按现在的要价算出的挂单价：net = 挂单库每笔应收的 BNB，official = 官方市场挂单价，seaportFee = Seaport 手续费项。
    ///         bemQuote = 0 表示现在不能卖。
    function prices(address board, uint256 index)
        public
        view
        returns (uint256 bemQuote, uint256 net, uint256 official, uint256 seaportFee)
    {
        bemQuote = IMachineSales(_sales(board)).quote(board, index);
        if (bemQuote == 0) return (0, 0, 0, 0);
        uint256 rate = ORACLE.quoteBemOut(1 ether); // 1 BNB 按 TWAP 换多少 BEM
        if (rate == 0) return (0, 0, 0, 0);
        net = _ceilDiv(_ceilDiv(bemQuote * 1 ether, rate) * BPS, BPS - SLIPPAGE_BPS);
        official = _ceilDiv(net * BPS, BPS - OFFICIAL_MARKET.feeBps());
        seaportFee = net * SEAPORT_FEE_BPS / BPS;
    }

    // ============ 挂单 / 改价 / 撤单 ============

    /// @notice 把 board 第 index 台矿机寄售到挂单库，按公式价挂到官方市场和 Seaport。任何人可调。
    function list(address board, uint256 index) external nonReentrant {
        address sales = _sales(board);
        if (IMachineSales(sales).LISTER() != address(this)) revert NotOurSales();
        (address collection, uint256 id) = _machineOf(board, index);
        address vault = vaultOf(board, index);
        if (vault.code.length == 0) Clones.cloneDeterministic(VAULT_IMPL, _salt(board, index));
        Listing storage l = _listings[vault];
        if (l.board == address(0)) {
            l.board = board;
            // forge-lint: disable-next-line(unsafe-typecast)
            l.index = uint64(index);
        }
        if (IERC721(collection).ownerOf(id) == vault) revert AlreadyListed();
        (uint256 bemQuote, uint256 net, uint256 official, uint256 fee) = prices(board, index);
        if (bemQuote == 0) revert NotForSale();
        IMachineSales(sales).consign(board, index, vault); // 卖矿合约再查一次现在能卖
        if (!l.approved) {
            l.approved = true;
            _exec(vault, collection, abi.encodeCall(IERC721.setApprovalForAll, (address(OFFICIAL_MARKET), true)));
            _exec(vault, collection, abi.encodeCall(IERC721.setApprovalForAll, (address(SEAPORT), true)));
        }
        l.lastPriced = uint64(block.timestamp);
        _postOfficial(vault, l, collection, id, official);
        _postSeaport(vault, l, collection, id, net, fee);
        _postFirsto(vault, l, collection, id, net);
        // 哪个平台都挂不上：整笔回滚（矿机留在主板）
        if (l.officialId == 0 && l.seaportEnd == 0 && l.firstoDigest == 0) revert ListingFailed();
        emit Listed(board, index, vault, bemQuote, net);
    }

    /// @notice 按最新要价（含规则决定 6.29 的"保持排序第一"）改价。任何人可调，只在以下情况改：价格变了且离上次改价满
    ///         REPRICE_INTERVAL（30 分钟）；或涨幅 ≥ REPRICE_BPS（0.5%）；或 Seaport / Firsto 单 1 天内到期；或官方市场那边没挂上。
    ///         现在不能卖（quote = 0）时请用 recall。
    function reprice(address board, uint256 index) external nonReentrant {
        address vault = vaultOf(board, index);
        Listing storage l = _listings[vault];
        (address collection, uint256 id) = _machineOf(board, index);
        if (l.board != board || IERC721(collection).ownerOf(id) != vault) revert NotListed();
        (uint256 bemQuote, uint256 net, uint256 official, uint256 fee) = prices(board, index);
        if (bemQuote == 0) revert NotForSale();
        uint256 old = l.net;
        bool due = net != old && block.timestamp >= uint256(l.lastPriced) + REPRICE_INTERVAL;
        bool up = net * BPS >= old * (BPS + REPRICE_BPS);
        bool firstoFresh = l.firstoExpiry == 0 || block.timestamp + 1 days < l.firstoExpiry;
        if (!due && !up && block.timestamp + 1 days < l.seaportEnd && l.officialId != 0 && firstoFresh) revert NoChange();
        l.lastPriced = uint64(block.timestamp);
        _postOfficial(vault, l, collection, id, official);
        _postSeaport(vault, l, collection, id, net, fee);
        _postFirsto(vault, l, collection, id, net);
    }

    /// @notice 撤单并把矿机和挂单库里的产出还给主板。卖矿合约随时可调；其他人只能在这台矿机现在不能卖时调用。
    ///         矿机不在挂单库时什么也不做。
    function recall(address board, uint256 index) external nonReentrant {
        address sales = _sales(board);
        if (msg.sender != sales && IMachineSales(sales).quote(board, index) != 0) revert NotAuthorized();
        address vault = vaultOf(board, index);
        Listing storage l = _listings[vault];
        (address collection, uint256 id) = _machineOf(board, index);
        if (l.board != board || IERC721(collection).ownerOf(id) != vault) return;
        _clear(vault, l, collection, id, address(0));
        _exec(vault, collection, abi.encodeWithSignature("transferFrom(address,address,uint256)", vault, board, id));
        _forwardBem(vault, board);
        emit Recalled(board, index, vault);
    }

    // ============ 成交结算 ============

    /// @notice 退路（任何人可调）：官方矿机市场现在成交时把卖款直接推给卖方；如果它以后升级成"卖款先记账、卖方自己提"，
    ///         挂单库的矿机被买走后收不到推款，这时调用这里替挂单库提款，提到的 BNB 照常走 onProceeds 结算。
    ///         不加 nonReentrant：提款会在同一笔交易里经挂单库回调 onProceeds（它有自己的重入锁）；本函数不改任何状态。
    function pullOfficialProceeds(address board, uint256 index) external {
        _sales(board);
        address vault = vaultOf(board, index);
        if (_listings[vault].board != board) revert NotListed();
        _exec(vault, address(OFFICIAL_MARKET), abi.encodeCall(IOfficialMarket.withdraw, ()));
    }

    /// @notice 只认挂单库（收到市场推来的卖款时调用；from = 推款的市场）。见合约说明。
    function onProceeds(address from) external payable nonReentrant {
        Listing storage l = _listings[msg.sender];
        address board = l.board;
        if (board == address(0)) revert NotVault();
        uint256 index = l.index;
        (address collection, uint256 id) = _machineOf(board, index);
        // 矿机还在挂单库 = 没卖出；已经撤回主板也不是卖出（审计 L-1：撤回后有人往挂单库打款，不能触发结算）
        address holder = IERC721(collection).ownerOf(id);
        if (holder == msg.sender || holder == board) revert NotSold();
        _clear(msg.sender, l, collection, id, from);
        _forwardBem(msg.sender, board); // 寄售期间的产出：直接归主板（不算卖出所得）
        uint256 got = SWAPPER.swapBnbForBem{value: msg.value}(
            ORACLE.quoteBemOut(msg.value) * (BPS - SLIPPAGE_BPS) / BPS, address(this)
        );
        address sales = _sales(board);
        uint256 price = IMachineSales(sales).quote(board, index);
        if (price == 0) revert NotForSale();
        if (got < price) revert BelowFormula(got, price);
        BEM.forceApprove(sales, price);
        uint256 paid = IMachineSales(sales).buyMachine(board, index, type(uint256).max); // 矿机已交出：只记账
        BEM.forceApprove(sales, 0);
        uint256 extra = got - paid;
        extra -= _premiumFee(board, index, paid, extra);
        if (extra > 0) BEM.safeTransfer(board, extra);
        emit Sold(board, index, msg.sender, msg.value, got, paid);
    }

    // ============ 内部 ============

    function _sales(address board) internal view returns (address) {
        if (!HUB.isBoard(board)) revert NotBoard();
        return IBoardForLister(board).SALES();
    }

    function _salt(address board, uint256 index) internal pure returns (bytes32) {
        return keccak256(abi.encode(board, index));
    }

    function _exec(address vault, address target, bytes memory data) internal returns (bytes memory) {
        return ListingVault(payable(vault)).exec(target, data);
    }

    function _forwardBem(address vault, address board) internal {
        uint256 bal = BEM.balanceOf(vault);
        if (bal > 0) _exec(vault, address(BEM), abi.encodeCall(IERC20.transfer, (board, bal)));
    }

    /// @dev 撤掉其他平台还挂着的单（成交后其他平台的单也撤，免得市场索引里留着失效的单）；对方回滚时忽略。
    ///      sold = 刚成交的市场（那一边的单已经成交，不再调用它）。Firsto 的摘要先作废（即使撤单调用失败，旧单也验不过签）
    function _clear(address vault, Listing storage l, address collection, uint256 id, address sold) internal {
        if (l.firstoDigest != bytes32(0)) {
            l.firstoDigest = bytes32(0);
            l.firstoExpiry = 0;
            if (sold != address(FIRSTO)) {
                try ListingVault(payable(vault))
                    .exec(address(FIRSTO), abi.encodeCall(IFirstoSignedAsk.cancelSignedAskNonce, (l.firstoNonce))) {}
                    catch {}
            }
        }
        if (l.officialId != 0 && sold != address(OFFICIAL_MARKET)) {
            try ListingVault(payable(vault))
                .exec(address(OFFICIAL_MARKET), abi.encodeCall(IOfficialMarket.delist, (l.officialId))) {}
                catch {}
        }
        if (l.seaportEnd != 0 && sold != address(SEAPORT)) {
            try this.cancelSeaportFor(vault, collection, id) {} catch {}
        }
        l.officialId = 0;
        l.officialPrice = 0;
        l.seaportStart = 0;
        l.seaportEnd = 0;
        l.net = 0;
    }

    /// @dev 只供本合约 try 调用（把 Seaport 撤单包成外部调用，失败时忽略）
    function cancelSeaportFor(address vault, address collection, uint256 id) external {
        if (msg.sender != address(this)) revert NotAuthorized();
        _cancelSeaport(vault, _listings[vault], collection, id);
    }

    function _cancelSeaport(address vault, Listing storage l, address collection, uint256 id) internal {
        if (l.seaportEnd == 0) return;
        OrderComponents[] memory cs = new OrderComponents[](1);
        OrderParameters memory p = _order(vault, l, collection, id);
        cs[0] = OrderComponents(
            p.offerer,
            p.zone,
            p.offer,
            p.consideration,
            p.orderType,
            p.startTime,
            p.endTime,
            p.zoneHash,
            p.salt,
            p.conduitKey,
            SEAPORT.getCounter(vault)
        );
        _exec(vault, address(SEAPORT), abi.encodeCall(ISeaport.cancel, (cs)));
    }

    /// @dev 官方市场：没挂过就 list，挂着就 setPrice（价格没变不动）。市场回滚时忽略（另一边照挂；改价失败时旧价更高或
    ///      成交时结算不过而回滚，都不会让主板少收）
    function _postOfficial(address vault, Listing storage l, address collection, uint256 id, uint256 price) internal {
        // forge-lint: disable-next-line(unsafe-typecast)
        uint96 p = uint96(price);
        if (l.officialId != 0) {
            if (price == l.officialPrice) return;
            try ListingVault(payable(vault))
                .exec(address(OFFICIAL_MARKET), abi.encodeCall(IOfficialMarket.setPrice, (l.officialId, p))) {
                l.officialPrice = price;
                emit OfficialListed(vault, l.officialId, price);
            } catch {}
            return;
        }
        try ListingVault(payable(vault))
            .exec(address(OFFICIAL_MARKET), abi.encodeCall(IOfficialMarket.list, (collection, id, p))) returns (
            bytes memory ret
        ) {
            l.officialId = abi.decode(ret, (uint256));
            l.officialPrice = price;
            emit OfficialListed(vault, l.officialId, price);
        } catch {}
    }

    /// @dev Seaport：先按旧单的参数撤掉旧单（如果有），再按新价 validate 一张新单（net 同时是两边共用的挂单库应收额）。
    ///      validate 回滚时这一边不挂
    function _postSeaport(address vault, Listing storage l, address collection, uint256 id, uint256 net, uint256 fee)
        internal
    {
        if (l.seaportEnd != 0) {
            try this.cancelSeaportFor(vault, collection, id) {} catch {}
        }
        l.net = net;
        l.salt += 1;
        l.seaportStart = block.timestamp;
        l.seaportEnd = block.timestamp + LISTING_DURATION;
        l.seaportFee = fee;
        Order[] memory os = new Order[](1);
        os[0] = Order(_order(vault, l, collection, id), "");
        try ListingVault(payable(vault)).exec(address(SEAPORT), abi.encodeCall(ISeaport.validate, (os))) {
            emit SeaportListed(vault, l.salt, l.seaportStart, l.seaportEnd, l.net, fee);
        } catch {
            l.seaportStart = 0;
            l.seaportEnd = 0;
        }
    }

    /// @dev Firsto 签名卖单 V2：旧单的摘要作废并 cancelSignedAskNonce（第一次挂时改为 approve(V2, tokenId)，只认按编号的授权），
    ///      再按新 nonce、price = 净价、payoutRecipient = 挂单库、当前费率 / feeEpoch / schemaVersion 登记新单的摘要。
    ///      Firsto 合约回滚（暂停、升级后接口变化）时这一边不挂。
    function _postFirsto(address vault, Listing storage l, address collection, uint256 id, uint256 net) internal {
        if (address(FIRSTO) == address(0)) return;
        if (l.firstoDigest != bytes32(0)) {
            l.firstoDigest = bytes32(0);
            try ListingVault(payable(vault))
                .exec(address(FIRSTO), abi.encodeCall(IFirstoSignedAsk.cancelSignedAskNonce, (l.firstoNonce))) {}
                catch {}
        } else {
            try ListingVault(payable(vault)).exec(collection, abi.encodeCall(IERC721.approve, (address(FIRSTO), id))) {}
            catch {
                return;
            }
        }
        l.firstoExpiry = 0;
        uint16 feeBps;
        uint256 epoch;
        uint16 schema;
        try FIRSTO.defaultTakerFeeBps() returns (uint16 f) {
            feeBps = f;
        } catch {
            return;
        }
        try FIRSTO.feeEpoch() returns (uint256 e) {
            epoch = e;
        } catch {
            return;
        }
        try FIRSTO.SIGNED_ASK_SCHEMA_VERSION() returns (uint16 v) {
            schema = v;
        } catch {
            return;
        }
        l.firstoNonce += 1;
        // forge-lint: disable-next-line(unsafe-typecast)
        l.firstoPrice = uint128(net);
        // forge-lint: disable-next-line(unsafe-typecast)
        l.firstoExpiry = uint64(block.timestamp + LISTING_DURATION);
        l.firstoFeeBps = feeBps;
        l.firstoFeeEpoch = epoch;
        l.firstoSchema = schema;
        SignedAsk memory a = _firstoAskOf(vault, l, collection, id);
        bytes32 d = FirstoSignedAskLib.digest(address(FIRSTO), a);
        l.firstoDigest = d;
        emit FirstoListed(vault, a, d);
    }

    function _firstoAskOf(address vault, Listing storage l, address collection, uint256 id)
        internal
        view
        returns (SignedAsk memory)
    {
        return SignedAsk(
            vault,
            collection,
            id,
            l.firstoNonce,
            l.firstoPrice,
            l.firstoExpiry,
            vault,
            l.firstoFeeBps,
            l.firstoFeeEpoch,
            l.firstoSchema
        );
    }

    /// @dev 当前 Seaport 卖单：offerer = 挂单库，一台矿机换 [net 原生币给挂单库, 手续费原生币给 tapeout.market]
    function _order(address vault, Listing storage l, address collection, uint256 id)
        internal
        view
        returns (OrderParameters memory p)
    {
        p.offerer = vault;
        p.offer = new OfferItem[](1);
        p.offer[0] = OfferItem(2, collection, id, 1, 1);
        uint256 n = l.seaportFee > 0 ? 2 : 1;
        p.consideration = new ConsiderationItem[](n);
        p.consideration[0] = ConsiderationItem(0, address(0), 0, l.net, l.net, payable(vault));
        if (n == 2) {
            p.consideration[1] = ConsiderationItem(0, address(0), 0, l.seaportFee, l.seaportFee, SEAPORT_FEE_RECIPIENT);
        }
        p.startTime = l.seaportStart;
        p.endTime = l.seaportEnd;
        p.salt = l.salt;
        p.totalOriginalConsiderationItems = n;
    }

    function _ceilDiv(uint256 a, uint256 b) private pure returns (uint256) {
        return a == 0 ? 0 : (a - 1) / b + 1;
    }

    /// @notice 只为接收兑换的找零（不应发生）；挂单库的卖款走 onProceeds
    receive() external payable {
        if (msg.sender != address(SWAPPER)) revert NotVault();
    }
}

interface IBoardForLister {
    function SALES() external view returns (address);
}

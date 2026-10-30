// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IBoardHub} from "../interfaces/ITapeBoard.sol";
import {IBemPriceOracle} from "../interfaces/ISwap.sol";
import {AskOrder, BidOrder, IFirstoSwapper, IFirstoSwapCallback} from "../firsto/IFirsto.sol";
import {
    IOfficialMarket,
    ISeaport,
    AdvancedOrder,
    CriteriaResolver,
    OfferItem,
    ConsiderationItem,
    IWBNBLike
} from "./IMarkets.sol";
import {SaleSettlement, IBoardForMarket} from "./SaleSettlement.sol";
import {SignedAsk, IFirstoSignedAsk} from "./FirstoSignedAsk.sol";

interface ISalesForTrader {
    function buyMachine(address board, uint256 index, uint256 maxPrice) external returns (uint256 paid);
}

interface IPoDForTrader {
    function minerKey(address circuits, uint256 id) external view returns (bytes32);
    function claim(bytes32 key) external;
}

/// @title MarketTrader（主板在第三方市场自动买卖矿机，单例；规则决定 6.22、6.26，FIRSTO-PROBE.md、MARKET-PROBE.md）
/// @notice rc5 的 FirstoTrader 扩成多市场。价格和资格全部由主板 / 卖矿合约按现有规则检查。买入只认运营地址（规则决定 6.37：
///         主板不再公开按报价收购，只由机器人在三个来源里按每单位算力从最便宜的挂单往上买，在链下比较后递单）；
///         卖出任何人都可以调用（F-2 a，主板至少拿到公式价）：
///         买入（矿机卖给主板）——经兑换适配器先拿到 BNB（闪电兑换），先替卖方 PoD.claim 领产出（F-1 a），在市场上买入
///         （收货地址 = 本合约），再调用主板 sellMachine(合集, 编号, 实际花费的 BEM)：主板照常检查收购期、合集、资格、预算、
///         100 台上限，并要求 实际花费 ≤ 计价算力 × 收购公式价，按实价记账、付 BEM；本合约用这笔 BEM 还清兑换。
///         兑换的 BEM 相对 30 分钟 TWAP 最多多付 2%（F-4 a）。
///           - buyFromAsk：Firsto 批量卖单（直接调用卖单合约 0x20b36528）；
///           - buyFromSignedAsk：Firsto 单笔签名卖单 V2（fillSignedAsk，正好付 价格 × (1 + 手续费)；规则决定 6.37）；
///           - buyFromOfficial：TapeOut 官方矿机市场的链上挂单（buy，正好付挂单价）；
///           - buyFromSeaport：Seaport 1.6 卖单（tapeout.market 的 TAPEMARKET_SEAPORT 来源；fulfillAdvancedOrder）。
///         卖出（主板矿机卖给买单 / 出价）——经兑换适配器先拿到 BEM，通过主板的卖矿合约按当前要价买下矿机（主板至少拿到公式价，
///         和普通买家完全一样；寄售中的矿机由卖矿合约先撤回），在市场上卖出，用到手的 BNB 还清兑换，剩下的按 TWAP − 2% 以上
///         换成 BEM，扣溢价分成后转给主板：
///           - sellToBid：Firsto 统一买单（0x4c67242f）；
///           - sellToOffer：Seaport 上的 WBNB 出价（单台或整个合集），收到的 WBNB 换回 BNB。
///         Firsto 已明确不接入合约自建的挂单和出价，所以在 Firsto 上只吃单；把主板矿机挂到官方市场 / Seaport 的是 MachineLister。
///         公式价成交照常开着，谁先成交算谁（F-3 a）。任何一步失败整笔回滚。本合约在两次调用之间不持有资金和矿机。
///         没有管理员，不可升级。
contract MarketTrader is SaleSettlement, ReentrancyGuard, IFirstoSwapCallback {
    using SafeERC20 for IERC20;

    bytes4 public constant ASK_BUY_SELECTOR = 0x20b36528;
    bytes4 public constant BID_SELL_SELECTOR = 0x4c67242f;
    uint8 internal constant OP_BUY = 1;
    uint8 internal constant OP_SELL = 2;
    uint8 internal constant VENUE_FIRSTO = 1;
    uint8 internal constant VENUE_OFFICIAL = 2;
    uint8 internal constant VENUE_SEAPORT = 3;
    uint8 internal constant VENUE_FIRSTO_SIGNED = 4;
    uint8 internal constant ITEM_NATIVE = 0;
    uint8 internal constant ITEM_ERC20 = 1;
    uint8 internal constant ITEM_ERC721 = 2;

    IBoardHub public immutable HUB;
    address public immutable ASK_EXCHANGE;
    /// @notice Firsto 单笔签名卖单 V2 合约（规则决定 6.37：买它挂的单）
    address public immutable SIGNED_ASK;
    address public immutable BID_EXCHANGE;
    IOfficialMarket public immutable OFFICIAL_MARKET;
    ISeaport public immutable SEAPORT;
    address public immutable WBNB;
    IFirstoSwapper public immutable SWAPPER;
    IBemPriceOracle public immutable ORACLE;
    address public immutable POD;
    uint256 public immutable SLIPPAGE_BPS;

    /// @dev 正在进行的操作（0 = 没有）；只有进行中才接受兑换回调和矿机
    uint8 internal _op;
    uint256 internal _result;
    uint256 internal _lastNet;
    uint256 internal _lastPrice;

    event BoughtMachine(
        address indexed board,
        address indexed collection,
        uint256 indexed tokenId,
        uint8 venue,
        address caller,
        uint256 bnbCost,
        uint256 bemPaid
    );
    event SoldMachine(
        address indexed board,
        uint256 indexed index,
        address indexed caller,
        uint8 venue,
        uint256 bnbNet,
        uint256 bemToBoard
    );

    error BadConfig();
    error NotOperator();
    error NotBoard();
    error BadOrder();
    error NotSwapper();
    error NotDelivered();
    error SlippageTooHigh();
    error InsufficientProceeds();
    error MarketCallFailed(bytes reason);
    error TransferFailed();

    struct Markets {
        address askExchange; // Firsto 卖单合约
        address signedAsk; // Firsto 单笔签名卖单 V2 合约
        address bidExchange; // Firsto 统一买单合约
        address officialMarket; // TapeOut 官方矿机市场
        address seaport; // Seaport 1.6
        address wbnb;
    }

    constructor(
        address bem,
        address hub,
        Markets memory mk,
        address swapper,
        address oracle,
        address pod,
        uint256 slippageBps
    ) SaleSettlement(bem) {
        if (
            bem == address(0) || hub == address(0) || mk.askExchange == address(0) || mk.signedAsk == address(0)
                || mk.bidExchange == address(0)
                || mk.officialMarket == address(0) || mk.seaport == address(0) || mk.wbnb == address(0)
                || swapper == address(0) || oracle == address(0) || pod == address(0) || slippageBps == 0
                || slippageBps >= BPS
        ) revert BadConfig();
        HUB = IBoardHub(hub);
        ASK_EXCHANGE = mk.askExchange;
        SIGNED_ASK = mk.signedAsk;
        BID_EXCHANGE = mk.bidExchange;
        OFFICIAL_MARKET = IOfficialMarket(mk.officialMarket);
        SEAPORT = ISeaport(mk.seaport);
        WBNB = mk.wbnb;
        SWAPPER = IFirstoSwapper(swapper);
        ORACLE = IBemPriceOracle(oracle);
        POD = pod;
        SLIPPAGE_BPS = slippageBps;
    }

    // ============ 买入（矿机卖给主板）============

    /// @notice Firsto 卖单的含费总价（BNB）= priceWei × (1 + feeBps)，卖单合约要求正好付这个数
    function askCost(AskOrder calldata o) public pure returns (uint256) {
        return o.leaf.priceWei + o.leaf.priceWei * o.leaf.feeBps / BPS;
    }

    /// @notice 吃一张 Firsto 卖单，把矿机按实际花费卖给 board。返回主板付出的 BEM。
    function buyFromAsk(address board, AskOrder calldata o) external nonReentrant returns (uint256 bemPaid) {
        if (o.header.maker != o.leaf.maker) revert BadOrder();
        return _buyFlash(board, VENUE_FIRSTO, o.leaf.collection, o.leaf.tokenId, askCost(o), abi.encode(o));
    }

    /// @notice 吃一张 Firsto 单笔签名卖单 V2，把矿机按实际花费卖给 board（规则决定 6.37：Firsto 上新挂的单大多是这种）。
    ///         付款 = price + price × feeBps / 10000（卖单合约要求正好付这个数，2026-10-25 按 10 张真实卖单核对过）。
    function buyFromSignedAsk(address board, SignedAsk calldata a, bytes calldata signature)
        external
        nonReentrant
        returns (uint256 bemPaid)
    {
        uint256 cost = uint256(a.price) + uint256(a.price) * a.feeBps / BPS;
        return _buyFlash(board, VENUE_FIRSTO_SIGNED, a.collection, a.tokenId, cost, abi.encode(a, signature));
    }

    /// @notice 买 TapeOut 官方矿机市场的第 listingId 号挂单（正好付挂单价），把矿机按实际花费卖给 board。
    function buyFromOfficial(address board, uint256 listingId) external nonReentrant returns (uint256 bemPaid) {
        (, address collection, uint256 tokenId, uint256 price,,) = OFFICIAL_MARKET.listingView(listingId);
        return _buyFlash(board, VENUE_OFFICIAL, collection, tokenId, price, abi.encode(listingId));
    }

    /// @notice 买一张 Seaport 卖单（只能是"一台 ERC721 矿机换原生 BNB"的单，各项金额不随时间变化），把矿机按实际花费卖给 board。
    ///         付款 = 全部对价项之和（含市场手续费项）。
    function buyFromSeaport(address board, AdvancedOrder calldata order)
        external
        nonReentrant
        returns (uint256 bemPaid)
    {
        OfferItem[] calldata offer = order.parameters.offer;
        if (
            offer.length != 1 || offer[0].itemType != ITEM_ERC721 || offer[0].startAmount != 1
                || offer[0].endAmount != 1
        ) {
            revert BadOrder();
        }
        ConsiderationItem[] calldata c = order.parameters.consideration;
        uint256 total;
        for (uint256 i = 0; i < c.length; i++) {
            if (c[i].itemType != ITEM_NATIVE || c[i].startAmount != c[i].endAmount) revert BadOrder();
            total += c[i].startAmount;
        }
        return _buyFlash(board, VENUE_SEAPORT, offer[0].token, offer[0].identifierOrCriteria, total, abi.encode(order));
    }

    function _buyFlash(
        address board,
        uint8 venue,
        address collection,
        uint256 tokenId,
        uint256 cost,
        bytes memory order
    ) internal returns (uint256 bemPaid) {
        // 规则决定 6.37：买入只认运营地址（机器人按日产能价从低到高挑单），别人不能挑一张自己挂的高价单让主板去吃
        address op = HUB.operator();
        if (op == address(0) || msg.sender != op) revert NotOperator();
        if (!HUB.isBoard(board)) revert NotBoard();
        _op = OP_BUY;
        SWAPPER.flashBnb(cost, abi.encode(board, venue, collection, tokenId, cost, order));
        bemPaid = _result;
        _finish(board);
        emit BoughtMachine(board, collection, tokenId, venue, msg.sender, cost, bemPaid);
    }

    // ============ 卖出（主板矿机卖给买单 / 出价）============

    /// @notice 把 board 第 index 台矿机卖给 Firsto 统一买单。bemAdvance = 先借多少 BEM 去向卖矿合约买下矿机（≥ 当前要价；
    ///         多借的连同卖出后多出来的 BNB 换成的 BEM，扣溢价分成后全部转给主板）。返回主板总共收到的 BEM。
    function sellToBid(address board, uint256 index, BidOrder calldata b, uint256 bemAdvance)
        external
        nonReentrant
        returns (uint256 bemToBoard)
    {
        return _sellFlash(board, index, VENUE_FIRSTO, bemAdvance, abi.encode(b));
    }

    /// @notice 接受一张 Seaport 出价：出价方给 WBNB（offer 只能是 WBNB），要第 index 台矿机（指定编号，或整个合集按条件——
    ///         criteriaResolvers 由调用者给出这台矿机的编号）。出价单里要卖方付的手续费项（WBNB）从收到的 WBNB 里付。
    function sellToOffer(
        address board,
        uint256 index,
        AdvancedOrder calldata offer,
        CriteriaResolver[] calldata criteriaResolvers,
        uint256 bemAdvance
    ) external nonReentrant returns (uint256 bemToBoard) {
        OfferItem[] calldata items = offer.parameters.offer;
        if (items.length == 0) revert BadOrder();
        for (uint256 i = 0; i < items.length; i++) {
            if (items[i].itemType != ITEM_ERC20 || items[i].token != WBNB || items[i].startAmount != items[i].endAmount)
            {
                revert BadOrder();
            }
        }
        return _sellFlash(board, index, VENUE_SEAPORT, bemAdvance, abi.encode(offer, criteriaResolvers));
    }

    function _sellFlash(address board, uint256 index, uint8 venue, uint256 bemAdvance, bytes memory order)
        internal
        returns (uint256 bemToBoard)
    {
        if (!HUB.isBoard(board)) revert NotBoard();
        uint256 balBefore = BEM.balanceOf(board);
        _op = OP_SELL;
        SWAPPER.flashBem(bemAdvance, abi.encode(board, index, venue, order));
        uint256 bnbLeft = address(this).balance;
        if (bnbLeft > 0) {
            uint256 minOut = ORACLE.quoteBemOut(bnbLeft) * (BPS - SLIPPAGE_BPS) / BPS;
            SWAPPER.swapBnbForBem{value: bnbLeft}(minOut, address(this));
        }
        uint256 price = _lastPrice;
        _lastPrice = 0;
        _premiumFee(board, index, price, BEM.balanceOf(address(this)));
        _finish(board);
        bemToBoard = BEM.balanceOf(board) - balBefore;
        emit SoldMachine(board, index, msg.sender, venue, _lastNet, bemToBoard);
        _lastNet = 0;
    }

    // ============ 兑换回调 ============

    /// @notice 兑换适配器回调：只在本合约发起的操作进行中、由适配器调用时有效。
    function onFlash(uint256 owed, bytes calldata data) external {
        if (msg.sender != address(SWAPPER) || _op == 0) revert NotSwapper();
        if (_op == OP_BUY) _buy(owed, data);
        else _sell(owed, data);
    }

    function _buy(uint256 owedBem, bytes calldata data) internal {
        (address board, uint8 venue, address collection, uint256 tokenId, uint256 cost, bytes memory order) =
            abi.decode(data, (address, uint8, address, uint256, uint256, bytes));
        // 兑换的 BEM 相对 TWAP 最多多付 2%
        if (owedBem * BPS > ORACLE.quoteBemOut(cost) * (BPS + SLIPPAGE_BPS)) revert SlippageTooHigh();
        // F-1 a：先替卖方领取这台矿机此前的产出（和 Firsto 路由、主板 sellMachine 的做法一致）
        try IPoDForTrader(POD).claim(IPoDForTrader(POD).minerKey(collection, tokenId)) {} catch {}
        bool ok;
        bytes memory ret;
        if (venue == VENUE_FIRSTO) {
            AskOrder memory o = abi.decode(order, (AskOrder));
            (ok, ret) = ASK_EXCHANGE.call{value: cost}(
                abi.encodeWithSelector(ASK_BUY_SELECTOR, o.header, o.leaf, o.merkleProof, o.signature, address(this))
            );
        } else if (venue == VENUE_FIRSTO_SIGNED) {
            (SignedAsk memory sa, bytes memory sig) = abi.decode(order, (SignedAsk, bytes));
            (ok, ret) = SIGNED_ASK.call{value: cost}(abi.encodeCall(IFirstoSignedAsk.fillSignedAsk, (sa, sig, address(this))));
        } else if (venue == VENUE_OFFICIAL) {
            // forge-lint: disable-next-line(unsafe-typecast)
            (ok, ret) = address(OFFICIAL_MARKET).call{value: cost}(
                abi.encodeCall(IOfficialMarket.buy, (abi.decode(order, (uint256)), uint96(cost)))
            );
        } else {
            AdvancedOrder memory a = abi.decode(order, (AdvancedOrder));
            a.numerator = 1;
            a.denominator = 1;
            (ok, ret) = address(SEAPORT).call{value: cost}(
                abi.encodeCall(ISeaport.fulfillAdvancedOrder, (a, new CriteriaResolver[](0), bytes32(0), address(this)))
            );
        }
        if (!ok) revert MarketCallFailed(ret);
        if (IERC721(collection).ownerOf(tokenId) != address(this)) revert NotDelivered();
        // 主板按实际花费付 BEM（检查收购期、合集、资格、预算、100 台、实际花费 ≤ 计价算力 × 收购公式价）
        IERC721(collection).approve(board, tokenId);
        _result = IBoardForMarket(board).sellMachine(collection, tokenId, owedBem);
        BEM.safeTransfer(address(SWAPPER), owedBem);
    }

    function _sell(uint256 owedBnb, bytes calldata data) internal {
        (address board, uint256 index, uint8 venue, bytes memory order) =
            abi.decode(data, (address, uint256, uint8, bytes));
        (address collection, uint256 tokenId) = _machineOf(board, index);
        // 和普通买家一样按卖矿合约的当前要价买下（主板至少拿到公式价；寄售中的由卖矿合约先撤回）
        address sales = IBoardForMarket(board).SALES();
        BEM.forceApprove(sales, BEM.balanceOf(address(this)));
        _lastPrice = ISalesForTrader(sales).buyMachine(board, index, type(uint256).max);
        BEM.forceApprove(sales, 0);
        if (IERC721(collection).ownerOf(tokenId) != address(this)) revert NotDelivered();
        uint256 before = address(this).balance;
        bool ok;
        bytes memory ret;
        if (venue == VENUE_FIRSTO) {
            BidOrder memory b = abi.decode(order, (BidOrder));
            // 统一买单合约只认按 tokenId 的授权
            IERC721(collection).approve(BID_EXCHANGE, tokenId);
            (ok, ret) = BID_EXCHANGE.call(
                abi.encodeWithSelector(
                    BID_SELL_SELECTOR,
                    b.orderId,
                    collection,
                    tokenId,
                    IPoDForTrader(POD).minerKey(collection, tokenId),
                    address(this),
                    b.dailyCapacityPriceWei,
                    b.feeBps,
                    b.minNetProceedsWei
                )
            );
            if (!ok) revert MarketCallFailed(ret);
        } else {
            (AdvancedOrder memory a, CriteriaResolver[] memory cr) =
                abi.decode(order, (AdvancedOrder, CriteriaResolver[]));
            uint256 offered;
            for (uint256 i = 0; i < a.parameters.offer.length; i++) {
                offered += a.parameters.offer[i].startAmount;
            }
            a.numerator = 1;
            a.denominator = 1;
            IERC721(collection).approve(address(SEAPORT), tokenId);
            // 出价单要卖方付的手续费项（WBNB）从收到的 WBNB 里付，授权额度不超过出价总额
            IERC20(WBNB).forceApprove(address(SEAPORT), offered);
            uint256 w0 = IERC20(WBNB).balanceOf(address(this));
            (ok, ret) = address(SEAPORT)
                .call(abi.encodeCall(ISeaport.fulfillAdvancedOrder, (a, cr, bytes32(0), address(this))));
            if (!ok) revert MarketCallFailed(ret);
            IERC20(WBNB).forceApprove(address(SEAPORT), 0);
            if (IERC721(collection).ownerOf(tokenId) == address(this)) revert NotDelivered();
            uint256 got = IERC20(WBNB).balanceOf(address(this)) - w0;
            if (got > 0) IWBNBLike(WBNB).withdraw(got);
        }
        uint256 net = address(this).balance - before;
        if (net < owedBnb) revert InsufficientProceeds();
        _lastNet = net;
        (ok,) = address(SWAPPER).call{value: owedBnb}("");
        if (!ok) revert TransferFailed();
    }

    // ============ 内部 ============

    /// @dev 操作结束：剩下的 BEM（多借的、主板 sellMachine 替本合约领到的零星产出）全部转给主板
    function _finish(address board) internal {
        _op = 0;
        _result = 0;
        uint256 left = BEM.balanceOf(address(this));
        if (left > 0) BEM.safeTransfer(board, left);
    }

    /// @notice 只在操作进行中接收矿机（Firsto 卖单合约、官方市场用 safeTransferFrom 交货）
    function onERC721Received(address, address, uint256, bytes calldata) external view returns (bytes4) {
        if (_op == 0) revert NotDelivered();
        return this.onERC721Received.selector;
    }

    /// @notice 接收兑换适配器的 BNB、统一买单的卖款、WBNB 换回的 BNB
    receive() external payable {}
}

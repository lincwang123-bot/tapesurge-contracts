// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {AskHeader, AskLeaf, IFirstoSwapper, IFirstoSwapCallback} from "../firsto/IFirsto.sol";
import {IBemPriceOracle} from "../interfaces/ISwap.sol";
import {PoDReader} from "../libraries/PoDReader.sol";
import {SignedAsk, FirstoSignedAskLib} from "../market/FirstoSignedAsk.sol";

interface IPoDKeyMock {
    function minerKey(address circuits, uint256 id) external view returns (bytes32);
}

interface IMintableBem {
    function mint(address to, uint256 amount) external;
}

/// @title MockFirstoAskExchange（仅测试 / 测试网：模拟 Firsto 卖单合约 0x3f58…dc43）
/// @notice 买入函数的选择器和参数与主网一致：0x20b36528(AskHeader, AskLeaf, bytes32[] proof, bytes signature, address recipient)，
///         payable，必须正好付 priceWei × (1 + feeBps)。不校验签名和 Merkle 证明（测试网没有 Firsto 的签名服务），
///         只检查：maker 仍持有矿机并授权了本合约、没过期、没被撤销、没成交过。用 safeTransferFrom 交货（和主网一样）。
///         挂单：持有人对本合约 setApprovalForAll 后，链下按 API 的字段组一张单即可（机器人在测试网自己组单）。
contract MockFirstoAskExchange {
    address public immutable feeRecipient;
    mapping(address => mapping(uint256 => bool)) public cancelled; // maker → batchNonce
    mapping(bytes32 => bool) public filled; // keccak(maker, batchNonce, leafIndex)

    event AskFilled(address indexed maker, address indexed buyer, address collection, uint256 tokenId, uint256 priceWei, address recipient);
    event AskCancelled(address indexed maker, uint256 batchNonce);

    error InvalidPayment(uint256 expected, uint256 got);
    error OrderInvalid();

    constructor(address feeRecipient_) {
        feeRecipient = feeRecipient_;
    }

    function cancel(uint256 batchNonce) external {
        cancelled[msg.sender][batchNonce] = true;
        emit AskCancelled(msg.sender, batchNonce);
    }

    fallback() external payable {
        if (msg.sig != 0x20b36528) revert OrderInvalid();
        (AskHeader memory h, AskLeaf memory l,,, address recipient) =
            abi.decode(msg.data[4:], (AskHeader, AskLeaf, bytes32[], bytes, address));
        bytes32 id = keccak256(abi.encode(l.maker, l.batchNonce, l.leafIndex));
        IERC721 c = IERC721(l.collection);
        if (
            h.maker != l.maker || h.batchNonce != l.batchNonce || block.timestamp >= h.expiry || cancelled[l.maker][l.batchNonce]
                || filled[id] || c.ownerOf(l.tokenId) != l.maker
                || !(c.isApprovedForAll(l.maker, address(this)) || c.getApproved(l.tokenId) == address(this))
        ) revert OrderInvalid();
        uint256 fee = l.priceWei * l.feeBps / 10_000;
        if (msg.value != l.priceWei + fee) revert InvalidPayment(l.priceWei + fee, msg.value);
        filled[id] = true;
        c.safeTransferFrom(l.maker, recipient, l.tokenId);
        (bool ok,) = l.payoutRecipient.call{value: l.priceWei}("");
        (bool ok2,) = feeRecipient.call{value: fee}("");
        if (!ok || !ok2) revert OrderInvalid();
        emit AskFilled(l.maker, msg.sender, l.collection, l.tokenId, l.priceWei, recipient);
    }
}

/// @title MockFirstoBidExchange（仅测试 / 测试网：模拟 Firsto 统一买单合约 0x9273…7040）
/// @notice 卖出函数的选择器和参数与主网一致：0x4c67242f(orderId, collection, tokenId, minerKey, proceedsRecipient,
///         expectedDailyCapacityPrice, feeBps, minNetProceeds)；只认按 tokenId 的授权（getApproved）。
///         毛价 = 日产能价 × 预计日产出 ÷ 1e8，预计日产出 = PoD 每单位权重日产出 × 权重；卖方付 1% 手续费。
///         建买单：createBid（附带 BNB 预算），大小范围按 PoD 权重（0 / 0 = 不限）。
contract MockFirstoBidExchange {
    struct Bid {
        address maker;
        address nftRecipient;
        uint256 dailyCapacityPriceWei;
        uint256 remainingBudgetWei;
        uint256 minCircuitH;
        uint256 maxCircuitH;
        bool active;
    }

    uint16 public constant FEE_BPS = 100;
    address public immutable POD;
    uint256 public immutable VERIFIED_SHARE_BPS;
    address public immutable feeRecipient;
    Bid[] internal _bids;

    event BidCreated(uint256 indexed orderId, address indexed maker, uint256 dailyCapacityPriceWei, uint256 budget);
    event BidFilled(uint256 indexed orderId, address indexed seller, uint256 tokenId, uint256 gross, uint256 net);
    event BidCancelled(uint256 indexed orderId, uint256 refund);

    error NotApproved(address collection, uint256 tokenId, address approved);
    error BidInvalid();

    constructor(address pod, uint256 verifiedShareBps, address feeRecipient_) {
        POD = pod;
        VERIFIED_SHARE_BPS = verifiedShareBps;
        feeRecipient = feeRecipient_;
    }

    function createBid(uint256 dailyCapacityPriceWei, uint256 minH, uint256 maxH, address nftRecipient)
        external
        payable
        returns (uint256 orderId)
    {
        orderId = _bids.length;
        _bids.push(Bid(msg.sender, nftRecipient, dailyCapacityPriceWei, msg.value, minH, maxH, true));
        emit BidCreated(orderId, msg.sender, dailyCapacityPriceWei, msg.value);
    }

    function cancelBid(uint256 orderId) external {
        Bid storage b = _bids[orderId];
        if (msg.sender != b.maker || !b.active) revert BidInvalid();
        b.active = false;
        uint256 r = b.remainingBudgetWei;
        b.remainingBudgetWei = 0;
        (bool ok,) = b.maker.call{value: r}("");
        if (!ok) revert BidInvalid();
        emit BidCancelled(orderId, r);
    }

    function bid(uint256 orderId) external view returns (Bid memory) {
        return _bids[orderId];
    }

    function bidCount() external view returns (uint256) {
        return _bids.length;
    }

    /// @notice 这台矿机按 orderId 的买单能卖多少（毛价，BNB）
    function grossFor(uint256 orderId, address collection, uint256 tokenId) public view returns (uint256) {
        bytes32 key = IPoDKeyMock(POD).minerKey(collection, tokenId);
        (bool ok, PoDReader.MinerView memory m) = PoDReader.tryRead(POD, key, collection, tokenId);
        (bool ok2, uint256 perDay) = PoDReader.tryUnitYieldPerDay(POD, VERIFIED_SHARE_BPS);
        if (!ok || !ok2) return 0;
        return _bids[orderId].dailyCapacityPriceWei * (perDay * m.weight) / 1e8;
    }

    struct SellArgs {
        uint256 orderId;
        address collection;
        uint256 tokenId;
        bytes32 minerKey;
        address proceeds;
        uint256 expectedDcp;
        uint16 feeBps;
        uint256 minNet;
    }

    fallback() external {
        if (msg.sig != 0x4c67242f) revert BidInvalid();
        _fill(abi.decode(msg.data[4:], (SellArgs)));
    }

    function _fill(SellArgs memory a) internal {
        Bid storage b = _bids[a.orderId];
        IERC721 c = IERC721(a.collection);
        if (c.ownerOf(a.tokenId) != msg.sender) revert BidInvalid();
        address approved = c.getApproved(a.tokenId);
        if (approved != address(this)) revert NotApproved(a.collection, a.tokenId, approved);
        if (!b.active || a.expectedDcp != b.dailyCapacityPriceWei || a.feeBps != FEE_BPS) revert BidInvalid();
        (bool ok, PoDReader.MinerView memory m) =
            PoDReader.tryRead(POD, IPoDKeyMock(POD).minerKey(a.collection, a.tokenId), a.collection, a.tokenId);
        if (!ok || !m.verified) revert BidInvalid();
        if (b.maxCircuitH != 0 && (m.weight < b.minCircuitH || m.weight > b.maxCircuitH)) revert BidInvalid();
        uint256 gross = grossFor(a.orderId, a.collection, a.tokenId);
        uint256 fee = gross * FEE_BPS / 10_000;
        if (gross == 0 || gross > b.remainingBudgetWei || gross - fee < a.minNet) revert BidInvalid();
        b.remainingBudgetWei -= gross;
        c.transferFrom(msg.sender, b.nftRecipient, a.tokenId);
        (bool ok1,) = a.proceeds.call{value: gross - fee}("");
        (bool ok3,) = feeRecipient.call{value: fee}("");
        if (!ok1 || !ok3) revert BidInvalid();
        emit BidFilled(a.orderId, msg.sender, a.tokenId, gross, gross - fee);
    }
}

/// @title MockFirstoSwapper（仅测试 / 测试网：FirstoTrader 的兑换适配器）
/// @notice 按 MockPriceOracle 的固定汇率兑换，另加 extraBps（模拟池子手续费 / 滑点）。BEM 直接铸造（MockBEM），
///         BNB 用本合约自己的余额（部署后打一点 tBNB 进来；卖出时还回来的 BNB 会补回余额）。
contract MockFirstoSwapper is IFirstoSwapper {
    IERC20 public immutable BEM;
    IBemPriceOracle public immutable ORACLE;
    address public trader;
    uint256 public extraBps = 50;

    error Underpaid();
    error NotTrader();

    constructor(address bem, address oracle) {
        BEM = IERC20(bem);
        ORACLE = IBemPriceOracle(oracle);
    }

    /// @dev 只能设置一次（部署脚本里 FirstoTrader 部署后设置）
    function setTrader(address t) external {
        if (trader != address(0)) revert NotTrader();
        trader = t;
    }

    function setExtraBps(uint256 b) external {
        extraBps = b;
    }

    function flashBnb(uint256 bnbOut, bytes calldata data) external {
        if (msg.sender != trader) revert NotTrader();
        uint256 owed = ORACLE.quoteBemOut(bnbOut) * (10_000 + extraBps) / 10_000;
        uint256 before = BEM.balanceOf(address(this));
        (bool ok,) = msg.sender.call{value: bnbOut}("");
        if (!ok) revert Underpaid();
        IFirstoSwapCallback(msg.sender).onFlash(owed, data);
        if (BEM.balanceOf(address(this)) - before < owed) revert Underpaid();
    }

    function flashBem(uint256 bemOut, bytes calldata data) external {
        if (msg.sender != trader) revert NotTrader();
        uint256 owed = bemOut * 1e18 / ORACLE.quoteBemOut(1e18) * (10_000 + extraBps) / 10_000;
        uint256 before = address(this).balance;
        IMintableBem(address(BEM)).mint(msg.sender, bemOut);
        IFirstoSwapCallback(msg.sender).onFlash(owed, data);
        if (address(this).balance - before < owed) revert Underpaid();
    }

    function swapBnbForBem(uint256 minOut, address to) external payable returns (uint256 out) {
        out = ORACLE.quoteBemOut(msg.value) * (10_000 - extraBps) / 10_000;
        if (out < minOut) revert Underpaid();
        IMintableBem(address(BEM)).mint(to, out);
    }

    receive() external payable {}
}

interface IERC1271Mock {
    function isValidSignature(bytes32 hash, bytes calldata signature) external view returns (bytes4);
}

/// @title MockFirstoSignedAsk（仅测试 / 测试网：模拟 Firsto 单笔签名卖单 V2 0x3342…7f29）
/// @notice 函数和主网相同：fillSignedAsk(ask, signature, nftRecipient) payable（正好付 price × (1 + feeBps)）、
///         cancelSignedAskNonce(nonce)、isSignedAskNonceInvalidated、defaultTakerFeeBps（100）、feeEpoch（1）、
///         SIGNED_ASK_SCHEMA_VERSION（2）。行为按主网分叉实测（FIRSTO-PROBE.md 第 7 节）：maker 是合约时调它的
///         isValidSignature(EIP-712 摘要, signature)（给 10 万 gas，必须返回 0x1626ba7e），普通钱包时 ecrecover；
///         只认 approve(本合约, tokenId)；先把矿机 safeTransferFrom 给 nftRecipient，再把 price 连同全部 gas 推给
///         payoutRecipient（推款失败整笔回滚），手续费给 feeRecipient；nonce 用过或撤销后失效。
contract MockFirstoSignedAsk {
    uint16 public constant SIGNED_ASK_SCHEMA_VERSION = 2;
    uint16 public defaultTakerFeeBps = 100;
    uint256 public feeEpoch = 1;
    bool public paused;
    address public immutable feeRecipient;
    mapping(address => mapping(uint256 => bool)) public isSignedAskNonceInvalidated;

    event SignedAskFilled(bytes32 indexed askHash, address indexed maker, address indexed buyer, uint256 price);
    event SignedAskNonceCancelled(address indexed maker, uint256 nonce);

    error InvalidSignature(address maker, uint256 nonce);
    error NonceInvalidated(address maker, uint256 nonce);
    error NotApproved(address collection, uint256 tokenId, address approved);
    error BadTerms();
    error InvalidPayment(uint256 expected, uint256 got);
    error PayoutFailed();

    constructor(address feeRecipient_) {
        feeRecipient = feeRecipient_;
    }

    function setPaused(bool p) external {
        paused = p;
    }

    function cancelSignedAskNonce(uint256 nonce) external {
        isSignedAskNonceInvalidated[msg.sender][nonce] = true;
        emit SignedAskNonceCancelled(msg.sender, nonce);
    }

    function fillSignedAsk(SignedAsk calldata ask, bytes calldata signature, address nftRecipient) external payable {
        if (paused) revert BadTerms();
        if (isSignedAskNonceInvalidated[ask.maker][ask.nonce]) revert NonceInvalidated(ask.maker, ask.nonce);
        if (
            block.timestamp >= ask.expiry || ask.feeBps != defaultTakerFeeBps || ask.feeEpoch != feeEpoch
                || ask.schemaVersion != SIGNED_ASK_SCHEMA_VERSION
        ) revert BadTerms();
        bytes32 h = FirstoSignedAskLib.digest(address(this), ask);
        if (ask.maker.code.length > 0) {
            try IERC1271Mock(ask.maker).isValidSignature{gas: 100_000}(h, signature) returns (bytes4 r) {
                if (r != 0x1626ba7e) revert InvalidSignature(ask.maker, ask.nonce);
            } catch {
                revert InvalidSignature(ask.maker, ask.nonce);
            }
        } else {
            if (signature.length != 65) revert InvalidSignature(ask.maker, ask.nonce);
            bytes32 r;
            bytes32 s;
            uint8 v;
            assembly {
                r := calldataload(signature.offset)
                s := calldataload(add(signature.offset, 32))
                v := byte(0, calldataload(add(signature.offset, 64)))
            }
            if (ecrecover(h, v, r, s) != ask.maker) revert InvalidSignature(ask.maker, ask.nonce);
        }
        IERC721 c = IERC721(ask.collection);
        address approved = c.getApproved(ask.tokenId);
        if (approved != address(this)) revert NotApproved(ask.collection, ask.tokenId, approved);
        uint256 fee = uint256(ask.price) * ask.feeBps / 10_000;
        if (msg.value != uint256(ask.price) + fee) revert InvalidPayment(uint256(ask.price) + fee, msg.value);
        isSignedAskNonceInvalidated[ask.maker][ask.nonce] = true;
        c.safeTransferFrom(ask.maker, nftRecipient, ask.tokenId);
        (bool ok,) = ask.payoutRecipient.call{value: ask.price}("");
        if (!ok) revert PayoutFailed();
        (ok,) = feeRecipient.call{value: fee}("");
        if (!ok) revert PayoutFailed();
        emit SignedAskFilled(h, ask.maker, msg.sender, ask.price);
    }
}

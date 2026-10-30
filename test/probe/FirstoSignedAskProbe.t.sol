// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test, Vm, console2} from "forge-std/Test.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";

struct SignedAsk {
    address maker;
    address collection;
    uint256 tokenId;
    uint256 nonce;
    uint128 price;
    uint64 expiry;
    address payoutRecipient;
    uint16 feeBps;
    uint256 feeEpoch;
    uint16 schemaVersion;
}

interface ISignedAskV2 {
    function fillSignedAsk(SignedAsk calldata ask, bytes calldata signature, address nftRecipient) external payable;
    function cancelSignedAskNonce(uint256 nonce) external;
    function isSignedAskNonceInvalidated(address maker, uint256 nonce) external view returns (bool);
    function defaultTakerFeeBps() external view returns (uint16);
    function feeEpoch() external view returns (uint256);
    function SIGNED_ASK_SCHEMA_VERSION() external view returns (uint16);
    function paused() external view returns (bool);
}

interface ICapacityBidV1 {
    function placeCapacityBid(
        uint256 dailyCapacityPriceWei,
        uint256 minCircuitH,
        uint256 maxCircuitH,
        address nftRecipient,
        address refundRecipient,
        uint16 expectedFeeBps
    ) external payable returns (uint256);
    function cancelCapacityBid(uint256 orderId) external;
    function acceptCapacityBid(
        uint256 orderId,
        address collection,
        uint256 tokenId,
        bytes32 minerKey,
        address proceedsRecipient,
        uint256 expectedDailyCapacityPriceWei,
        uint16 expectedFeeBps,
        uint256 minNetProceedsWei
    ) external;
    function defaultTakerFeeBps() external view returns (uint16);
    function recoveryBnb(address account) external view returns (uint256);
}

interface IPoDKey {
    function minerKey(address circuits, uint256 id) external view returns (bytes32);
}

interface IOfficialMarketView {
    function nextListingId() external view returns (uint256);
}

/// @dev 合约卖家 / 买单方：EIP-1271 只认预先登记的摘要；收 BNB 时记下金额和剩余 gas（看卖款是推送还是记账、给多少 gas）
contract FirstoMakerProbe {
    mapping(bytes32 => bool) public valid;
    uint256 public received;
    uint256 public lastGas;
    uint256 public receiveCount;
    address public watchCollection;
    uint256 public watchToken;
    address public ownerAtReceive; // 收到卖款那一刻矿机在谁手里（看是先交货还是先付款）

    function watch(address c, uint256 id) external {
        watchCollection = c;
        watchToken = id;
    }

    function register(bytes32 digest) external {
        valid[digest] = true;
    }

    function isValidSignature(bytes32 h, bytes calldata) external view returns (bytes4) {
        return valid[h] ? bytes4(0x1626ba7e) : bytes4(0xffffffff);
    }

    function call(address target, uint256 value, bytes calldata data) external returns (bytes memory ret) {
        bool ok;
        (ok, ret) = target.call{value: value}(data);
        if (!ok) {
            assembly {
                revert(add(ret, 32), mload(ret))
            }
        }
    }

    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        return this.onERC721Received.selector;
    }

    receive() external payable {
        lastGas = gasleft();
        if (watchCollection != address(0)) ownerAtReceive = IERC721(watchCollection).ownerOf(watchToken);
        received += msg.value;
        receiveCount++;
    }
}

/// @dev 只收钱、不写存储的合约
contract CheapReceiver {
    receive() external payable {}
}

/// @title Firsto 单笔签名卖单 V2（合约卖家走 EIP-1271）和日产能统一买单 V1（合约挂买单）：主网分叉实测
/// @notice FIRSTO_PROBE=1 BSC_RPC_URL=<主网 RPC>（blastapi）forge test --match-contract FirstoSignedAskProbe -vv
///         第一个测试（EIP-712 哈希对照资料示例）不需要分叉，总是运行。
contract FirstoSignedAskProbe is Test {
    ISignedAskV2 internal constant V2 = ISignedAskV2(0x33423244F9a5bF81b12B1a018aF6F4e079B97f29);
    ICapacityBidV1 internal constant BIDS = ICapacityBidV1(0x9273d46b77B67Ba9B24177C25EC25fcbADf27040);
    address internal constant TAPEOUT = 0xb1024b89886B9a34Aa4ff5F31C411D708b20a14C;
    address internal constant OFFICIAL_MARKET = 0x6feEbbEbC07BcB90bd1Ac8b0CF9BaA4f0fF2B46f;
    address internal constant POD = 0x7E2E0DC66a3bD9103E69b766afA62d9f7b697b46;

    bytes32 internal constant ASK_TYPEHASH = keccak256(
        "SignedAsk(address maker,address collection,uint256 tokenId,uint256 nonce,uint128 price,uint64 expiry,address payoutRecipient,uint16 feeBps,uint256 feeEpoch,uint16 schemaVersion)"
    );

    function _fork() internal returns (bool) {
        if (!vm.envOr("FIRSTO_PROBE", false)) {
            vm.skip(true);
            return false;
        }
        uint256 blk = vm.envOr("FORK_BLOCK", uint256(0));
        if (blk == 0) vm.createSelectFork(vm.envString("BSC_RPC_URL"));
        else vm.createSelectFork(vm.envString("BSC_RPC_URL"), blk);
        return true;
    }

    function _digest(SignedAsk memory a, uint256 chainId) internal pure returns (bytes32) {
        bytes32 domain = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256("Firsto Circuit Signed Ask"),
                keccak256("2"),
                chainId,
                address(V2)
            )
        );
        // 全是静态类型的结构体按字段顺序原样编码，等于 abi.encode(TYPEHASH, maker, collection, …, schemaVersion)
        bytes32 s = keccak256(abi.encode(ASK_TYPEHASH, a));
        return keccak256(abi.encodePacked("\x19\x01", domain, s));
    }

    /// @dev 资料 examples/signed-ask-v2.typed-data.json 的示例单，哈希应等于 examples/signed-ask-v2.example-hash.json
    function test_TypedDataHashMatchesFirstoExample() public pure {
        SignedAsk memory a = SignedAsk(
            0x1111111111111111111111111111111111111111,
            TAPEOUT,
            123,
            123456789,
            1 ether,
            1893456000,
            0x1111111111111111111111111111111111111111,
            100,
            1,
            2
        );
        assertEq(_digest(a, 56), 0x325153d821eab5289316ddfbd38fd289d42874da6e6f77ab8aaf37d9a87d0ac3);
    }

    /// @dev 从官方矿机市场的挂单里找一台还在卖家手里的官方矿机，把它（以卖家身份）转给 to
    function _takeMachine(address to) internal returns (uint256 id) {
        uint256 n = IOfficialMarketView(OFFICIAL_MARKET).nextListingId();
        for (uint256 i = n - 1; i > n - 3000; i--) {
            (bool ok, bytes memory ret) = OFFICIAL_MARKET.staticcall(abi.encodeWithSelector(0xbeab7067, i));
            if (!ok || ret.length < 192) continue;
            (address seller, address col, uint256 tokenId) = abi.decode(ret, (address, address, uint256));
            if (seller == address(0) || col != TAPEOUT) continue;
            try IERC721(TAPEOUT).ownerOf(tokenId) returns (address o) {
                if (o != seller || seller.code.length > 0) continue;
            } catch {
                continue;
            }
            vm.prank(seller);
            IERC721(TAPEOUT).transferFrom(seller, to, tokenId);
            return tokenId;
        }
        revert("no machine");
    }

    function _ask(FirstoMakerProbe maker, uint256 id, uint256 nonce, address payout)
        internal
        view
        returns (SignedAsk memory a)
    {
        a = SignedAsk(
            address(maker),
            TAPEOUT,
            id,
            nonce,
            0.5 ether,
            uint64(block.timestamp + 7 days),
            payout,
            V2.defaultTakerFeeBps(),
            V2.feeEpoch(),
            V2.SIGNED_ASK_SCHEMA_VERSION()
        );
    }

    function _cost(SignedAsk memory a) internal pure returns (uint256) {
        return uint256(a.price) + uint256(a.price) * a.feeBps / 10_000;
    }

    function _fill(SignedAsk memory a, bytes memory sig, address taker) internal returns (bool ok, bytes memory ret) {
        vm.deal(taker, 10 ether);
        vm.prank(taker);
        (ok, ret) = address(V2).call{value: _cost(a)}(abi.encodeCall(V2.fillSignedAsk, (a, sig, taker)));
    }

    /// @dev 合约当卖家：登记过的摘要 → 能否成交；isValidSignature 是否被调用；卖款怎么到账
    function test_ContractMakerFillsThroughEip1271() public {
        if (!_fork()) return;
        console2.log("V2 paused", V2.paused(), "feeBps", V2.defaultTakerFeeBps());
        console2.log("feeEpoch / schema", V2.feeEpoch(), V2.SIGNED_ASK_SCHEMA_VERSION());
        FirstoMakerProbe maker = new FirstoMakerProbe();
        uint256 id = _takeMachine(address(maker));
        maker.call(TAPEOUT, 0, abi.encodeCall(IERC721.approve, (address(V2), id)));
        SignedAsk memory a = _ask(maker, id, 1, address(maker));
        bytes32 d = _digest(a, block.chainid);
        maker.register(d);
        maker.watch(TAPEOUT, id);
        address taker = makeAddr("taker");
        vm.expectCall(address(maker), abi.encodeWithSelector(FirstoMakerProbe.isValidSignature.selector, d));
        vm.recordLogs();
        (bool ok, bytes memory ret) = _fill(a, hex"01", taker);
        console2.log("fill with a registered digest succeeded?", ok);
        if (!ok) console2.logBytes(ret);
        assertTrue(ok, "contract maker fill");
        assertEq(IERC721(TAPEOUT).ownerOf(id), taker, "NFT to nftRecipient");
        console2.log("maker received (wei)", maker.received(), "pushes", maker.receiveCount());
        console2.log("gas left inside maker.receive", maker.lastGas());
        assertEq(maker.ownerAtReceive(), taker, "NFT already delivered when the proceeds arrive");
        Vm.Log[] memory logs = vm.getRecordedLogs();
        console2.log("logs emitted", logs.length);
        assertTrue(V2.isSignedAskNonceInvalidated(address(maker), 1), "nonce consumed");
    }

    /// @dev 没登记的摘要（isValidSignature 返回 0xffffffff）、空签名：都应该拒绝
    function test_ContractMakerRejectsUnregisteredAndEmptySignatures() public {
        if (!_fork()) return;
        FirstoMakerProbe maker = new FirstoMakerProbe();
        uint256 id = _takeMachine(address(maker));
        maker.call(TAPEOUT, 0, abi.encodeCall(IERC721.approve, (address(V2), id)));
        SignedAsk memory a = _ask(maker, id, 7, address(maker));
        address taker = makeAddr("taker");
        (bool ok, bytes memory ret) = _fill(a, hex"01", taker);
        console2.log("unregistered digest filled?", ok);
        if (!ok) console2.logBytes(ret);
        assertFalse(ok);
        maker.register(_digest(a, block.chainid));
        (ok, ret) = _fill(a, "", taker);
        console2.log("registered digest + empty signature filled?", ok);
        if (!ok) console2.logBytes(ret);
        (ok, ret) = _fill(a, hex"deadbeef", taker);
        console2.log("registered digest + arbitrary 4 bytes filled?", ok);
        if (!ok) console2.logBytes(ret);
    }

    /// @dev 撤单：maker 调 cancelSignedAskNonce 后不能成交；只 setApprovalForAll 不够
    function test_CancelAndApprovalRules() public {
        if (!_fork()) return;
        FirstoMakerProbe maker = new FirstoMakerProbe();
        uint256 id = _takeMachine(address(maker));
        maker.call(TAPEOUT, 0, abi.encodeCall(IERC721.setApprovalForAll, (address(V2), true)));
        SignedAsk memory a = _ask(maker, id, 9, address(maker));
        maker.register(_digest(a, block.chainid));
        address taker = makeAddr("taker");
        (bool ok, bytes memory ret) = _fill(a, hex"01", taker);
        console2.log("setApprovalForAll only: filled?", ok);
        if (!ok) console2.logBytes(ret);
        maker.call(TAPEOUT, 0, abi.encodeCall(IERC721.approve, (address(V2), id)));
        maker.call(address(V2), 0, abi.encodeCall(V2.cancelSignedAskNonce, (9)));
        assertTrue(V2.isSignedAskNonceInvalidated(address(maker), 9));
        (ok, ret) = _fill(a, hex"01", taker);
        console2.log("after cancel: filled?", ok);
        if (!ok) console2.logBytes(ret);
        assertFalse(ok, "cancelled nonce");
    }

    /// @dev 合约挂统一买单：另一个地址把一台真实矿机卖给它；NFT 到 nftRecipient、预算扣减、撤单退款
    function test_ContractPlacesCapacityBid() public {
        if (!_fork()) return;
        FirstoMakerProbe bidder = new FirstoMakerProbe();
        vm.deal(address(bidder), 5 ether);
        uint256 dcp = 20 ether; // 每 1 BEM/日 20 BNB（远高于市场，保证这台能卖进来）
        vm.recordLogs();
        bidder.call(
            address(BIDS),
            3 ether,
            abi.encodeCall(
                BIDS.placeCapacityBid, (dcp, 0, 0, address(bidder), address(bidder), BIDS.defaultTakerFeeBps())
            )
        );
        uint256 orderId = _orderIdFromLogs(vm.getRecordedLogs());
        console2.log("capacity bid placed by a contract, orderId", orderId);
        uint256 id = _sellInto(orderId, dcp);
        assertEq(IERC721(TAPEOUT).ownerOf(id), address(bidder), "NFT delivered to the contract (onERC721Received)");
        uint256 b0 = address(bidder).balance;
        bidder.call(address(BIDS), 0, abi.encodeCall(BIDS.cancelCapacityBid, (orderId)));
        uint256 back = address(bidder).balance - b0;
        console2.log("refund pushed to the contract (wei)", back, "recoveryBnb", BIDS.recoveryBnb(address(bidder)));
        assertGt(back + BIDS.recoveryBnb(address(bidder)), 0, "remaining budget refunded");
        // 退款记账后，合约自己提取
        uint256 owed = BIDS.recoveryBnb(address(bidder));
        if (owed > 0) {
            b0 = address(bidder).balance;
            bidder.call(address(BIDS), 0, abi.encodeWithSignature("claimRecoveryBnb(uint256,address)", owed, address(bidder)));
            console2.log("claimRecoveryBnb pulled (wei)", address(bidder).balance - b0);
            assertEq(BIDS.recoveryBnb(address(bidder)), 0);
        }
    }

    /// @dev 退款对象是普通钱包 / 收款只做最少事情的合约时，撤单退款是否直接到账（判断退款推送给的 gas）
    function test_CapacityBidRefundPushTargets() public {
        if (!_fork()) return;
        FirstoMakerProbe bidder = new FirstoMakerProbe();
        vm.deal(address(bidder), 5 ether);
        address eoa = makeAddr("refundEoa");
        address cheap = address(new CheapReceiver());
        address[2] memory targets = [eoa, cheap];
        for (uint256 i = 0; i < 2; i++) {
            vm.recordLogs();
            bidder.call(
                address(BIDS),
                1 ether,
                abi.encodeCall(BIDS.placeCapacityBid, (20 ether, 0, 0, address(bidder), targets[i], BIDS.defaultTakerFeeBps()))
            );
            uint256 orderId = _orderIdFromLogs(vm.getRecordedLogs());
            uint256 b0 = targets[i].balance;
            bidder.call(address(BIDS), 0, abi.encodeCall(BIDS.cancelCapacityBid, (orderId)));
            console2.log(i == 0 ? "EOA refund recipient: pushed" : "cheap contract refund recipient: pushed", targets[i].balance - b0);
            console2.log("  recoveryBnb(maker)", BIDS.recoveryBnb(address(bidder)), "recoveryBnb(recipient)", BIDS.recoveryBnb(targets[i]));
        }
    }

    /// @dev 另一个地址（普通钱包）把一台真实官方矿机卖给第 orderId 张买单
    function _sellInto(uint256 orderId, uint256 dcp) internal returns (uint256 id) {
        address seller = makeAddr("seller");
        id = _takeMachine(seller);
        bytes32 key = IPoDKey(POD).minerKey(TAPEOUT, id);
        uint16 fee = BIDS.defaultTakerFeeBps();
        vm.startPrank(seller);
        IERC721(TAPEOUT).approve(address(BIDS), id);
        uint256 s0 = seller.balance;
        (bool ok, bytes memory ret) =
            address(BIDS).call(abi.encodeCall(BIDS.acceptCapacityBid, (orderId, TAPEOUT, id, key, seller, dcp, fee, 0)));
        vm.stopPrank();
        console2.log("seller filled the contract's bid?", ok);
        if (!ok) console2.logBytes(ret);
        assertTrue(ok);
        console2.log("seller net proceeds (wei)", seller.balance - s0);
    }

    function _orderIdFromLogs(Vm.Log[] memory logs) internal pure returns (uint256) {
        bytes32 sig = keccak256(
            "CapacityBidPlaced(uint256,address,address,address,uint256,uint256,uint256,uint256,uint16)"
        );
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics.length > 0 && logs[i].topics[0] == sig) {
                if (logs[i].topics.length > 1) return uint256(logs[i].topics[1]);
                return abi.decode(logs[i].data, (uint256));
            }
        }
        revert("no CapacityBidPlaced");
    }
}

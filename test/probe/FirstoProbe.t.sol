// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test, console2} from "forge-std/Test.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {TapeSurgeDefaults} from "../../script/TapeSurgeDefaults.sol";

interface IPoDKey {
    function minerKey(address circuits, uint256 tokenId) external view returns (bytes32);
}

/// @dev 探针：一个普通合约账户，代替主板去 Firsto 吃单 / 卖给统一买单
contract FirstoProbe {
    bool public acceptNft;

    function setAcceptNft(bool v) external {
        acceptNft = v;
    }

    receive() external payable {}

    function exec(address target, uint256 value, bytes calldata data) external returns (bool ok, bytes memory ret) {
        (ok, ret) = target.call{value: value}(data);
    }

    function onERC721Received(address, address, uint256, bytes calldata) external view returns (bytes4) {
        require(acceptNft, "probe: no onERC721Received");
        return this.onERC721Received.selector;
    }
}

/// @title Firsto 交易所在 BSC 主网分叉上的可行性探针（只读快照 + 本地分叉，不发任何主网交易）
/// @notice 运行：FIRSTO_PROBE=1 BSC_RPC_URL=<主网 RPC> forge test --match-contract FirstoProbeTest -vv
///         快照 test/probe/firsto-snapshot.json 来自 Firsto 公开 API；卖单被别人买走或过期后测试会失败，重新抓快照即可。
///         调用格式由链上真实成交反推：
///         - 买卖单（经路由 0x8b18…1d59）：0x5a017662((uint256 kind, address collection, uint256 tokenId, uint256 qty, uint256 maxCost,
///           bytes order, uint256 zero)[] items, address recipient, uint256 deadline)，payable；
///         - 卖给统一买单：0x4c67242f(uint256 orderId, address collection, uint256 tokenId, bytes32 minerKey,
///           address proceedsRecipient, uint256 expectedDailyCapacityPrice, uint16 feeBps, uint256 minNetProceeds)。
contract FirstoProbeTest is Test {

    struct Item {
        uint256 kind;
        address collection;
        uint256 tokenId;
        uint256 qty;
        uint256 maxCost;
        bytes order;
        uint256 zero;
    }

    /// @dev Firsto 的买入路由（链上真实买入交易发往这里，由它调用卖单合约 0x3f58…dc43）
    address internal constant ROUTER = 0x8b18Af20165c3168C17F4F5a9250414E5dF81d59;

    string internal snap;
    FirstoProbe internal probe;
    address internal exchange;
    IERC721 internal circuits;
    uint256 internal tokenId;
    uint256 internal cost;

    function setUp() public {
        if (!vm.envOr("FIRSTO_PROBE", false)) return;
        vm.createSelectFork(vm.envString("BSC_RPC_URL"));
        snap = vm.readFile("test/probe/firsto-snapshot.json");
        exchange = vm.parseJsonAddress(snap, ".ask.exchange");
        circuits = IERC721(vm.parseJsonAddress(snap, ".ask.collection"));
        tokenId = _u(".ask.tokenId");
        cost = _u(".ask.buyerCostWei");
        probe = new FirstoProbe();
        vm.deal(address(probe), 100 ether);
    }

    function _u(string memory key) internal view returns (uint256) {
        return vm.parseUint(vm.parseJsonString(snap, key));
    }

    function _order() internal view returns (bytes memory) {
        bytes32[] memory proof = vm.parseJsonBytes32Array(snap, ".ask.merkleProof");
        bytes memory sig = vm.parseJsonBytes(snap, ".ask.signature");
        address maker = vm.parseJsonAddress(snap, ".ask.maker");
        address payout = vm.parseJsonAddress(snap, ".ask.payoutRecipient");
        bytes memory head = abi.encode(
            maker,
            vm.parseJsonBytes32(snap, ".ask.merkleRoot"),
            _u(".ask.batchNonce"),
            _u(".ask.expiry"),
            payout,
            _u(".ask.feeBps"),
            _u(".ask.feeEpoch"),
            _u(".ask.schemaVersion")
        );
        bytes memory leaf = abi.encode(
            maker,
            address(circuits),
            tokenId,
            _u(".ask.priceWei"),
            payout,
            _u(".ask.feeBps"),
            _u(".ask.feeEpoch"),
            _u(".ask.batchNonce"),
            _u(".ask.leafIndex"),
            _u(".ask.schemaVersion")
        );
        // 尾部：(bytes32[] proof, bytes signature) 的 ABI 编码，偏移量相对于整个订单数据的开头（20 个字之后）
        bytes memory tail = abi.encode(uint256(0x280), uint256(0x2a0 + 32 * proof.length), proof.length);
        bytes memory p;
        for (uint256 i = 0; i < proof.length; i++) {
            p = bytes.concat(p, proof[i]);
        }
        uint256 padded = (sig.length + 31) / 32 * 32;
        bytes memory s = bytes.concat(abi.encode(sig.length), sig, new bytes(padded - sig.length));
        return bytes.concat(head, leaf, tail, p, s);
    }

    function _buyCalldata(address recipient, uint256 maxCost) internal view returns (bytes memory) {
        Item[] memory items = new Item[](1);
        items[0] = Item(4, address(circuits), tokenId, 1, maxCost, _order(), 0);
        return abi.encodeWithSelector(bytes4(0x5a017662), items, recipient, block.timestamp + 600);
    }

    function _skip() internal returns (bool) {
        if (!vm.envOr("FIRSTO_PROBE", false)) {
            vm.skip(true);
            return true;
        }
        return false;
    }

    // ---------------- 买 Firsto 卖单 ----------------

    /// @dev 合约账户（不实现 onERC721Received）吃单：能否成交、矿机到谁手里、gas
    function test_ContractBuysAskWithoutReceiverHook() public {
        if (_skip()) return;
        probe.setAcceptNft(false);
        uint256 b0 = address(probe).balance;
        uint256 g = gasleft();
        (bool ok, bytes memory ret) = probe.exec(ROUTER, cost, _buyCalldata(address(probe), cost));
        console2.log("buy (no hook) ok", ok, "gas", g - gasleft());
        if (!ok) console2.logBytes(ret);
        if (ok) {
            console2.log("owner == probe", circuits.ownerOf(tokenId) == address(probe));
            console2.log("paid", b0 - address(probe).balance, "expected", cost);
        }
    }

    function test_ContractBuysAskWithHookAndOverpays() public {
        if (_skip()) return;
        probe.setAcceptNft(true);
        uint256 b0 = address(probe).balance;
        address origin = tx.origin;
        uint256 o0 = origin.balance;
        (bool ok, bytes memory ret) = probe.exec(ROUTER, cost + 0.1 ether, _buyCalldata(address(probe), cost));
        console2.log("buy (overpay 0.1) ok", ok);
        if (!ok) console2.logBytes(ret);
        if (ok) {
            console2.log("owner == probe", circuits.ownerOf(tokenId) == address(probe));
            console2.log("probe net paid", b0 - address(probe).balance, "cost", cost);
            console2.log("tx.origin balance change", origin.balance - o0);
        }
    }

    /// @dev 收货地址填别的地址（例如主板）：矿机去哪里
    function test_ContractBuysAskForAnotherRecipient() public {
        if (_skip()) return;
        address board = makeAddr("board stand-in");
        (bool ok, bytes memory ret) = probe.exec(ROUTER, cost, _buyCalldata(board, cost));
        console2.log("buy for recipient ok", ok);
        if (!ok) console2.logBytes(ret);
        if (ok) console2.log("owner == recipient", circuits.ownerOf(tokenId) == board);
    }

    function test_BuyRejectsWhenMaxCostBelowPrice() public {
        if (_skip()) return;
        (bool ok,) = probe.exec(ROUTER, cost, _buyCalldata(address(probe), cost - 1));
        console2.log("buy with maxCost = cost - 1 ok (expect false)", ok);
        (ok,) = probe.exec(ROUTER, cost - 1, _buyCalldata(address(probe), cost));
        console2.log("buy with value = cost - 1 ok (expect false)", ok);
    }

    /// @dev 不经路由、直接调用卖单合约 0x20b36528(header, leaf, bytes32[] proof, bytes signature, address recipient)
    function _directCalldata(address recipient) internal view returns (bytes memory) {
        bytes memory o = _order();
        // _order() = header(8) + leaf(10) + [proofOffset, sigOffset] + proof + sig；直接调用多一个静态参数 recipient，
        // 两个偏移量各加 32 字节
        bytes32[] memory proof = vm.parseJsonBytes32Array(snap, ".ask.merkleProof");
        bytes memory sig = vm.parseJsonBytes(snap, ".ask.signature");
        bytes memory head = new bytes(18 * 32);
        for (uint256 i = 0; i < head.length; i++) {
            head[i] = o[i];
        }
        bytes memory tail = new bytes(o.length - 20 * 32);
        for (uint256 i = 0; i < tail.length; i++) {
            tail[i] = o[20 * 32 + i];
        }
        uint256 proofOff = 21 * 32;
        uint256 sigOff = proofOff + 32 + 32 * proof.length;
        sig; // 长度已在 tail 里
        return bytes.concat(bytes4(0x20b36528), head, abi.encode(proofOff, sigOff, recipient), tail);
    }

    function test_ContractBuysDirectlyFromAskContract() public {
        if (_skip()) return;
        probe.setAcceptNft(true);
        uint256 b0 = address(probe).balance;
        uint256 g = gasleft();
        (bool ok, bytes memory ret) = probe.exec(exchange, cost, _directCalldata(address(probe)));
        console2.log("direct buy ok", ok, "gas", g - gasleft());
        if (!ok) console2.logBytes(ret);
        if (ok) {
            console2.log("owner == probe", circuits.ownerOf(tokenId) == address(probe));
            console2.log("paid", b0 - address(probe).balance, "expected", cost);
        }
        // 没有 onERC721Received 的合约直接调用：整笔回滚（不像路由那样跳过）
    }

    function test_DirectBuyRevertsForContractWithoutHook() public {
        if (_skip()) return;
        probe.setAcceptNft(false);
        (bool ok,) = probe.exec(exchange, cost, _directCalldata(address(probe)));
        console2.log("direct buy without hook ok (expect false)", ok);
    }

    // ---------------- 卖给 Firsto 统一买单 ----------------

    function _sellCalldata(string memory bidKey, address proceeds, uint256 minNet) internal view returns (bytes memory) {
        bytes32 key = IPoDKey(TapeSurgeDefaults.mainnetAddresses().pod).minerKey(address(circuits), tokenId);
        return abi.encodeWithSelector(
            bytes4(0x4c67242f),
            _u(string.concat(bidKey, ".orderId")),
            address(circuits),
            tokenId,
            key,
            proceeds,
            _u(string.concat(bidKey, ".dailyCapacityPriceWei")),
            uint16(_u(string.concat(bidKey, ".feeBps"))),
            minNet
        );
    }

    /// @dev 先吃单买到一台，再由同一个合约卖给统一买单：要不要授权、钱打到哪、gas
    function test_ContractSellsToCapacityBid() public {
        if (_skip()) return;
        probe.setAcceptNft(true);
        (bool ok, bytes memory ret) = probe.exec(ROUTER, cost, _buyCalldata(address(probe), cost));
        require(ok, "buy failed");
        address bidEx = vm.parseJsonAddress(snap, ".bidExchange");
        address proceeds = makeAddr("proceeds");
        // 1. 不授权
        (ok, ret) = probe.exec(bidEx, 0, _sellCalldata(".bidSizeRange", proceeds, 0));
        console2.log("sell without approval ok (expect false)", ok);
        if (!ok) console2.logBytes(ret);
        // 2. 只给 setApprovalForAll：买单合约只看 getApproved(tokenId)，仍然不行
        probe.exec(address(circuits), 0, abi.encodeWithSelector(IERC721.setApprovalForAll.selector, bidEx, true));
        (ok,) = probe.exec(bidEx, 0, _sellCalldata(".bidSizeRange", proceeds, 0));
        console2.log("sell with setApprovalForAll only ok (expect false)", ok);
        // 3. 按 tokenId 授权买单合约后再卖
        probe.exec(address(circuits), 0, abi.encodeWithSelector(IERC721.approve.selector, bidEx, tokenId));
        uint256 p0 = proceeds.balance;
        uint256 g = gasleft();
        (ok, ret) = probe.exec(bidEx, 0, _sellCalldata(".bidSizeRange", proceeds, 0));
        console2.log("sell to size-range bid ok", ok, "gas", g - gasleft());
        if (!ok) {
            console2.logBytes(ret);
            (ok, ret) = probe.exec(bidEx, 0, _sellCalldata(".bidAnySize", proceeds, 0));
            console2.log("sell to any-size bid ok", ok);
            if (!ok) console2.logBytes(ret);
        }
        if (ok) {
            console2.log("proceeds received (wei)", proceeds.balance - p0);
            console2.log("nft new owner", circuits.ownerOf(tokenId));
        }
    }

    /// @dev minNetProceeds 高于实际到手：应当整笔回滚
    function test_SellRejectsWhenMinNetTooHigh() public {
        if (_skip()) return;
        probe.setAcceptNft(true);
        (bool ok,) = probe.exec(ROUTER, cost, _buyCalldata(address(probe), cost));
        require(ok, "buy failed");
        address bidEx = vm.parseJsonAddress(snap, ".bidExchange");
        probe.exec(address(circuits), 0, abi.encodeWithSelector(IERC721.approve.selector, bidEx, tokenId));
        (ok,) = probe.exec(bidEx, 0, _sellCalldata(".bidAnySize", makeAddr("proceeds"), 100 ether));
        console2.log("sell with minNet = 100 BNB ok (expect false)", ok);
    }
}

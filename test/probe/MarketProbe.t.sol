// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test, console2} from "forge-std/Test.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";

interface IOfficialMarket {
    function list(address collection, uint256 tokenId, uint96 price) external returns (uint256);
    function setPrice(uint256 listingId, uint96 price) external;
    function delist(uint256 listingId) external;
    function delistStale(uint256 listingId) external;
    function buy(uint256 listingId, uint96 maxPrice) external payable;
    function owed(address account) external view returns (uint256);
    function withdraw() external;
    function listingOf(address collection, uint256 tokenId) external view returns (uint256);
    function nextListingId() external view returns (uint256);
    function feeBps() external view returns (uint256);
    function isSealed() external view returns (bool);
    function owner() external view returns (address);
}

/// @dev 合约账户：实现 onERC721Received（官方市场用 safeTransferFrom 交货，没有它买入回滚 ERC721InvalidReceiver），能收 BNB。
///      收款时记录：剩余 gas、此刻矿机在谁手里；可以设置成收款时回滚（看市场是回滚整笔还是改记账）。
contract MarketProbeAccount {
    bool public revertOnReceive;
    uint256 public gasAtReceive;
    address public watchCollection;
    uint256 public watchId;
    address public ownerAtReceive;
    uint256 public received;

    function call(address target, uint256 value, bytes calldata data) external returns (bytes memory ret) {
        bool ok;
        (ok, ret) = target.call{value: value}(data);
        if (!ok) {
            assembly {
                revert(add(ret, 32), mload(ret))
            }
        }
    }

    function setRevert(bool v) external {
        revertOnReceive = v;
    }

    function watch(address c, uint256 id) external {
        watchCollection = c;
        watchId = id;
    }

    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        return this.onERC721Received.selector;
    }

    function isValidSignature(bytes32, bytes calldata) external pure returns (bytes4) {
        return 0xffffffff;
    }

    receive() external payable {
        require(!revertOnReceive, "probe: refuse BNB");
        gasAtReceive = gasleft();
        received += msg.value;
        if (watchCollection != address(0)) ownerAtReceive = IERC721(watchCollection).ownerOf(watchId);
    }
}

/// @dev 没有 onERC721Received 的合约账户
contract PlainAccount {
    function call(address target, uint256 value, bytes calldata data) external returns (bool ok, bytes memory ret) {
        (ok, ret) = target.call{value: value}(data);
    }

    receive() external payable {}
}

/// @title TapeOut 官方矿机市场 0x6fee…b46f：主网分叉实测（合约买入、合约挂单 / 改价 / 撤单、卖款提取）
/// @notice MARKET_PROBE=1 BSC_RPC_URL=<主网 RPC> forge test --match-contract OfficialMarketProbe -vv
contract OfficialMarketProbe is Test {
    IOfficialMarket internal constant M = IOfficialMarket(0x6feEbbEbC07BcB90bd1Ac8b0CF9BaA4f0fF2B46f);
    address internal constant OFFICIAL = 0xb1024b89886B9a34Aa4ff5F31C411D708b20a14C;

    function setUp() public {
        if (!vm.envOr("MARKET_PROBE", false)) return;
        uint256 blk = vm.envOr("FORK_BLOCK", uint256(0));
        if (blk == 0) vm.createSelectFork(vm.envString("BSC_RPC_URL"));
        else vm.createSelectFork(vm.envString("BSC_RPC_URL"), blk);
    }

    function _skip() internal returns (bool) {
        if (!vm.envOr("MARKET_PROBE", false)) {
            vm.skip(true);
            return true;
        }
        return false;
    }

    struct L {
        address seller;
        address collection;
        uint256 tokenId;
        uint256 price;
        uint256 feeBps;
        uint256 status;
    }

    function _view(uint256 id) internal view returns (L memory l) {
        (bool ok, bytes memory ret) = address(M).staticcall(abi.encodeWithSelector(0xbeab7067, id));
        require(ok && ret.length >= 192, "listingView");
        l = abi.decode(ret, (L));
    }

    /// @dev 从最新的挂单号往回找一张还有效、卖家仍持有、对 collection 的挂单
    function _live(address collection) internal view returns (uint256 id, L memory l) {
        uint256 n = M.nextListingId();
        for (uint256 i = n - 1; i > n - 3000; i--) {
            l = _view(i);
            if (l.seller == address(0) || l.collection != collection) continue;
            try IERC721(collection).ownerOf(l.tokenId) returns (address o) {
                if (o != l.seller) continue;
            } catch {
                continue;
            }
            return (i, l);
        }
        revert("no live listing");
    }

    function test_ContractBuysListsRepricesDelistsAndWithdraws() public {
        if (_skip()) return;
        console2.log("owner", M.owner(), "sealed", M.isSealed());
        console2.log("feeBps", M.feeBps());
        (uint256 id, L memory l) = _live(OFFICIAL);
        console2.log("live listing", id, "tokenId", l.tokenId);
        console2.log("price", l.price, "status", l.status);

        // 1. 合约买入：付多少？矿机到谁？
        MarketProbeAccount buyer = new MarketProbeAccount();
        vm.deal(address(buyer), 10 ether);
        uint256 sellerOwed0 = M.owed(l.seller);
        uint256 sellerBal0 = l.seller.balance;
        uint256 b0 = address(buyer).balance;
        buyer.call(address(M), l.price, abi.encodeCall(M.buy, (id, uint96(l.price))));
        console2.log("buyer paid", b0 - address(buyer).balance);
        assertEq(IERC721(OFFICIAL).ownerOf(l.tokenId), address(buyer), "delivered to the calling contract");
        console2.log(
            "seller owed delta", M.owed(l.seller) - sellerOwed0, "seller bal delta", l.seller.balance - sellerBal0
        );
        console2.log("listingOf after sale", M.listingOf(OFFICIAL, l.tokenId));

        // 2. 合约挂单：先授权（看挂单是否托管 NFT）
        buyer.call(OFFICIAL, 0, abi.encodeCall(IERC721.setApprovalForAll, (address(M), true)));
        bytes memory r = buyer.call(address(M), 0, abi.encodeCall(M.list, (OFFICIAL, l.tokenId, uint96(1 ether))));
        uint256 lid = abi.decode(r, (uint256));
        console2.log("contract listed, id", lid, "nft owner now", IERC721(OFFICIAL).ownerOf(l.tokenId));
        L memory mine = _view(lid);
        assertEq(mine.seller, address(buyer));
        assertEq(mine.price, 1 ether);
        // 改价
        buyer.call(address(M), 0, abi.encodeCall(M.setPrice, (lid, uint96(0.5 ether))));
        assertEq(_view(lid).price, 0.5 ether, "setPrice");
        // 撤单再挂
        buyer.call(address(M), 0, abi.encodeCall(M.delist, (lid)));
        console2.log("after delist status", _view(lid).status, "listingOf", M.listingOf(OFFICIAL, l.tokenId));
        r = buyer.call(address(M), 0, abi.encodeCall(M.list, (OFFICIAL, l.tokenId, uint96(0.4 ether))));
        lid = abi.decode(r, (uint256));

        // 3. 别人买走合约挂的单：卖款到哪？
        address eoa = makeAddr("eoaBuyer");
        vm.deal(eoa, 10 ether);
        uint256 seller0 = address(buyer).balance;
        vm.prank(eoa);
        M.buy{value: 0.4 ether}(lid, uint96(0.4 ether));
        assertEq(IERC721(OFFICIAL).ownerOf(l.tokenId), eoa);
        uint256 owedNow = M.owed(address(buyer));
        console2.log("contract seller: pushed", address(buyer).balance - seller0, "owed", owedNow);
        if (owedNow > 0) {
            uint256 before = address(buyer).balance;
            buyer.call(address(M), 0, abi.encodeCall(M.withdraw, ()));
            console2.log("withdrawn", address(buyer).balance - before);
            assertEq(M.owed(address(buyer)), 0);
        }
    }

    /// @dev 挂单后 NFT 转走 / 授权撤销：挂单是否还能成交，delistStale 谁能调
    function test_StaleListing() public {
        if (_skip()) return;
        (uint256 id, L memory l) = _live(OFFICIAL);
        MarketProbeAccount a = new MarketProbeAccount();
        vm.deal(address(a), 10 ether);
        a.call(address(M), l.price, abi.encodeCall(M.buy, (id, uint96(l.price))));
        a.call(OFFICIAL, 0, abi.encodeCall(IERC721.setApprovalForAll, (address(M), true)));
        uint256 lid = abi.decode(
            a.call(address(M), 0, abi.encodeCall(M.list, (OFFICIAL, l.tokenId, uint96(0.3 ether)))), (uint256)
        );
        // NFT 转走：挂单变成"陈旧"
        address other = makeAddr("other");
        a.call(
            OFFICIAL, 0, abi.encodeWithSignature("transferFrom(address,address,uint256)", address(a), other, l.tokenId)
        );
        address eoa = makeAddr("eoa2");
        vm.deal(eoa, 1 ether);
        vm.prank(eoa);
        (bool ok,) = address(M).call{value: 0.3 ether}(abi.encodeCall(M.buy, (lid, uint96(0.3 ether))));
        console2.log("buy after NFT moved succeeded?", ok);
        vm.prank(eoa);
        (ok,) = address(M).call(abi.encodeCall(M.delistStale, (lid)));
        console2.log("anyone can delistStale?", ok);
    }

    address internal constant BEHEMOTH = 0x1F5Cb4aeaE1807Bf60c3b9C0D8aDBCC14e91f12C;

    /// @dev 先买下一张活挂单，得到一个持有矿机、已授权市场的合约账户
    function _own(address collection) internal returns (MarketProbeAccount a, uint256 tokenId) {
        uint256 id;
        L memory l;
        if (collection == BEHEMOTH) {
            // 往回扫 Behemoth 挂单太慢（每个挂单一次 RPC），用 API 查到的挂单号（tokenId 249，FORK_BLOCK=129350109 时有效）
            id = vm.envOr("BEHEMOTH_LISTING", uint256(23422));
            l = _view(id);
            require(
                l.collection == BEHEMOTH && IERC721(BEHEMOTH).ownerOf(l.tokenId) == l.seller, "stale behemoth listing"
            );
        } else {
            (id, l) = _live(collection);
        }
        a = new MarketProbeAccount();
        vm.deal(address(a), 100 ether);
        a.call(address(M), l.price, abi.encodeCall(M.buy, (id, uint96(l.price))));
        tokenId = l.tokenId;
        a.call(collection, 0, abi.encodeCall(IERC721.setApprovalForAll, (address(M), true)));
    }

    /// @dev 卖款推送：转给卖方时还剩多少 gas、矿机是否已经交到买家；卖方收款回滚时整笔回滚还是改记账
    function test_SellerPushSemantics() public {
        if (_skip()) return;
        (MarketProbeAccount a, uint256 tokenId) = _own(OFFICIAL);
        uint256 g = gasleft();
        uint256 lid = abi.decode(
            a.call(address(M), 0, abi.encodeCall(M.list, (OFFICIAL, tokenId, uint96(0.2 ether)))), (uint256)
        );
        console2.log("list gas", g - gasleft());
        g = gasleft();
        a.call(address(M), 0, abi.encodeCall(M.setPrice, (lid, uint96(0.25 ether))));
        console2.log("setPrice gas", g - gasleft());
        a.watch(OFFICIAL, tokenId);
        address eoa = makeAddr("eoa3");
        vm.deal(eoa, 10 ether);
        g = gasleft();
        vm.prank(eoa);
        M.buy{value: 0.25 ether}(lid, uint96(0.25 ether));
        console2.log("buy gas (seller = contract)", g - gasleft());
        console2.log("seller received", a.received(), "gas left in receive", a.gasAtReceive());
        console2.log("owner at receive is buyer?", a.ownerAtReceive() == eoa);

        // 卖方收款回滚
        vm.prank(eoa);
        IERC721(OFFICIAL).transferFrom(eoa, address(a), tokenId);
        lid = abi.decode(
            a.call(address(M), 0, abi.encodeCall(M.list, (OFFICIAL, tokenId, uint96(0.3 ether)))), (uint256)
        );
        a.setRevert(true);
        vm.prank(eoa);
        (bool ok, bytes memory ret) = address(M).call{value: 0.3 ether}(abi.encodeCall(M.buy, (lid, uint96(0.3 ether))));
        console2.log("buy succeeds when seller refuses BNB?", ok);
        if (!ok) {
            console2.logBytes(ret);
        } else {
            console2.log(
                "seller owed after refused push",
                M.owed(address(a)),
                "new owner is buyer",
                IERC721(OFFICIAL).ownerOf(tokenId) == eoa
            );
        }
    }

    /// @dev 已授权的操作员能不能替持有人挂单；买方是没有 onERC721Received 的合约时能不能买；多付 / 少付
    function test_OperatorListingAndPlainBuyer() public {
        if (_skip()) return;
        (MarketProbeAccount a, uint256 tokenId) = _own(OFFICIAL);
        MarketProbeAccount op = new MarketProbeAccount();
        a.call(OFFICIAL, 0, abi.encodeCall(IERC721.setApprovalForAll, (address(op), true)));
        (bool ok, bytes memory ret) = address(op)
            .call(
                abi.encodeCall(op.call, (address(M), 0, abi.encodeCall(M.list, (OFFICIAL, tokenId, uint96(0.2 ether)))))
            );
        console2.log("approved operator can list for owner?", ok);
        if (!ok) console2.logBytes(ret);

        uint256 lid = abi.decode(
            a.call(address(M), 0, abi.encodeCall(M.list, (OFFICIAL, tokenId, uint96(0.2 ether)))), (uint256)
        );
        PlainAccount p = new PlainAccount();
        vm.deal(address(p), 10 ether);
        (ok, ret) = p.call(address(M), 0.2 ether, abi.encodeCall(M.buy, (lid, uint96(0.2 ether))));
        console2.log("buyer without onERC721Received succeeds?", ok);
        if (!ok) console2.logBytes(ret);
        (ok,) = p.call(address(M), 0.21 ether, abi.encodeCall(M.buy, (lid, uint96(0.21 ether))));
        console2.log("overpay accepted?", ok);
        (ok,) = p.call(address(M), 0.19 ether, abi.encodeCall(M.buy, (lid, uint96(0.2 ether))));
        console2.log("underpay accepted?", ok);
        (ok,) = p.call(address(M), 0.2 ether, abi.encodeCall(M.buy, (lid, uint96(0.19 ether))));
        console2.log("maxPrice below price accepted?", ok);
    }

    /// @dev Behemoth 合集在官方市场：合约买入、挂单
    function test_BehemothOnOfficialMarket() public {
        if (_skip()) return;
        (MarketProbeAccount a, uint256 tokenId) = _own(BEHEMOTH);
        assertEq(IERC721(BEHEMOTH).ownerOf(tokenId), address(a));
        uint256 lid =
            abi.decode(a.call(address(M), 0, abi.encodeCall(M.list, (BEHEMOTH, tokenId, uint96(1 ether)))), (uint256));
        L memory mine = _view(lid);
        assertEq(mine.collection, BEHEMOTH);
        console2.log("behemoth listed by contract, id", lid, "token", tokenId);
        // 非工厂合集能不能挂（拿一个普通 ERC721：通行证以外随便一个合约都不行，这里用 Seaport 地址代替会直接回滚）
        (bool ok,) = address(a)
            .call(
                abi.encodeCall(a.call, (address(M), 0, abi.encodeCall(M.list, (address(0xdead), 1, uint96(1 ether)))))
            );
        console2.log("non-CPU collection listable?", ok);
    }
}

// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test, console2} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {MarketProbeAccount, IOfficialMarket} from "./MarketProbe.t.sol";

// Seaport 1.6 的结构（枚举按 uint8 编码：ItemType 0 原生币 / 1 ERC20 / 2 ERC721 / 4 ERC721 按条件；OrderType 0 FULL_OPEN）
struct OfferItem {
    uint8 itemType;
    address token;
    uint256 identifierOrCriteria;
    uint256 startAmount;
    uint256 endAmount;
}

struct ConsiderationItem {
    uint8 itemType;
    address token;
    uint256 identifierOrCriteria;
    uint256 startAmount;
    uint256 endAmount;
    address payable recipient;
}

struct OrderParameters {
    address offerer;
    address zone;
    OfferItem[] offer;
    ConsiderationItem[] consideration;
    uint8 orderType;
    uint256 startTime;
    uint256 endTime;
    bytes32 zoneHash;
    uint256 salt;
    bytes32 conduitKey;
    uint256 totalOriginalConsiderationItems;
}

struct Order {
    OrderParameters parameters;
    bytes signature;
}

struct AdvancedOrder {
    OrderParameters parameters;
    uint120 numerator;
    uint120 denominator;
    bytes signature;
    bytes extraData;
}

struct OrderComponents {
    address offerer;
    address zone;
    OfferItem[] offer;
    ConsiderationItem[] consideration;
    uint8 orderType;
    uint256 startTime;
    uint256 endTime;
    bytes32 zoneHash;
    uint256 salt;
    bytes32 conduitKey;
    uint256 counter;
}

struct CriteriaResolver {
    uint256 orderIndex;
    uint8 side;
    uint256 index;
    uint256 identifier;
    bytes32[] criteriaProof;
}

interface ISeaport {
    function fulfillOrder(Order calldata order, bytes32 fulfillerConduitKey) external payable returns (bool);
    function fulfillAdvancedOrder(
        AdvancedOrder calldata advancedOrder,
        CriteriaResolver[] calldata criteriaResolvers,
        bytes32 fulfillerConduitKey,
        address recipient
    ) external payable returns (bool);
    function validate(Order[] calldata orders) external returns (bool);
    function cancel(OrderComponents[] calldata orders) external returns (bool);
    function getOrderHash(OrderComponents calldata order) external view returns (bytes32);
    function getOrderStatus(bytes32 orderHash)
        external
        view
        returns (bool isValidated, bool isCancelled, uint256 totalFilled, uint256 totalSize);
    function getCounter(address offerer) external view returns (uint256);
    function information()
        external
        view
        returns (string memory version, bytes32 domainSeparator, address conduitController);
}

interface IWBNB {
    function deposit() external payable;
    function withdraw(uint256) external;
}

/// @title Seaport 1.6（tapeout.market 的 TAPEMARKET_SEAPORT 来源）主网分叉实测
/// @notice MARKET_PROBE=1 FORK_BLOCK=129350109 BSC_RPC_URL=<主网 RPC> forge test --match-contract SeaportProbe -vv
///         真实卖单来自 api.tapeout.market/api/v1/listings/<orderHash>（2026-10-24 抓取，FORK_BLOCK 时有效）。
contract SeaportProbe is Test {
    ISeaport internal constant SP = ISeaport(0x0000000000000068F116a894984e2DB1123eB395);
    IOfficialMarket internal constant OM = IOfficialMarket(0x6feEbbEbC07BcB90bd1Ac8b0CF9BaA4f0fF2B46f);
    address internal constant OFFICIAL = 0xb1024b89886B9a34Aa4ff5F31C411D708b20a14C;
    address internal constant BEHEMOTH = 0x1F5Cb4aeaE1807Bf60c3b9C0D8aDBCC14e91f12C;
    address internal constant WBNB = 0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c;
    /// @dev tapeout.market 的 Seaport 卖单都带一项 1% 的买方手续费，付给这个地址
    address payable internal constant TM_FEE = payable(0xf0972A5ee0FD4054159A8c7177e59126ef478dA9);

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

    // ============ 真实卖单 ============

    /// @dev tapeout.market 卖单 0x0fa8…2e47：官方矿机 #8340（71 算力），卖方到手 3.1643 BNB + 1% 手续费
    function _realOrder8340() internal pure returns (OrderParameters memory p, bytes memory sig, uint256 total) {
        p.offerer = 0x78e3a21209a35FD6BD101eb9eA0f44D00EcE2F88;
        p.offer = new OfferItem[](1);
        p.offer[0] = OfferItem(2, OFFICIAL, 8340, 1, 1);
        p.consideration = new ConsiderationItem[](2);
        p.consideration[0] =
            ConsiderationItem(0, address(0), 0, 3164337029702970300, 3164337029702970300, payable(p.offerer));
        p.consideration[1] = ConsiderationItem(0, address(0), 0, 31643370297029703, 31643370297029703, TM_FEE);
        p.startTime = 1792668741;
        p.endTime = 1793273541;
        p.salt = 0x66e82ff5a011fc4b;
        p.totalOriginalConsiderationItems = 2;
        sig =
            hex"1cab36df043c2014562750423f992aa452c348f7f8694c35e2faf584b9fcd5e80b7032b32b1eee90ba2905ff01fe3e9bfae26fdd80a1678a950a38d880d2c9dd";
        total = 3164337029702970300 + 31643370297029703;
    }

    /// @dev tapeout.market 卖单 0xd4df…64be：Behemoth #1050（60 算力），卖方到手 3.5 BNB + 1%
    function _realOrder1050() internal pure returns (OrderParameters memory p, bytes memory sig, uint256 total) {
        p.offerer = 0x1A1443e6B832F2Db3Ee86F099fa22aBCa7e763A2;
        p.offer = new OfferItem[](1);
        p.offer[0] = OfferItem(2, BEHEMOTH, 1050, 1, 1);
        p.consideration = new ConsiderationItem[](2);
        p.consideration[0] = ConsiderationItem(0, address(0), 0, 3.5 ether, 3.5 ether, payable(p.offerer));
        p.consideration[1] = ConsiderationItem(0, address(0), 0, 0.035 ether, 0.035 ether, TM_FEE);
        p.startTime = 1792743192;
        p.endTime = 1793347992;
        p.salt = 0xd5d3fb172e54bdda;
        p.totalOriginalConsiderationItems = 2;
        sig =
            hex"507fc7bc9c510ebffef3a3210c68b7b44f5cc3af246782d8690852a6d8c1282dab273a01657e14ba6da6469617c29a5bd3959e87b4985cc49015339e49a6de28";
        total = 3.535 ether;
    }

    function _components(OrderParameters memory p, uint256 counter) internal pure returns (OrderComponents memory c) {
        c.offerer = p.offerer;
        c.zone = p.zone;
        c.offer = p.offer;
        c.consideration = p.consideration;
        c.orderType = p.orderType;
        c.startTime = p.startTime;
        c.endTime = p.endTime;
        c.zoneHash = p.zoneHash;
        c.salt = p.salt;
        c.conduitKey = p.conduitKey;
        c.counter = counter;
    }

    function _fill(
        MarketProbeAccount buyer,
        OrderParameters memory p,
        bytes memory sig,
        uint256 value,
        address recipient
    ) internal returns (uint256 gasUsed) {
        bytes memory data = abi.encodeCall(
            SP.fulfillAdvancedOrder, (AdvancedOrder(p, 1, 1, sig, ""), new CriteriaResolver[](0), bytes32(0), recipient)
        );
        gasUsed = gasleft();
        buyer.call(address(SP), value, data);
        gasUsed -= gasleft();
    }

    /// @dev 合约买 Seaport 卖单：fulfillAdvancedOrder 可以指定收货地址；多付的 BNB 退回调用者
    function test_ContractBuysRealListings() public {
        if (_skip()) return;
        MarketProbeAccount buyer = new MarketProbeAccount();
        vm.deal(address(buyer), 20 ether);
        address recipient = address(new MarketProbeAccount());

        (OrderParameters memory p, bytes memory sig, uint256 total) = _realOrder8340();
        (bool v, bool c,,) = SP.getOrderStatus(SP.getOrderHash(_components(p, SP.getCounter(p.offerer))));
        console2.log("order 8340 validated/cancelled", v, c);
        uint256 b0 = address(buyer).balance;
        console2.log("fulfillAdvancedOrder gas", _fill(buyer, p, sig, total + 1 ether, recipient));
        console2.log("buyer net paid", b0 - address(buyer).balance, "expected", total);
        assertEq(IERC721(OFFICIAL).ownerOf(8340), recipient, "delivered to recipient");

        (p, sig, total) = _realOrder1050();
        console2.log("behemoth fulfill gas", _fill(buyer, p, sig, total, address(buyer)));
        assertEq(IERC721(BEHEMOTH).ownerOf(1050), address(buyer));
    }

    // ============ 合约在 Seaport 上挂单 ============

    function _ownViaOfficial() internal returns (MarketProbeAccount a, uint256 tokenId) {
        // 从官方市场往回找一张活的官方矿机挂单买下来
        uint256 n = OM.nextListingId();
        for (uint256 i = n - 1; i > n - 300; i--) {
            (bool ok, bytes memory ret) = address(OM).staticcall(abi.encodeWithSelector(0xbeab7067, i));
            if (!ok) continue;
            (address seller, address col, uint256 id, uint256 price,,) =
                abi.decode(ret, (address, address, uint256, uint256, uint256, uint256));
            if (seller == address(0) || col != OFFICIAL) continue;
            try IERC721(OFFICIAL).ownerOf(id) returns (address o) {
                if (o != seller) continue;
            } catch {
                continue;
            }
            a = new MarketProbeAccount();
            vm.deal(address(a), 100 ether);
            a.call(address(OM), price, abi.encodeCall(OM.buy, (i, uint96(price))));
            return (a, id);
        }
        revert("no live official listing");
    }

    function _listing(address offerer, address col, uint256 id, uint256 price, uint256 salt)
        internal
        view
        returns (OrderParameters memory p)
    {
        p.offerer = offerer;
        p.offer = new OfferItem[](1);
        p.offer[0] = OfferItem(2, col, id, 1, 1);
        p.consideration = new ConsiderationItem[](2);
        p.consideration[0] = ConsiderationItem(0, address(0), 0, price, price, payable(offerer));
        p.consideration[1] = ConsiderationItem(0, address(0), 0, price / 100, price / 100, TM_FEE);
        p.startTime = block.timestamp;
        p.endTime = block.timestamp + 30 days;
        p.salt = salt;
        p.totalOriginalConsiderationItems = 2;
    }

    /// @dev 合约用 validate() 链上挂单（不需要签名），别人用空签名成交；卖方收款时矿机是否已交出、剩多少 gas；收款回滚能否挡住成交；
    ///      撤单（cancel）后不能成交；改价 = 撤旧单 + 挂新单
    function test_ContractListsValidatesCancels() public {
        if (_skip()) return;
        (MarketProbeAccount a, uint256 id) = _ownViaOfficial();
        a.call(OFFICIAL, 0, abi.encodeCall(IERC721.setApprovalForAll, (address(SP), true)));

        OrderParameters memory p = _listing(address(a), OFFICIAL, id, 0.5 ether, 1);
        Order[] memory os = new Order[](1);
        os[0] = Order(p, "");
        uint256 g = gasleft();
        a.call(address(SP), 0, abi.encodeCall(SP.validate, (os)));
        console2.log("validate gas", g - gasleft());
        bytes32 h = SP.getOrderHash(_components(p, SP.getCounter(address(a))));
        (bool v,,,) = SP.getOrderStatus(h);
        assertTrue(v, "validated on chain");

        // 别人不能替 offerer validate（没有签名）
        Order[] memory os2 = new Order[](1);
        os2[0] = Order(_listing(address(a), OFFICIAL, id, 0.1 ether, 99), "");
        (bool ok,) = address(SP).call(abi.encodeCall(SP.validate, (os2)));
        console2.log("third party can validate for a contract offerer without signature?", ok);

        // 改价：撤旧单、挂新单
        OrderComponents[] memory cs = new OrderComponents[](1);
        cs[0] = _components(p, SP.getCounter(address(a)));
        g = gasleft();
        a.call(address(SP), 0, abi.encodeCall(SP.cancel, (cs)));
        console2.log("cancel gas", g - gasleft());
        address eoa = makeAddr("spBuyer");
        vm.deal(eoa, 10 ether);
        vm.prank(eoa);
        (ok,) = address(SP).call{value: 0.505 ether}(abi.encodeCall(SP.fulfillOrder, (Order(p, ""), bytes32(0))));
        console2.log("fill after cancel succeeds?", ok);
        // 别人能不能撤合约的单
        (ok,) = address(SP).call(abi.encodeCall(SP.cancel, (cs)));
        console2.log("third party can cancel?", ok);

        p = _listing(address(a), OFFICIAL, id, 0.4 ether, 2);
        os[0] = Order(p, "");
        a.call(address(SP), 0, abi.encodeCall(SP.validate, (os)));

        // 卖方收款回滚：整笔成交回滚？
        a.setRevert(true);
        vm.prank(eoa);
        (ok,) = address(SP).call{value: 0.404 ether}(abi.encodeCall(SP.fulfillOrder, (Order(p, ""), bytes32(0))));
        console2.log("fill succeeds when offerer refuses BNB?", ok);
        a.setRevert(false);

        a.watch(OFFICIAL, id);
        uint256 fee0 = TM_FEE.balance;
        g = gasleft();
        vm.prank(eoa);
        SP.fulfillOrder{value: 0.404 ether}(Order(p, ""), bytes32(0));
        console2.log("fulfillOrder gas (offerer = contract)", g - gasleft());
        assertEq(IERC721(OFFICIAL).ownerOf(id), eoa);
        console2.log("offerer received", a.received(), "fee recipient got", TM_FEE.balance - fee0);
        console2.log("NFT already at buyer when offerer is paid?", a.ownerAtReceive() == eoa);
        console2.log("gas left in offerer receive", a.gasAtReceive());
    }

    // ============ 接受出价 ============

    function _offer(address bidder, bool criteria, uint256 id, uint256 salt)
        internal
        view
        returns (OrderParameters memory p)
    {
        p.offerer = bidder;
        p.offer = new OfferItem[](1);
        p.offer[0] = OfferItem(1, WBNB, 0, 1 ether, 1 ether);
        p.consideration = new ConsiderationItem[](1);
        p.consideration[0] = ConsiderationItem(criteria ? 4 : 2, OFFICIAL, criteria ? 0 : id, 1, 1, payable(bidder));
        p.startTime = block.timestamp;
        p.endTime = block.timestamp + 1 days;
        p.salt = salt;
        p.totalOriginalConsiderationItems = 1;
    }

    function _sign(uint256 pk, OrderParameters memory p) internal view returns (bytes memory) {
        (, bytes32 domain,) = SP.information();
        bytes32 h = SP.getOrderHash(_components(p, SP.getCounter(p.offerer)));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, keccak256(abi.encodePacked("\x19\x01", domain, h)));
        return abi.encodePacked(r, s, v);
    }

    function _accept(MarketProbeAccount a, OrderParameters memory p, bytes memory sig, CriteriaResolver[] memory cr)
        internal
        returns (uint256 gasUsed)
    {
        bytes memory data =
            abi.encodeCall(SP.fulfillAdvancedOrder, (AdvancedOrder(p, 1, 1, sig, ""), cr, bytes32(0), address(a)));
        gasUsed = gasleft();
        a.call(address(SP), 0, data);
        gasUsed -= gasleft();
    }

    /// @dev 普通钱包签一张 WBNB 出价（指定矿机，或整个合集任意一台），合约持有人用 fulfillAdvancedOrder 接受，收到 WBNB
    function test_ContractAcceptsOffers() public {
        if (_skip()) return;
        (MarketProbeAccount a, uint256 id) = _ownViaOfficial();
        a.call(OFFICIAL, 0, abi.encodeCall(IERC721.setApprovalForAll, (address(SP), true)));
        (address bidder, uint256 pk) = makeAddrAndKey("bidder");
        vm.deal(bidder, 10 ether);
        vm.startPrank(bidder);
        IWBNB(WBNB).deposit{value: 5 ether}();
        IERC20(WBNB).approve(address(SP), type(uint256).max);
        vm.stopPrank();

        for (uint256 k = 0; k < 2; k++) {
            bool criteria = k == 1;
            OrderParameters memory p = _offer(bidder, criteria, id, 100 + k);
            bytes memory sig = _sign(pk, p);
            CriteriaResolver[] memory cr = new CriteriaResolver[](criteria ? 1 : 0);
            if (criteria) cr[0] = CriteriaResolver(0, 1, 0, id, new bytes32[](0));
            uint256 w0 = IERC20(WBNB).balanceOf(address(a));
            uint256 g = _accept(a, p, sig, cr);
            console2.log(criteria ? "collection offer accepted, gas" : "token offer accepted, gas", g);
            console2.log("seller got WBNB", IERC20(WBNB).balanceOf(address(a)) - w0);
            assertEq(IERC721(OFFICIAL).ownerOf(id), bidder);
            // 退回，接下一张
            vm.prank(bidder);
            IERC721(OFFICIAL).transferFrom(bidder, address(a), id);
        }
    }
}

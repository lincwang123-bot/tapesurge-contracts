// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {
    AdvancedOrder,
    CriteriaResolver,
    Order,
    OrderComponents,
    OrderParameters,
    OfferItem,
    ConsiderationItem
} from "../market/IMarkets.sol";

interface ICPURegistry {
    function isCPU(address circuits) external view returns (bool);
}

/// @title MockOfficialMarket（仅测试 / 测试网：模拟 TapeOut 官方矿机市场 0x6fee…b46f）
/// @notice 复现 2026-10-24 主网分叉实测的行为（MARKET-PROBE.md 第 2 节）：只有持有人能挂单（"not owner"）、只收工厂创建的
///         处理器的矿机、挂单不托管；buy 必须正好付挂单价，用 safeTransferFrom 交货，再把扣掉手续费的卖款带全部 gas 推给卖方，
///         卖方收款回滚则整笔回滚；矿机转走后挂单失效，任何人可以 delistStale。
contract MockOfficialMarket {
    struct Listing {
        address seller;
        address collection;
        uint256 tokenId;
        uint256 price;
        uint256 feeBps;
        uint256 status; // 1 = 挂着
    }

    ICPURegistry public immutable FACTORY;
    address public immutable protocolWallet;
    uint256 public feeBps = 100;
    uint256 public nextListingId = 1;
    /// @notice 测试辅助：模拟官方市场升级成"卖款先记账、卖方自己提"
    bool public pullMode;
    mapping(address => uint256) public owed;
    mapping(uint256 => Listing) internal _listings;
    mapping(address => mapping(uint256 => uint256)) public listingOf;

    event Listed(uint256 indexed listingId, address indexed seller, address collection, uint256 tokenId, uint256 price);
    event Bought(uint256 indexed listingId, address indexed buyer, uint256 price);

    constructor(address factory, address wallet) {
        FACTORY = ICPURegistry(factory);
        protocolWallet = wallet;
    }

    function setPullMode(bool v) external {
        pullMode = v;
    }

    function withdraw() external {
        uint256 a = owed[msg.sender];
        owed[msg.sender] = 0;
        (bool ok,) = msg.sender.call{value: a}("");
        require(ok, "withdraw failed");
    }

    function setFeeBps(uint256 b) external {
        require(b <= 300, "fee");
        feeBps = b;
    }

    function list(address collection, uint256 tokenId, uint96 price) external returns (uint256 id) {
        require(FACTORY.isCPU(collection), "not cpu");
        require(IERC721(collection).ownerOf(tokenId) == msg.sender, "not owner");
        require(
            IERC721(collection).isApprovedForAll(msg.sender, address(this))
                || IERC721(collection).getApproved(tokenId) == address(this),
            "not approved"
        );
        require(price > 0 && listingOf[collection][tokenId] == 0, "listed");
        id = nextListingId++;
        _listings[id] = Listing(msg.sender, collection, tokenId, price, feeBps, 1);
        listingOf[collection][tokenId] = id;
        emit Listed(id, msg.sender, collection, tokenId, price);
    }

    function setPrice(uint256 id, uint96 price) external {
        Listing storage l = _listings[id];
        require(l.status == 1 && l.seller == msg.sender && price > 0, "not seller");
        l.price = price;
    }

    function delist(uint256 id) external {
        Listing storage l = _listings[id];
        require(l.status == 1 && l.seller == msg.sender, "not seller");
        _close(l);
    }

    function delistStale(uint256 id) external {
        Listing storage l = _listings[id];
        require(l.status == 1 && IERC721(l.collection).ownerOf(l.tokenId) != l.seller, "not stale");
        _close(l);
    }

    function buy(uint256 id, uint96 maxPrice) external payable {
        Listing storage l = _listings[id];
        require(l.status == 1, "inactive");
        require(l.price <= maxPrice && msg.value == l.price, "bad payment");
        require(IERC721(l.collection).ownerOf(l.tokenId) == l.seller, "stale");
        address seller = l.seller;
        uint256 price = l.price;
        uint256 fee = price * feeBps / 10_000;
        _close(l);
        IERC721(l.collection).safeTransferFrom(seller, msg.sender, l.tokenId);
        (bool ok,) = protocolWallet.call{value: fee}("");
        require(ok, "pay fee failed");
        if (pullMode) {
            owed[seller] += price - fee;
        } else {
            (ok,) = seller.call{value: price - fee}("");
            require(ok, "pay seller failed");
        }
        emit Bought(id, msg.sender, price);
    }

    function _close(Listing storage l) internal {
        l.status = 0;
        listingOf[l.collection][l.tokenId] = 0;
    }

    function listingView(uint256 id)
        external
        view
        returns (address seller, address collection, uint256 tokenId, uint256 price, uint256 fee, uint256 status)
    {
        Listing storage l = _listings[id];
        return (l.seller, l.collection, l.tokenId, l.price, l.feeBps, l.status);
    }
}

/// @title MockSeaport（仅测试 / 测试网：Seaport 1.6 的一个子集）
/// @notice 只支持本项目用到的部分：链上 validate / cancel（只有 offerer 本人）、fulfillAdvancedOrder（整单成交，金额不随时间
///         变化；对价里的 ERC721 可以按条件匹配）。没有签名（offerer 先 validate）、没有 zone、没有 conduit。
///         成交顺序和主网一致：先把 offer 项从 offerer 转给收货人，再由成交方付对价（原生币带全部 gas 推送，收款方回滚则整笔回滚）。
contract MockSeaport {
    mapping(bytes32 => bool) public validated;
    mapping(bytes32 => bool) public cancelled;
    mapping(bytes32 => bool) public filled;

    event OrderFulfilled(bytes32 indexed orderHash, address indexed offerer, address indexed fulfiller);

    function getCounter(address) external pure returns (uint256) {
        return 0;
    }

    function getOrderHash(OrderComponents memory c) public pure returns (bytes32) {
        return keccak256(abi.encode(c));
    }

    function _hash(OrderParameters memory p) internal pure returns (bytes32) {
        return getOrderHash(
            OrderComponents(
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
                0
            )
        );
    }

    function validate(Order[] calldata orders) external returns (bool) {
        for (uint256 i = 0; i < orders.length; i++) {
            require(orders[i].parameters.offerer == msg.sender, "signature");
            bytes32 h = _hash(orders[i].parameters);
            require(!cancelled[h], "cancelled");
            validated[h] = true;
        }
        return true;
    }

    function cancel(OrderComponents[] calldata orders) external returns (bool) {
        for (uint256 i = 0; i < orders.length; i++) {
            require(orders[i].offerer == msg.sender, "offerer");
            bytes32 h = getOrderHash(orders[i]);
            require(!filled[h], "filled");
            cancelled[h] = true;
        }
        return true;
    }

    function fulfillAdvancedOrder(
        AdvancedOrder calldata a,
        CriteriaResolver[] calldata resolvers,
        bytes32,
        address recipient
    ) external payable returns (bool) {
        OrderParameters calldata p = a.parameters;
        bytes32 h = _hash(p);
        require(validated[h] && !cancelled[h] && !filled[h], "order");
        require(block.timestamp >= p.startTime && block.timestamp < p.endTime, "time");
        filled[h] = true;
        if (recipient == address(0)) recipient = msg.sender;
        for (uint256 i = 0; i < p.offer.length; i++) {
            OfferItem calldata o = p.offer[i];
            require(o.startAmount == o.endAmount, "amount");
            if (o.itemType == 2) IERC721(o.token).transferFrom(p.offerer, recipient, o.identifierOrCriteria);
            else if (o.itemType == 1) require(
                IERC20(o.token).transferFrom(p.offerer, recipient, o.startAmount), "erc20"
            );
            else revert("offer item");
        }
        uint256 spent;
        for (uint256 i = 0; i < p.consideration.length; i++) {
            ConsiderationItem calldata c = p.consideration[i];
            require(c.startAmount == c.endAmount, "amount");
            if (c.itemType == 0) {
                spent += c.startAmount;
                (bool ok,) = c.recipient.call{value: c.startAmount}("");
                require(ok, "native transfer");
            } else if (c.itemType == 1) {
                require(IERC20(c.token).transferFrom(msg.sender, c.recipient, c.startAmount), "erc20");
            } else if (c.itemType == 2 || c.itemType == 4) {
                uint256 id = c.identifierOrCriteria;
                if (c.itemType == 4) {
                    require(id == 0, "criteria root");
                    id = _resolve(resolvers, i);
                }
                IERC721(c.token).transferFrom(msg.sender, c.recipient, id);
            } else {
                revert("consideration item");
            }
        }
        require(msg.value >= spent, "insufficient value");
        if (msg.value > spent) {
            (bool ok,) = msg.sender.call{value: msg.value - spent}("");
            require(ok, "refund");
        }
        emit OrderFulfilled(h, p.offerer, msg.sender);
        return true;
    }

    function _resolve(CriteriaResolver[] calldata resolvers, uint256 index) internal pure returns (uint256) {
        for (uint256 k = 0; k < resolvers.length; k++) {
            if (resolvers[k].side == 1 && resolvers[k].index == index) return resolvers[k].identifier;
        }
        revert("no resolver");
    }
}

/// @title MockWBNB（仅测试：最简单的 WBNB）
contract MockWBNB {
    string public constant name = "Wrapped BNB";
    string public constant symbol = "WBNB";
    uint8 public constant decimals = 18;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function deposit() public payable {
        balanceOf[msg.sender] += msg.value;
    }

    function withdraw(uint256 amount) external {
        balanceOf[msg.sender] -= amount;
        (bool ok,) = msg.sender.call{value: amount}("");
        require(ok, "withdraw");
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        if (from != msg.sender && allowance[from][msg.sender] != type(uint256).max) {
            allowance[from][msg.sender] -= amount;
        }
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    receive() external payable {
        deposit();
    }
}

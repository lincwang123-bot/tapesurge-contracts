// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @notice TapeOut 官方矿机市场 `0x6feEbbEbC07BcB90bd1Ac8b0CF9BaA4f0fF2B46f`（UUPS 代理，Safe 管理；源码未公开，
///         函数名按选择器数据库解析、行为按 2026-10-24 主网分叉实测，MARKET-PROBE.md 第 2 节）：
///         - 链上挂单不托管矿机：只有持有人能 list（"not owner"），矿机留在卖方，买入时用 safeTransferFrom 交给买方
///           （买方是合约时必须实现 onERC721Received）；
///         - buy 必须正好付挂单价，maxPrice 小于挂单价回滚；手续费（feeBps，现在 1%，上限 3%）从卖方的款里扣；
///         - 卖款带全部 gas 直接推给卖方，推款时矿机已经交到买方；卖方收款回滚则整笔 buy 回滚；
///         - 挂单后矿机转走即失效，任何人可以 delistStale；没有暂停功能；只收工厂创建的处理器的矿机。
interface IOfficialMarket {
    function list(address collection, uint256 tokenId, uint96 price) external returns (uint256 listingId);
    function setPrice(uint256 listingId, uint96 price) external;
    function delist(uint256 listingId) external;
    function buy(uint256 listingId, uint96 maxPrice) external payable;
    function feeBps() external view returns (uint256);
    /// @dev 卖方名下记账待提的卖款（现在的实现推款失败就整笔回滚，实测一直为 0；为对方升级成"先记账后提"留的退路）
    function owed(address account) external view returns (uint256);
    function withdraw() external;
    /// @dev 选择器 0xbeab7067：(seller, collection, tokenId, price, feeBps, status)
    function listingView(uint256 listingId)
        external
        view
        returns (address seller, address collection, uint256 tokenId, uint256 price, uint256 feeBps, uint256 status);
}

// ============ Seaport 1.6 `0x0000000000000068F116a894984e2DB1123eB395`（不可升级、无管理员）============
// 枚举按 uint8 编码：ItemType 0 原生币 / 1 ERC20 / 2 ERC721 / 3 ERC1155 / 4 ERC721 按条件 / 5 ERC1155 按条件；
// OrderType 0 FULL_OPEN；Side 0 OFFER / 1 CONSIDERATION。

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

/// @notice 实测（MARKET-PROBE.md 第 3 节）：合约能 fulfillAdvancedOrder 买卖单（可指定收货地址）、接受 WBNB 出价
///         （单台 / 整合集）；offerer 是合约时用 validate() 链上挂单（只有 offerer 本人能 validate / cancel）；
///         卖款带全部 gas 推给收款方，推款时矿机已经交出，收款回滚则整笔成交回滚。
interface ISeaport {
    function fulfillAdvancedOrder(
        AdvancedOrder calldata advancedOrder,
        CriteriaResolver[] calldata criteriaResolvers,
        bytes32 fulfillerConduitKey,
        address recipient
    ) external payable returns (bool);
    function validate(Order[] calldata orders) external returns (bool);
    function cancel(OrderComponents[] calldata orders) external returns (bool);
    function getCounter(address offerer) external view returns (uint256);
}

interface IWBNBLike {
    function withdraw(uint256 amount) external;
}

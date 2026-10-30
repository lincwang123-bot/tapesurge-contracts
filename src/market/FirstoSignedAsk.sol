// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @notice Firsto 单笔签名卖单 V2 的订单（字段和顺序同 Firsto 接入资料第五节；FIRSTO-PROBE.md 第 7 节实测）
struct SignedAsk {
    address maker;
    address collection;
    uint256 tokenId;
    uint256 nonce;
    uint128 price; // BNB wei：卖方到手；买方另付 price × feeBps / 10000 给 Firsto
    uint64 expiry;
    address payoutRecipient;
    uint16 feeBps;
    uint256 feeEpoch;
    uint16 schemaVersion;
}

/// @notice Firsto 单笔签名卖单 V2（主网 0x33423244F9a5bF81b12B1a018aF6F4e079B97f29，UUPS）用到的接口
interface IFirstoSignedAsk {
    function fillSignedAsk(SignedAsk calldata ask, bytes calldata signature, address nftRecipient) external payable;
    function cancelSignedAskNonce(uint256 nonce) external;
    function isSignedAskNonceInvalidated(address maker, uint256 nonce) external view returns (bool);
    function defaultTakerFeeBps() external view returns (uint16);
    function feeEpoch() external view returns (uint256);
    function SIGNED_ASK_SCHEMA_VERSION() external view returns (uint16);
}

/// @title FirstoSignedAskLib：签名卖单 V2 的 EIP-712 摘要
/// @notice domain = ("Firsto Circuit Signed Ask", "2", chainId, 卖单合约地址)；摘要 = Firsto 的 askHash。
///         和资料示例的哈希一致（test/probe/FirstoSignedAskProbe.t.sol）。
library FirstoSignedAskLib {
    bytes32 internal constant DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");
    bytes32 internal constant NAME_HASH = keccak256("Firsto Circuit Signed Ask");
    bytes32 internal constant VERSION_HASH = keccak256("2");
    bytes32 internal constant ASK_TYPEHASH = keccak256(
        "SignedAsk(address maker,address collection,uint256 tokenId,uint256 nonce,uint128 price,uint64 expiry,address payoutRecipient,uint16 feeBps,uint256 feeEpoch,uint16 schemaVersion)"
    );

    function digest(address exchange, SignedAsk memory a) internal view returns (bytes32) {
        bytes32 domain = keccak256(abi.encode(DOMAIN_TYPEHASH, NAME_HASH, VERSION_HASH, block.chainid, exchange));
        // 全是静态类型的结构体按字段顺序原样编码
        return keccak256(abi.encodePacked("\x19\x01", domain, keccak256(abi.encode(ASK_TYPEHASH, a))));
    }
}

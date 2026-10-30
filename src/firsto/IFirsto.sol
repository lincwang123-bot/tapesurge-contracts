// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @notice Firsto 卖单（circuit_batch_ask）的字段，和 Firsto API `bestAsk.execution` 一一对应（FIRSTO-PROBE.md 第 2 节）。
///         卖单合约 0x3f58…dc43 的买入函数 0x20b36528(AskHeader, AskLeaf, bytes32[] proof, bytes signature, address recipient)。
struct AskHeader {
    address maker;
    bytes32 merkleRoot;
    uint256 batchNonce;
    uint256 expiry;
    address payoutRecipient;
    uint256 feeBps;
    uint256 feeEpoch;
    uint256 schemaVersion;
}

struct AskLeaf {
    address maker;
    address collection;
    uint256 tokenId;
    uint256 priceWei;
    address payoutRecipient;
    uint256 feeBps;
    uint256 feeEpoch;
    uint256 batchNonce;
    uint256 leafIndex;
    uint256 schemaVersion;
}

struct AskOrder {
    AskHeader header;
    AskLeaf leaf;
    bytes32[] merkleProof;
    bytes signature;
}

/// @notice Firsto 统一买单（capacity bid）的成交参数，和 Firsto API `/v1/circuit/capacity-bids` 对应。
///         统一买单合约 0x9273…7040 的卖出函数 0x4c67242f(orderId, collection, tokenId, minerKey, proceedsRecipient,
///         expectedDailyCapacityPrice, feeBps, minNetProceeds)。
struct BidOrder {
    uint256 orderId;
    uint256 dailyCapacityPriceWei; // 必须等于订单当前的日产能价（防止对方改价）
    uint16 feeBps; // 必须等于订单当前的手续费率
    uint256 minNetProceedsWei; // 卖方到手（BNB）至少多少，不够整笔回滚
}

/// @notice BEM ↔ BNB 闪电兑换适配器（主网：PancakeSwap V3 池子；测试网 / 本地：mock）
interface IFirstoSwapper {
    /// @notice 先把 bnbOut 个 BNB 发给调用者，再回调 onFlash(owedBem, data)；回调结束前调用者要把 owedBem 个 BEM 转给本合约
    function flashBnb(uint256 bnbOut, bytes calldata data) external;
    /// @notice 先把 bemOut 个 BEM 发给调用者，再回调 onFlash(owedBnb, data)；回调结束前调用者要把 owedBnb 个 BNB（原生币）转给本合约
    function flashBem(uint256 bemOut, bytes calldata data) external;
    /// @notice 把附带的 BNB 全部换成 BEM 发给 to，至少 minOut
    function swapBnbForBem(uint256 minOut, address to) external payable returns (uint256 out);
}

interface IFirstoSwapCallback {
    function onFlash(uint256 owed, bytes calldata data) external;
}

// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IRandomSource, IRandomConsumer, IBoardRegistry} from "../interfaces/IRandomSource.sol";

/// @notice Chainlink VRF v2.5 的请求结构（与 @chainlink/contracts VRFV2PlusClient 相同的 ABI）。
library VRFV2PlusClient {
    bytes4 internal constant EXTRA_ARGS_V1_TAG = bytes4(keccak256("VRF ExtraArgsV1"));

    struct ExtraArgsV1 {
        bool nativePayment;
    }

    struct RandomWordsRequest {
        bytes32 keyHash;
        uint256 subId;
        uint16 requestConfirmations;
        uint32 callbackGasLimit;
        uint32 numWords;
        bytes extraArgs;
    }

    function argsToBytes(ExtraArgsV1 memory extraArgs) internal pure returns (bytes memory) {
        return abi.encodeWithSelector(EXTRA_ARGS_V1_TAG, extraArgs);
    }
}

interface IVRFCoordinatorV2Plus {
    function requestRandomWords(VRFV2PlusClient.RandomWordsRequest calldata req) external returns (uint256 requestId);
}

/// @title Chainlink VRF v2.5 随机数适配器（主网和测试网共用）
/// @notice 不可升级，没有管理员：协调器、keyHash、订阅号、确认数、回调 gas 全部在构造时写死。
///         没有继承 Chainlink 的 VRFConsumerBaseV2Plus，因为它带 owner 和 setCoordinator（管理员权限）。
///
///         只接受官方 BoardFactory 创建的主板发起请求，防止别人消耗 VRF 订阅。
///         由于主板地址要等 BoardFactory 部署后才有，部署脚本先预测 BoardFactory 的地址再部署本合约。
///
///         订阅（subscription）的所有者需要把本合约加为 consumer 并充值。订阅所有者如果取消订阅，
///         VRF 会停摆，主板会按"24 小时重新请求 / 7 天安全退出"的兜底规则处理。
contract ChainlinkVRFAdapter is IRandomSource {
    IVRFCoordinatorV2Plus public immutable coordinator;
    bytes32 public immutable keyHash;
    uint256 public immutable subscriptionId;
    uint16 public immutable requestConfirmations;
    uint32 public immutable callbackGasLimit;
    bool public immutable nativePayment;
    IBoardRegistry public immutable registry;

    mapping(uint256 => address) public consumerOf;

    event RandomnessRequested(uint256 indexed requestId, address indexed consumer);
    event RandomnessDelivered(uint256 indexed requestId, address indexed consumer, bool success);

    error NotBoard();
    error OnlyCoordinator();
    error BadConfig();

    constructor(
        address coordinator_,
        bytes32 keyHash_,
        uint256 subscriptionId_,
        uint16 requestConfirmations_,
        uint32 callbackGasLimit_,
        bool nativePayment_,
        address registry_
    ) {
        // 内审 F3：协调器和注册中心非零；回调 gas > 0；确认数在 Chainlink 允许的 3–200 之间
        if (
            coordinator_ == address(0) || registry_ == address(0) || callbackGasLimit_ == 0 || requestConfirmations_ < 3
                || requestConfirmations_ > 200
        ) revert BadConfig();
        coordinator = IVRFCoordinatorV2Plus(coordinator_);
        keyHash = keyHash_;
        subscriptionId = subscriptionId_;
        requestConfirmations = requestConfirmations_;
        callbackGasLimit = callbackGasLimit_;
        nativePayment = nativePayment_;
        registry = IBoardRegistry(registry_);
    }

    function requestRandomness() external returns (uint256 requestId) {
        if (!registry.isBoard(msg.sender)) revert NotBoard();
        requestId = coordinator.requestRandomWords(
            VRFV2PlusClient.RandomWordsRequest({
                keyHash: keyHash,
                subId: subscriptionId,
                requestConfirmations: requestConfirmations,
                callbackGasLimit: callbackGasLimit,
                numWords: 1,
                extraArgs: VRFV2PlusClient.argsToBytes(VRFV2PlusClient.ExtraArgsV1({nativePayment: nativePayment}))
            })
        );
        consumerOf[requestId] = msg.sender;
        emit RandomnessRequested(requestId, msg.sender);
    }

    /// @notice VRF 协调器回调（与 VRFConsumerBaseV2Plus 的函数签名相同）。
    /// @dev 用 try/catch 转发：主板回调即使失败也不会让协调器的回调失败，主板之后可按超时规则重新请求。
    function rawFulfillRandomWords(uint256 requestId, uint256[] calldata randomWords) external {
        if (msg.sender != address(coordinator)) revert OnlyCoordinator();
        address consumer = consumerOf[requestId];
        if (consumer == address(0) || randomWords.length == 0) return;
        delete consumerOf[requestId];
        bool success;
        try IRandomConsumer(consumer).onRandomness(requestId, randomWords[0]) {
            success = true;
        } catch {}
        emit RandomnessDelivered(requestId, consumer, success);
    }
}

// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IRandomSource, IRandomConsumer} from "../interfaces/IRandomSource.sol";
import {VRFV2PlusClient} from "../random/ChainlinkVRFAdapter.sol";

/// @notice 仅用于测试：异步随机数源。请求后由测试代码调用 fulfill 交付随机数。
contract MockRandomSource is IRandomSource {
    uint256 public lastRequestId;
    mapping(uint256 => address) public consumerOf;

    event Requested(uint256 indexed requestId, address indexed consumer);

    function requestRandomness() external returns (uint256 requestId) {
        requestId = ++lastRequestId;
        consumerOf[requestId] = msg.sender;
        emit Requested(requestId, msg.sender);
    }

    function fulfill(uint256 requestId, uint256 word) external {
        IRandomConsumer(consumerOf[requestId]).onRandomness(requestId, word);
    }
}

interface IRawFulfill {
    function rawFulfillRandomWords(uint256 requestId, uint256[] calldata randomWords) external;
}

/// @notice 仅用于测试：模拟 Chainlink VRF v2.5 协调器。
contract MockVRFCoordinatorV2Plus {
    uint256 public lastRequestId;
    mapping(uint256 => address) public consumerOf;
    VRFV2PlusClient.RandomWordsRequest internal _last;

    function requestRandomWords(VRFV2PlusClient.RandomWordsRequest calldata req) external returns (uint256 requestId) {
        requestId = ++lastRequestId;
        consumerOf[requestId] = msg.sender;
        _last = req;
    }

    function lastRequest() external view returns (VRFV2PlusClient.RandomWordsRequest memory) {
        return _last;
    }

    function fulfill(uint256 requestId, uint256 word) external {
        uint256[] memory words = new uint256[](1);
        words[0] = word;
        IRawFulfill(consumerOf[requestId]).rawFulfillRandomWords{gas: _last.callbackGasLimit}(requestId, words);
    }
}

// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Fixture} from "./utils/Fixture.sol";
import {TapeSurgeDefaults} from "../script/TapeSurgeDefaults.sol";
import {TapeBoard} from "../src/TapeBoard.sol";
import {BoardFactory} from "../src/BoardFactory.sol";
import {ChainlinkVRFAdapter, VRFV2PlusClient} from "../src/random/ChainlinkVRFAdapter.sol";
import {MockVRFCoordinatorV2Plus} from "../src/mocks/MockRandom.sol";
import {MonthBoard} from "../src/MonthBoard.sol";
import {MonthFactory} from "../src/MonthFactory.sol";
import {MonthState} from "../src/interfaces/IMonthBoard.sol";

/// @notice Chainlink VRF v2.5 适配器：只接受官方主板的请求、只接受协调器回调、回调 gas 足够
contract VRFAdapterTest is Fixture {
    MockVRFCoordinatorV2Plus internal coord;
    ChainlinkVRFAdapter internal adapter;
    bytes32 internal constant KEY_HASH = keccak256("bsc-testnet-key");
    uint256 internal constant SUB_ID = 12345;
    uint32 internal constant CALLBACK_GAS = TapeSurgeDefaults.VRF_CALLBACK_GAS; // 部署默认值 75 万

    function setUp() public override {
        vm.warp(START_TIME);
        _deployMocks();
        coord = new MockVRFCoordinatorV2Plus();
        // 适配器只认 BoardFactory 创建的主板：先预测 BoardFactory 的地址（适配器之后依次部署分账合约、BoardFactory）
        address predicted = vm.computeCreateAddress(address(this), vm.getNonce(address(this)) + 2);
        adapter = new ChainlinkVRFAdapter(address(coord), KEY_HASH, SUB_ID, 3, CALLBACK_GAS, true, predicted);
        BoardFactory.Params memory p = defaultParams();
        p.board.randomSource = address(adapter);
        MonthFactory.Params memory mp = defaultMonthParams();
        mp.board.randomSource = address(adapter);
        _deploySystem(p, mp);
        assertEq(address(factory), predicted);
    }

    function test_RevertWhen_RequesterIsNotBoard() public {
        vm.expectRevert(ChainlinkVRFAdapter.NotBoard.selector);
        adapter.requestRandomness();
    }

    function test_RevertWhen_FulfillerIsNotCoordinator() public {
        uint256[] memory words = new uint256[](1);
        vm.expectRevert(ChainlinkVRFAdapter.OnlyCoordinator.selector);
        adapter.rawFulfillRandomWords(1, words);
    }

    function test_FullDrawThroughChainlinkAdapter() public {
        TapeBoard b = _startGenesis();
        _fillUniform(b, 25, 20 * BEM_1);
        _sell(b, _newUser(), 200);
        _topUpPool(b);
        b.pulse();
        uint256 id = b.pendingRequestId();
        assertEq(adapter.consumerOf(id), address(b));
        VRFV2PlusClient.RandomWordsRequest memory req = coord.lastRequest();
        assertEq(req.keyHash, KEY_HASH);
        assertEq(req.subId, SUB_ID);
        assertEq(req.requestConfirmations, 3);
        assertEq(req.callbackGasLimit, CALLBACK_GAS);
        assertEq(req.numWords, 1);
        assertEq(
            req.extraArgs,
            abi.encodeWithSelector(bytes4(keccak256("VRF ExtraArgsV1")), VRFV2PlusClient.ExtraArgsV1(true))
        );
        // 协调器用 callbackGasLimit 的 gas 回调：主板在这个预算内完成抽签和记账
        coord.fulfill(id, uint256(keccak256("word")));
        assertEq(b.aliveCount(), 24);
        assertFalse(b.drawPending());
        // 同一请求重复回调：适配器已删除映射，直接忽略
        coord.fulfill(id, 1);
        assertEq(b.aliveCount(), 24);
    }

    function test_CallbackGasFitsForLargestBoard() public {
        // 1,000 BEM 主板、最小投入 2 BEM：最多约 500 人，树最深
        BoardFactory.Params memory p = defaultParams();
        p.targets.initialTarget = 1_000 * BEM_1;
        address predicted = vm.computeCreateAddress(address(this), vm.getNonce(address(this)) + 2);
        adapter = new ChainlinkVRFAdapter(address(coord), KEY_HASH, SUB_ID, 3, CALLBACK_GAS, true, predicted);
        p.board.randomSource = address(adapter);
        _deploySystem(p);
        TapeBoard b = _startGenesis();
        _fillUniform(b, 500, 2 * BEM_1);
        _sell(b, _newUser(), 200);
        _topUpPool(b);
        b.pulse();
        uint256 g = gasleft();
        coord.fulfill(b.pendingRequestId(), uint256(keccak256("deep")));
        uint256 used = g - gasleft();
        assertEq(b.aliveCount(), 499, "callback succeeded within gas limit");
        assertLt(used, CALLBACK_GAS);
    }

    function test_MonthBoardDrawThroughChainlinkAdapter() public {
        _startGenesis();
        MonthBoard mb = _monthBoard();
        _fillMonth(mb);
        _sellMonth(mb, _newUser(), 50);
        vm.warp(mb.prepEnd());
        mb.sync();
        pod.addYield(mb.machine(0).key, 5 * BEM_1);
        vm.warp(mb.miningEnd());
        mb.drawPrizes();
        uint256 id = mb.pendingRequestId();
        assertEq(adapter.consumerOf(id), address(mb), "hub recognises month boards");
        uint256 g = gasleft();
        coord.fulfill(id, uint256(keccak256("month")));
        assertLt(g - gasleft(), 150_000, "month callback only stores the word (incl. coordinator + adapter)");
        assertTrue(mb.wordReceived(), "callback succeeded");
        mb.finalizePrizes();
        assertTrue(mb.prizesDrawn());
        assertEq(uint256(mb.state()), uint256(MonthState.Settling));
    }
}

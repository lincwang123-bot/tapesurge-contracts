// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test, console2} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {TapeSurgeDefaults} from "../../script/TapeSurgeDefaults.sol";
import {MarketTrader} from "../../src/market/MarketTrader.sol";
import {PancakeFirstoSwapper} from "../../src/firsto/PancakeFirstoSwapper.sol";
import {PancakeV3TwapOracle} from "../../src/oracle/PancakeV3TwapOracle.sol";
import {AskHeader, AskLeaf, AskOrder, BidOrder} from "../../src/firsto/IFirsto.sol";

/// @dev 最小的"主板 + 卖矿合约 + 注册中心"桩：只实现 MarketTrader 用到的接口，规则检查在本地单元测试里覆盖
contract StubBoard {
    IERC20 public immutable bem;
    IERC721 public immutable circuits;
    uint256 public askPrice; // 卖矿合约的要价（整台，BEM）
    uint256 public tokenId;

    constructor(address bem_, address circuits_) {
        bem = IERC20(bem_);
        circuits = IERC721(circuits_);
    }

    // 注册中心
    function isBoard(address) external pure returns (bool) {
        return true;
    }

    /// @dev 规则决定 6.37：MarketTrader 的买入只认运营地址；这里由部署本合约的测试合约当运营地址
    address public immutable operator = msg.sender;

    // 主板：MarketTrader 按实际花费卖进来
    function sellMachine(address, uint256 id, uint256 paid) external returns (uint256) {
        circuits.transferFrom(msg.sender, address(this), id);
        tokenId = id;
        bem.transfer(msg.sender, paid);
        return paid;
    }

    function SALES() external view returns (address) {
        return address(this);
    }

    /// @dev 按月局 MachineView 的字段返回（key, circuitId, collection, weight, active, sold, cost）。规则决定 6.37 起卖矿溢价分成
    ///      在所有结局都收，MarketTrader 卖出时会查 PREMIUM_FEE_BPS 和这台的成本；成本设成最大值 = 没有溢价，不收分成
    function machine(uint256) external view returns (bytes32, uint256, address, uint64, bool, bool, uint128) {
        return (bytes32(0), tokenId, address(circuits), 0, true, false, type(uint128).max);
    }

    function PREMIUM_FEE_BPS() external pure returns (uint256) {
        return 1_000;
    }

    function setAskPrice(uint256 p) external {
        askPrice = p;
    }

    // 卖矿合约：按要价卖给调用者
    function buyMachine(address, uint256, uint256) external returns (uint256) {
        bem.transferFrom(msg.sender, address(this), askPrice);
        circuits.transferFrom(address(this), msg.sender, tokenId);
        return askPrice;
    }
}

/// @title MarketTrader 主网分叉集成测试：真实 Firsto 卖单 / 统一买单 + 真实 PancakeSwap V3 池子（嵌套闪电兑换）
/// @notice FIRSTO_PROBE=1 BSC_RPC_URL=<主网 RPC> forge test --match-contract MarketTraderForkTest -vv
contract MarketTraderForkTest is Test {
    string internal snap;
    StubBoard internal board;
    MarketTrader internal trader;
    PancakeFirstoSwapper internal swapper;
    PancakeV3TwapOracle internal oracle;
    TapeSurgeDefaults.Mainnet internal m;

    function setUp() public {
        if (!vm.envOr("FIRSTO_PROBE", false)) return;
        // 快照里的订单会成交或过期：FIRSTO_FORK_BLOCK 设成快照的区块（askSourceBlock 附近）可以重放；不设时用最新区块
        uint256 blk = vm.envOr("FIRSTO_FORK_BLOCK", uint256(0));
        if (blk == 0) vm.createSelectFork(vm.envString("BSC_RPC_URL"));
        else vm.createSelectFork(vm.envString("BSC_RPC_URL"), blk);
        snap = vm.readFile("test/probe/firsto-snapshot.json");
        m = TapeSurgeDefaults.mainnetAddresses();
        address[] memory tokens = new address[](3);
        tokens[0] = m.wbnb;
        tokens[1] = m.usdt;
        tokens[2] = m.bem;
        address[] memory pools = new address[](2);
        pools[0] = m.poolWbnbUsdt;
        pools[1] = m.poolUsdtBem;
        oracle = new PancakeV3TwapOracle(tokens, pools, TapeSurgeDefaults.TWAP_WINDOW);
        board = new StubBoard(m.bem, m.machineCircuits);
        uint256 n = vm.getNonce(address(this));
        address predictedTrader = vm.computeCreateAddress(address(this), n + 1);
        swapper = new PancakeFirstoSwapper(
            m.wbnb, m.usdt, m.bem, m.poolWbnbUsdt, m.poolUsdtBem, m.router, 100, 10_000, predictedTrader
        );
        trader = new MarketTrader(
            m.bem,
            address(board),
            _markets(),
            address(swapper),
            address(oracle),
            m.pod,
            TapeSurgeDefaults.FIRSTO_SLIPPAGE_BPS
        );
        assertEq(address(trader), predictedTrader);
        deal(m.bem, address(board), 1_000e8);
    }

    function _markets() internal view returns (MarketTrader.Markets memory) {
        return MarketTrader.Markets({
            askExchange: m.firstoAskExchange,
            signedAsk: m.firstoSignedAsk,
            bidExchange: m.firstoBidExchange,
            officialMarket: m.officialMarket,
            seaport: m.seaport,
            wbnb: m.wbnb
        });
    }

    function _u(string memory key) internal view returns (uint256) {
        return vm.parseUint(vm.parseJsonString(snap, key));
    }

    function _order() internal view returns (AskOrder memory o) {
        address maker = vm.parseJsonAddress(snap, ".ask.maker");
        address payout = vm.parseJsonAddress(snap, ".ask.payoutRecipient");
        o.header = AskHeader(
            maker,
            vm.parseJsonBytes32(snap, ".ask.merkleRoot"),
            _u(".ask.batchNonce"),
            _u(".ask.expiry"),
            payout,
            _u(".ask.feeBps"),
            _u(".ask.feeEpoch"),
            _u(".ask.schemaVersion")
        );
        o.leaf = AskLeaf(
            maker,
            vm.parseJsonAddress(snap, ".ask.collection"),
            _u(".ask.tokenId"),
            _u(".ask.priceWei"),
            payout,
            _u(".ask.feeBps"),
            _u(".ask.feeEpoch"),
            _u(".ask.batchNonce"),
            _u(".ask.leafIndex"),
            _u(".ask.schemaVersion")
        );
        o.merkleProof = vm.parseJsonBytes32Array(snap, ".ask.merkleProof");
        o.signature = vm.parseJsonBytes(snap, ".ask.signature");
    }

    function _skip() internal returns (bool) {
        if (!vm.envOr("FIRSTO_PROBE", false)) {
            vm.skip(true);
            return true;
        }
        return false;
    }

    /// @dev 真实卖单 → 嵌套闪电兑换（BEM → USDT → WBNB）→ 直接调用卖单合约 → 按实际花费卖给"主板"；
    ///      再把这台卖给真实统一买单（嵌套闪电兑换 WBNB → USDT → BEM），剩余 BNB 经路由换成 BEM 给"主板"
    function test_BuyFromRealAskThenSellToRealBid() public {
        if (_skip()) return;
        AskOrder memory o = _order();
        uint256 cost = trader.askCost(o);
        assertEq(cost, _u(".ask.buyerCostWei"), "askCost matches the API's buyerCostWei");
        uint256 twapBem = oracle.quoteBemOut(cost);
        uint256 b0 = IERC20(m.bem).balanceOf(address(board));
        uint256 g = gasleft();
        uint256 paid = trader.buyFromAsk(address(board), o);
        console2.log("buyFromAsk gas", g - gasleft());
        console2.log("BNB cost", cost, "BEM paid", paid);
        console2.log("TWAP BEM for the cost", twapBem);
        assertEq(IERC721(m.machineCircuits).ownerOf(o.leaf.tokenId), address(board), "machine delivered");
        assertEq(b0 - IERC20(m.bem).balanceOf(address(board)), paid);
        assertLe(paid * 10_000, twapBem * 10_200, "within TWAP + 2%");
        assertEq(IERC20(m.bem).balanceOf(address(trader)), 0);
        assertEq(address(trader).balance, 0);
        assertEq(address(swapper).balance, 0);
        assertEq(IERC20(m.bem).balanceOf(address(swapper)), 0);

        // 卖给统一买单：主板要价 = 买入花费的 70%（买单的价格低于卖单，演示"要价以上的部分也回到主板"）
        board.setAskPrice(paid * 7 / 10);
        BidOrder memory b = BidOrder(
            _u(".bidSizeRange.orderId"),
            _u(".bidSizeRange.dailyCapacityPriceWei"),
            uint16(_u(".bidSizeRange.feeBps")),
            0
        );
        uint256 b1 = IERC20(m.bem).balanceOf(address(board));
        g = gasleft();
        uint256 got = trader.sellToBid(address(board), 0, b, paid * 7 / 10);
        console2.log("sellToBid gas", g - gasleft());
        console2.log("BEM to board", got, "ask", paid * 7 / 10);
        assertEq(IERC20(m.bem).balanceOf(address(board)) - b1, got);
        assertGe(got, paid * 7 / 10);
        assertTrue(IERC721(m.machineCircuits).ownerOf(o.leaf.tokenId) != address(board), "machine sold to the bid");
        assertEq(IERC20(m.bem).balanceOf(address(trader)), 0);
        assertEq(address(trader).balance, 0);
        assertEq(address(swapper).balance, 0);
    }

    /// @dev 滑点上限只给 0.01%：池子手续费（1% + 0.01%）就超过了，必然拒绝（SlippageTooHigh），不会成交
    function test_SlippageGuardRejectsTightTolerance() public {
        if (_skip()) return;
        uint256 n = vm.getNonce(address(this));
        address t = vm.computeCreateAddress(address(this), n + 1);
        PancakeFirstoSwapper sw =
            new PancakeFirstoSwapper(m.wbnb, m.usdt, m.bem, m.poolWbnbUsdt, m.poolUsdtBem, m.router, 100, 10_000, t);
        MarketTrader strict =
            new MarketTrader(m.bem, address(board), _markets(), address(sw), address(oracle), m.pod, 1);
        AskOrder memory o = _order();
        vm.expectRevert(MarketTrader.SlippageTooHigh.selector);
        strict.buyFromAsk(address(board), o);
        assertTrue(IERC721(m.machineCircuits).ownerOf(o.leaf.tokenId) != address(board));
    }
}

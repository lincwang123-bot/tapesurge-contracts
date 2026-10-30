// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Fixture} from "./utils/Fixture.sol";
import {TapeBoard} from "../src/TapeBoard.sol";
import {MonthBoard} from "../src/MonthBoard.sol";
import {MarketTrader} from "../src/market/MarketTrader.sol";
import {AskHeader, AskLeaf, AskOrder, BidOrder} from "../src/firsto/IFirsto.sol";
import {MonthState} from "../src/interfaces/IMonthBoard.sol";
import {BoardState, SettleMode} from "../src/interfaces/ITapeBoard.sol";
import {SignedAsk, FirstoSignedAskLib} from "../src/market/FirstoSignedAsk.sol";

/// @title MarketTrader（主板在 Firsto 上自动买卖矿机；规则决定 6.22）——本地 mock 交易所
contract MarketTraderTest is Fixture {
    address internal maker = address(0x3A4E);
    /// @dev 递单的运营地址（规则决定 6.37：买入只认运营地址；夹具的运营地址就是测试合约自己）
    address internal keeper = address(this);
    address internal bidder = address(0xB1DD);
    address internal bidNft = address(0xB1DE);
    uint256 internal nonce;

    // ---------------- 辅助 ----------------

    /// @dev maker 持有一台 weight 的矿机，按 priceWei（BNB，不含 1% 手续费）在 mock 卖单合约挂单
    function _ask(uint256 weight, uint256 priceWei) internal returns (AskOrder memory o, uint256 id) {
        (id,) = _newMachine(maker, weight);
        vm.prank(maker);
        machines.setApprovalForAll(address(firstoAsk), true);
        nonce++;
        o.header = AskHeader(maker, bytes32(nonce), nonce, block.timestamp + 30 days, maker, 100, 1, 1);
        o.leaf = AskLeaf(maker, address(machines), id, priceWei, maker, 100, 1, nonce, 0, 1);
    }

    /// @dev 让 weight × 收购价 × fraction 的 BEM 恰好对应的卖单价（BNB，不含手续费）
    function _priceFor(uint256 bemTotal) internal view returns (uint256) {
        // 1 BNB = oracle.quoteBemOut(1e18) BEM；含费 1%，兑换另加 0.5%
        return bemTotal * 1e18 / oracle.quoteBemOut(1e18) * 10_000 / 10_100 * 10_000 / 10_050;
    }

    function _buy(address board, AskOrder memory o) internal returns (uint256) {
        vm.prank(keeper);
        return trader.buyFromAsk(board, o);
    }

    /// @dev 建一张统一买单，使这台矿机卖出的到手 BNB 约为 bemNet 个 BEM 的价值
    function _bid(uint256 id, uint256 bemNet) internal returns (BidOrder memory b) {
        vm.deal(bidder, 1_000 ether);
        vm.prank(bidder);
        uint256 probe = firstoBid.createBid{value: 0}(1e18, 0, 0, bidNft);
        uint256 g1 = firstoBid.grossFor(probe, address(machines), id); // 日产能价 1 BNB 时的毛价
        uint256 wantGross = bemNet * 1e18 / oracle.quoteBemOut(1e18) * 10_000 / 9_900;
        uint256 dcp = 1e18 * wantGross / g1 + 1;
        vm.prank(bidder);
        uint256 oid = firstoBid.createBid{value: 100 ether}(dcp, 0, 0, bidNft);
        b = BidOrder(oid, dcp, 100, 0);
    }

    function _monthPreparing() internal returns (MonthBoard m) {
        _startGenesis();
        m = _monthBoard();
        _fillMonth(m);
        assertTrue(m.isPurchasing());
    }

    function _monthSettling(MonthBoard m) internal {
        vm.warp(m.prepEnd());
        m.sync();
        vm.warp(m.miningEnd());
        m.drawPrizes();
        if (m.state() == MonthState.Drawing) {
            rng.fulfill(m.pendingRequestId(), 7);
            m.finalizePrizes();
        }
        assertEq(uint256(m.state()), uint256(MonthState.Settling));
    }

    // ---------------- 买入 ----------------

    function test_BuyFromAskIntoMonthBoard() public {
        MonthBoard m = _monthPreparing();
        uint256 cap = 30 * m.buyPrice();
        (AskOrder memory o, uint256 id) = _ask(30, _priceFor(cap * 9 / 10));
        uint256 cost = trader.askCost(o);
        uint256 budget0 = m.budget();
        uint256 maker0 = maker.balance;
        uint256 paid = _buy(address(m), o);
        assertEq(machines.ownerOf(id), address(m), "machine in the board");
        assertEq(m.machineCount(), 1);
        assertEq(m.machine(0).cost, paid, "recorded at the real BEM cost");
        assertEq(budget0 - m.budget(), paid);
        assertLe(paid, cap, "within weight x formula price");
        assertEq(paid, oracle.quoteBemOut(cost) * 10_050 / 10_000, "BEM owed for the swap");
        assertEq(maker.balance - maker0, o.leaf.priceWei, "maker paid in BNB");
        assertEq(FIRSTO_FEE_TO.balance, cost - o.leaf.priceWei, "Firsto 1% fee");
        assertEq(bem.balanceOf(address(trader)), 0);
        assertEq(address(trader).balance, 0);
    }

    function test_BuyFromAskIntoStandardBoard() public {
        TapeBoard b = _startGenesis();
        _fillUniform(b, 25, 20 * BEM_1);
        uint256 cap = 40 * b.buyPrice();
        (AskOrder memory o, uint256 id) = _ask(40, _priceFor(cap * 9 / 10));
        uint256 paid = _buy(address(b), o);
        assertEq(machines.ownerOf(id), address(b));
        assertEq(b.machineCount(), 1);
        assertEq(b.totalSpent(), paid, "standard board books the real cost");
        assertEq(bem.balanceOf(address(trader)), 0);
    }

    /// @dev 实际花费超过 权重 × 收购公式价：主板拒绝（和普通卖家同一个错误）
    function test_BuyRevertsAboveFormulaCap() public {
        MonthBoard m = _monthPreparing();
        uint256 cap = 30 * m.buyPrice();
        (AskOrder memory o,) = _ask(30, _priceFor(cap * 11 / 10));
        vm.prank(keeper);
        vm.expectRevert(MonthBoard.PriceBelowMinimum.selector);
        trader.buyFromAsk(address(m), o);
    }

    /// @dev 兑换比 TWAP 贵 2% 以上：拒绝（F-4 a）
    function test_BuyRevertsOnSlippage() public {
        MonthBoard m = _monthPreparing();
        (AskOrder memory o,) = _ask(30, _priceFor(30 * m.buyPrice() / 2));
        firstoSwapper.setExtraBps(201);
        vm.prank(keeper);
        vm.expectRevert(MarketTrader.SlippageTooHigh.selector);
        trader.buyFromAsk(address(m), o);
        firstoSwapper.setExtraBps(200);
        _buy(address(m), o);
    }

    /// @dev 资格和状态沿用主板规则：未验证的矿机、收购期外、报价过期都拒绝；被撤的单 Firsto 侧回滚
    function test_BuyRespectsBoardRules() public {
        MonthBoard m = _monthPreparing();
        uint256 price = _priceFor(30 * m.buyPrice() / 2);
        (AskOrder memory o, uint256 id) = _ask(30, price);
        pod.setFlags(pod.minerKey(address(machines), id), true, false);
        vm.prank(keeper);
        vm.expectRevert(MonthBoard.MachineNotEligible.selector);
        trader.buyFromAsk(address(m), o);
        pod.setFlags(pod.minerKey(address(machines), id), true, true);
        vm.prank(maker);
        firstoAsk.cancel(o.leaf.batchNonce);
        vm.prank(keeper);
        vm.expectRevert(); // FirstoCallFailed(OrderInvalid)
        trader.buyFromAsk(address(m), o);
        (AskOrder memory o2,) = _ask(30, price);
        priceFeed.post(m.buyPriceCap() / 2, m.buyPriceCap() / 2);
        vm.warp(block.timestamp + 3 hours); // 报价过期：主板暂停收购
        vm.prank(keeper);
        vm.expectRevert(MonthBoard.PriceUnavailable.selector);
        trader.buyFromAsk(address(m), o2);
        vm.warp(m.prepEnd());
        vm.prank(keeper);
        vm.expectRevert(MonthBoard.BuyRoundInactive.selector);
        trader.buyFromAsk(address(m), o2);
    }

    /// @dev 规则决定 6.37：Firsto 单笔签名卖单 V2 也能买（正好付 价格 × (1 + 1%)），按实际花费记账
    function test_BuyFromSignedAskIntoMonthBoard() public {
        MonthBoard m = _monthPreparing();
        uint256 pk = 0xA11CE;
        address signer = vm.addr(pk);
        (uint256 id,) = _newMachine(signer, 30);
        vm.prank(signer);
        machines.approve(address(firstoSigned), id);
        SignedAsk memory a = SignedAsk({
            maker: signer,
            collection: address(machines),
            tokenId: id,
            nonce: 1,
            price: uint128(_priceFor(30 * m.buyPrice() * 9 / 10)),
            expiry: uint64(block.timestamp + 1 days),
            payoutRecipient: signer,
            feeBps: firstoSigned.defaultTakerFeeBps(),
            feeEpoch: firstoSigned.feeEpoch(),
            schemaVersion: firstoSigned.SIGNED_ASK_SCHEMA_VERSION()
        });
        (uint8 v, bytes32 r, bytes32 s_) = vm.sign(pk, FirstoSignedAskLib.digest(address(firstoSigned), a));
        uint256 seller0 = signer.balance;
        vm.prank(keeper);
        uint256 paid = trader.buyFromSignedAsk(address(m), a, abi.encodePacked(r, s_, v));
        assertEq(machines.ownerOf(id), address(m));
        assertEq(m.machine(0).cost, paid, "books the real cost");
        assertEq(signer.balance - seller0, a.price, "seller got the ask price");
        assertEq(bem.balanceOf(address(trader)), 0);
        assertEq(address(trader).balance, 0);
        // 同一张不能买两次；别人不能递单
        vm.prank(address(0xBEEF));
        vm.expectRevert(MarketTrader.NotOperator.selector);
        trader.buyFromSignedAsk(address(m), a, abi.encodePacked(r, s_, v));
    }

    /// @dev 规则决定 6.37：买入只认运营地址，别人不能挑一张自己挂的单让主板去吃；运营地址为 0 时谁都不能买
    function test_BuyOnlyByOperator() public {
        MonthBoard m = _monthPreparing();
        (AskOrder memory o,) = _ask(30, _priceFor(30 * m.buyPrice() / 2));
        vm.prank(address(0xBEEF));
        vm.expectRevert(MarketTrader.NotOperator.selector);
        trader.buyFromAsk(address(m), o);
        vm.prank(FEE_SAFE);
        factory.setOperator(address(0));
        vm.expectRevert(MarketTrader.NotOperator.selector);
        trader.buyFromAsk(address(m), o);
    }

    function test_RejectsNonBoardsAndForeignCallbacks() public {
        _startGenesis();
        (AskOrder memory o,) = _ask(30, 1 ether);
        vm.expectRevert(MarketTrader.NotBoard.selector);
        trader.buyFromAsk(address(0xBAD), o);
        vm.expectRevert(MarketTrader.NotSwapper.selector);
        trader.onFlash(1, "");
        vm.expectRevert(MarketTrader.NotDelivered.selector);
        trader.onERC721Received(address(0), address(0), 1, "");
    }

    // ---------------- 卖出 ----------------

    /// @dev 月局：主板先按要价（≥ 成本价）收到 BEM，Firsto 买单比要价高出的部分换成 BEM 也转给主板
    function test_SellToBidFromMonthBoard() public {
        MonthBoard m = _monthPreparing();
        (AskOrder memory o, uint256 id) = _ask(30, _priceFor(30 * m.buyPrice() * 9 / 10));
        _buy(address(m), o);
        _monthSettling(m);
        uint256 ask = sales.askPrice(address(m), 0);
        assertEq(ask, m.machine(0).cost, "feed never posted: at cost");
        BidOrder memory b = _bid(id, ask * 13 / 10);
        uint256 bal0 = bem.balanceOf(address(m));
        uint256 fee0 = bem.balanceOf(FEE_SAFE);
        vm.prank(keeper);
        uint256 got = trader.sellToBid(address(m), 0, b, ask);
        assertEq(machines.ownerOf(id), bidNft, "machine delivered to the bid's recipient");
        assertEq(bem.balanceOf(address(m)) - bal0, got);
        assertGe(got, ask, "board gets at least the formula price");
        assertGt(got, ask * 12 / 10, "and the surplus over it");
        // 溢价分成（规则决定 6.24）：要价 = 成本价，多出来的全是溢价，其中 10% 由 MarketTrader 转给手续费地址
        uint256 fee = bem.balanceOf(FEE_SAFE) - fee0;
        uint256 extra = got - ask + fee;
        assertEq(fee, extra / 10, "10% of the premium over cost");
        assertEq(m.unsoldMachines(), 0);
        assertEq(bem.balanceOf(address(trader)), 0);
        assertEq(address(trader).balance, 0);
    }

    /// @dev Firsto 买单低于主板要价：还不起兑换，整笔回滚，矿机留在主板
    function test_SellRevertsWhenBidBelowAsk() public {
        MonthBoard m = _monthPreparing();
        (AskOrder memory o, uint256 id) = _ask(30, _priceFor(30 * m.buyPrice() * 9 / 10));
        _buy(address(m), o);
        _monthSettling(m);
        uint256 ask = sales.askPrice(address(m), 0);
        BidOrder memory b = _bid(id, ask * 9 / 10);
        vm.prank(keeper);
        vm.expectRevert(MarketTrader.InsufficientProceeds.selector);
        trader.sellToBid(address(m), 0, b, ask);
        assertEq(machines.ownerOf(id), address(m));
        // 借的 BEM 少于要价：卖矿合约收不到钱，整笔回滚
        BidOrder memory b2 = _bid(id, ask * 2);
        vm.prank(keeper);
        vm.expectRevert();
        trader.sellToBid(address(m), 0, b2, ask - 1);
    }

    /// @dev 标准局：30 天市价期（需要有效报价）按公式价，主板没有成本价底线；多借的 BEM 也回到主板
    function test_SellToBidFromStandardBoard() public {
        TapeBoard sb = _startGenesis();
        _fillUniform(sb, 25, 20 * BEM_1);
        (AskOrder memory o, uint256 id) = _ask(40, _priceFor(40 * sb.buyPrice() * 9 / 10));
        _buy(address(sb), o);
        vm.warp(sb.startedAt() + 730 days);
        sb.expire();
        assertEq(uint256(sb.state()), uint256(BoardState.Liquidating));
        uint256 floor = sb.sellFloorPrice();
        priceFeed.post(floor, floor);
        (uint256 p, uint8 phase) = stdSales.askPrice(address(sb), 0);
        assertEq(phase, 1);
        uint256 askTotal = p * 40;
        BidOrder memory b = _bid(id, askTotal * 15 / 10);
        uint256 pot0 = sb.potAllocated();
        uint256 fee0 = bem.balanceOf(FEE_SAFE);
        vm.prank(keeper);
        uint256 got = trader.sellToBid(address(sb), 0, b, askTotal + 5 * BEM_1); // 多借 5 BEM：原样回到主板
        assertEq(machines.ownerOf(id), bidNft);
        assertGt(got, askTotal * 14 / 10);
        assertGe(sb.potAllocated() - pot0, askTotal, "proceeds reach the pot");
        assertEq(bem.balanceOf(address(trader)), 0);
        assertEq(bem.balanceOf(FEE_SAFE), fee0, "no premium fee on standard boards");
    }

    /// @dev 标准局正常终局（规则决定 6.25）：要价低于成本时卖矿合约不扣；Firsto 买单高出的部分合计超过成本的那一段，
    ///      由 MarketTrader 扣 10% 给手续费地址
    function test_SellToBidFromStandardBoardNormalEndPaysPremiumFee() public {
        TapeBoard sb = _startGenesis();
        _fillUniform(sb, 25, 20 * BEM_1);
        (AskOrder memory o, uint256 id) = _ask(40, _priceFor(40 * sb.buyPrice() * 9 / 10));
        _buy(address(sb), o);
        _drawUntilKing(sb, 9);
        _topUpPool(sb);
        sb.pulse();
        assertEq(uint256(sb.settleMode()), uint256(SettleMode.Normal));
        uint256 floor = sb.sellFloorPrice();
        _postPrices(floor, floor);
        (uint256 p,) = stdSales.askPrice(address(sb), 0);
        uint256 price = p * 40;
        uint256 basis = stdSales.machineCost(address(sb), 0);
        assertLt(price, basis, "ask below cost: no fee at the sale singleton");
        BidOrder memory b = _bid(id, basis * 2);
        uint256 fee0 = bem.balanceOf(FEE_SAFE);
        vm.prank(keeper);
        uint256 got = trader.sellToBid(address(sb), 0, b, price);
        uint256 fee = bem.balanceOf(FEE_SAFE) - fee0;
        uint256 extra = got - price + fee;
        assertGt(price + extra, basis);
        assertEq(fee, (price + extra - basis) / 10, "10% of the part above cost");
        assertEq(bem.balanceOf(address(trader)), 0);
    }

    // ---------------- 完整流程：Firsto 买入 → 挖矿 → Firsto 卖出 ----------------

    function test_FullFlowMonthBoard() public {
        MonthBoard m = _monthPreparing();
        (AskOrder memory o1, uint256 id1) = _ask(30, _priceFor(30 * m.buyPrice() * 9 / 10));
        (AskOrder memory o2, uint256 id2) = _ask(20, _priceFor(20 * m.buyPrice() * 8 / 10));
        _buy(address(m), o1);
        _buy(address(m), o2);
        vm.warp(m.prepEnd());
        m.sync();
        pod.addYield(m.machine(0).key, 6 * BEM_1);
        pod.addYield(m.machine(1).key, 4 * BEM_1);
        vm.warp(m.miningEnd());
        m.drawPrizes();
        rng.fulfill(m.pendingRequestId(), 11);
        m.finalizePrizes();
        uint256 owedBefore = _owedAll(m);
        uint256 subsidy0 = m.subsidyRemaining();
        uint256 a0 = sales.askPrice(address(m), 0);
        uint256 a1 = sales.askPrice(address(m), 1);
        uint256 got0 = _sellTo(address(m), 0, id1, a0 * 12 / 10, a0);
        uint256 got1 = _sellTo(address(m), 1, id2, a1 * 11 / 10, a1);
        assertEq(m.unsoldMachines(), 0);
        assertGt(m.finishedAt(), 0, "month board finished");
        // 卖款按"本金 → 回馈资本 → 溢价"记账：持仓可领的增加 + 收回的回馈资本 = 两笔卖款（只差取整尘埃）
        m.sweep(); // 最后一笔转进来的溢价还没扫入账本（领取时也会先 sweep）
        uint256 subsidyBack = subsidy0 - m.subsidyRemaining();
        assertApproxEqAbs(_owedAll(m) - owedBefore + subsidyBack, got0 + got1, m.socketCount() * 2);
    }

    function test_FullFlowStandardBoard() public {
        TapeBoard sb = _startGenesis();
        _fillUniform(sb, 25, 20 * BEM_1);
        (AskOrder memory o, uint256 id) = _ask(60, _priceFor(60 * sb.buyPrice() * 9 / 10));
        _buy(address(sb), o);
        pod.addYield(sb.machine(0).key, 5 * BEM_1);
        sb.harvest();
        vm.warp(sb.startedAt() + 730 days);
        sb.expire();
        uint256 floor = sb.sellFloorPrice();
        priceFeed.post(floor, floor * 2);
        (uint256 p,) = stdSales.askPrice(address(sb), 0);
        BidOrder memory b = _bid(id, p * 60 * 12 / 10);
        vm.prank(keeper);
        trader.sellToBid(address(sb), 0, b, p * 60);
        assertEq(sb.unsoldMachines(), 0);
        assertGt(sb.finishedAt(), 0, "standard board finished");
        assertEq(machines.ownerOf(id), bidNft);
    }

    function _sellTo(address board, uint256 index, uint256 id, uint256 bemNet, uint256 advance)
        internal
        returns (uint256)
    {
        BidOrder memory b = _bid(id, bemNet);
        vm.prank(keeper);
        return trader.sellToBid(board, index, b, advance);
    }

    function _owedAll(MonthBoard m) internal view returns (uint256 t) {
        for (uint256 s = 1; s <= m.socketCount(); s++) {
            t += m.owed(s);
        }
    }
}

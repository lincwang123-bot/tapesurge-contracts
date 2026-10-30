// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Fixture} from "./utils/Fixture.sol";
import {TapeBoard} from "../src/TapeBoard.sol";
import {PositionExchange} from "../src/month/PositionExchange.sol";
import {BoardState, SettleMode} from "../src/interfaces/ITapeBoard.sol";

/// @notice 标准局持仓凭证与转让（规则决定 6.23）：开局且首轮收购结束后可转、开奖等待随机数期间锁定；
///         转让后出局 105%、硅王 105% + 30%、终局 65% 份额、保底退款都归当时的持有人；已发出的留给原持有人；
///         已出局的持仓也能转；通行证成交时退回原持有人；和月局共用一个盘口。
contract StdPositionsTest is Fixture {
    TapeBoard internal b;
    address internal buyer = address(0xB0B);
    address internal x = address(0xA11CE);
    address internal y = address(0xB0B0);
    uint256 internal constant N = 40;

    function setUp() public override {
        super.setUp();
        b = _startGenesis();
        _fillUniform(b, 20, 20 * BEM_1);
        _fillUniform(b, 20, 5 * BEM_1);
        _sell(b, _newUser(), 200);
        bem.mint(buyer, 10_000 * BEM_1);
        bem.mint(x, 10_000 * BEM_1);
        vm.prank(buyer);
        bem.approve(address(b), type(uint256).max);
    }

    function _id(uint256 slot) internal view returns (uint256) {
        return positions.idOf(address(b), slot);
    }

    function _move(uint256 slot, address to) internal {
        address from = b.socket(slot).owner;
        uint256 id = _id(slot);
        vm.prank(from);
        positions.transferFrom(from, to, id);
    }

    function _afterFirstRound() internal {
        vm.warp(b.initialBuyEnd());
    }

    function _wordFor(uint256 slot) internal view returns (uint256 w) {
        for (uint256 i = 0; i < 20_000; i++) {
            w = uint256(keccak256(abi.encode("word", i)));
            if (b.previewEject(w) == slot) return w;
        }
        revert("no word");
    }

    function _ejectSlot(uint256 slot) internal {
        _topUpPool(b);
        b.pulse();
        rng.fulfill(b.pendingRequestId(), _wordFor(slot));
        assertTrue(b.socket(slot).ejected);
    }

    // ---------------- 什么时候能转 ----------------

    function test_PositionMintedOnJoinAndLockedUntilFirstBuyRoundEnds() public {
        address p = b.socket(1).owner;
        assertEq(positions.ownerOf(_id(1)), p);
        assertEq(b.holderCount(p), 1);
        // 招募中的主板不能转
        TapeBoard next = _board();
        address u = _join(next, 10 * BEM_1);
        uint256 nid = positions.idOf(address(next), 1);
        vm.prank(u);
        vm.expectRevert(TapeBoard.TransferLocked.selector);
        positions.transferFrom(u, x, nid);
        // 开局了，但首轮收购还没结束
        assertFalse(b.transferable());
        uint256 id = _id(1);
        vm.prank(p);
        vm.expectRevert(TapeBoard.TransferLocked.selector);
        positions.transferFrom(p, x, id);
        // 首轮收购结束（开始挖矿）后可以转
        _afterFirstRound();
        assertTrue(b.transferable());
        uint256 passId = b.socket(1).passId;
        assertEq(passCircuits.ownerOf(passId), address(b));
        _move(1, x);
        assertEq(b.socket(1).owner, x);
        assertEq(positions.ownerOf(id), x);
        assertEq(b.holderCount(p), 0);
        assertEq(b.holderCount(x), 1);
        assertEq(b.socket(1).version, 1);
        // 通行证成交时退回原持有人（不随持仓转让）
        assertEq(passCircuits.ownerOf(passId), p);
        assertTrue(b.socket(1).passReturned);
        // 再转一次：通行证已经退过，版本号继续增加
        _move(1, y);
        assertEq(b.socket(1).owner, y);
        assertEq(b.socket(1).version, 2);
        assertEq(passCircuits.ownerOf(passId), p);
    }

    function test_LockedWhileDrawPending() public {
        _afterFirstRound();
        _topUpPool(b);
        b.pulse();
        assertTrue(b.drawPending());
        assertFalse(b.transferable());
        address p = b.socket(1).owner;
        uint256 id = _id(1);
        vm.prank(p);
        vm.expectRevert(TapeBoard.TransferLocked.selector);
        positions.transferFrom(p, x, id);
        // 随机数交付后解锁
        rng.fulfill(b.pendingRequestId(), 12_345);
        assertTrue(b.transferable());
        _move(1, x);
        assertEq(b.socket(1).owner, x);
    }

    function test_ClaimsClosedLocksTransfers() public {
        _drawUntilKing(b, 7);
        _topUpPool(b);
        b.pulse();
        _stdBuy(b, 0, buyer);
        assertTrue(b.transferable(), "liquidating: transferable");
        vm.warp(b.finishedAt() + 365 days);
        b.closeClaims();
        assertFalse(b.transferable());
        address p = b.socket(1).owner;
        uint256 id = _id(1);
        vm.prank(p);
        vm.expectRevert(TapeBoard.TransferLocked.selector);
        positions.transferFrom(p, x, id);
    }

    // ---------------- 转让后的权益归属 ----------------

    function test_EjectionPaysCurrentHolderAndBumpsTradeEpoch() public {
        _afterFirstRound();
        uint256 slot = 5;
        address seller = b.socket(slot).owner;
        _move(slot, x);
        uint256 sellerBal = bem.balanceOf(seller);
        uint256 xBal = bem.balanceOf(x);
        uint64 epoch = b.tradeEpoch();
        _ejectSlot(slot);
        assertEq(bem.balanceOf(x) - xBal, 21 * BEM_1, "105% pushed to the holder");
        assertEq(bem.balanceOf(seller), sellerBal, "seller gets nothing after the sale");
        assertEq(b.tradeEpoch(), epoch + 1);
    }

    function test_EjectedPositionIsTransferableAndPotShareFollowsHolder() public {
        _afterFirstRound();
        uint256 slot = 25; // 投 5 BEM
        address p = b.socket(slot).owner;
        uint256 pBal = bem.balanceOf(p);
        _ejectSlot(slot);
        assertEq(bem.balanceOf(p) - pBal, 5.25e8, "105% already paid to the original holder");
        _move(slot, x); // 已出局的持仓（还有终局 65% 份额）也能转
        assertEq(b.socket(slot).owner, x);
        // 打到终局：正常结局，卖矿机，底池 65% 按投入分（含已出局者）
        _drawUntilKing(b, 3);
        _topUpPool(b);
        b.pulse();
        assertEq(uint256(b.settleMode()), uint256(SettleMode.Normal));
        _stdBuy(b, 0, buyer);
        uint256 share = stdSales.owed(address(b), slot);
        assertGt(share, 0);
        assertEq(_owedOf(b, p), 0, "original holder has nothing left in the pot");
        uint256 xBal = bem.balanceOf(x);
        stdSales.claimAll(address(b), slot);
        assertEq(bem.balanceOf(x) - xBal, share);
        assertEq(bem.balanceOf(p) - pBal, 5.25e8, "nothing more to the seller");
    }

    function test_KingPositionTransferredBeforePayout() public {
        _afterFirstRound();
        _drawUntilKing(b, 11);
        uint256 king = b.kingSocket();
        address p = b.socket(king).owner;
        uint256 stake = b.socket(king).stake;
        _move(king, x);
        uint256 xBal = bem.balanceOf(x);
        uint256 pBal = bem.balanceOf(p);
        _topUpPool(b);
        b.pulse(); // 硅王 105% 直接推送，进入终局
        assertEq(bem.balanceOf(x) - xBal, stake * 105 / 100, "king's 105% to the holder");
        _stdBuy(b, 0, buyer);
        uint256 pot = b.potAllocated();
        assertApproxEqAbs(stdSales.owed(address(b), king), pot * 3_000 / 10_000, 1, "king 30% to the holder");
        assertEq(bem.balanceOf(p), pBal);
    }

    function test_TransferDuringLiquidationCarriesAccruedShareToSeller() public {
        _drawUntilKing(b, 21);
        _topUpPool(b);
        b.pulse();
        _stdBuy(b, 0, buyer);
        uint256 slot = b.kingSocket() == 2 ? 3 : 2;
        address seller = b.socket(slot).owner;
        uint256 accrued = stdSales.owed(address(b), slot);
        assertGt(accrued, 0);
        uint256 creditBefore = b.credit(seller);
        _move(slot, x);
        assertEq(b.credit(seller) - creditBefore, accrued, "accrued share stays with the seller");
        assertEq(stdSales.owed(address(b), slot), 0, "buyer starts from zero");
        // 之后的新资金归买方
        bem.mint(address(b), 10 * BEM_1);
        b.sweep();
        uint256 later = stdSales.owed(address(b), slot);
        assertApproxEqAbs(later, 10 * BEM_1 * 6_500 / 10_000 * b.socket(slot).stake / b.proRataStake(), 1);
        uint256 sBal = bem.balanceOf(seller);
        b.withdrawCredit(seller);
        assertEq(bem.balanceOf(seller) - sBal, creditBefore + accrued);
        uint256 xBal = bem.balanceOf(x);
        b.withdraw(slot);
        assertEq(bem.balanceOf(x) - xBal, later);
    }

    function test_FallbackRefundGoesToHolder() public {
        _afterFirstRound();
        uint256 slot = 1; // 投 20 BEM，没出局
        address seller = b.socket(slot).owner;
        _move(slot, x);
        vm.warp(b.startedAt() + 730 days);
        uint256 fee0 = b.credit(FEE_SAFE);
        b.expire();
        assertEq(uint256(b.settleMode()), uint256(SettleMode.Fallback));
        _stdBuy(b, 0, buyer);
        // 保底：先收 2% 手续费（规则决定 6.37），再按未出局者的投入比例退本金（卖一台矿机的钱还不够全部退完）
        uint256 pot = b.potAllocated() - (b.credit(FEE_SAFE) - fee0);
        uint256 alive = b.priorityStake();
        assertLt(pot, alive);
        assertApproxEqAbs(stdSales.owed(address(b), slot), pot * 20 * BEM_1 / alive, 1, "refund to the holder");
        assertEq(_owedOf(b, seller), 0, "nothing to the seller");
    }

    // ---------------- 一个地址持有多份、兜底权限 ----------------

    function test_OneHolderManyPositions() public {
        _afterFirstRound();
        _move(1, x);
        _move(2, x);
        assertEq(b.holderCount(x), 2);
        assertEq(positions.balanceOf(x), 2);
        // 持有人可以兜底推进开奖（运营地址超过 3 天没执行）
        vm.warp(b.lastPulseAt() + 3 days);
        _topUpPool(b);
        vm.prank(x);
        b.pulse();
        rng.fulfill(b.pendingRequestId(), 777);
        // 终局后两份都推送给 x
        _drawUntilKing(b, 5);
        _topUpPool(b);
        b.pulse();
        _stdBuy(b, 0, buyer);
        uint256 due = stdSales.owed(address(b), 1) + stdSales.owed(address(b), 2) + b.credit(x);
        uint256 xBal = bem.balanceOf(x);
        stdSales.distribute(address(b), 1, 2); // 测试合约是运营地址
        assertEq(bem.balanceOf(x) - xBal, due);
    }

    function test_EmergencyExitByAliveHolder() public {
        _afterFirstRound();
        _move(3, x);
        machineBeacon.upgradeTo(address(0xBAD));
        address p = address(0xDEAD1);
        vm.prank(p);
        vm.expectRevert(TapeBoard.NotAliveParticipant.selector);
        b.emergencyExit(3);
        vm.prank(x);
        b.emergencyExit(3);
        assertEq(uint256(b.state()), uint256(BoardState.Liquidating));
    }

    // ---------------- 盘口 ----------------

    function test_ExchangeAsksAndBidsOnStandardBoard() public {
        address p1 = b.socket(1).owner;
        address p2 = b.socket(2).owner;
        // 开局后就能挂单，首轮收购结束前不能成交
        vm.prank(p1);
        positions.setApprovalForAll(address(exchange), true);
        vm.prank(p1);
        exchange.listAsk(address(b), 1, 0.9e8, uint64(block.timestamp + 10 days));
        assertFalse(exchange.tradable(address(b)));
        vm.prank(x);
        bem.approve(address(exchange), type(uint256).max);
        vm.prank(x);
        vm.expectRevert(PositionExchange.NotTransferable.selector);
        exchange.buyAsk(address(b), 1, 1e8);

        _afterFirstRound();
        uint256 p1Bal = bem.balanceOf(p1);
        vm.prank(x);
        uint256 cost = exchange.buyAsk(address(b), 1, 1e8);
        assertEq(cost, 18 * BEM_1, "20 BEM principal at 0.9");
        assertEq(bem.balanceOf(p1) - p1Bal, cost);
        assertEq(b.socket(1).owner, x);

        // 通用买单：x 挂买单，p2 卖给它
        vm.prank(x);
        uint256 bidId = exchange.placeBid(address(b), 0.8e8, 100 * BEM_1, 1, type(uint96).max, uint64(block.timestamp + 10 days));
        vm.prank(p2);
        positions.setApprovalForAll(address(exchange), true);
        vm.prank(p2);
        exchange.sellToBid(bidId, 2, 0.8e8);
        assertEq(b.socket(2).owner, x);
        assertEq(b.holderCount(x), 2);

        // 开奖等待随机数期间不能成交；出局后此前的卖单全部失效（局交易版本号 +1）
        address p3 = b.socket(3).owner;
        vm.prank(p3);
        positions.setApprovalForAll(address(exchange), true);
        vm.prank(p3);
        exchange.listAsk(address(b), 3, 0.5e8, uint64(block.timestamp + 10 days));
        assertTrue(exchange.askValid(address(b), 3));
        _topUpPool(b);
        b.pulse();
        vm.prank(buyer);
        bem.approve(address(exchange), type(uint256).max);
        vm.prank(buyer);
        vm.expectRevert(PositionExchange.NotTransferable.selector);
        exchange.buyAsk(address(b), 3, 1e8);
        rng.fulfill(b.pendingRequestId(), 4242);
        assertFalse(exchange.askValid(address(b), 3), "ejection invalidates old asks");
        assertFalse(exchange.bidValid(bidId), "ejection invalidates old bids too");
        vm.prank(p3);
        exchange.listAsk(address(b), 3, 0.5e8, uint64(block.timestamp + 10 days));
        vm.prank(buyer);
        exchange.buyAsk(address(b), 3, 1e8);
        assertEq(b.socket(3).owner, buyer);
    }

    /// @dev 标准局终局阶段：盘口的订单版本号拼上未卖矿机数，每卖出一台矿机，旧买单 / 卖单随之失效。
    function test_LiquidationMachineSaleInvalidatesOldOrders() public {
        _drawUntilKing(b, 21);
        _topUpPool(b);
        b.pulse();
        assertEq(uint256(b.state()), uint256(BoardState.Liquidating));
        uint256 king = b.kingSocket();
        address holder = b.socket(king).owner;
        vm.prank(x);
        bem.approve(address(exchange), type(uint256).max);
        vm.prank(x);
        uint256 bidId = exchange.placeBid(address(b), 0.5e8, 100 * BEM_1, 1, type(uint96).max, uint64(block.timestamp + 10 days));
        vm.startPrank(holder);
        positions.setApprovalForAll(address(exchange), true);
        exchange.listAsk(address(b), king, 0.5e8, uint64(block.timestamp + 10 days));
        vm.stopPrank();
        assertTrue(exchange.bidValid(bidId));
        assertTrue(exchange.askValid(address(b), king));
        uint256 owedBefore = stdSales.owed(address(b), king);
        _stdBuy(b, 0, buyer); // 终局卖出一台矿机
        assertGt(stdSales.owed(address(b), king), owedBefore, "30% of the sale accrued to the king (carried to a seller)");
        assertFalse(exchange.bidValid(bidId), "machine sale invalidates old bids");
        assertFalse(exchange.askValid(address(b), king), "and old asks");
        vm.prank(holder);
        vm.expectRevert(PositionExchange.BidStale.selector);
        exchange.sellToBid(bidId, king, 0);
        vm.prank(buyer);
        bem.approve(address(exchange), type(uint256).max);
        vm.prank(buyer);
        vm.expectRevert(PositionExchange.AskNotValid.selector);
        exchange.buyAsk(address(b), king, 1e8);
        // 任何人可以帮买家退款；重挂之后照常成交
        uint256 xBal = bem.balanceOf(x);
        exchange.refundBid(bidId);
        assertEq(bem.balanceOf(x) - xBal, 100 * BEM_1);
        vm.prank(x);
        uint256 bid2 = exchange.placeBid(address(b), 0.5e8, 100 * BEM_1, 1, type(uint96).max, uint64(block.timestamp + 10 days));
        vm.prank(holder);
        exchange.sellToBid(bid2, king, 0.5e8);
        assertEq(b.socket(king).owner, x);
        assertEq(exchange.totalEscrow(), bem.balanceOf(address(exchange)));
    }

    function test_BuyBestFillsSeveralStandardPositionsForOneBuyer() public {
        _afterFirstRound();
        uint256[] memory slots = new uint256[](3);
        for (uint256 i = 0; i < 3; i++) {
            uint256 s = 21 + i; // 投 5 BEM 的人
            slots[i] = s;
            address o = b.socket(s).owner;
            vm.prank(o);
            positions.setApprovalForAll(address(exchange), true);
            vm.prank(o);
            exchange.listAsk(address(b), s, (90 + i) * 1e6, uint64(block.timestamp + 5 days));
        }
        vm.prank(x);
        bem.approve(address(exchange), type(uint256).max);
        vm.prank(x);
        (uint256 filled, uint256 spent) = exchange.buyBest(address(b), slots, 1e8, 100 * BEM_1);
        assertEq(filled, 3);
        assertEq(spent, 5 * (90 + 91 + 92) * 1e6);
        assertEq(b.holderCount(x), 3);
    }
}

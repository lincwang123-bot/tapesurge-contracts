// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Fixture} from "./utils/Fixture.sol";
import {TapeBoard} from "../src/TapeBoard.sol";
import {StdMachineSales} from "../src/StdMachineSales.sol";
import {BoardState} from "../src/interfaces/ITapeBoard.sol";

/// @title 标准局终局卖矿：30 天按报价公式卖 + 之后降价拍卖（规则决定 6.17 / 6.18）
contract StdMachineSalesTest is Fixture {
    TapeBoard internal b;
    address internal buyer = address(0xB0B);
    uint256 internal floor;
    uint256 internal avg;
    uint256 internal t0;

    function setUp() public override {
        super.setUp();
        b = _startGenesis();
        _fillUniform(b, 25, 20 * BEM_1);
        _sell(b, _newUser(), 100);
        _sell(b, _newUser(), 100);
        _sell(b, _newUser(), 100);
        vm.warp(b.startedAt() + 730 days);
        b.expire(); // 最长期限：进入终局（保底公式），卖矿流程相同
        assertEq(uint256(b.state()), uint256(BoardState.Liquidating));
        t0 = b.liquidationStart();
        avg = b.totalSpent() / b.totalWeightBought();
        floor = b.sellFloorPrice();
        assertEq(floor, avg * 6_000 / 10_000);
        bem.mint(buyer, 100_000 * BEM_1);
        vm.prank(buyer);
        bem.approve(address(stdSales), type(uint256).max);
    }

    function _buy(uint256 index) internal returns (uint256) {
        vm.prank(buyer);
        return stdSales.buyMachine(address(b), index, type(uint256).max);
    }

    // ---------------- 市价期 ----------------

    /// @dev 前 30 天：卖价 = max(买一, 卖一 × (99% − 0.5% × n))，n = 已过的整 6 小时数；没有成本价底线，
    ///      但不低于拍卖底价（采购均价 × 60%，规则决定 6.31）
    function test_MarketPeriodSellsAtFormulaNeverBelowAuctionFloor() public {
        uint256 bid = floor / 2; // 买一低于底价：公式降到买一时按底价卖
        uint256 ask = floor * 2;
        _postPrices(bid, ask);
        uint256 n = (block.timestamp - t0) / 6 hours; // 规则决定 6.21：每 6 小时降 0.5%
        uint256 f = ask * (9_900 - 50 * n) / 10_000;
        uint256 expected = f > bid ? f : bid;
        assertGt(expected, floor);
        (uint256 p, uint8 phase) = stdSales.askPrice(address(b), 0);
        assertEq(phase, 1);
        assertEq(p, expected);
        assertEq(_buy(0), 100 * expected);
        assertEq(machines.ownerOf(b.machine(0).circuitId), buyer);
        // 每 6 小时按公式下调；公式价跌破底价后停在底价（99% → 50% 要 98 档 ≈ 588 小时，仍在 30 天市价期内）
        for (uint256 k = 0; k < 300; k++) {
            vm.warp(block.timestamp + 2 hours);
            _postPrices(bid, ask);
        }
        (p, phase) = stdSales.askPrice(address(b), 1);
        assertEq(phase, 1);
        assertEq(p, floor, "held at the auction floor, not the bid");
        assertEq(_buy(1), 100 * floor);
    }

    /// @dev 运营地址被盗、把报价压到极低（过期后第一次报价不限幅度）：市价期最低按底价卖（TapeCode rc10 第 2 份报告 C3）
    function test_MarketPeriodFloorBoundsCompromisedOperator() public {
        _postPrices(floor, floor * 2);
        vm.warp(block.timestamp + 3 hours); // 报价过期
        _postPrices(1, 1);
        (uint256 p, uint8 phase) = stdSales.askPrice(address(b), 0);
        assertEq(phase, 1);
        assertEq(p, floor);
        assertEq(_buy(0), 100 * floor);
    }

    function test_MarketPeriodPausedWhenFeedStale() public {
        (uint256 p, uint8 phase) = stdSales.askPrice(address(b), 0);
        assertEq(phase, 0, "never posted");
        assertEq(p, 0);
        vm.prank(buyer);
        vm.expectRevert(StdMachineSales.NotForSale.selector);
        stdSales.buyMachine(address(b), 0, type(uint256).max);
        _postPrices(floor, floor * 2);
        vm.warp(block.timestamp + 3 hours);
        vm.prank(buyer);
        vm.expectRevert(StdMachineSales.NotForSale.selector);
        stdSales.buyMachine(address(b), 0, type(uint256).max);
        vm.expectRevert(StdMachineSales.NotYet.selector);
        stdSales.startAuction(address(b));
    }

    // ---------------- 降价拍卖 ----------------

    /// @dev 第 30 天起：起价 = 第一次触发时的买一（报价有效时），时钟从第 30 天整算（P-4 a）
    function test_AuctionStartsFromBidSnapshotClockFromDay30() public {
        vm.warp(t0 + 30 days + 5 hours);
        uint256 bid = avg * 2;
        _postPrices(bid, bid * 12 / 10);
        stdSales.startAuction(address(b));
        assertEq(stdSales.auctionStartPrice(address(b)), bid);
        (uint256 p, uint8 phase) = stdSales.askPrice(address(b), 0);
        assertEq(phase, 2);
        assertEq(p, bid - (bid - floor) * 5 hours / 14 days, "clock from day 30");
        stdSales.startAuction(address(b)); // 已开始：不重复快照
        vm.warp(t0 + 30 days + 14 days);
        (p,) = stdSales.askPrice(address(b), 1);
        assertEq(p, floor);
        vm.warp(t0 + 30 days + 21 days);
        (p,) = stdSales.askPrice(address(b), 1);
        assertEq(p, bid, "restarts after the 7-day hold");
    }

    /// @dev 报价无效时起价 = 采购均价 × 150%；买家购买时自动开始拍卖；拍卖不依赖报价
    function test_AuctionWithoutFeedAndAutoStartOnBuy() public {
        vm.warp(t0 + 30 days);
        uint256 cost = _buy(2);
        assertEq(cost, 100 * b.sellStartPrice());
        assertEq(stdSales.auctionStartPrice(address(b)), b.sellStartPrice());
        vm.warp(block.timestamp + 14 days);
        assertEq(_buy(1), 100 * floor);
    }

    function test_AuctionStartPriceNeverBelowFloor() public {
        vm.warp(t0 + 30 days);
        _postPrices(floor / 3, floor / 2);
        stdSales.startAuction(address(b));
        assertEq(stdSales.auctionStartPrice(address(b)), floor);
        (uint256 p,) = stdSales.askPrice(address(b), 0);
        assertEq(p, floor);
    }

    function test_AuctionPriceCapForBuyer() public {
        vm.warp(t0 + 30 days);
        stdSales.startAuction(address(b));
        uint256 start = b.sellStartPrice();
        vm.prank(buyer);
        vm.expectRevert(StdMachineSales.PriceAboveMaximum.selector);
        stdSales.buyMachine(address(b), 0, start - 1);
    }

    // ---------------- 计价权重、权限、收尾 ----------------

    function test_UnverifiedMachinePricing() public {
        _postPrices(floor * 2, floor * 2);
        pod.revoke(b.machine(0).key);
        (uint256 p,) = stdSales.askPrice(address(b), 0);
        assertEq(_buy(0), 100 * p, "market: market price x purchase weight");
        vm.warp(t0 + 30 days);
        pod.revoke(b.machine(1).key);
        assertEq(_buy(1), 100 * floor, "auction: floor x purchase weight");
    }

    function test_SellOutFinishesBoardAndPaysPot() public {
        _postPrices(floor, floor);
        uint256 alloc0 = b.potAllocated();
        uint256 fee0 = bem.balanceOf(FEE_SAFE);
        uint256 c0 = _buy(0);
        vm.warp(t0 + 30 days);
        uint256 c1 = _buy(1);
        uint256 c2 = _buy(2);
        assertEq(b.unsoldMachines(), 0);
        assertEq(b.finishedAt(), block.timestamp);
        // 卖出所得扣掉溢价分成（规则决定 6.37 起保底结局也收）后全部进底池
        assertGe(b.potAllocated() - alloc0 + (bem.balanceOf(FEE_SAFE) - fee0), c0 + c1 + c2, "proceeds go to the pot");
        assertEq(bem.balanceOf(address(stdSales)), 0, "sales contract holds nothing");
        vm.prank(buyer);
        vm.expectRevert(StdMachineSales.AlreadySold.selector);
        stdSales.buyMachine(address(b), 0, type(uint256).max);
    }

    function test_RejectsOtherBoardsAndStates() public {
        address month = address(_monthBoard());
        TapeBoard active = _board(); // 正在招募的下一块
        vm.expectRevert(StdMachineSales.NotStandardBoard.selector);
        stdSales.startAuction(month);
        vm.expectRevert(StdMachineSales.NotStandardBoard.selector);
        stdSales.startAuction(address(0xBAD));
        vm.expectRevert(StdMachineSales.WrongState.selector);
        stdSales.startAuction(address(active));
        vm.expectRevert(TapeBoard.NotAuthorized.selector);
        b.releaseMachine(0, buyer, 100, 0);
    }
}

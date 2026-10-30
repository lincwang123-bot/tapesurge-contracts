// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Fixture} from "./utils/Fixture.sol";
import {MonthBoard} from "../src/MonthBoard.sol";
import {TapeBoard} from "../src/TapeBoard.sol";
import {MarketPriceFeed} from "../src/MarketPriceFeed.sol";
import {MonthState} from "../src/interfaces/IMonthBoard.sol";
import {TapeSurgeDefaults} from "../script/TapeSurgeDefaults.sol";

/// @title 矿机市场报价与买卖公式（MarketPriceFeed，两种局共用；规则决定 6.17 / 6.18）
contract MarketPriceFeedTest is Fixture {
    MonthBoard internal m;
    uint256 internal cap;

    function setUp() public override {
        super.setUp();
        _startGenesis();
        m = _monthBoard();
        _fillMonth(m);
        assertEq(uint256(m.state()), uint256(MonthState.Preparing));
        cap = m.buyPriceCap();
        assertGt(cap, 0);
    }

    function _curve() internal view returns (uint256) {
        MonthBoard.Config memory c = monthFactory.boardConfig();
        uint256 bps = c.buyStartBps + ((block.timestamp - m.startedAt()) / c.buyStepInterval) * c.buyStepBps;
        if (bps > 10_000) bps = 10_000;
        return cap * bps / 10_000;
    }

    // ---------------- 报价 ----------------

    function test_OnlyOperatorPostsValidPrices() public {
        vm.prank(address(0xBAD));
        vm.expectRevert(MarketPriceFeed.NotOperator.selector);
        priceFeed.post(cap / 2, cap);
        vm.expectRevert(MarketPriceFeed.BadPrices.selector);
        priceFeed.post(0, cap);
        vm.expectRevert(MarketPriceFeed.BadPrices.selector);
        priceFeed.post(cap, cap - 1); // bid > ask
        vm.expectEmit(address(priceFeed));
        emit MarketPriceFeed.PricesPosted(cap / 2, cap * 8 / 10, 0, 0, block.timestamp);
        priceFeed.post(cap / 2, cap * 8 / 10); // 测试合约是运营地址
        assertTrue(priceFeed.fresh());
        assertFalse(priceFeed.abandoned());
        assertEq(priceFeed.bid(), cap / 2);
        assertEq(priceFeed.ask(), cap * 8 / 10);
    }

    function test_ChangeLimitAndMinIntervalForBothSides() public {
        uint256 b = cap / 2 / 400 * 400;
        uint256 a = cap * 8 / 10 / 400 * 400;
        priceFeed.post(b, a);
        vm.expectRevert(MarketPriceFeed.TooSoon.selector);
        priceFeed.post(b, a);
        vm.warp(block.timestamp + 50 minutes);
        vm.expectRevert(MarketPriceFeed.ChangeTooLarge.selector);
        priceFeed.post(b * 106 / 100, a);
        vm.expectRevert(MarketPriceFeed.ChangeTooLarge.selector);
        priceFeed.post(b, a * 94 / 100);
        priceFeed.post(b * 105 / 100, a * 95 / 100); // 恰好 ±5%
        // 审计 H-1：上一次已过期（停报再久）也照样限幅
        vm.warp(block.timestamp + 30 days);
        vm.expectRevert(MarketPriceFeed.ChangeTooLarge.selector);
        priceFeed.post(b * 3, a * 3);
        uint256 nb = priceFeed.bid() * 105 / 100;
        uint256 na = priceFeed.ask() * 105 / 100;
        priceFeed.post(nb, na); // 每次 5% 照常可以
        assertEq(priceFeed.bid(), nb);
    }

    function test_StaleAndAbandoned() public {
        assertTrue(priceFeed.abandoned(), "never posted");
        assertFalse(priceFeed.fresh());
        priceFeed.post(cap / 2, cap);
        vm.warp(block.timestamp + 3 hours);
        assertFalse(priceFeed.fresh(), "stale after 3 hours");
        assertFalse(priceFeed.abandoned());
        vm.warp(priceFeed.updatedAt() + 7 days - 1);
        assertFalse(priceFeed.abandoned());
        vm.warp(priceFeed.updatedAt() + 7 days);
        assertTrue(priceFeed.abandoned(), "abandoned after 7 days");
        priceFeed.post(cap / 2, cap);
        vm.prank(FEE_SAFE);
        factory.setOperator(address(0));
        // 审计 M-4：运营地址为 0 只是暂停（fresh 为假），7 天没报价才算停运
        assertFalse(priceFeed.abandoned(), "no operator is not abandonment");
        assertFalse(priceFeed.fresh());
        vm.warp(priceFeed.updatedAt() + 7 days);
        assertTrue(priceFeed.abandoned());
    }

    function test_ConstructorBounds() public {
        MarketPriceFeed.Params memory p = TapeSurgeDefaults.feedParams(7 days);
        vm.expectRevert(MarketPriceFeed.BadConfig.selector);
        new MarketPriceFeed(address(0), p);
        p.abandonAfter = 1 hours; // 短于过期时间
        vm.expectRevert(MarketPriceFeed.BadConfig.selector);
        new MarketPriceFeed(address(factory), p);
        p = TapeSurgeDefaults.feedParams(7 days);
        p.minInterval = 3 hours;
        vm.expectRevert(MarketPriceFeed.BadConfig.selector);
        new MarketPriceFeed(address(factory), p);
    }

    // ---------------- 买入 ----------------

    function test_NoPostUsesDefaultCurve() public {
        assertEq(priceFeed.updatedAt(), 0);
        assertEq(m.buyPrice(), cap / 2, "curve starts at half of the cap");
        vm.warp(block.timestamp + 6 hours);
        assertEq(m.buyPrice(), _curve());
        assertEq(m.buyPrice(), cap * 55 / 100);
    }

    /// @dev 规则决定 6.37：报价有效时收购价上限 = min(卖一, 一年产出)，开局就按卖一，不再从买一每小时 +0.5% 往上爬；
    ///      每小时按最新报价重算；按实际花费记账
    function test_BuyPriceIsTheAskFromTheStart() public {
        uint256 bid = cap * 6 / 10;
        uint256 ask = cap * 63 / 100;
        priceFeed.post(bid, ask);
        assertEq(m.buyPrice(), ask, "the ask from the first hour");
        vm.warp(block.timestamp + 2 hours);
        assertEq(m.buyPrice(), ask, "does not climb with time");
        vm.warp(block.timestamp + 1 hours);
        priceFeed.post(bid, ask * 104 / 100);
        assertEq(m.buyPrice(), ask * 104 / 100, "follows the latest ask");
        (,, uint256 paid) = _sellMonth(m, _newUser(), 30);
        assertEq(paid, 30 * (ask * 104 / 100));
    }

    function test_BuyPriceCappedAtFullYearNoFloor() public {
        priceFeed.post(cap * 2, cap * 3);
        assertEq(m.buyPrice(), cap, "capped at one year of output");
        _postPrices(cap / 10, cap / 5); // 相当于机器人分几次追到了这个价（每次最多 5%，审计 H-1）
        assertEq(m.buyPrice(), cap / 5, "the ask, no half-year floor");
        assertLt(m.buyPrice(), cap / 2);
    }

    function test_StaleFeedSuspendsPurchases() public {
        priceFeed.post(cap * 6 / 10, cap * 8 / 10);
        vm.warp(block.timestamp + 3 hours);
        assertEq(m.buyPrice(), 0, "stale: suspended, not the curve");
        address seller = _newUser();
        (uint256 id,) = _newMachine(seller, 30);
        _toTrader(address(m), address(machines), id, seller);
        vm.prank(address(trader));
        vm.expectRevert(MonthBoard.PriceUnavailable.selector);
        m.sellMachine(address(machines), id, 0);
        priceFeed.post(cap * 6 / 10, cap * 8 / 10);
        assertGt(m.buyPrice(), 0, "resumes on the next post");
        vm.prank(address(trader));
        m.sellMachine(address(machines), id, 0);
        assertEq(m.machineCount(), 1);
    }

    /// @dev 运营地址设成 0：没人能报价，暂停收购（审计 M-4）；满 7 天停运后仍然暂停，不退回默认曲线（全局审计 G-1）
    function test_NoOperatorPausesAndStaysPausedWhenAbandoned() public {
        priceFeed.post(cap * 6 / 10, cap * 8 / 10);
        vm.prank(FEE_SAFE);
        factory.setOperator(address(0));
        assertEq(m.buyPrice(), 0, "paused, not the curve");
        vm.expectRevert(MarketPriceFeed.NotOperator.selector);
        priceFeed.post(cap / 2, cap);
        // 准备期没那么长（测试参数）：直接看报价合约的收购价
        vm.warp(priceFeed.updatedAt() + 7 days);
        assertTrue(priceFeed.abandoned());
        assertEq(priceFeed.buyQuote(cap, 123, m.startedAt()), 0, "abandoned: still paused, not the curve");
    }

    function test_NoPurchaseAfterPreparation() public {
        priceFeed.post(cap * 6 / 10, cap * 8 / 10);
        vm.warp(m.prepEnd());
        assertEq(m.buyPrice(), 0);
    }

    /// @dev 两种局共用同一个报价实例；标准局的 h 从本轮收购开始（buyRoundStart）算
    function test_StandardBoardUsesSharedFeed() public {
        TapeBoard sb = _board();
        _fillUniform(sb, 25, 20 * BEM_1);
        assertTrue(sb.isPurchasing());
        assertEq(sb.PRICE_FEED(), address(priceFeed));
        assertEq(m.PRICE_FEED(), address(priceFeed));
        uint256 scap = sb.buyPriceCap();
        assertEq(sb.buyPrice(), scap / 2, "no post: default curve");
        uint256 bid = scap * 6 / 10;
        priceFeed.post(bid, scap * 9 / 10);
        uint256 expected = scap * 9 / 10; // 规则决定 6.37：= 卖一
        assertEq(sb.buyPrice(), expected);
        (,, uint256 paid) = _sell(sb, _newUser(), 40);
        assertEq(paid, 40 * expected);
        vm.warp(block.timestamp + 3 hours);
        assertEq(sb.buyPrice(), 0, "stale: suspended");
    }

    // ---------------- 卖出 ----------------

    /// @dev 卖价 = max(买一, 卖一 × (99% − 0.5% × h))，降到买一后跟着买一；过期 → 0
    function test_SellQuoteDecaysToBid() public {
        uint256 since = block.timestamp;
        uint256 bid = 1_000_000;
        uint256 ask = 1_200_000;
        assertEq(priceFeed.sellQuote(since), 0, "never posted");
        priceFeed.post(bid, ask);
        assertEq(priceFeed.sellQuote(since), ask * 9_900 / 10_000);
        // 超过 3 小时没更新就算过期，所以每次检查前先重新报价（同样的价格）
        vm.warp(since + 5 hours);
        priceFeed.post(bid, ask);
        assertEq(priceFeed.sellQuote(since), ask * 9_900 / 10_000, "no drop within the first 6 hours (rule 6.21)");
        vm.warp(since + 6 hours);
        priceFeed.post(bid, ask);
        assertEq(priceFeed.sellQuote(since), ask * 9_850 / 10_000, "0.5% per 6 hours");
        vm.warp(since + 12 hours);
        priceFeed.post(bid, ask);
        assertEq(priceFeed.sellQuote(since), ask * 9_800 / 10_000);
        for (uint256 k = 0; k < 100; k++) {
            vm.warp(block.timestamp + 2 hours);
            priceFeed.post(bid, ask);
        }
        assertEq(priceFeed.sellQuote(since), bid, "followed down to the bid");
        vm.warp(block.timestamp + 3 hours);
        assertEq(priceFeed.sellQuote(since), 0, "stale");
    }
}

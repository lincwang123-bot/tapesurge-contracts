// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Fixture} from "./utils/Fixture.sol";
import {TapeBoard} from "../src/TapeBoard.sol";
import {MonthBoard} from "../src/MonthBoard.sol";
import {MonthState} from "../src/interfaces/IMonthBoard.sol";
import {BoardState} from "../src/interfaces/ITapeBoard.sol";
import {MarketPriceFeed} from "../src/MarketPriceFeed.sol";

/// @notice 第三方复核（2026-10-25，v2.0-audit.2）的 3 个测试；N-1 在 v2.0-audit.3 修复后改为回归测试（追价期间暂停买卖）。
contract AuditRecheckTest is Fixture {
    // ------------------------------------------------------------------
    // N-1：行情跳空后分步追价（postCatchUp），追价期间报价不算有效，两种局暂停按报价买卖；追到市价的最后一步（post）恢复
    // ------------------------------------------------------------------
    function test_N1_CatchUpPausesTradingUntilTheLastStep() public {
        TapeBoard b = _startGenesis();
        _fillUniform(b, 25, 20 * BEM_1); // 500 BEM，开局
        uint256 cap = b.buyPriceCap();
        uint256 fair = cap / 2;
        priceFeed.post(fair, fair);

        // 机器人离线 4 小时，这期间市场跌了 30%
        vm.warp(block.timestamp + 4 hours);
        uint256 market = fair * 70 / 100;
        assertEq(b.buyPrice(), 0, "stale feed pauses purchases");

        // 机器人恢复，每 50 分钟追 5%：每一步之后都不能按报价卖矿机给主板
        uint256 p = fair;
        uint256 steps;
        while (true) {
            uint256 next = (p * 9_500 + 9_999) / 10_000;
            vm.warp(priceFeed.updatedAt() + 50 minutes);
            if (next <= market) {
                priceFeed.post(market, market); // 最后一步：已经是市价
                break;
            }
            p = next;
            priceFeed.postCatchUp(p, p);
            steps++;
            assertTrue(priceFeed.catchingUp());
            assertFalse(priceFeed.fresh());
            assertFalse(priceFeed.abandoned(), "catching up is not abandonment");
            assertEq(b.buyPrice(), 0, "catching up: purchases paused");
            address seller = _newUser();
            (uint256 id,) = _newMachine(seller, 30);
            _toTrader(address(b), address(machines), id, seller);
            vm.prank(address(trader));
            vm.expectRevert(TapeBoard.PriceUnavailable.selector);
            b.sellMachine(address(machines), id, 0);
        }
        assertEq(steps, 6);
        assertFalse(priceFeed.catchingUp());
        assertTrue(priceFeed.fresh());
        assertLe(b.buyPrice(), market * 10_100 / 10_000, "resumes at the market");
        (,, uint256 paid) = _sell(b, _newUser(), 30);
        assertLe(paid, 30 * market * 10_100 / 10_000);
    }

    /// @dev 追价和普通报价同样受限（只有运营地址、间隔 ≥ 50 分钟、每次 ±5%）；月局结算中追价时暂停出售，不按成本价兜底
    function test_N1_CatchUpLimitsAndMonthSalesPaused() public {
        _startGenesis();
        MonthBoard m = _monthBoard();
        _fillMonth(m);
        _sellMonth(m, _newUser(), 30);
        vm.warp(m.prepEnd());
        m.sync();
        vm.warp(m.miningEnd());
        m.drawPrizes();
        uint256 unit = _unitFor(m, 0, 13_000);
        priceFeed.post(unit, unit);
        assertGt(sales.askPrice(address(m), 0), m.machine(0).cost);

        vm.prank(address(0xBAD));
        vm.expectRevert(MarketPriceFeed.NotOperator.selector);
        priceFeed.postCatchUp(unit, unit);
        vm.expectRevert(MarketPriceFeed.TooSoon.selector);
        priceFeed.postCatchUp(unit, unit);
        vm.warp(block.timestamp + 50 minutes);
        vm.expectRevert(MarketPriceFeed.ChangeTooLarge.selector);
        priceFeed.postCatchUp(unit * 2, unit * 2);

        uint256 up = unit * 105 / 100;
        vm.expectEmit(address(priceFeed));
        emit MarketPriceFeed.CatchUpPosted(up, up, block.timestamp);
        priceFeed.postCatchUp(up, up);
        assertEq(sales.askPrice(address(m), 0), 0, "catching up: month sale paused, not at cost");
        // 追价几个小时远不到停运（停运按最后一次有效报价算，7 天）
        vm.warp(priceFeed.updatedAt() + 50 minutes);
        priceFeed.postCatchUp(up * 105 / 100, up * 105 / 100);
        vm.warp(priceFeed.updatedAt() + 50 minutes);
        priceFeed.post(up * 105 / 100, up * 105 / 100);
        assertGt(sales.askPrice(address(m), 0), m.machine(0).cost, "live again");
    }

    // ------------------------------------------------------------------
    // H-2 复核：起价 = 成本、底价 = 1 wei 的计划，成交价仍不低于买一 × 算力 × 95%
    // ------------------------------------------------------------------
    function test_H2_PlanFloorFollowsBid() public {
        _startGenesis();
        MonthBoard m = _monthBoard();
        _fillMonth(m);
        _sellMonth(m, _newUser(), 30);
        vm.warp(m.prepEnd());
        m.sync();
        vm.warp(m.miningEnd());
        m.drawPrizes();
        assertEq(uint256(m.state()), uint256(MonthState.Settling));

        uint256[] memory idx = new uint256[](1);
        uint128[] memory st = new uint128[](1);
        uint128[] memory fl = new uint128[](1);
        st[0] = m.machine(0).cost;
        fl[0] = 1;
        bytes32 h = governor.publishPlan(address(m), idx, st, fl);
        vm.warp(m.settleStart() + 7 days);
        uint256[] memory sup = new uint256[](3);
        for (uint256 s = 1; s <= 3; s++) {
            sup[s - 1] = s;
            uint256[] memory one = new uint256[](1);
            one[0] = s;
            vm.prank(m.socket(s).owner);
            governor.support(address(m), one, h);
        }
        governor.openVote(address(m), h, sup);
        uint8 yes = governor.YES();
        for (uint256 s = 1; s <= 13; s++) {
            uint256[] memory one = new uint256[](1);
            one[0] = s;
            vm.prank(m.socket(s).owner);
            governor.castVote(address(m), one, yes);
        }
        vm.warp(block.timestamp + 24 hours);
        governor.finalizeVote(address(m));
        vm.warp(block.timestamp + 24 hours);
        governor.execute(address(m));
        vm.warp(block.timestamp + 8 days); // 计划价已降到底价 1 wei

        uint256 unit = _unitFor(m, 0, 5_000); // 市价 = 成本的一半
        priceFeed.post(unit, unit);
        uint256 w = m.machine(0).weight;
        assertEq(sales.askPrice(address(m), 0), unit * w * 9_500 / 10_000, "plan price floored at 95% of bid");
        // 报价过期（未到停运）：计划价暂停
        vm.warp(block.timestamp + 3 hours);
        assertEq(sales.askPrice(address(m), 0), 0);
    }

    // ------------------------------------------------------------------
    // M-3 复核：重发后，旧请求先到也被采用，之后到的另一个请求被忽略
    // ------------------------------------------------------------------
    function test_M3_OldRequestStillCountsAfterRetry() public {
        TapeBoard b = _startGenesis();
        _fillUniform(b, 25, 20 * BEM_1);
        _sell(b, _newUser(), 200);
        _topUpPool(b);
        b.pulse();
        uint256 first = b.pendingRequestId();
        vm.warp(block.timestamp + 1 days);
        b.retryDraw();
        uint256 second = b.pendingRequestId();
        assertTrue(first != second);
        uint256 alive = b.aliveCount();
        rng.fulfill(first, 12345);
        assertEq(b.aliveCount(), alive - 1, "old request was used");
        assertFalse(b.drawPending());
        rng.fulfill(second, 999);
        assertEq(b.aliveCount(), alive - 1, "second answer ignored");
    }
}

// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Fixture} from "./utils/Fixture.sol";
import {MonthBoard} from "../src/MonthBoard.sol";
import {MonthState} from "../src/interfaces/IMonthBoard.sol";

/// @notice 第三方第二次复核（2026-10-25，v2.0-audit.3）的 2 个测试；N-2 在 v2.0-audit.4 修复后改为回归测试：
///         一直追价也会在最后一次有效报价 7 天后停运。
contract AuditRecheck2Test is Fixture {
    MonthBoard internal m;

    function setUp() public override {
        super.setUp();
        _startGenesis();
        m = _monthBoard();
        _fillMonth(m);
        _sellMonth(m, _newUser(), 30);
        vm.warp(m.prepEnd());
        m.sync();
        vm.warp(m.miningEnd());
        m.drawPrizes();
        assertEq(uint256(m.state()), uint256(MonthState.Settling));
        uint256 unit = _unitFor(m, 0, 8_000); // 市价低于成本：月局卖不掉，等停运后按成本价兜底
        priceFeed.post(unit, unit);
        assertEq(sales.askPrice(address(m), 0), m.machine(0).cost);
    }

    /// @dev 对照：运营地址不报价，7 天后停运，月局按成本价可买（本金能收回）
    function test_N2_NoPostingReachesCostFallback() public {
        vm.warp(block.timestamp + 7 days);
        assertTrue(priceFeed.abandoned());
        assertEq(sales.askPrice(address(m), 0), m.machine(0).cost, "abandoned: cost-price fallback");
    }

    /// @dev N-2（已修复）：运营地址每 50 分钟报一次 postCatchUp（价格在 5% 内来回），追价期间暂停；最后一次有效报价
    ///      满 7 天后照样停运，月局按成本价兜底（停运按 liveAt 算）
    function test_N2_EndlessCatchUpStillReachesCostFallback() public {
        uint256 live = priceFeed.liveAt();
        uint256 p = priceFeed.bid();
        uint256 end = block.timestamp + 8 days;
        bool down = true;
        while (block.timestamp < end) {
            vm.warp(priceFeed.updatedAt() + 50 minutes);
            uint256 q = down ? p * 9_800 / 10_000 : p;
            priceFeed.postCatchUp(q, q);
            down = !down;
            if (block.timestamp < live + 7 days) {
                assertEq(sales.askPrice(address(m), 0), 0, "catching up: paused");
            }
        }
        assertEq(priceFeed.liveAt(), live, "catch-up posts do not refresh liveAt");
        assertTrue(priceFeed.abandoned(), "abandoned 7 days after the last live post");
        assertEq(sales.askPrice(address(m), 0), m.machine(0).cost, "cost-price fallback");
        // 一次有效报价恢复正常（不再停运）
        vm.warp(priceFeed.updatedAt() + 50 minutes);
        priceFeed.post(p, p);
        assertFalse(priceFeed.abandoned());
        assertEq(priceFeed.liveAt(), block.timestamp);
    }
}

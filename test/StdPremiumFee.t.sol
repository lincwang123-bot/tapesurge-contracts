// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Fixture} from "./utils/Fixture.sol";
import {TapeBoard} from "../src/TapeBoard.sol";
import {SettleMode} from "../src/interfaces/ITapeBoard.sol";

/// @notice 标准局卖矿溢价分成（规则决定 6.25）：正常终局卖出时，成交额超过这台矿机成本
///         （平均每单位算力成本 × 收购时算力）的部分 10% 给手续费地址，其余并入底池；不高于成本、异常结局不收。
contract StdPremiumFeeTest is Fixture {
    TapeBoard internal b;
    address internal buyer = address(0xB0B);

    function setUp() public override {
        super.setUp();
        b = _startGenesis();
        _fillUniform(b, 20, 20 * BEM_1);
        _fillUniform(b, 20, 5 * BEM_1);
        _sell(b, _newUser(), 200);
        bem.mint(buyer, 10_000 * BEM_1);
    }

    function _normalEnd() internal {
        _drawUntilKing(b, 5);
        _topUpPool(b);
        b.pulse();
        assertEq(uint256(b.settleMode()), uint256(SettleMode.Normal));
    }

    /// @dev 把卖价报成成本单价 × pct%（买一 = 卖一，市价期卖价 = max(买一, 卖一 × 99%) = 买一）
    function _priceAt(uint256 pct) internal {
        uint256 unit = stdSales.machineCost(address(b), 0) / b.machine(0).weight;
        _postPrices(unit * pct / 100, unit * pct / 100);
    }

    function test_MachineCostIsAverageUnitCostTimesWeight() public view {
        assertEq(stdSales.PREMIUM_FEE_BPS(), 1_000);
        assertEq(stdSales.machineCost(address(b), 0), b.totalSpent() * b.machine(0).weight / b.totalWeightBought());
    }

    function test_NormalSaleAbovePaysTenPercentOfThePremium() public {
        _normalEnd();
        _priceAt(130);
        uint256 basis = stdSales.machineCost(address(b), 0);
        uint256 fee0 = bem.balanceOf(FEE_SAFE);
        uint256 pot0 = b.potAllocated();
        uint256 paid = _stdBuy(b, 0, buyer);
        assertGt(paid, basis);
        uint256 fee = (paid - basis) / 10;
        assertEq(bem.balanceOf(FEE_SAFE) - fee0, fee, "10% of the premium to the fee safe");
        assertGe(b.potAllocated() - pot0, paid - fee, "the rest goes into the pot");
        assertEq(bem.balanceOf(address(stdSales)), 0);
    }

    function test_NormalSaleAtOrBelowCostPaysNothing() public {
        _normalEnd();
        _priceAt(90);
        uint256 fee0 = bem.balanceOf(FEE_SAFE);
        uint256 pot0 = b.potAllocated();
        uint256 paid = _stdBuy(b, 0, buyer);
        assertLe(paid, stdSales.machineCost(address(b), 0));
        assertEq(bem.balanceOf(FEE_SAFE), fee0);
        assertGe(b.potAllocated() - pot0, paid);
    }

    /// @dev 规则决定 6.37：保底结局卖出高于成本时也收 10% 溢价分成
    function test_AbnormalEndAlsoPaysPremiumFee() public {
        vm.warp(b.startedAt() + 730 days);
        b.expire();
        assertEq(uint256(b.settleMode()), uint256(SettleMode.Fallback));
        _priceAt(150);
        uint256 fee0 = bem.balanceOf(FEE_SAFE);
        uint256 cost = stdSales.machineCost(address(b), 0);
        uint256 paid = _stdBuy(b, 0, buyer);
        assertGt(paid, cost);
        assertEq(bem.balanceOf(FEE_SAFE) - fee0, (paid - cost) * 1_000 / 10_000, "premium fee in fallback too");
    }
}

// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IMonthBoardV2} from "../interfaces/IMonthV2.sol";

interface IBoardForMarket {
    function sellMachine(address collection, uint256 circuitId, uint256 minPricePerWeight)
        external
        returns (uint256 paid);
    function SALES() external view returns (address);
    function FEE_RECIPIENT() external view returns (address);
}

interface IStdSalesForMarket {
    function PREMIUM_FEE_BPS() external view returns (uint256);
    function machineCost(address board, uint256 index) external view returns (uint256);
}

/// @title 市场成交后给主板结账的共用部分（MarketTrader 卖给买单 / 接受出价、MachineLister 挂单成交）
abstract contract SaleSettlement {
    using SafeERC20 for IERC20;

    uint256 public constant BPS = 10_000;

    IERC20 public immutable BEM;

    event PremiumFeePaid(address indexed board, uint256 amount);

    constructor(address bem) {
        BEM = IERC20(bem);
    }

    /// @dev 两种主板 machine(index) 返回的结构体前三个字段都是 (bytes32 key, uint256 circuitId, address collection)
    function _machineOf(address board, uint256 index) internal view returns (address collection, uint256 id) {
        (bool ok, bytes memory ret) = board.staticcall(abi.encodeWithSignature("machine(uint256)", index));
        if (!ok || ret.length < 96) revert MachineUnknown();
        (, id, collection) = abi.decode(ret, (bytes32, uint256, address));
    }

    error MachineUnknown();

    /// @dev 卖矿溢价分成（规则决定 6.24 月局、6.25 标准局）：要价之外多出来的 extra 个 BEM 也是这台矿机的卖出所得，
    ///      交割时已经按 max(要价 − 成本, 0) 扣过；这里扣 max(要价 + extra − 成本, 0) − max(要价 − 成本, 0) 的 10%，
    ///      转给主板的手续费地址，返回扣下的数额（调用方把 extra − 返回值 转给主板）。
    ///      月局：比例 = 主板 PREMIUM_FEE_BPS，成本 = 这台的买入价；标准局：比例 = StdMachineSales.PREMIUM_FEE_BPS，
    ///      成本 = StdMachineSales.machineCost（平均每单位算力成本 × 收购时算力）；规则决定 6.37 起保底结局也收。
    function _premiumFee(address board, uint256 index, uint256 price, uint256 extra) internal returns (uint256 fee) {
        if (extra == 0) return 0;
        uint256 bps;
        uint256 cost;
        (bool ok, bytes memory ret) = board.staticcall(abi.encodeWithSignature("PREMIUM_FEE_BPS()"));
        if (ok && ret.length >= 32) {
            bps = abi.decode(ret, (uint256));
            cost = IMonthBoardV2(board).machine(index).cost;
        } else {
            IStdSalesForMarket sales = IStdSalesForMarket(IBoardForMarket(board).SALES());
            bps = sales.PREMIUM_FEE_BPS();
            cost = sales.machineCost(board, index);
        }
        uint256 total = price + extra;
        if (total <= cost) return 0;
        uint256 premium = total - cost - (price > cost ? price - cost : 0);
        fee = premium * bps / BPS;
        if (fee == 0) return 0;
        BEM.safeTransfer(IBoardForMarket(board).FEE_RECIPIENT(), fee);
        emit PremiumFeePaid(board, fee);
    }
}

// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ISwapRouter} from "../interfaces/ISwap.sol";
import {IFirstoSwapper, IFirstoSwapCallback} from "./IFirsto.sol";

interface IPancakeV3Pool {
    function token0() external view returns (address);
    function swap(address recipient, bool zeroForOne, int256 amountSpecified, uint160 sqrtPriceLimitX96, bytes calldata data)
        external
        returns (int256 amount0, int256 amount1);
}

interface IWBNB {
    function deposit() external payable;
    function withdraw(uint256 amount) external;
    function transfer(address to, uint256 amount) external returns (bool);
}

/// @title PancakeFirstoSwapper（MarketTrader 的主网兑换适配器；MachineLister 也用它把卖款换成 BEM）
/// @notice 走和分账合约回购相同的路径：WBNB ⇄（WBNB/USDT 0.01% 池）⇄ USDT ⇄（USDT/BEM 1% 池）⇄ BEM。
///         - flashBnb：两跳"精确输出 WBNB"的嵌套兑换：池 1 先把 WBNB 发给本合约，回调里让池 2 把 USDT 直接付给池 1，
///           池 2 的回调里把 WBNB 换成 BNB 发给调用者、回调调用者（调用者用这些 BNB 买矿机、从主板收 BEM、把欠的 BEM 转给
///           本合约），最后把 BEM 付给池 2。
///         - flashBem：两跳"精确输出 BEM"：池 2 先把 BEM 发给调用者，回调里让池 1 把 USDT 直接付给池 2，池 1 的回调里
///           回调调用者（调用者卖出矿机拿到 BNB、把欠的 BNB 转给本合约），本合约包装成 WBNB 付给池 1。
///         - swapBnbForBem：经 PancakeSwap V3 SwapRouter 精确输入兑换（附带的 BNB 由路由包装成 WBNB）。
///         价格保护（相对 TWAP ±2%）在 FirstoTrader 里检查；这里不设价格上限（sqrtPriceLimit 取极值），由调用者检查欠款。
///         只服务一个调用者（构造时固定的 FirstoTrader）。没有管理员，不托管资金（每次调用结束时余额回到 0）。
contract PancakeFirstoSwapper is IFirstoSwapper {
    using SafeERC20 for IERC20;

    uint160 internal constant MIN_SQRT_RATIO = 4295128739;
    uint160 internal constant MAX_SQRT_RATIO = 1461446703485210103287273052203988822378723970342;
    uint8 internal constant MODE_BNB = 1;
    uint8 internal constant MODE_BEM = 2;

    IWBNB public immutable WBNB;
    address public immutable USDT;
    IERC20 public immutable BEM;
    IPancakeV3Pool public immutable POOL_WBNB_USDT;
    IPancakeV3Pool public immutable POOL_USDT_BEM;
    ISwapRouter public immutable ROUTER;
    uint24 public immutable FEE_WBNB_USDT;
    uint24 public immutable FEE_USDT_BEM;
    address public immutable TRADER;

    /// @dev 进行中的模式（0 = 空闲）；金额和调用者数据经池子回调的 data 原样传递，不写存储
    uint8 internal _mode;

    error BadConfig();
    error NotTrader();
    error NotPool();
    error Busy();
    error Underpaid();

    constructor(
        address wbnb,
        address usdt,
        address bem,
        address poolWbnbUsdt,
        address poolUsdtBem,
        address router,
        uint24 feeWbnbUsdt,
        uint24 feeUsdtBem,
        address trader
    ) {
        if (
            wbnb == address(0) || usdt == address(0) || bem == address(0) || poolWbnbUsdt == address(0)
                || poolUsdtBem == address(0) || router == address(0) || trader == address(0)
        ) revert BadConfig();
        WBNB = IWBNB(wbnb);
        USDT = usdt;
        BEM = IERC20(bem);
        POOL_WBNB_USDT = IPancakeV3Pool(poolWbnbUsdt);
        POOL_USDT_BEM = IPancakeV3Pool(poolUsdtBem);
        ROUTER = ISwapRouter(router);
        FEE_WBNB_USDT = feeWbnbUsdt;
        FEE_USDT_BEM = feeUsdtBem;
        TRADER = trader;
    }

    modifier onlyTrader() {
        if (msg.sender != TRADER) revert NotTrader();
        if (_mode != 0) revert Busy();
        _;
    }

    function flashBnb(uint256 bnbOut, bytes calldata data) external onlyTrader {
        _mode = MODE_BNB;
        // 池 1：精确输出 bnbOut 个 WBNB 给本合约，输入 USDT
        bool zeroForOne = POOL_WBNB_USDT.token0() == USDT;
        POOL_WBNB_USDT.swap(
            address(this), zeroForOne, -int256(bnbOut), _limit(zeroForOne), abi.encode(uint8(1), bnbOut, data)
        );
        _mode = 0;
    }

    function flashBem(uint256 bemOut, bytes calldata data) external onlyTrader {
        _mode = MODE_BEM;
        // 池 2：精确输出 bemOut 个 BEM 给调用者，输入 USDT
        bool zeroForOne = POOL_USDT_BEM.token0() == USDT;
        POOL_USDT_BEM.swap(TRADER, zeroForOne, -int256(bemOut), _limit(zeroForOne), abi.encode(uint8(1), bemOut, data));
        _mode = 0;
    }

    /// @notice 把附带的 BNB 全部换成 BEM 发给 to（至少 minOut）。任何人都可以调用（rc8：MachineLister 结算挂单成交时也用它）：
    ///         只换调用者自己附带的 BNB，本合约不经手别人的资金。
    function swapBnbForBem(uint256 minOut, address to) external payable returns (uint256 out) {
        out = ROUTER.exactInput{value: msg.value}(
            ISwapRouter.ExactInputParams({
                path: abi.encodePacked(address(WBNB), FEE_WBNB_USDT, USDT, FEE_USDT_BEM, address(BEM)),
                recipient: to,
                deadline: block.timestamp,
                amountIn: msg.value,
                amountOutMinimum: minOut
            })
        );
    }

    /// @notice PancakeSwap V3 的兑换回调
    function pancakeV3SwapCallback(int256 amount0Delta, int256 amount1Delta, bytes calldata data) external {
        (uint8 step, uint256 amount, bytes memory payload) = abi.decode(data, (uint8, uint256, bytes));
        uint256 owed = uint256(amount0Delta > 0 ? amount0Delta : amount1Delta);
        if (_mode == MODE_BNB) {
            if (step == 1) {
                // 池 1 要 USDT：让池 2 精确输出 owed 个 USDT 直接付给池 1，输入 BEM
                if (msg.sender != address(POOL_WBNB_USDT)) revert NotPool();
                bool zeroForOne = POOL_USDT_BEM.token0() == address(BEM);
                POOL_USDT_BEM.swap(
                    address(POOL_WBNB_USDT), zeroForOne, -int256(owed), _limit(zeroForOne), abi.encode(uint8(2), amount, payload)
                );
            } else {
                // 池 2 要 BEM：把收到的 WBNB 换成 BNB 发给调用者，回调它，收回 owed 个 BEM 付给池 2
                if (msg.sender != address(POOL_USDT_BEM)) revert NotPool();
                WBNB.withdraw(amount);
                uint256 bemBefore = BEM.balanceOf(address(this));
                (bool ok,) = TRADER.call{value: amount}("");
                if (!ok) revert Underpaid();
                IFirstoSwapCallback(TRADER).onFlash(owed, payload);
                if (BEM.balanceOf(address(this)) - bemBefore < owed) revert Underpaid();
                BEM.safeTransfer(msg.sender, owed);
            }
        } else if (_mode == MODE_BEM) {
            if (step == 1) {
                // 池 2 要 USDT：让池 1 精确输出 owed 个 USDT 直接付给池 2，输入 WBNB
                if (msg.sender != address(POOL_USDT_BEM)) revert NotPool();
                bool zeroForOne = POOL_WBNB_USDT.token0() == address(WBNB);
                POOL_WBNB_USDT.swap(
                    address(POOL_USDT_BEM), zeroForOne, -int256(owed), _limit(zeroForOne), abi.encode(uint8(2), amount, payload)
                );
            } else {
                // 池 1 要 WBNB：回调调用者（它已经拿到 BEM），收回 owed 个 BNB，包装后付给池 1
                if (msg.sender != address(POOL_WBNB_USDT)) revert NotPool();
                uint256 before = address(this).balance;
                IFirstoSwapCallback(TRADER).onFlash(owed, payload);
                if (address(this).balance - before < owed) revert Underpaid();
                WBNB.deposit{value: owed}();
                if (!WBNB.transfer(msg.sender, owed)) revert Underpaid();
            }
        } else {
            revert NotPool();
        }
    }

    function _limit(bool zeroForOne) internal pure returns (uint160) {
        return zeroForOne ? MIN_SQRT_RATIO + 1 : MAX_SQRT_RATIO - 1;
    }

    receive() external payable {}
}

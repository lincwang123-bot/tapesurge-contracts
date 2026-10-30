// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ISwapRouter, IBemPriceOracle} from "../interfaces/ISwap.sol";

interface IMintable {
    function mint(address to, uint256 amount) external;
}

/// @notice 仅用于测试 / 测试网：按固定汇率把 BNB 换成 BEM（直接铸造 MockBEM）。
///         校验路径以 WBNB 开头、以 BEM 结尾，模拟 PancakeSwap V3 的 exactInput。
contract MockRouter is ISwapRouter {
    address public immutable wbnb;
    address public immutable bem;
    /// @notice 1 BNB（1e18 wei）能换多少 BEM 最小单位
    uint256 public bemPerBnb;
    uint256 public swapCount;
    bytes public lastPath;

    constructor(address wbnb_, address bem_, uint256 bemPerBnb_) {
        wbnb = wbnb_;
        bem = bem_;
        bemPerBnb = bemPerBnb_;
    }

    function setRate(uint256 r) external {
        bemPerBnb = r;
    }

    function exactInput(ExactInputParams calldata p) external payable returns (uint256 amountOut) {
        bytes calldata path = p.path;
        require(path.length >= 43 && (path.length - 20) % 23 == 0, "path");
        require(address(bytes20(path[0:20])) == wbnb, "tokenIn");
        require(address(bytes20(path[path.length - 20:])) == bem, "tokenOut");
        require(msg.value == p.amountIn, "value");
        require(p.deadline >= block.timestamp, "Transaction too old");
        amountOut = p.amountIn * bemPerBnb / 1e18;
        require(amountOut >= p.amountOutMinimum, "Too little received");
        swapCount++;
        lastPath = p.path;
        IMintable(bem).mint(p.recipient, amountOut);
    }
}

/// @notice 仅用于测试 / 测试网：固定参考价的预言机。
contract MockPriceOracle is IBemPriceOracle {
    uint256 public bemPerBnb;

    constructor(uint256 bemPerBnb_) {
        bemPerBnb = bemPerBnb_;
    }

    function setRate(uint256 r) external {
        bemPerBnb = r;
    }

    function quoteBemOut(uint256 bnbIn) external view returns (uint256) {
        return bnbIn * bemPerBnb / 1e18;
    }
}

/// @notice 仅用于测试：固定 tick 的 V3 池子，用于测试 TWAP 预言机的数学。
contract MockV3Pool {
    address public token0;
    address public token1;
    int24 public tick;

    constructor(address t0, address t1, int24 tick_) {
        token0 = t0;
        token1 = t1;
        tick = tick_;
    }

    function setTick(int24 t) external {
        tick = t;
    }

    function observe(uint32[] calldata secondsAgos)
        external
        view
        returns (int56[] memory tickCumulatives, uint160[] memory secondsPerLiquidityCumulativeX128s)
    {
        tickCumulatives = new int56[](secondsAgos.length);
        secondsPerLiquidityCumulativeX128s = new uint160[](secondsAgos.length);
        for (uint256 i = 0; i < secondsAgos.length; i++) {
            tickCumulatives[i] = int56(tick) * int56(uint56(block.timestamp - secondsAgos[i]));
        }
    }
}

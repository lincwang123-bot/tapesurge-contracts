// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test, console2} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {TapeSurgeDefaults} from "../../script/TapeSurgeDefaults.sol";
import {PancakeFirstoSwapper} from "../../src/firsto/PancakeFirstoSwapper.sol";
import {PancakeV3TwapOracle} from "../../src/oracle/PancakeV3TwapOracle.sol";

interface IPoolSlot0 {
    function slot0() external view returns (uint160, int24, uint16, uint16, uint16, uint32, bool);
}

/// @title 主网分叉实测 PancakeFirstoSwapper 的兑换成本（0.45–2 BNB）
/// @notice 只测兑换本身（不碰 Firsto）：本合约充当 FirstoTrader，在回调里直接还款。
///         成本都相对 TWAP（FirstoTrader 的价格保护用的就是它）：
///         - 买入路径 flashBnb(x)：欠 BEM ÷ TWAP(x) − 1
///         - 卖出路径 flashBem(TWAP(x))：欠 BNB ÷ x − 1
///         - 余款兑换 swapBnbForBem(x)：1 − 到手 BEM ÷ TWAP(x)
///         另外打印现价相对 TWAP 的偏离（两跳合计），用来区分"手续费 + 价格冲击"和"现价漂移"。
///         FIRSTO_PROBE=1 BSC_RPC_URL=<主网 RPC> forge test --match-contract SwapCostForkTest -vv
///         （SWAP_POOL_USDT_BEM / SWAP_FEE_USDT_BEM 换池子；FORK_BLOCK 指定区块，需要归档节点）
contract SwapCostForkTest is Test {
    TapeSurgeDefaults.Mainnet internal m;
    PancakeFirstoSwapper internal swapper;
    PancakeV3TwapOracle internal oracle;
    uint8 internal mode; // 1 = 买入路径，2 = 卖出路径
    uint256 internal owedSeen;

    function setUp() public {
        if (!vm.envOr("FIRSTO_PROBE", false)) return;
        uint256 blk = vm.envOr("FORK_BLOCK", uint256(0));
        if (blk == 0) vm.createSelectFork(vm.envString("BSC_RPC_URL"));
        else vm.createSelectFork(vm.envString("BSC_RPC_URL"), blk);
        m = TapeSurgeDefaults.mainnetAddresses();
        address[] memory tokens = new address[](3);
        tokens[0] = m.wbnb;
        tokens[1] = m.usdt;
        tokens[2] = m.bem;
        address[] memory pools = new address[](2);
        pools[0] = m.poolWbnbUsdt;
        pools[1] = m.poolUsdtBem;
        oracle = new PancakeV3TwapOracle(tokens, pools, TapeSurgeDefaults.TWAP_WINDOW);
        // SWAP_POOL_USDT_BEM / SWAP_FEE_USDT_BEM：换一个 USDT/BEM 池子测（例如 0.01% 池 0x2f5e…ea38，fee 100）；TWAP 参照不变
        swapper = new PancakeFirstoSwapper(
            m.wbnb,
            m.usdt,
            m.bem,
            m.poolWbnbUsdt,
            vm.envOr("SWAP_POOL_USDT_BEM", m.poolUsdtBem),
            m.router,
            100,
            uint24(vm.envOr("SWAP_FEE_USDT_BEM", uint256(10_000))),
            address(this)
        );
    }

    receive() external payable {}

    function onFlash(uint256 owed, bytes calldata) external {
        owedSeen = owed;
        if (mode == 1) {
            deal(m.bem, address(this), owed);
            IERC20(m.bem).transfer(address(swapper), owed);
        } else {
            vm.deal(address(this), address(this).balance + owed);
            (bool ok,) = address(swapper).call{value: owed}("");
            require(ok);
        }
    }

    /// @dev 现价（两跳 slot0）相对 TWAP 的偏离，基点；正数 = 现价下 1 BNB 换到的 BEM 比 TWAP 多
    function _spotVsTwapBps() internal view returns (int256) {
        (, int24 t1,,,,,) = IPoolSlot0(m.poolWbnbUsdt).slot0();
        (, int24 t2,,,,,) = IPoolSlot0(m.poolUsdtBem).slot0();
        uint256 spot = oracle.quoteAtTick(t2, oracle.quoteAtTick(t1, 1e18, m.wbnb, m.usdt), m.usdt, m.bem);
        uint256 twap = oracle.quoteBemOut(1e18);
        return (int256(spot) - int256(twap)) * 10_000 / int256(twap);
    }

    function test_SwapCosts() public {
        if (!vm.envOr("FIRSTO_PROBE", false)) {
            vm.skip(true);
            return;
        }
        console2.log("block", block.number);
        console2.log("TWAP BEM per 1 BNB (8 decimals)", oracle.quoteBemOut(1e18));
        console2.log("spot vs TWAP (bps, signed)");
        console2.logInt(_spotVsTwapBps());
        uint256[5] memory sizes = [uint256(0.45 ether), 0.7 ether, 1 ether, 1.5 ether, 2 ether];
        for (uint256 i = 0; i < sizes.length; i++) {
            uint256 x = sizes[i];
            uint256 twapBem = oracle.quoteBemOut(x);
            uint256 snap = vm.snapshotState();

            mode = 1;
            swapper.flashBnb(x, "");
            int256 buyBps = (int256(owedSeen) - int256(twapBem)) * 10_000 / int256(twapBem);
            vm.revertToState(snap);

            mode = 2;
            swapper.flashBem(twapBem, "");
            int256 sellBps = (int256(owedSeen) - int256(x)) * 10_000 / int256(x);
            vm.revertToState(snap);

            vm.deal(address(this), x);
            uint256 out = swapper.swapBnbForBem{value: x}(0, address(this));
            int256 restBps = (int256(twapBem) - int256(out)) * 10_000 / int256(twapBem);
            vm.revertToState(snap);

            console2.log("size (milli-BNB)", x / 1e15);
            console2.log("  buy path flashBnb: BEM owed vs TWAP (bps)");
            console2.logInt(buyBps);
            console2.log("  sell path flashBem: BNB owed vs TWAP (bps)");
            console2.logInt(sellBps);
            console2.log("  swapBnbForBem: shortfall vs TWAP (bps)");
            console2.logInt(restBps);
        }
    }
}

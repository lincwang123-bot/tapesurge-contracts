// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test, console2} from "forge-std/Test.sol";
import {BoardFactory} from "../src/BoardFactory.sol";
import {MonthFactory} from "../src/MonthFactory.sol";
import {GenesisSplitter} from "../src/GenesisSplitter.sol";
import {MockTapeOutFactory} from "../src/mocks/MockTapeOut.sol";
import {MachineLister} from "../src/market/MachineLister.sol";
import {TapeSurgeDefaults} from "../script/TapeSurgeDefaults.sol";

/// @notice 按主网规则检查合约大小：EIP-170 运行时代码 ≤ 24,576 字节；EIP-3860 初始化代码（含构造参数）≤ 49,152 字节。
/// @dev 2026-10-19 测试网部署时发现 BoardFactory 的初始化代码加构造参数超过 49,152 字节，而 Foundry 默认不检查大小。
///      这里所有合约都用 deployCode（vm.getCode + CREATE）按部署顺序、带默认构造参数真实部署一遍。本测试合约不内嵌
///      它们的创建代码，自身很小，所以能在开启大小限制的配置下运行，由 EVM 真实执行这两条规则：
///          FOUNDRY_PROFILE=sizecheck forge test --match-path test/SizeLimits.t.sol
///      默认配置（不限制大小）下也会运行，用显式断言检查同样的上限。
contract SizeLimitsTest is Test {
    uint256 internal constant MAX_RUNTIME = 24_576;
    uint256 internal constant MAX_INITCODE = 49_152;
    address internal constant WBNB = address(0xBB4C);
    address internal constant USDT = address(0x55D3);
    uint256 internal constant BEM_PER_BNB = 2_193_000_000;

    function test_ProductionContractsFitMainnetLimits() public {
        vm.deal(address(this), 1 ether);
        TapeSurgeDefaults.Addresses memory a = _mocks();

        // 部署顺序与 DeployTestnet 相同：分账合约（n）→ BoardFactory（n + 1）→ MonthFactory（n + 2）
        //   → MonthPositions（n + 3）→ MonthMachineSales（n + 4）→ MonthExitGovernor（n + 5）→ PositionExchange（n + 6）
        uint256 n = vm.getNonce(address(this));
        a.monthPositions = vm.computeCreateAddress(address(this), n + 3);
        a.monthSales = vm.computeCreateAddress(address(this), n + 4);
        a.monthGovernor = vm.computeCreateAddress(address(this), n + 5);
        a.priceFeed = vm.computeCreateAddress(address(this), n + 7);
        a.stdSales = vm.computeCreateAddress(address(this), n + 8);
        GenesisSplitter.Params memory sp = TapeSurgeDefaults.splitterParams(a);
        BoardFactory.Params memory p = TapeSurgeDefaults.params(a);
        MonthFactory.Params memory mp = TapeSurgeDefaults.monthParams(a);
        sp.boardFactory = vm.computeCreateAddress(address(this), n + 1);
        p.monthFactory = vm.computeCreateAddress(address(this), n + 2);
        p.initialOperator = address(this);

        bytes memory spArgs = abi.encode(sp);
        address splitter = deployCode(
            "GenesisSplitter.sol:GenesisSplitter", spArgs, MockTapeOutFactory(payable(a.tapeoutFactory)).deployFee()
        );
        p.splitter = splitter;
        bytes memory pArgs = abi.encode(p);
        address factory = deployCode("BoardFactory.sol:BoardFactory", pArgs);
        bytes memory mArgs = abi.encode(factory, mp);
        address monthFactory = deployCode("MonthFactory.sol:MonthFactory", mArgs);
        address[4] memory v2 = _deployMonthV2(a, factory, monthFactory);
        assertEq(GenesisSplitter(payable(splitter)).boardFactory(), factory);
        assertEq(BoardFactory(factory).monthFactory(), monthFactory);

        _initcode("GenesisSplitter", "GenesisSplitter.sol:GenesisSplitter", spArgs);
        _initcode("BoardFactory", "BoardFactory.sol:BoardFactory", pArgs);
        _initcode("MonthFactory", "MonthFactory.sol:MonthFactory", mArgs);
        _runtime("GenesisSplitter", splitter);
        _runtime("BoardFactory", factory);
        _runtime("MonthFactory", monthFactory);
        _runtime("TapeBoard (implementation)", BoardFactory(factory).boardImplementation());
        _runtime("MonthBoard (implementation)", MonthFactory(monthFactory).boardImplementation());
        _runtime("MonthPositions", v2[0]);
        _runtime("MonthMachineSales", v2[1]);
        _runtime("MonthExitGovernor", v2[2]);
        _runtime("PositionExchange", v2[3]);
        address feed = deployCode(
            "MarketPriceFeed.sol:MarketPriceFeed",
            abi.encode(factory, TapeSurgeDefaults.feedParams(TapeSurgeDefaults.FEED_ABANDON_AFTER))
        );
        assertEq(feed, a.priceFeed, "price feed prediction");
        _runtime("MarketPriceFeed", feed);
        address ss = deployCode(
            "StdMachineSales.sol:StdMachineSales",
            abi.encode(
                a.bem,
                factory,
                TapeSurgeDefaults.STD_MARKET_PERIOD,
                TapeSurgeDefaults.STD_SELL_DECAY,
                TapeSurgeDefaults.STD_SELL_FLOOR_HOLD,
                uint256(3 days),
                TapeSurgeDefaults.PREMIUM_FEE_BPS,
                address(0x1234)
            )
        );
        assertEq(ss, a.stdSales, "std sales prediction");
        _runtime("StdMachineSales", ss);
        _marketModules(a.machineRules);
    }

    /// @dev 兑换适配器、MarketTrader、MachineRules、MachineLister、挂单库（构造参数用占位地址，只看代码大小）
    function _marketModules(address machineRules) internal {
        address t = address(0x1234);
        _runtime(
            "PancakeFirstoSwapper",
            deployCode(
                "PancakeFirstoSwapper.sol:PancakeFirstoSwapper",
                abi.encode(t, t, t, t, t, t, uint24(100), uint24(10_000), t)
            )
        );
        _runtime(
            "MarketTrader",
            deployCode("MarketTrader.sol:MarketTrader", abi.encode(t, t, t, t, t, t, t, t, t, t, t, uint256(200)))
        );
        _runtime("MachineRules", machineRules);
        address lister = deployCode(
            "MachineLister.sol:MachineLister",
            abi.encode(t, t, t, t, t, uint256(100), t, t, t, uint256(200), uint256(50), uint256(30 minutes), uint256(30 days))
        );
        _runtime("MachineLister", lister);
        _runtime("ListingVault (implementation)", MachineLister(payable(lister)).VAULT_IMPL());
    }

    /// @dev v2 月局单例：MonthPositions（n + 3）→ MonthMachineSales（n + 4）→ MonthExitGovernor（n + 5）→ PositionExchange（n + 6）
    function _deployMonthV2(TapeSurgeDefaults.Addresses memory a, address factory, address monthFactory)
        internal
        returns (address[4] memory v2)
    {
        v2[0] = deployCode("MonthPositions.sol:MonthPositions", abi.encode(monthFactory, factory));
        v2[1] = deployCode(
            "MonthMachineSales.sol:MonthMachineSales",
            abi.encode(
                a.bem,
                monthFactory,
                factory,
                a.monthGovernor,
                uint256(3 days),
                TapeSurgeDefaults.MONTH_PLAN_DECAY,
                address(0x1234)
            )
        );
        v2[2] = deployCode(
            "MonthExitGovernor.sol:MonthExitGovernor",
            abi.encode(
                monthFactory,
                v2[1],
                TapeSurgeDefaults.GOV_MIN_SETTLE_AGE,
                TapeSurgeDefaults.GOV_VOTE_PERIOD,
                TapeSurgeDefaults.GOV_EXECUTION_DELAY,
                TapeSurgeDefaults.GOV_EXECUTION_WINDOW,
                TapeSurgeDefaults.GOV_FAIL_COOLDOWN,
                TapeSurgeDefaults.GOV_REPRICE_COOLDOWN
            )
        );
        v2[3] = deployCode("PositionExchange.sol:PositionExchange", abi.encode(a.bem, v2[0], monthFactory, factory));
        assertEq(v2[0], a.monthPositions, "positions prediction");
        assertEq(v2[1], a.monthSales, "sales prediction");
        assertEq(v2[2], a.monthGovernor, "governor prediction");
    }

    function _mocks() internal returns (TapeSurgeDefaults.Addresses memory a) {
        address bem = deployCode("MockBEM.sol:MockBEM");
        address tapeout = deployCode("MockTapeOut.sol:MockTapeOutFactory", abi.encode(uint256(1)));
        address beacon = address(MockTapeOutFactory(payable(tapeout)).circuitsBeacon());
        a = TapeSurgeDefaults.Addresses({
            tapeoutFactory: tapeout,
            bem: bem,
            pod: deployCode("MockPoD.sol:MockPoD", abi.encode(bem)),
            machineCircuits: deployCode(
                "MockCircuits.sol:MockCircuits", abi.encode("Circuits", "CIRC", address(0), uint256(0.0002 ether))
            ),
            circuitsBeacon: beacon,
            passBeacon: beacon,
            randomSource: deployCode("MockRandom.sol:MockRandomSource"),
            wbnb: WBNB,
            usdt: USDT,
            router: deployCode("MockSwap.sol:MockRouter", abi.encode(WBNB, bem, BEM_PER_BNB)),
            oracle: deployCode("MockSwap.sol:MockPriceOracle", abi.encode(BEM_PER_BNB)),
            foundation: TapeSurgeDefaults.FOUNDATION_SAFE,
            feeSafe: TapeSurgeDefaults.FEE_SAFE,
            monthPositions: address(0),
            monthSales: address(0),
            monthGovernor: address(0),
            priceFeed: address(0),
            stdSales: address(0),
            marketTrader: address(0x1234),
            machineRules: address(0)
        });
        a.machineRules = deployCode("MachineRules.sol:MachineRules", abi.encode(a.pod, tapeout, a.machineCircuits));
    }

    function _initcode(string memory name, string memory artifact, bytes memory args) internal view {
        uint256 size = vm.getCode(artifact).length + args.length;
        console2.log(
            string.concat(name, " initcode + args (B), margin"), size, size <= MAX_INITCODE ? MAX_INITCODE - size : 0
        );
        assertLe(size, MAX_INITCODE, string.concat(name, ": initcode exceeds EIP-3860"));
    }

    function _runtime(string memory name, address at) internal view {
        uint256 size = at.code.length;
        console2.log(string.concat(name, " runtime (B), margin"), size, size <= MAX_RUNTIME ? MAX_RUNTIME - size : 0);
        assertLe(size, MAX_RUNTIME, string.concat(name, ": runtime exceeds EIP-170"));
    }

    receive() external payable {}
}

// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ERC1155} from "@openzeppelin/contracts/token/ERC1155/ERC1155.sol";
import {MockCircuits, MockBeacon} from "./MockCircuits.sol";

/// @notice 仅用于测试 / 测试网：模拟处理器的晶体管合约（ERC-1155）。
/// @dev 铸造收入记在 owed[creator]，withdraw() 把调用者名下的 owed 打给调用者。
///      ⚠️ 真实合约的 withdraw 打款对象待测试网确认（见 README）。
contract MockTransistors is ERC1155 {
    uint256 public constant NAND = 0;
    uint256 public constant LATCH = 1;
    /// @notice 每颗晶体管的协议费（主网 0.0001 BNB；测试网快速模式可以调低）
    uint256 public immutable PROTOCOL_FEE;

    address public immutable creator;
    address public immutable protocol;
    uint256 public immutable supplyCap;
    uint256 public immutable mintPrice;
    address public circuits;
    uint256 public minted;
    mapping(address => uint256) public owed;

    error Insufficient();
    error CapExceeded();
    error OnlyCircuits();
    error NothingOwed();

    constructor(address creator_, address protocol_, uint256 supplyCap_, uint256 mintPrice_, uint256 protocolFee_)
        ERC1155("")
    {
        creator = creator_;
        protocol = protocol_;
        supplyCap = supplyCap_;
        mintPrice = mintPrice_;
        PROTOCOL_FEE = protocolFee_;
    }

    /// @notice 主网晶体管合约的协议费 getter 是小写的 protocolFee()（PROTOCOL_FEE() 在主网会 revert），这里两个都提供
    function protocolFee() external view returns (uint256) {
        return PROTOCOL_FEE;
    }

    function setCircuits(address c) external {
        require(circuits == address(0) && msg.sender == protocol, "set");
        circuits = c;
    }

    function mint(uint256 id, uint256 amount) external payable {
        require(id == NAND || id == LATCH, "id");
        if (msg.value != (mintPrice + PROTOCOL_FEE) * amount) revert Insufficient();
        if (minted + amount > supplyCap) revert CapExceeded();
        minted += amount;
        owed[creator] += mintPrice * amount;
        owed[protocol] += PROTOCOL_FEE * amount;
        _mint(msg.sender, id, amount, "");
    }

    function withdraw() external {
        uint256 amt = owed[msg.sender];
        if (amt == 0) revert NothingOwed();
        owed[msg.sender] = 0;
        (bool ok,) = msg.sender.call{value: amt}("");
        require(ok, "send");
    }

    function burnFor(address from, uint256 id, uint256 amount) external {
        if (msg.sender != circuits) revert OnlyCircuits();
        _burn(from, id, amount);
    }
}

/// @notice 仅用于测试 / 测试网：模拟 TapeOut 处理器工厂。creator = createCPU 的调用者。
/// @dev feeDivisor：部署费、协议费、流片费都按主网数额除以它（测试用 1；测试网快速模式用 100，省 tBNB）。
contract MockTapeOutFactory {
    uint256 public immutable deployFee;
    uint256 public immutable protocolFee;
    uint256 public immutable tapeoutFee;

    /// @notice 所有处理器电路合约共用的信标（模拟），用于升级哨兵测试。
    MockBeacon public immutable circuitsBeacon;

    address public lastTransistors;
    address public lastCircuits;
    /// @notice 和主网一样：工厂创建的处理器电路合约为 true（rc8 起主板按它判断收哪些合集的矿机）
    mapping(address => bool) public isCPU;

    event CPUCreated(address indexed creator, address transistors, address circuits);

    constructor(uint256 feeDivisor) {
        require(feeDivisor > 0, "divisor");
        deployFee = 0.001 ether / feeDivisor;
        protocolFee = 0.0001 ether / feeDivisor;
        tapeoutFee = 0.0002 ether / feeDivisor;
        circuitsBeacon = new MockBeacon(address(0xC1C1));
    }

    function createCPU(
        string calldata name,
        string calldata symbol,
        string calldata, /* story */
        uint256 transistorSupply,
        uint256 mintPrice
    ) external payable returns (address transistors, address circuits) {
        require(msg.value >= deployFee, "fee");
        MockTransistors t = new MockTransistors(msg.sender, address(this), transistorSupply, mintPrice, protocolFee);
        MockCircuits c = new MockCircuits(name, symbol, address(t), tapeoutFee);
        t.setCircuits(address(c));
        transistors = address(t);
        circuits = address(c);
        lastTransistors = transistors;
        lastCircuits = circuits;
        isCPU[circuits] = true;
        emit CPUCreated(msg.sender, transistors, circuits);
    }

    /// @notice 测试辅助：把单独部署的矿机电路合约（模拟官方矿机 / Behemoth）登记成工厂创建的处理器
    function registerCPU(address circuits) external {
        isCPU[circuits] = true;
    }

    receive() external payable {}
}

// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @title TemplateTimelock（主板模板切换，7 天时间锁；BoardFactory 和 MonthFactory 共用）
/// @notice 只影响之后新开的局（规则决定 6.11，V2-DESIGN.md 第 12 节）：
///         - 每块主板是 EIP-1167 最小代理，代理字节码里写死开局时的实现合约地址，主板没有任何升级、暂停、改参数的入口，
///           所以已开局（包括正在招募）的主板永远按开局时的代码运行；
///         - 管理员（手续费 Safe）提议新模板：把新实现合约的创建代码（含构造参数）交给工厂，由工厂 CREATE 部署
///           （新模板的 FACTORY 因此就是本工厂），链上公示 7 天，期间可以撤销；
///         - 公示期满后 7 天内任何人都可以让它生效（U1a / U2a），过期作废需要重新提议；
///         - 生效后，下一次开局起用新模板。
abstract contract TemplateTimelock {
    /// @notice 公示期
    uint256 public constant UPGRADE_DELAY = 7 days;
    /// @notice 公示期满后的生效窗口，过期作废
    uint256 public constant UPGRADE_WINDOW = 7 days;

    /// @dev 当前模板：之后开出的主板克隆它（boardImplementation()）
    address internal _boardImplementation;
    /// @notice 待生效的模板（0 = 没有）和最早生效时间
    address public pendingImplementation;
    uint256 public pendingEta;
    /// @notice 历次生效的模板（第 0 个是部署时的模板）
    address[] public implementationHistory;
    /// @notice 每块主板开局时用的模板
    mapping(address => address) public implementationOf;

    event ImplementationProposed(address indexed implementation, bytes32 codehash, uint256 eta);
    event ImplementationCancelled(address indexed implementation);
    event ImplementationActivated(address indexed previous, address indexed implementation, uint256 version);

    error OnlyAdmin();
    error NoPendingImplementation();
    error TooEarly();
    error ProposalExpired();
    error DeployFailed();
    error BadTemplate();

    /// @notice 管理员（手续费 Safe）
    function admin() public view virtual returns (address);

    /// @notice 当前模板：之后开出的主板克隆它
    function boardImplementation() public view virtual returns (address) {
        return _boardImplementation;
    }

    function implementationCount() external view returns (uint256) {
        return implementationHistory.length;
    }

    /// @notice 提议新模板：工厂用 creationCode（创建代码 + ABI 编码的构造参数）部署新实现合约，核对锚点地址后公示 7 天。
    ///         已有待生效的提议时，新提议取代它（重新计 7 天）。
    function proposeImplementation(bytes calldata creationCode) external returns (address impl) {
        if (msg.sender != admin()) revert OnlyAdmin();
        bytes memory code = creationCode;
        assembly ("memory-safe") {
            impl := create(0, add(code, 0x20), mload(code))
        }
        if (impl == address(0)) revert DeployFailed();
        _checkTemplate(impl);
        address old = pendingImplementation;
        if (old != address(0)) emit ImplementationCancelled(old);
        pendingImplementation = impl;
        uint256 eta = block.timestamp + UPGRADE_DELAY;
        pendingEta = eta;
        emit ImplementationProposed(impl, impl.codehash, eta);
    }

    /// @notice 公示期内（或生效前）撤销待生效的提议。
    function cancelImplementation() external {
        if (msg.sender != admin()) revert OnlyAdmin();
        address impl = pendingImplementation;
        if (impl == address(0)) revert NoPendingImplementation();
        delete pendingImplementation;
        delete pendingEta;
        emit ImplementationCancelled(impl);
    }

    /// @notice 公示期满后 7 天内，任何人都可以让待生效的模板生效；下一次开局起使用。
    function activateImplementation() external {
        address impl = pendingImplementation;
        if (impl == address(0)) revert NoPendingImplementation();
        uint256 eta = pendingEta;
        if (block.timestamp < eta) revert TooEarly();
        if (block.timestamp >= eta + UPGRADE_WINDOW) revert ProposalExpired();
        delete pendingImplementation;
        delete pendingEta;
        address previous = _boardImplementation;
        _boardImplementation = impl;
        implementationHistory.push(impl);
        emit ImplementationActivated(previous, impl, implementationHistory.length - 1);
    }

    function _setInitialImplementation(address impl) internal {
        _boardImplementation = impl;
        implementationHistory.push(impl);
    }

    function _recordImplementation(address board) internal {
        implementationOf[board] = _boardImplementation;
    }

    /// @dev 新模板必须指向本工厂和同一组锚点合约，并实现工厂要调用的函数（否则开局流程会坏）
    function _checkTemplate(address impl) internal view virtual;
}

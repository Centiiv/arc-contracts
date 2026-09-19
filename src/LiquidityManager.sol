// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./interfaces/ILiquidityManager.sol";

error InvalidFeePercentLM();
error ZeroAddressLM();
error AddressAlreadySetLM();
error UnauthorizedLM();
error NoPendingAdminLM();
error AdminSlotConflictLM();
error ContractAlreadyInitializedLM();
error InvalidParameterLM();

contract LiquidityManager is ILiquidityManager {
    address public admin1;
    address public admin2;
    address public pendingAdmin1;
    address public pendingAdmin2;
    address public treasury;
    address public relayer;
    bool public paused;
    mapping(address => bool) public tokenSupported;

    bool private _initialized;

    modifier onlyAdmin() {
        if (msg.sender != admin1 && msg.sender != admin2) revert UnauthorizedLM();
        _;
    }

    modifier onlyAdmin1() {
        if (msg.sender != admin1) revert UnauthorizedLM();
        _;
    }

    modifier onlyAdmin2() {
        if (msg.sender != admin2) revert UnauthorizedLM();
        _;
    }

    modifier onlyPendingAdmin1() {
        if (msg.sender != pendingAdmin1) revert NoPendingAdminLM();
        _;
    }

    modifier onlyPendingAdmin2() {
        if (msg.sender != pendingAdmin2) revert NoPendingAdminLM();
        _;
    }

    constructor() {
        _initialized = false;
    }

    function initialize(
        address _admin1,
        address _admin2,
        address _treasury,
        address _relayerAddress
    ) external {
        if (_initialized) revert ContractAlreadyInitializedLM();
        if (_admin1 == address(0) || _admin2 == address(0) || _treasury == address(0) || _relayerAddress == address(0)) {
            revert ZeroAddressLM();
        }
        admin1 = _admin1;
        admin2 = _admin2;
        treasury = _treasury;
        relayer = _relayerAddress;
        paused = false;
        _initialized = true;
    }

    function transferAdmin1(address newAdmin) external override onlyAdmin1 {
        if (newAdmin == admin2) revert AdminSlotConflictLM();
        if (newAdmin == admin1) revert AddressAlreadySetLM();
        pendingAdmin1 = newAdmin;
        emit AdminTransferProposed(1, newAdmin);
    }

    function acceptAdmin1() external override onlyPendingAdmin1 {
        admin1 = pendingAdmin1;
        delete pendingAdmin1;
        emit AdminTransferred(1, msg.sender);
    }

    function transferAdmin2(address newAdmin) external override onlyAdmin2 {
        if (newAdmin == admin1) revert AdminSlotConflictLM();
        if (newAdmin == admin2) revert AddressAlreadySetLM();
        pendingAdmin2 = newAdmin;
        emit AdminTransferProposed(2, newAdmin);
    }

    function acceptAdmin2() external override onlyPendingAdmin2 {
        admin2 = pendingAdmin2;
        delete pendingAdmin2;
        emit AdminTransferred(2, msg.sender);
    }

    function updateProtocolAddress(uint8 what, address value) external override onlyAdmin {
        if (value == address(0)) revert ZeroAddressLM();
        if (what == 0) {
            if (treasury == value) revert AddressAlreadySetLM();
            treasury = value;
        } else if (what == 1) {
            if (relayer == value) revert AddressAlreadySetLM();
            relayer = value;
        } else {
            revert InvalidParameterLM();
        }
        emit ProtocolAddressUpdated(what, value);
    }

    function pause() external override onlyAdmin {
        paused = true;
        emit PausedEvent();
    }

    function unpause() external override onlyAdmin {
        paused = false;
        emit UnpausedEvent();
    }

    function getTreasuryAddress() external view override returns (address) {
        return treasury;
    }

    function getRelayerAddress() external view override returns (address) {
        return relayer;
    }

    function getAdmin1() external view override returns (address) {
        return admin1;
    }

    function getAdmin2() external view override returns (address) {
        return admin2;
    }

    function isTokenSupported(address token) external view override returns (bool) {
        return tokenSupported[token];
    }

    function isPaused() external view override returns (bool) {
        return paused;
    }

    event ProtocolAddressUpdated(uint8 what, address value);
    event AdminTransferProposed(uint8 adminSlot, address newAdmin);
    event AdminTransferred(uint8 adminSlot, address newAdmin);
    event PausedEvent();
    event UnpausedEvent();
}

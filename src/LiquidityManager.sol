// SPDX-License-Identifier: UNLICENSED
// © 2026 Centiiv Technologies. All rights reserved.
//
// NOTICE: All information contained herein is, and remains the property of
// Centiiv Technologies. The intellectual and technical concepts contained
// herein are proprietary to Centiiv Technologies and are protected by trade
// secret, copyright, and other applicable laws.
//
// Dissemination, reproduction, modification, copying, or reverse engineering
// of this material in whole or in part is strictly forbidden unless prior
// written permission is obtained from Centiiv Technologies.


pragma solidity ^0.8.20;

import "./interfaces/ILiquidityManager.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";

error InvalidFeePercentLM();
error ZeroAddressLM();
error AddressAlreadySetLM();
error UnauthorizedLM();
error NoPendingAdminLM();
error AdminSlotConflictLM();
error ContractAlreadyInitializedLM();
error InvalidParameterLM();

contract LiquidityManager is ILiquidityManager, Initializable {
    address public admin1;
    address public admin2;
    address public pendingAdmin1;
    address public pendingAdmin2;
    address public treasury;
    address public relayer;
    bool public paused;
    mapping(address => bool) public tokenSupported;

    uint256 private __gap;

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
        _disableInitializers();
    }

    function initialize(
        address _admin1,
        address _admin2,
        address _treasury,
        address _relayerAddress,
        address _usdc,
        address _eurc
    ) external initializer {
        if (_admin1 == address(0) || _admin2 == address(0) || _treasury == address(0) || _relayerAddress == address(0)) {
            revert ZeroAddressLM();
        }
        if (_usdc == address(0)) revert ZeroAddressLM();
        if (_admin1 == _admin2) revert AdminSlotConflictLM();
        admin1 = _admin1;
        admin2 = _admin2;
        treasury = _treasury;
        relayer = _relayerAddress;
        paused = false;

        tokenSupported[_usdc] = true;
        emit TokenSupportedUpdated(_usdc, true);
        if (_eurc != address(0)) {
            tokenSupported[_eurc] = true;
            emit TokenSupportedUpdated(_eurc, true);
        }
    }

    function transferAdmin1(address newAdmin) external override onlyAdmin1 {
        if (newAdmin == admin2) revert AdminSlotConflictLM();
        if (newAdmin == admin1) revert AddressAlreadySetLM();
        pendingAdmin1 = newAdmin;
        emit AdminTransferProposed(1, newAdmin);
    }

    function acceptAdmin1() external override onlyPendingAdmin1 {
        if (pendingAdmin1 == admin2) revert AdminSlotConflictLM();
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
        if (pendingAdmin2 == admin1) revert AdminSlotConflictLM();
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

    /// @notice Register (or unregister) an ERC-20 as an order token. LiquidityProvider
    ///         gates createOrder on this, so USDC must be seeded before that gate
    ///         goes live on an already-deployed proxy.
    function setTokenSupported(address token, bool supported) external override onlyAdmin {
        if (token == address(0)) revert ZeroAddressLM();
        tokenSupported[token] = supported;
        emit TokenSupportedUpdated(token, supported);
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
    event TokenSupportedUpdated(address indexed token, bool supported);
    event AdminTransferProposed(uint8 adminSlot, address newAdmin);
    event AdminTransferred(uint8 adminSlot, address newAdmin);
    event PausedEvent();
    event UnpausedEvent();
}

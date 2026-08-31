// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface ILiquidityManager {
    function transferAdmin1(address newAdmin) external;
    function acceptAdmin1() external;
    function transferAdmin2(address newAdmin) external;
    function acceptAdmin2() external;
    function updateProtocolAddress(uint8 what, address value) external;
    function pause() external;
    function unpause() external;

    function getAdmin1() external view returns (address);
    function getAdmin2() external view returns (address);
    function getTreasuryAddress() external view returns (address);
    function getRelayerAddress() external view returns (address);
    function isPaused() external view returns (bool);
    function isTokenSupported(address token) external view returns (bool);
}

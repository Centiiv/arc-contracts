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

import "../libraries/Types.sol";

interface ILiquidityProvider {
    function createOrder(Types.OrderParams calldata params) external;
    function settle(
        bytes32 orderId,
        address liquidityProvider,
        int256 settlePercent
    ) external returns (bool);
    function settle(
        bytes32 orderId,
        address liquidityProvider,
        int256 settlePercent,
        int256 appliedFeeBps
    ) external returns (bool);
    function executeSettlementTransfer(
        bytes32 orderId,
        address tokenAddress,
        Types.PermitSig calldata permitSig
    ) external;
    function refund(bytes32 orderId) external;
    function executeRefundTransfer(
        bytes32 orderId,
        address tokenAddress,
        Types.PermitSig calldata permitSig
    ) external;
    function emergencyRefund(bytes32 orderId) external;
    function cancelSettlement(bytes32 orderId) external;
    function getOrderInfo(bytes32 orderId) external view returns (Types.Order memory);
    function getTokenBalance(address user) external view returns (uint256);
    function updateTierFee(uint8 tier, int256 feeBps) external;
    function getTierFee(uint8 tier) external view returns (int256);
    function updateSettingsContract(address newSettingsContract) external;
    function settingsContract() external view returns (address);
    function usdc() external view returns (address);

    event SettlementCancelled(bytes32 indexed orderId);
    event SettingsContractUpdated(address indexed oldSettingsContract, address indexed newSettingsContract);
}

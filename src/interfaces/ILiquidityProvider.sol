// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "../libraries/Types.sol";

interface ILiquidityProvider {
    function createOrder(Types.OrderParams calldata params) external;
    function settle(bytes32 orderId, address liquidityProvider, int256 settlePercent) external returns (bool);
    function executeSettlementTransfer(bytes32 orderId, address tokenAddress) external;
    function refund(bytes32 orderId) external;
    function executeRefundTransfer(bytes32 orderId, address tokenAddress) external;
    function emergencyRefund(bytes32 orderId) external;
    function getOrderInfo(bytes32 orderId) external view returns (Types.Order memory);
    function getTokenBalance(address user) external view returns (uint256);
    function updateTierFee(uint8 tier, int256 feeBps) external;
    function getTierFee(uint8 tier) external view returns (int256);
    function updateSettingsContract(address newSettingsContract) external;
    function settingsContract() external view returns (address);
    function usdc() external view returns (address);
}

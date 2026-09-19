// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./interfaces/IERC20.sol";
import "./interfaces/ILiquidityManager.sol";
import "./libraries/Types.sol";

contract LiquidityProvider {
    using Types for *;

    address public settingsContract;
    address public usdc;
    mapping(bytes32 => Types.Order) public orders;
    mapping(bytes32 => Types.PendingSettlement) public pendingSettlements;
    mapping(bytes32 => Types.PendingRefund) public pendingRefunds;
    mapping(uint8 => int256) public tierFees;

    bool private _initialized;

    modifier onlyRelayer() {
        address _relayer = ILiquidityManager(settingsContract).getRelayerAddress();
        if (msg.sender != _relayer) revert Unauthorized();
        _;
    }

    modifier onlySettingsAdmin() {
        address _admin1 = ILiquidityManager(settingsContract).getAdmin1();
        address _admin2 = ILiquidityManager(settingsContract).getAdmin2();
        if (msg.sender != _admin1 && msg.sender != _admin2) revert Unauthorized();
        _;
    }

    modifier whenNotPaused() {
        if (ILiquidityManager(settingsContract).isPaused()) revert Paused();
        _;
    }

    modifier whenPaused() {
        if (!ILiquidityManager(settingsContract).isPaused()) revert NotPaused();
        _;
    }

    function initialize(address _usdc, address _settingsContract) external {
        if (_initialized) revert ContractAlreadyInitialized();
        if (_usdc == address(0) || _settingsContract == address(0)) revert ZeroAddress();

        usdc = _usdc;
        settingsContract = _settingsContract;
        tierFees[uint8(Types.ProtocolFees.Basic)] = 400;
        tierFees[uint8(Types.ProtocolFees.Alpha)] = 300;
        tierFees[uint8(Types.ProtocolFees.Ultimate)] = 200;
        _initialized = true;
    }

    function createOrder(Types.OrderParams calldata params) external whenNotPaused {
        // Relayer check removed — LP nodes call createOrder directly with their own
        // wallet for onramp. settle() and refund() still enforce onlyRelayer.
        if (params.sender == address(0)) revert ZeroAddress();
        if (params.amount <= 0) revert InvalidAmount();
        if (params.amount < Types.MIN_ORDER_AMOUNT) revert AmountBelowMinimum();
        if (params.messageHash == bytes32(0)) revert InvalidMessageHash();
        if (params.token == address(0)) revert ZeroAddress();
        if (params.temporaryWalletAddress == address(0)) revert ZeroAddress();
        if (params.refundAddress == address(0)) revert ZeroAddress();

        if (params.orderId == bytes32(0)) revert InvalidParameter();
        if (orders[params.orderId].orderId != bytes32(0)) revert OrderAlreadyExists();

        int256 protocolFeeAmount = _calculateProtocolFee(params.amount, params.protocolFee);

        IERC20(params.token).transferFrom(params.sender, params.temporaryWalletAddress, uint256(params.amount));

        int256 feeBps = tierFees[uint8(params.protocolFee)];

        orders[params.orderId] = Types.Order({
            orderId: params.orderId,
            sender: params.sender,
            token: params.token,
            temporaryWalletAddress: params.temporaryWalletAddress,
            protocolFee: protocolFeeAmount,
            isFulfilled: false,
            isRefunded: false,
            refundAddress: params.refundAddress,
            currentBps: Types.MAX_BPS,
            amount: params.amount,
            rate: params.rate,
            messageHash: params.messageHash,
            feeTier: params.protocolFee,
            feesCollected: 0,
            feeBps: feeBps
        });

        emit OrderCreated(params.orderId, params.sender, params.amount, protocolFeeAmount, params.rate, params.messageHash);
    }

    function settle(
        bytes32 orderId,
        address liquidityProvider,
        int256 settlePercent
    ) external whenNotPaused returns (bool) {
        if (pendingSettlements[orderId].orderId != bytes32(0)) revert PendingSettlementExists();

        address _relayer = ILiquidityManager(settingsContract).getRelayerAddress();
        if (msg.sender != _relayer) revert Unauthorized();

        if (settlePercent <= 0 || settlePercent > Types.MAX_BPS) revert InvalidSettlePercent();

        Types.Order storage order = orders[orderId];
        if (order.orderId == bytes32(0)) revert OrderNotFound();
        if (order.currentBps == 0) revert OrderFulfilled();
        if (order.isFulfilled) revert OrderFulfilled();
        if (order.isRefunded) revert OrderRefunded();
        if (settlePercent > order.currentBps) revert InvalidSettlePercent();

        int256 currentOrderBps = order.currentBps;
        order.currentBps -= settlePercent;

        int256 liquidityProviderAmount = (order.amount * settlePercent) / currentOrderBps;
        if (liquidityProviderAmount == 0) revert ZeroPayoutSettlement();

        order.amount -= liquidityProviderAmount;

        int256 protocolFee = _calculateProtocolFeeFromBps(liquidityProviderAmount, order.feeBps);
        order.feesCollected += protocolFee;

        int256 transferAmount = liquidityProviderAmount - protocolFee;

        if (order.currentBps == 0) {
            order.isFulfilled = true;
        }

        pendingSettlements[orderId] = Types.PendingSettlement({
            orderId: orderId,
            protocolFee: protocolFee,
            transferAmount: transferAmount,
            liquidityProvider: liquidityProvider,
            settlePercent: settlePercent
        });

        emit OrderSettled(orderId, liquidityProvider, settlePercent);
        return true;
    }

    function executeSettlementTransfer(bytes32 orderId, address tokenAddress) external {
        Types.Order storage order = orders[orderId];
        if (order.orderId == bytes32(0)) revert OrderNotFound();

        if (msg.sender != order.temporaryWalletAddress) revert Unauthorized();

        Types.PendingSettlement memory ps = pendingSettlements[orderId];
        if (ps.orderId == bytes32(0)) revert NoPendingSettlement();

        address _treasury = ILiquidityManager(settingsContract).getTreasuryAddress();

        if (ps.protocolFee > 0) {
            IERC20(tokenAddress).transferFrom(order.temporaryWalletAddress, _treasury, uint256(ps.protocolFee));
        }

        if (ps.transferAmount > 0) {
            IERC20(tokenAddress).transferFrom(order.temporaryWalletAddress, ps.liquidityProvider, uint256(ps.transferAmount));
        }

        delete pendingSettlements[orderId];

        emit SettlementTransferred(orderId, ps.settlePercent);
    }

    function refund(bytes32 orderId) external whenNotPaused {
        if (pendingSettlements[orderId].orderId != bytes32(0)) revert PendingSettlementExists();

        address _relayer = ILiquidityManager(settingsContract).getRelayerAddress();
        if (msg.sender != _relayer) revert Unauthorized();

        Types.Order storage order = orders[orderId];
        if (order.orderId == bytes32(0)) revert OrderNotFound();
        if (order.isFulfilled) revert OrderFulfilled();
        if (order.isRefunded) revert OrderRefunded();

        pendingRefunds[orderId] = Types.PendingRefund({
            orderId: orderId,
            refundAmount: order.amount
        });

        order.isRefunded = true;
        order.currentBps = 0;
        order.amount = 0;

        emit OrderRefundedEvent(orderId);
    }

    function executeRefundTransfer(bytes32 orderId, address tokenAddress) external {
        Types.Order storage order = orders[orderId];
        if (order.orderId == bytes32(0)) revert OrderNotFound();

        if (msg.sender != order.temporaryWalletAddress) revert Unauthorized();

        Types.PendingRefund memory pr = pendingRefunds[orderId];
        if (pr.orderId == bytes32(0)) revert NoPendingRefund();

        IERC20(tokenAddress).transferFrom(order.temporaryWalletAddress, order.refundAddress, uint256(pr.refundAmount));

        delete pendingRefunds[orderId];

        emit RefundTransferred(orderId, pr.refundAmount);
    }

    function emergencyRefund(bytes32 orderId) external whenPaused {
        address _relayer = ILiquidityManager(settingsContract).getRelayerAddress();
        if (msg.sender != _relayer) revert Unauthorized();

        Types.Order storage order = orders[orderId];
        if (order.orderId == bytes32(0)) revert OrderNotFound();
        if (order.isFulfilled) revert OrderFulfilled();
        if (order.isRefunded) revert OrderRefunded();
        if (pendingSettlements[orderId].orderId != bytes32(0)) revert PendingSettlementExists();

        pendingRefunds[orderId] = Types.PendingRefund({
            orderId: orderId,
            refundAmount: order.amount
        });

        order.isRefunded = true;
        order.currentBps = 0;
        order.amount = 0;

        emit EmergencyRefund(orderId);
    }

    function getOrderInfo(bytes32 orderId) external view returns (Types.Order memory) {
        if (orders[orderId].orderId == bytes32(0)) revert OrderNotFound();
        return orders[orderId];
    }

    function getTokenBalance(address user) external view returns (uint256) {
        return IERC20(usdc).balanceOf(user);
    }

    function updateTierFee(uint8 tier, int256 feeBps) external onlySettingsAdmin {
        if (feeBps < 0 || feeBps > 10_000) revert InvalidFeePercent();
        tierFees[tier] = feeBps;
        emit TierFeeUpdated(tier, feeBps);
    }

    function getTierFee(uint8 tier) external view returns (int256) {
        return tierFees[tier];
    }

    function updateSettingsContract(address newSettingsContract) external {
        if (newSettingsContract == address(0)) revert ZeroAddress();
        address _admin1 = ILiquidityManager(settingsContract).getAdmin1();
        if (msg.sender != _admin1) revert Unauthorized();
        settingsContract = newSettingsContract;
    }

    function _calculateProtocolFee(int256 amount, Types.ProtocolFees tier) internal view returns (int256) {
        int256 tierBps = tierFees[uint8(tier)];
        if (tierBps == 0) revert FeePercentNotSet();
        if (amount <= 0) return 0;

        int256 numerator;
        unchecked {
            numerator = amount * tierBps;
            if (amount > 0 && tierBps > 0 && numerator / tierBps != amount) revert Overflow();
        }

        int256 feeWhole = numerator / Types.MAX_BPS;
        int256 remainder = numerator % Types.MAX_BPS;

        if (remainder > 0) {
            feeWhole += 1;
        }

        return feeWhole;
    }

    function _calculateProtocolFeeFromBps(int256 amount, int256 feeBps) internal pure returns (int256) {
        if (amount <= 0) return 0;

        int256 numerator;
        unchecked {
            numerator = amount * feeBps;
            if (amount > 0 && feeBps > 0 && numerator / feeBps != amount) revert Overflow();
        }

        int256 feeWhole = numerator / Types.MAX_BPS;
        int256 remainder = numerator % Types.MAX_BPS;

        if (remainder > 0) {
            feeWhole += 1;
        }

        return feeWhole;
    }

    event OrderCreated(bytes32 indexed orderId, address indexed sender, int256 amount, int256 protocolFee, int256 rate, bytes32 messageHash);
    event OrderSettled(bytes32 indexed orderId, address indexed liquidityProvider, int256 settlePercent);
    event SettlementTransferred(bytes32 indexed orderId, int256 settlePercent);
    event OrderRefundedEvent(bytes32 indexed orderId);
    event RefundTransferred(bytes32 indexed orderId, int256 refundAmount);
    event EmergencyRefund(bytes32 indexed orderId);
    event TierFeeUpdated(uint8 tier, int256 feeBps);
}

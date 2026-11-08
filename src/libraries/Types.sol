// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

library Types {
    int256 internal constant MAX_BPS = 100_000;
    int256 internal constant MIN_ORDER_AMOUNT = 250;

    enum ProtocolFees { Basic, Alpha, Ultimate }
    enum ProtocolAddressType { Treasury, Relayer }

    struct Order {
        bytes32 orderId;
        address sender;
        address token;
        address temporaryWalletAddress;
        int256 protocolFee;
        bool isFulfilled;
        bool isRefunded;
        address refundAddress;
        int256 currentBps;
        int256 amount;
        int256 rate;
        bytes32 messageHash;
        ProtocolFees feeTier;
        int256 feesCollected;
        int256 feeBps;
    }

    struct OrderParams {
        bytes32 orderId;
        address token;
        address sender;
        int256 amount;
        int256 rate;
        address temporaryWalletAddress;
        address refundAddress;
        bytes32 messageHash;
        ProtocolFees protocolFee;
        PermitSig permitSig;
        // Appended in the 5.1.2 remediation. Required only when the relayer
        // creates an order on behalf of `sender`; ignored on the self path.
        OrderIntentSig intentSig;
    }

    struct PendingSettlement {
        bytes32 orderId;
        int256 protocolFee;
        int256 transferAmount;
        address liquidityProvider;
        int256 settlePercent;
    }

    struct PendingRefund {
        bytes32 orderId;
        int256 refundAmount;
    }

    struct PermitSig {
        uint256 deadline;
        uint8 v;
        bytes32 r;
        bytes32 s;
    }

    /// @notice EIP-712 authorisation for a relayer-created order. Binds the
    ///         sender's intent to every field that determines where the funds
    ///         go, so a compromised relayer cannot redirect the deposit.
    struct OrderIntentSig {
        uint256 deadline;
        uint256 nonce;
        uint8 v;
        bytes32 r;
        bytes32 s;
    }
}

error InvalidAmount();
error ZeroAddress();
error InvalidSenderFeeRecipient();
error InvalidMessageHash();
error InvalidSettlePercent();
error OrderAlreadyExists();
error OrderNotFound();
error OrderFulfilled();
error OrderRefunded();
error FeeExceedsProtocolFee();
error FeeExceedsCap();
error Paused();
error Unauthorized();
error TransferFailed();
error AddressAlreadySet();
error InvalidParameter();
error InvalidLpNodeParameters();
error LpNodeIdAlreadyExists();
error SettingsContractNotSet();
error UsdcNotSet();
error TokenNotSupported();
error NoPendingSettlement();
error NoPendingRefund();
error FeePercentNotSet();
error InvalidFeePercent();
error Overflow();
error DivisionByZero();
error AmountBelowMinimum();
error PendingSettlementExists();
error NegativeFee();
error ZeroPayoutSettlement();
error NotPaused();
error NoPendingAdmin();
error AdminSlotConflict();
error ContractAlreadyInitialized();
error InvalidSignature();
error SignatureExpired();
error InvalidNonce();

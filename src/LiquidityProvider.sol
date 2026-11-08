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

import "./interfaces/IERC20.sol";
import "./interfaces/IERC20Permit.sol";
import "./interfaces/ILiquidityManager.sol";
import "./interfaces/ILiquidityProvider.sol";
import "./libraries/Types.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";

contract LiquidityProvider is ILiquidityProvider, Initializable {
    using Types for *;

    /// @notice EIP-712 domain for the order intent introduced in 5.1.2.
    ///         Implemented locally rather than via OZ `EIP712Upgradeable`
    ///         because the latter pulls in `Bytes.sol`, which requires the
    ///         Cancun `MCOPY` opcode; these contracts compile for `paris` to
    ///         stay deployable on Arc. Name/version are constants and the
    ///         domain separator is recomputed per call, so no storage or
    ///         initializer migration is involved.
    string private constant EIP712_NAME = "CentiivLiquidityProvider";
    string private constant EIP712_VERSION = "1";

    bytes32 private constant EIP712_DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");

    bytes32 private constant ORDER_INTENT_TYPEHASH = keccak256(
        "OrderIntent(bytes32 orderId,address token,int256 amount,address temporaryWalletAddress,address refundAddress,uint8 protocolFee,uint256 deadline,uint256 nonce)"
    );

    address public settingsContract;
    address public usdc;
    mapping(bytes32 => Types.Order) public orders;
    mapping(bytes32 => Types.PendingSettlement) public pendingSettlements;
    mapping(bytes32 => Types.PendingRefund) public pendingRefunds;
    mapping(uint8 => int256) public tierFees;

    /// @notice Per-sender nonce for EIP-712 order intents (5.1.2). Consumes the
    ///         former gap slot; the gap is redeclared after it so future
    ///         variables remain append-only.
    mapping(address => uint256) public intentNonce;

    uint256[50] private __gap;

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

    constructor() {
        _disableInitializers();
    }

    function initialize(address _usdc, address _settingsContract) external initializer {
        if (_usdc == address(0) || _settingsContract == address(0)) revert ZeroAddress();

        usdc = _usdc;
        settingsContract = _settingsContract;
        tierFees[uint8(Types.ProtocolFees.Basic)] = 400;
        tierFees[uint8(Types.ProtocolFees.Alpha)] = 300;
        tierFees[uint8(Types.ProtocolFees.Ultimate)] = 200;
    }

    function createOrder(Types.OrderParams calldata params) external whenNotPaused {
        // LP nodes call createOrder directly with their own wallet for on-ramp
        // (self path, no signature). The relayer calls on behalf of off-ramp
        // senders and must supply an EIP-712 order intent signed by the sender
        // (5.1.2) so the deposit destination cannot be changed.
        if (params.sender == address(0)) revert ZeroAddress();
        if (params.amount <= 0) revert InvalidAmount();
        if (params.amount < Types.MIN_ORDER_AMOUNT) revert AmountBelowMinimum();
        if (params.messageHash == bytes32(0)) revert InvalidMessageHash();
        if (params.token == address(0)) revert ZeroAddress();
        if (!ILiquidityManager(settingsContract).isTokenSupported(params.token)) revert TokenNotSupported();
        if (params.temporaryWalletAddress == address(0)) revert ZeroAddress();
        if (params.refundAddress == address(0)) revert ZeroAddress();

        if (params.orderId == bytes32(0)) revert InvalidParameter();
        if (orders[params.orderId].orderId != bytes32(0)) revert OrderAlreadyExists();

        // Caller Guard: Must be sender (LP on-ramp) OR Relayer (off-ramp)
        address relayer = ILiquidityManager(settingsContract).getRelayerAddress();
        if (msg.sender != params.sender && msg.sender != relayer) {
            revert Unauthorized();
        }

        // Authorisation Guard: whenever the relayer acts for the sender, the
        // sender must have signed this exact order. The permit/allowance still
        // moves the tokens; the intent only proves where they may go.
        if (msg.sender != params.sender) {
            _verifyOrderIntent(params);
        }

        // Destination Guard: On-ramp LP can only target their own wallet
        if (msg.sender == params.sender && params.temporaryWalletAddress != msg.sender) {
            revert InvalidParameter();
        }

        int256 protocolFeeAmount = _calculateProtocolFee(params.amount, params.protocolFee);

        _permitIfProvided(params.token, params.sender, uint256(params.amount), params.permitSig);

        bool success = IERC20(params.token).transferFrom(params.sender, params.temporaryWalletAddress, uint256(params.amount));
        if (!success) revert TransferFailed();

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

    /// @notice Settle using the fee rate snapshotted at order creation (the cap).
    function settle(
        bytes32 orderId,
        address liquidityProvider,
        int256 settlePercent
    ) external whenNotPaused returns (bool) {
        return _settle(orderId, liquidityProvider, settlePercent, orders[orderId].feeBps);
    }

    /// @notice Settle with an optional fee override. appliedFeeBps must be
    ///         0 <= appliedFeeBps <= the fee rate snapshotted at order creation.
    function settle(
        bytes32 orderId,
        address liquidityProvider,
        int256 settlePercent,
        int256 appliedFeeBps
    ) external whenNotPaused returns (bool) {
        return _settle(orderId, liquidityProvider, settlePercent, appliedFeeBps);
    }

    function _settle(
        bytes32 orderId,
        address liquidityProvider,
        int256 settlePercent,
        int256 appliedFeeBps
    ) internal returns (bool) {
        if (pendingSettlements[orderId].orderId != bytes32(0)) revert PendingSettlementExists();

        address _relayer = ILiquidityManager(settingsContract).getRelayerAddress();
        if (msg.sender != _relayer) revert Unauthorized();

        if (settlePercent <= 0 || settlePercent > Types.MAX_BPS) revert InvalidSettlePercent();

        if (liquidityProvider == address(0)) revert ZeroAddress();

        Types.Order storage order = orders[orderId];
        if (order.orderId == bytes32(0)) revert OrderNotFound();
        if (order.currentBps == 0) revert OrderFulfilled();
        if (order.isFulfilled) revert OrderFulfilled();
        if (order.isRefunded) revert OrderRefunded();
        if (settlePercent > order.currentBps) revert InvalidSettlePercent();
        if (appliedFeeBps < 0 || appliedFeeBps > order.feeBps) revert FeeExceedsCap();

        int256 currentOrderBps = order.currentBps;
        order.currentBps -= settlePercent;

        int256 liquidityProviderAmount = (order.amount * settlePercent) / currentOrderBps;
        if (liquidityProviderAmount == 0) revert ZeroPayoutSettlement();

        order.amount -= liquidityProviderAmount;

        int256 protocolFee = _calculateProtocolFeeFromBps(liquidityProviderAmount, appliedFeeBps);
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

        emit OrderSettled(orderId, liquidityProvider, settlePercent, appliedFeeBps);
        return true;
    }

    function executeSettlementTransfer(
        bytes32 orderId,
        address tokenAddress,
        Types.PermitSig calldata permitSig
    ) external whenNotPaused {
        Types.Order storage order = orders[orderId];
        if (order.orderId == bytes32(0)) revert OrderNotFound();
        if (tokenAddress != order.token) revert InvalidParameter();

        Types.PendingSettlement memory ps = pendingSettlements[orderId];
        if (ps.orderId == bytes32(0)) revert NoPendingSettlement();

        address _relayer = ILiquidityManager(settingsContract).getRelayerAddress();
        if (
            msg.sender != ps.liquidityProvider &&
            msg.sender != _relayer &&
            msg.sender != order.temporaryWalletAddress
        ) revert Unauthorized();

        uint256 totalAmount = uint256(ps.protocolFee) + uint256(ps.transferAmount);

        // EFFECT FIRST
        delete pendingSettlements[orderId];

        _permitIfProvided(tokenAddress, order.temporaryWalletAddress, totalAmount, permitSig);

        address _treasury = ILiquidityManager(settingsContract).getTreasuryAddress();

        if (ps.protocolFee > 0) {
            bool feeSuccess = IERC20(tokenAddress).transferFrom(order.temporaryWalletAddress, _treasury, uint256(ps.protocolFee));
            if (!feeSuccess) revert TransferFailed();
        }

        if (ps.transferAmount > 0) {
            bool transferSuccess = IERC20(tokenAddress).transferFrom(order.temporaryWalletAddress, ps.liquidityProvider, uint256(ps.transferAmount));
            if (!transferSuccess) revert TransferFailed();
        }

        emit SettlementTransferred(orderId, ps.settlePercent);
    }

    /// @notice Reverses a recorded settlement. Deliberately not pause-gated:
    ///         it moves no tokens and is the first step of the only unwind path
    ///         available while paused (5.2.4).
    function cancelSettlement(bytes32 orderId) external {
        address _relayer = ILiquidityManager(settingsContract).getRelayerAddress();
        address _admin1 = ILiquidityManager(settingsContract).getAdmin1();
        address _admin2 = ILiquidityManager(settingsContract).getAdmin2();
        if (msg.sender != _relayer && msg.sender != _admin1 && msg.sender != _admin2) {
            revert Unauthorized();
        }

        Types.PendingSettlement memory ps = pendingSettlements[orderId];
        if (ps.orderId == bytes32(0)) revert NoPendingSettlement();

        Types.Order storage order = orders[orderId];
        if (order.orderId == bytes32(0)) revert OrderNotFound();

        int256 totalSettledAmount = ps.transferAmount + ps.protocolFee;

        order.amount += totalSettledAmount;
        order.currentBps += ps.settlePercent;
        order.feesCollected -= ps.protocolFee;
        if (order.isFulfilled) {
            order.isFulfilled = false;
        }

        delete pendingSettlements[orderId];

        emit SettlementCancelled(orderId);
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

    function executeRefundTransfer(
        bytes32 orderId,
        address tokenAddress,
        Types.PermitSig calldata permitSig
    ) external {
        Types.Order storage order = orders[orderId];
        if (order.orderId == bytes32(0)) revert OrderNotFound();
        if (tokenAddress != order.token) revert InvalidParameter();

        Types.PendingRefund memory pr = pendingRefunds[orderId];
        if (pr.orderId == bytes32(0)) revert NoPendingRefund();

        address _relayer = ILiquidityManager(settingsContract).getRelayerAddress();
        if (
            msg.sender != order.refundAddress &&
            msg.sender != _relayer &&
            msg.sender != order.temporaryWalletAddress
        ) revert Unauthorized();

        // EFFECT FIRST
        delete pendingRefunds[orderId];

        _permitIfProvided(tokenAddress, order.temporaryWalletAddress, uint256(pr.refundAmount), permitSig);

        // INTERACTION
        bool success = IERC20(tokenAddress).transferFrom(order.temporaryWalletAddress, order.refundAddress, uint256(pr.refundAmount));
        if (!success) revert TransferFailed();

        emit RefundTransferred(orderId, pr.refundAmount);
    }

    function _permitIfProvided(
        address token,
        address owner,
        uint256 value,
        Types.PermitSig calldata permitSig
    ) internal {
        if (permitSig.r == bytes32(0)) return;

        // Always attempt the permit. Skipping it when the current allowance
        // already covers `value` leaves the nonce unconsumed, so the signature
        // stays replayable from calldata until its deadline (5.2.15).
        try IERC20Permit(token).permit(
            owner,
            address(this),
            value,
            permitSig.deadline,
            permitSig.v,
            permitSig.r,
            permitSig.s
        ) {} catch {}

        if (IERC20(token).allowance(owner, address(this)) < value) revert TransferFailed();
    }

    /// @notice EIP-712 v4 domain separator. Recomputed per verification so a
    ///         chain-id change can never replay an intent on a fork.
    function _domainSeparatorV4() internal view returns (bytes32) {
        return keccak256(
            abi.encode(
                EIP712_DOMAIN_TYPEHASH,
                keccak256(bytes(EIP712_NAME)),
                keccak256(bytes(EIP712_VERSION)),
                block.chainid,
                address(this)
            )
        );
    }

    function _hashTypedDataV4(bytes32 structHash) internal view returns (bytes32) {
        return keccak256(abi.encodePacked("\x19\x01", _domainSeparatorV4(), structHash));
    }

    /// @notice Verifies the sender's EIP-712 authorisation for a relayer-created
    ///         order and consumes one intent nonce. Reverts unless every field
    ///         that decides where the deposited funds go matches the signature.
    function _verifyOrderIntent(Types.OrderParams calldata params) internal {
        Types.OrderIntentSig calldata sig = params.intentSig;

        if (sig.r == bytes32(0)) revert InvalidSignature();
        if (block.timestamp > sig.deadline) revert SignatureExpired();
        // Monotonic rather than strictly sequential: a nonce may skip ahead,
        // but a consumed nonce can never be reused. Gaps only ever invalidate
        // the sender's own unused signatures.
        if (sig.nonce < intentNonce[params.sender]) revert InvalidNonce();

        bytes32 structHash = keccak256(
            abi.encode(
                ORDER_INTENT_TYPEHASH,
                params.orderId,
                params.token,
                params.amount,
                params.temporaryWalletAddress,
                params.refundAddress,
                uint8(params.protocolFee),
                sig.deadline,
                sig.nonce
            )
        );

        (address signer, ECDSA.RecoverError err,) =
            ECDSA.tryRecover(_hashTypedDataV4(structHash), sig.v, sig.r, sig.s);
        if (err != ECDSA.RecoverError.NoError || signer != params.sender) revert InvalidSignature();

        intentNonce[params.sender] = sig.nonce + 1;
    }

    function emergencyRefund(bytes32 orderId) external whenPaused {
        Types.Order storage order = orders[orderId];
        if (order.orderId == bytes32(0)) revert OrderNotFound();

        address _relayer = ILiquidityManager(settingsContract).getRelayerAddress();
        address _admin1 = ILiquidityManager(settingsContract).getAdmin1();
        address _admin2 = ILiquidityManager(settingsContract).getAdmin2();
        if (
            msg.sender != _relayer &&
            msg.sender != _admin1 &&
            msg.sender != _admin2 &&
            msg.sender != order.sender
        ) {
            revert Unauthorized();
        }

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

    function getTokenBalance(address user, address token) external view returns (uint256) {
        if (token == address(0)) revert ZeroAddress();
        return IERC20(token).balanceOf(user);
    }

    /// @notice Updates a tier rate. `feeBps` is in fee units, not basis
    ///         points: 1 unit = 0.001%, denominator 100,000. The cap of 10,000
    ///         units is 10%. Zero is a valid promotional rate (5.2.3).
    function updateTierFee(uint8 tier, int256 feeBps) external onlySettingsAdmin {
        if (feeBps < 0 || feeBps > 10_000) revert InvalidFeePercent();
        tierFees[tier] = feeBps;
        emit TierFeeUpdated(tier, feeBps);
    }

    function getTierFee(uint8 tier) external view returns (int256) {
        return tierFees[tier];
    }

    /// @notice Trusted escape hatch for a broken settings contract.
    /// @dev Only `admin1` may call this, and the new address is not verified to
    ///      implement `ILiquidityManager`. A mispointed settings contract
    ///      disables every state-changing path, and recovery requires a further
    ///      call from `admin1` as reported by the *new* contract. Supply the
    ///      correct address in this call; there is no second chance otherwise.
    ///      After the governance migration this path requires Safe quorum.
    function updateSettingsContract(address newSettingsContract) external {
        if (newSettingsContract == address(0)) revert ZeroAddress();
        address _admin1 = ILiquidityManager(settingsContract).getAdmin1();
        if (msg.sender != _admin1) revert Unauthorized();

        address oldSettings = settingsContract;
        settingsContract = newSettingsContract;

        emit SettingsContractUpdated(oldSettings, newSettingsContract);
    }

    function _calculateProtocolFee(int256 amount, Types.ProtocolFees tier) internal view returns (int256) {
        int256 tierBps = tierFees[uint8(tier)];
        // A zero rate is a valid (promotional) tier, not an unset one: the
        // seeded tiers are non-zero and preserved across upgrades. Returning 0
        // matches updateTierFee, which has always accepted 0 (5.2.3).
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

    /// @dev Rounds up per slice. With n slices the aggregate can exceed
    ///      `ceil(total * feeBps / 100_000)` by at most n - 1 base units (5.2.5).
    ///      The excess accrues to the treasury; the protocol never under-charges.
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
    event OrderSettled(bytes32 indexed orderId, address indexed liquidityProvider, int256 settlePercent, int256 appliedFeeBps);
    event SettlementTransferred(bytes32 indexed orderId, int256 settlePercent);
    event OrderRefundedEvent(bytes32 indexed orderId);
    event RefundTransferred(bytes32 indexed orderId, int256 refundAmount);
    event EmergencyRefund(bytes32 indexed orderId);
    event TierFeeUpdated(uint8 tier, int256 feeBps);
}

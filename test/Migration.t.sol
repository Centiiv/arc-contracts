// SPDX-License-Identifier: UNLICENSED
// © 2026 Centiiv Technologies. All rights reserved.


pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../src/LiquidityProvider.sol";
import "../src/libraries/Types.sol";

/// @notice Minimal stand-in for the pre-Wave-2 decoder: ten-field `OrderParams`.
contract LegacyOrderParamsMock {
    struct PermitSig {
        uint256 deadline;
        uint8 v;
        bytes32 r;
        bytes32 s;
    }

    struct OldOrderParams {
        bytes32 orderId;
        address token;
        address sender;
        int256 amount;
        int256 rate;
        address temporaryWalletAddress;
        address refundAddress;
        bytes32 messageHash;
        Types.ProtocolFees protocolFee;
        PermitSig permitSig;
    }

    bytes32 public lastOrderId;
    int256 public lastAmount;

    function createOrder(OldOrderParams calldata params) external {
        lastOrderId = params.orderId;
        lastAmount = params.amount;
    }
}

/// @notice Wave 2 ABI migration facts.
///
///         `OrderParams` gained an appended `intentSig` field. Solidity derives
///         the function selector from the full canonical tuple, so the selector
///         changes. That is the operating consequence: the backend release
///         must be coordinated with the contract upgrade, and relayer-created
///         orders revert until it lands. The *data* layout is not the problem:
///         if the selector were unchanged, the old decoder would simply ignore
///         the trailing tuple.
contract MigrationTest is Test {
    bytes4 internal constant LEGACY_CREATE_ORDER_SELECTOR = bytes4(
        keccak256(
            "createOrder((bytes32,address,address,int256,int256,address,address,bytes32,uint8,(uint256,uint8,bytes32,bytes32)))"
        )
    );

    function testAppendedFieldChangesTheSelector() public pure {
        assertTrue(
            LiquidityProvider.createOrder.selector != LEGACY_CREATE_ORDER_SELECTOR,
            "backend must ship with the upgrade; old calldata will not route"
        );
    }

    function testLegacyDecoderIgnoresTrailingTuple() public {
        LegacyOrderParamsMock legacy = new LegacyOrderParamsMock();

        Types.OrderParams memory params = Types.OrderParams({
            orderId: bytes32(uint256(7)),
            token: address(0x100),
            sender: address(0xA1),
            amount: 1234e6,
            rate: 1,
            temporaryWalletAddress: address(0xB2),
            refundAddress: address(0xC3),
            messageHash: bytes32(uint256(42)),
            protocolFee: Types.ProtocolFees.Alpha,
            permitSig: Types.PermitSig({deadline: 0, v: 0, r: bytes32(0), s: bytes32(0)}),
            intentSig: Types.OrderIntentSig({
                deadline: block.timestamp + 1 hours,
                nonce: 0,
                v: 27,
                r: bytes32(uint256(1)),
                s: bytes32(uint256(2))
            })
        });

        // Deliberately call the *legacy* selector with the *new* encoding.
        (bool ok, bytes memory ret) =
            address(legacy).call(abi.encodeWithSelector(LEGACY_CREATE_ORDER_SELECTOR, params));

        assertTrue(ok, string(ret));
        assertEq(legacy.lastOrderId(), params.orderId);
        assertEq(legacy.lastAmount(), params.amount);
    }
}

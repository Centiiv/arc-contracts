// SPDX-License-Identifier: UNLICENSED
// © 2026 Centiiv Technologies. All rights reserved.


pragma solidity ^0.8.20;

import "./CentiivTestBase.sol";

/// @notice 5.1.2 — a relayer-created order must carry an EIP-712 intent signed
///         by `params.sender`, binding every field that decides where the
///         deposited funds go.
contract LiquidityProviderIntentTest is CentiivTestBase {
    address internal attackerWallet = address(0xBAD);

    function _signedParams(bytes32 orderId, int256 amount)
        internal
        view
        returns (Types.OrderParams memory params, Types.OrderIntentSig memory sig)
    {
        params = _params(orderId, sender, amount, Types.ProtocolFees.Basic);
        sig = _signIntent(params, 0, block.timestamp + 1 hours);
    }

    function testValidIntentAllowsRelayerOrder() public {
        (Types.OrderParams memory params, Types.OrderIntentSig memory sig) = _signedParams(ORDER_ID_1, 1000e6);
        params.intentSig = sig;

        uint256 before = usdc.balanceOf(tempWallet);

        vm.prank(relayer);
        lp.createOrder(params);

        assertEq(usdc.balanceOf(tempWallet) - before, 1000e6);
        assertEq(lp.intentNonce(sender), 1);
        assertEq(lp.getOrderInfo(ORDER_ID_1).sender, sender);
    }

    function testRelayerCannotCreateOrderWithoutIntent() public {
        Types.OrderParams memory params = _params(ORDER_ID_1, sender, 1000e6, Types.ProtocolFees.Basic);
        // intentSig deliberately left empty

        vm.prank(relayer);
        vm.expectRevert(InvalidSignature.selector);
        lp.createOrder(params);
    }

    function testRelayerCannotRedirectTemporaryWallet() public {
        (Types.OrderParams memory params, Types.OrderIntentSig memory sig) = _signedParams(ORDER_ID_1, 1000e6);
        params.temporaryWalletAddress = attackerWallet;
        params.intentSig = sig;

        vm.prank(relayer);
        vm.expectRevert(InvalidSignature.selector);
        lp.createOrder(params);
    }

    function testRelayerCannotRedirectRefundAddress() public {
        (Types.OrderParams memory params, Types.OrderIntentSig memory sig) = _signedParams(ORDER_ID_1, 1000e6);
        params.refundAddress = attackerWallet;
        params.intentSig = sig;

        vm.prank(relayer);
        vm.expectRevert(InvalidSignature.selector);
        lp.createOrder(params);
    }

    function testRelayerCannotChangeAmount() public {
        (Types.OrderParams memory params, Types.OrderIntentSig memory sig) = _signedParams(ORDER_ID_1, 1000e6);
        params.amount = 10_000e6;
        params.intentSig = sig;

        vm.prank(relayer);
        vm.expectRevert(InvalidSignature.selector);
        lp.createOrder(params);
    }

    function testRelayerCannotChangeToken() public {
        (Types.OrderParams memory params, Types.OrderIntentSig memory sig) = _signedParams(ORDER_ID_1, 1000e6);
        params.token = address(eurc);
        params.intentSig = sig;

        vm.prank(relayer);
        vm.expectRevert(InvalidSignature.selector);
        lp.createOrder(params);
    }

    function testRelayerCannotChangeFeeTier() public {
        (Types.OrderParams memory params, Types.OrderIntentSig memory sig) = _signedParams(ORDER_ID_1, 1000e6);
        params.protocolFee = Types.ProtocolFees.Ultimate;
        params.intentSig = sig;

        vm.prank(relayer);
        vm.expectRevert(InvalidSignature.selector);
        lp.createOrder(params);
    }

    function testRelayerCannotChangeOrderId() public {
        (Types.OrderParams memory params, Types.OrderIntentSig memory sig) = _signedParams(ORDER_ID_1, 1000e6);
        params.orderId = ORDER_ID_2;
        params.intentSig = sig;

        vm.prank(relayer);
        vm.expectRevert(InvalidSignature.selector);
        lp.createOrder(params);
    }

    function testExpiredIntentReverts() public {
        Types.OrderParams memory params = _params(ORDER_ID_1, sender, 1000e6, Types.ProtocolFees.Basic);
        params.intentSig = _signIntent(params, 0, block.timestamp - 1);

        vm.prank(relayer);
        vm.expectRevert(SignatureExpired.selector);
        lp.createOrder(params);
    }

    function testWrongSignerReverts() public {
        Types.OrderParams memory params = _params(ORDER_ID_1, sender, 1000e6, Types.ProtocolFees.Basic);
        // Signed by the temp-wallet key, not by `sender`.
        params.intentSig = _signIntent(params, TEMP_WALLET_PK, 0, block.timestamp + 1 hours);

        vm.prank(relayer);
        vm.expectRevert(InvalidSignature.selector);
        lp.createOrder(params);
    }

    function testHigherNonceIsAcceptedAndAdvancesCursor() public {
        // Gaps are allowed: the sender's own signature decides the cursor.
        Types.OrderParams memory params = _params(ORDER_ID_1, sender, 1000e6, Types.ProtocolFees.Basic);
        params.intentSig = _signIntent(params, 5, block.timestamp + 1 hours);

        vm.prank(relayer);
        lp.createOrder(params);

        assertEq(lp.intentNonce(sender), 6);
    }

    function testNonceCannotBeReusedAfterSuccess() public {
        _createRelayerOrder(ORDER_ID_1, 1000e6, Types.ProtocolFees.Basic);
        assertEq(lp.intentNonce(sender), 1);

        Types.OrderParams memory params = _params(ORDER_ID_2, sender, 1000e6, Types.ProtocolFees.Basic);
        params.intentSig = _signIntent(params, 0, block.timestamp + 1 hours); // reused nonce

        vm.prank(relayer);
        vm.expectRevert(InvalidNonce.selector);
        lp.createOrder(params);
    }

    function testNonceAdvancesSequentially() public {
        _createRelayerOrder(ORDER_ID_1, 1000e6, Types.ProtocolFees.Basic);

        Types.OrderParams memory params = _params(ORDER_ID_2, sender, 1000e6, Types.ProtocolFees.Basic);
        params.intentSig = _signIntent(params, 1, block.timestamp + 1 hours);

        vm.prank(relayer);
        lp.createOrder(params);

        assertEq(lp.intentNonce(sender), 2);
    }

    function testIntentBoundToChainId() public {
        (Types.OrderParams memory params, Types.OrderIntentSig memory sig) = _signedParams(ORDER_ID_1, 1000e6);
        params.intentSig = sig;

        vm.chainId(block.chainid + 1);
        vm.prank(relayer);
        vm.expectRevert(InvalidSignature.selector);
        lp.createOrder(params);

        vm.chainId(block.chainid - 1);
    }

    function testIntentBoundToVerifyingContract() public {
        (Types.OrderParams memory params,) = _signedParams(ORDER_ID_1, 1000e6);

        bytes32 foreignDomain = keccak256(
            abi.encode(
                EIP712_DOMAIN_TYPEHASH,
                keccak256(bytes(EIP712_NAME)),
                keccak256(bytes(EIP712_VERSION)),
                block.chainid,
                address(0x1234)
            )
        );
        bytes32 digest = keccak256(
            abi.encodePacked("\x19\x01", foreignDomain, _intentStructHash(params, block.timestamp + 1 hours, 0))
        );
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(SENDER_PK, digest);
        params.intentSig = Types.OrderIntentSig({
            deadline: block.timestamp + 1 hours,
            nonce: 0,
            v: v,
            r: r,
            s: s
        });

        vm.prank(relayer);
        vm.expectRevert(InvalidSignature.selector);
        lp.createOrder(params);
    }

    function testSelfPathNeedsNoIntent() public {
        Types.OrderParams memory params = _params(ORDER_ID_1, sender, 1000e6, Types.ProtocolFees.Basic);
        params.temporaryWalletAddress = sender;

        vm.prank(sender);
        lp.createOrder(params);

        assertEq(lp.getOrderInfo(ORDER_ID_1).temporaryWalletAddress, sender);
        assertEq(lp.intentNonce(sender), 0, "self path must not consume an intent nonce");
    }

    function testIntentAuthorisesButDoesNotMoveTokens() public {
        // The intent is authorisation only; the permit/allowance still moves funds.
        vm.prank(sender);
        usdc.approve(address(lp), 0);

        Types.OrderParams memory params = _params(ORDER_ID_1, sender, 1000e6, Types.ProtocolFees.Basic);
        params.intentSig = _signIntent(params, 0, block.timestamp + 1 hours);

        vm.prank(relayer);
        vm.expectRevert("insufficient allowance");
        lp.createOrder(params);
    }
}

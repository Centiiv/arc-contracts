// SPDX-License-Identifier: UNLICENSED
// © 2026 Centiiv Technologies. All rights reserved.


pragma solidity ^0.8.20;

import "../CentiivTestBase.sol";

/// @notice Auditor PoC for 5.1.2. A relayer acting on behalf of a sender could
///         name any destination wallet; an EIP-712 intent from the sender is
///         now required before the relayer path moves a single token.
contract RelayerOrderCreationUnboundTest is CentiivTestBase {
    address internal attackerWallet = address(0xBAD);

    function _attackerParams() internal view returns (Types.OrderParams memory params) {
        params = _params(ORDER_ID_1, sender, 10_000e6, Types.ProtocolFees.Basic);
        params.temporaryWalletAddress = attackerWallet;
        params.refundAddress = attackerWallet;
    }

    function testPoc_RelayerCannotRedirectDepositWithoutIntent() public {
        Types.OrderParams memory params = _attackerParams();

        uint256 attackerBefore = usdc.balanceOf(attackerWallet);

        vm.prank(relayer);
        vm.expectRevert(InvalidSignature.selector);
        lp.createOrder(params);

        assertEq(usdc.balanceOf(attackerWallet), attackerBefore);
    }

    function testPoc_SignedDestinationReceivesDepositNotAttacker() public {
        Types.OrderParams memory params = _params(ORDER_ID_1, sender, 10_000e6, Types.ProtocolFees.Basic);
        params.intentSig = _signIntent(params, 0, block.timestamp + 1 hours);

        uint256 tempBefore = usdc.balanceOf(tempWallet);
        uint256 attackerBefore = usdc.balanceOf(attackerWallet);

        vm.prank(relayer);
        lp.createOrder(params);

        assertEq(usdc.balanceOf(tempWallet) - tempBefore, 10_000e6);
        assertEq(usdc.balanceOf(attackerWallet), attackerBefore);

        // The stored order must match the signed intent.
        Types.Order memory order = lp.getOrderInfo(ORDER_ID_1);
        assertEq(order.temporaryWalletAddress, tempWallet);
        assertEq(order.refundAddress, refundAddr);
        assertEq(order.amount, 10_000e6);
    }

    function testPoc_IntentForDifferentDestinationCannotBeReused() public {
        Types.OrderParams memory signedParams = _params(ORDER_ID_1, sender, 10_000e6, Types.ProtocolFees.Basic);
        Types.OrderIntentSig memory sig = _signIntent(signedParams, 0, block.timestamp + 1 hours);

        Types.OrderParams memory params = _attackerParams();
        params.intentSig = sig;

        vm.prank(relayer);
        vm.expectRevert(InvalidSignature.selector);
        lp.createOrder(params);
    }
}

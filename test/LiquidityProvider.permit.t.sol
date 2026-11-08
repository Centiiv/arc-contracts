// SPDX-License-Identifier: UNLICENSED
// © 2026 Centiiv Technologies. All rights reserved.


pragma solidity ^0.8.20;

import "./CentiivTestBase.sol";

/// @notice 5.2.15 — a supplied permit signature must consume its nonce even
///         when the existing allowance already covers the transfer. Otherwise
///         the signature remains replayable from calldata until its deadline.
contract LiquidityProviderPermitTest is CentiivTestBase {
    function testCreateOrderConsumesNonceWhenAllowanceAlreadySufficient() public {
        // Fixture grants tempWallet max allowance, so the permit is redundant
        // from the contract's point of view — but its nonce must still burn.
        assertGe(usdc.allowance(tempWallet, address(lp)), 1000e6);
        assertEq(usdc.nonces(tempWallet), 0);

        Types.OrderParams memory params = _params(ORDER_ID_1, tempWallet, 1000e6, Types.ProtocolFees.Basic);
        params.permitSig = _signPermit(address(usdc), tempWallet, address(lp), 1000e6, block.timestamp + 1 hours);
        params.intentSig = _signIntent(params, TEMP_WALLET_PK, 0, block.timestamp + 1 hours);

        vm.prank(relayer);
        lp.createOrder(params);

        assertEq(usdc.nonces(tempWallet), 1, "permit nonce must be consumed");
        // The permit overwrote the fixture allowance with exactly `value`,
        // which transferFrom then consumed.
        assertEq(usdc.allowance(tempWallet, address(lp)), 0);
    }

    function testExecuteSettlementConsumesNonceWhenAllowanceAlreadySufficient() public {
        _createRelayerOrder(ORDER_ID_1, 10_000e6, Types.ProtocolFees.Basic);
        vm.prank(relayer);
        lp.settle(ORDER_ID_1, lpNode, Types.MAX_BPS);

        (, int256 psProtocolFee, int256 psTransferAmount,,) = lp.pendingSettlements(ORDER_ID_1);
        uint256 totalAmount = uint256(psProtocolFee) + uint256(psTransferAmount);

        Types.PermitSig memory permitSig =
            _signPermit(address(usdc), tempWallet, address(lp), totalAmount, block.timestamp + 1 hours);

        assertEq(usdc.nonces(tempWallet), 0);

        vm.prank(lpNode);
        lp.executeSettlementTransfer(ORDER_ID_1, address(usdc), permitSig);

        assertEq(usdc.nonces(tempWallet), 1, "permit nonce must be consumed");
    }

    function testStalePermitCannotBeReplayedOnAnotherOrder() public {
        Types.OrderParams memory first = _params(ORDER_ID_1, tempWallet, 1000e6, Types.ProtocolFees.Basic);
        first.permitSig = _signPermit(address(usdc), tempWallet, address(lp), 1000e6, block.timestamp + 1 hours);
        first.intentSig = _signIntent(first, TEMP_WALLET_PK, 0, block.timestamp + 1 hours);

        // Drain the allowance so the replay has nothing to fall back on.
        vm.prank(tempWallet);
        usdc.approve(address(lp), 0);

        vm.prank(relayer);
        lp.createOrder(first);

        assertEq(usdc.nonces(tempWallet), 1);
        assertEq(usdc.allowance(tempWallet, address(lp)), 0);

        Types.OrderParams memory replay = _params(ORDER_ID_2, tempWallet, 1000e6, Types.ProtocolFees.Basic);
        replay.permitSig = first.permitSig; // same (v, r, s, deadline)
        replay.intentSig = _signIntent(replay, TEMP_WALLET_PK, 1, block.timestamp + 1 hours);

        vm.prank(relayer);
        vm.expectRevert(TransferFailed.selector);
        lp.createOrder(replay);

        assertEq(usdc.nonces(tempWallet), 1, "replay must not advance the nonce");
    }

    function testSignatureLessPathIsUnchanged() public {
        vm.prank(tempWallet);
        usdc.approve(address(lp), 0);

        Types.OrderParams memory params = _params(ORDER_ID_1, tempWallet, 1000e6, Types.ProtocolFees.Basic);
        params.intentSig = _signIntent(params, TEMP_WALLET_PK, 0, block.timestamp + 1 hours);

        assertEq(params.permitSig.r, bytes32(0));

        vm.prank(relayer);
        vm.expectRevert("insufficient allowance");
        lp.createOrder(params);

        assertEq(usdc.nonces(tempWallet), 0);
    }

    function testInvalidPermitWithInsufficientAllowanceReverts() public {
        vm.prank(tempWallet);
        usdc.approve(address(lp), 0);

        Types.OrderParams memory params = _params(ORDER_ID_1, tempWallet, 1000e6, Types.ProtocolFees.Basic);
        params.permitSig = Types.PermitSig({
            deadline: block.timestamp + 1 hours,
            v: 27,
            r: bytes32(uint256(1)),
            s: bytes32(uint256(2))
        });
        params.intentSig = _signIntent(params, TEMP_WALLET_PK, 0, block.timestamp + 1 hours);

        vm.prank(relayer);
        vm.expectRevert(TransferFailed.selector);
        lp.createOrder(params);
    }

    function testPermitStillToleratedWhenFrontRunOnCreateOrder() public {
        vm.prank(tempWallet);
        usdc.approve(address(lp), 0);

        Types.OrderParams memory params = _params(ORDER_ID_1, tempWallet, 1000e6, Types.ProtocolFees.Basic);
        params.permitSig = _signPermit(address(usdc), tempWallet, address(lp), 1000e6, block.timestamp + 1 hours);
        params.intentSig = _signIntent(params, TEMP_WALLET_PK, 0, block.timestamp + 1 hours);

        // Attacker submits the permit first, consuming the nonce.
        usdc.permit(
            tempWallet,
            address(lp),
            1000e6,
            params.permitSig.deadline,
            params.permitSig.v,
            params.permitSig.r,
            params.permitSig.s
        );

        assertEq(usdc.nonces(tempWallet), 1);

        vm.prank(relayer);
        lp.createOrder(params);

        assertEq(usdc.nonces(tempWallet), 1, "front-run nonce is not re-consumed");
        assertEq(lp.getOrderInfo(ORDER_ID_1).amount, 1000e6);
    }
}

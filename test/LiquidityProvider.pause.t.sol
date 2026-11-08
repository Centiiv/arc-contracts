// SPDX-License-Identifier: UNLICENSED
// © 2026 Centiiv Technologies. All rights reserved.


pragma solidity ^0.8.20;

import "./CentiivTestBase.sol";

/// @notice Paused-state matrix for 5.1.1 / 5.2.4.
///
///         The contract must never allow a discretionary payout while paused:
///         `executeSettlementTransfer` is gated. It must always leave an exit:
///         `cancelSettlement` and `executeRefundTransfer` are not gated, and
///         `emergencyRefund` remains the entry point into a refund.
contract LiquidityProviderPauseTest is CentiivTestBase {
    function _pause() internal {
        vm.prank(admin1);
        lm.pause();
    }

    function _openOrder() internal {
        _createRelayerOrder(ORDER_ID_1, 10_000e6, Types.ProtocolFees.Basic);
    }

    function _orderWithPendingSettlement() internal {
        _createRelayerOrder(ORDER_ID_1, 10_000e6, Types.ProtocolFees.Basic);
        vm.prank(relayer);
        lp.settle(ORDER_ID_1, lpNode, Types.MAX_BPS / 2);
    }

    function _orderWithPendingRefund() internal {
        _createRelayerOrder(ORDER_ID_1, 10_000e6, Types.ProtocolFees.Basic);
        vm.prank(relayer);
        lp.refund(ORDER_ID_1);
    }

    // ------------------------------------------------------------ pause gates

    function testPausedBlocksCreateOrder() public {
        _pause();

        Types.OrderParams memory params = _params(ORDER_ID_1, sender, 1000e6, Types.ProtocolFees.Basic);
        params.intentSig = _signIntent(params, 0, block.timestamp + 1 hours);

        vm.prank(relayer);
        vm.expectRevert(Paused.selector);
        lp.createOrder(params);
    }

    function testPausedBlocksSettleWithSnapshottedFee() public {
        _openOrder();
        _pause();

        vm.prank(relayer);
        vm.expectRevert(Paused.selector);
        lp.settle(ORDER_ID_1, lpNode, Types.MAX_BPS / 2);
    }

    function testPausedBlocksSettleWithFeeOverride() public {
        _openOrder();
        _pause();

        vm.prank(relayer);
        vm.expectRevert(Paused.selector);
        lp.settle(ORDER_ID_1, lpNode, Types.MAX_BPS, 100);
    }

    function testPausedBlocksRefund() public {
        _openOrder();
        _pause();

        vm.prank(relayer);
        vm.expectRevert(Paused.selector);
        lp.refund(ORDER_ID_1);
    }

    // The drain: a settlement recorded before the pause must not be executable.
    function testPausedBlocksExecuteSettlementTransfer() public {
        _orderWithPendingSettlement();
        _pause();

        vm.prank(lpNode);
        vm.expectRevert(Paused.selector);
        lp.executeSettlementTransfer(ORDER_ID_1, address(usdc), _noPermit());
    }

    // ------------------------------------------------------------- paused exits

    function testPausedAllowsCancelSettlement() public {
        _orderWithPendingSettlement();
        _pause();

        vm.prank(relayer);
        lp.cancelSettlement(ORDER_ID_1);

        (bytes32 psOrderId,,,,) = lp.pendingSettlements(ORDER_ID_1);
        assertEq(psOrderId, bytes32(0), "pending settlement must be cleared");

        Types.Order memory order = lp.getOrderInfo(ORDER_ID_1);
        assertEq(order.amount, 10_000e6);
        assertEq(order.currentBps, Types.MAX_BPS);
        assertEq(order.feesCollected, 0);
        assertFalse(order.isFulfilled);
    }

    function testPausedCancelSettlementWithoutPendingReverts() public {
        _openOrder();
        _pause();

        vm.prank(relayer);
        vm.expectRevert(NoPendingSettlement.selector);
        lp.cancelSettlement(ORDER_ID_1);
    }

    function testPausedAllowsEmergencyRefund() public {
        _openOrder();
        _pause();

        vm.prank(relayer);
        lp.emergencyRefund(ORDER_ID_1);

        Types.Order memory order = lp.getOrderInfo(ORDER_ID_1);
        assertTrue(order.isRefunded);
        assertEq(order.amount, 0);

        (bytes32 prOrderId, int256 refundAmount) = lp.pendingRefunds(ORDER_ID_1);
        assertEq(prOrderId, ORDER_ID_1);
        assertEq(refundAmount, 10_000e6);
    }

    function testPausedAllowsExecuteRefundTransfer() public {
        _orderWithPendingRefund();
        _pause();

        uint256 before = usdc.balanceOf(refundAddr);
        vm.prank(refundAddr);
        lp.executeRefundTransfer(ORDER_ID_1, address(usdc), _noPermit());

        assertEq(usdc.balanceOf(refundAddr) - before, 10_000e6);
        (bytes32 prOrderId,) = lp.pendingRefunds(ORDER_ID_1);
        assertEq(prOrderId, bytes32(0));
    }

    function testPausedPendingSettlementBlocksEmergencyRefund() public {
        _orderWithPendingSettlement();
        _pause();

        vm.prank(relayer);
        vm.expectRevert(PendingSettlementExists.selector);
        lp.emergencyRefund(ORDER_ID_1);
    }

    function testPausedRefundedOrderBlocksEmergencyRefund() public {
        _orderWithPendingRefund();
        _pause();

        vm.prank(relayer);
        vm.expectRevert(OrderRefunded.selector);
        lp.emergencyRefund(ORDER_ID_1);
    }

    // 5.2.6: the order's own sender may trigger the emergency refund.
    function testSenderCanTriggerEmergencyRefundWhilePaused() public {
        _openOrder();
        _pause();

        vm.prank(sender);
        lp.emergencyRefund(ORDER_ID_1);

        assertTrue(lp.getOrderInfo(ORDER_ID_1).isRefunded);
        (bytes32 prOrderId,) = lp.pendingRefunds(ORDER_ID_1);
        assertEq(prOrderId, ORDER_ID_1);
    }

    function testSenderCannotUnseatPendingSettlementViaEmergencyRefund() public {
        _orderWithPendingSettlement();
        _pause();

        vm.prank(sender);
        vm.expectRevert(PendingSettlementExists.selector);
        lp.emergencyRefund(ORDER_ID_1);
    }

    // 5.2.13: a zero settlement recipient must be rejected, not recorded.
    function testSettleRevertsIfLiquidityProviderIsZero() public {
        _openOrder();

        vm.prank(relayer);
        vm.expectRevert(ZeroAddress.selector);
        lp.settle(ORDER_ID_1, address(0), Types.MAX_BPS);

        (bytes32 psOrderId,,,,) = lp.pendingSettlements(ORDER_ID_1);
        assertEq(psOrderId, bytes32(0));
    }

    function testUnpausedBlocksEmergencyRefund() public {
        _openOrder();

        vm.prank(relayer);
        vm.expectRevert(NotPaused.selector);
        lp.emergencyRefund(ORDER_ID_1);
    }

    // The full deadlock fix: every step of the unwind must work while paused.
    function testDeadlockUnwindPathCompletesWhilePaused() public {
        _orderWithPendingSettlement();
        _pause();

        vm.startPrank(relayer);
        lp.cancelSettlement(ORDER_ID_1);
        lp.emergencyRefund(ORDER_ID_1);
        vm.stopPrank();

        assertTrue(lp.getOrderInfo(ORDER_ID_1).isRefunded);
        assertEq(lp.getOrderInfo(ORDER_ID_1).amount, 0);

        uint256 before = usdc.balanceOf(refundAddr);
        vm.prank(refundAddr);
        lp.executeRefundTransfer(ORDER_ID_1, address(usdc), _noPermit());

        assertEq(usdc.balanceOf(refundAddr) - before, 10_000e6, "depositor must be made whole");
    }

    // ---------------------------------------------------------- unpaused paths

    function testUnpausedExecuteSettlementTransferWorks() public {
        _orderWithPendingSettlement();

        uint256 treasuryBefore = usdc.balanceOf(treasury);
        uint256 lpBefore = usdc.balanceOf(lpNode);

        vm.prank(lpNode);
        lp.executeSettlementTransfer(ORDER_ID_1, address(usdc), _noPermit());

        assertEq(usdc.balanceOf(treasury) - treasuryBefore, 20e6);
        assertEq(usdc.balanceOf(lpNode) - lpBefore, 5_000e6 - 20e6);
    }

    function testUnpausedExecuteRefundTransferWorks() public {
        _orderWithPendingRefund();

        uint256 before = usdc.balanceOf(refundAddr);
        vm.prank(refundAddr);
        lp.executeRefundTransfer(ORDER_ID_1, address(usdc), _noPermit());
        assertEq(usdc.balanceOf(refundAddr) - before, 10_000e6);
    }

    // ---------------------------------------------- boundary: settlePercent

    function testSettleZeroPercentReverts() public {
        _openOrder();

        vm.prank(relayer);
        vm.expectRevert(InvalidSettlePercent.selector);
        lp.settle(ORDER_ID_1, lpNode, 0);
    }

    function testSettleMaxBpsPlusOneReverts() public {
        _openOrder();

        vm.prank(relayer);
        vm.expectRevert(InvalidSettlePercent.selector);
        lp.settle(ORDER_ID_1, lpNode, Types.MAX_BPS + 1);
    }

    function testSettleExactlyMaxBpsSucceeds() public {
        _openOrder();

        vm.prank(relayer);
        lp.settle(ORDER_ID_1, lpNode, Types.MAX_BPS);

        assertTrue(lp.getOrderInfo(ORDER_ID_1).isFulfilled);
    }
}

// SPDX-License-Identifier: UNLICENSED
// © 2026 Centiiv Technologies. All rights reserved.


pragma solidity ^0.8.20;

import "../CentiivTestBase.sol";

/// @notice Auditor PoC for 5.1.1. A settlement recorded before an incident
///         pause must not remain executable; the paused state must also not
///         trap an order (5.2.4).
contract ExecuteTransfersMissingPauseGateTest is CentiivTestBase {
    function _orderWithPendingSettlement() internal {
        _createRelayerOrder(ORDER_ID_1, 10_000e6, Types.ProtocolFees.Basic);
        vm.prank(relayer);
        lp.settle(ORDER_ID_1, lpNode, Types.MAX_BPS);
    }

    function testPoc_SettlementTransferRevertsWhilePaused() public {
        _orderWithPendingSettlement();

        vm.prank(admin1);
        lm.pause();

        vm.prank(lpNode);
        vm.expectRevert(Paused.selector);
        lp.executeSettlementTransfer(ORDER_ID_1, address(usdc), _noPermit());
    }

    function testPoc_RefundTransferStaysExecutableWhilePaused() public {
        _createRelayerOrder(ORDER_ID_1, 10_000e6, Types.ProtocolFees.Basic);
        vm.prank(relayer);
        lp.refund(ORDER_ID_1);

        vm.prank(admin1);
        lm.pause();

        uint256 before = usdc.balanceOf(refundAddr);
        vm.prank(refundAddr);
        lp.executeRefundTransfer(ORDER_ID_1, address(usdc), _noPermit());

        assertEq(usdc.balanceOf(refundAddr) - before, 10_000e6);
    }

    function testPoc_CancelSettlementStaysExecutableWhilePaused() public {
        _orderWithPendingSettlement();

        vm.prank(admin1);
        lm.pause();

        vm.prank(relayer);
        lp.cancelSettlement(ORDER_ID_1);

        assertEq(lp.getOrderInfo(ORDER_ID_1).amount, 10_000e6);
    }

    function testPoc_PausedOrderCanAlwaysBeUnwound() public {
        _orderWithPendingSettlement();

        vm.prank(admin1);
        lm.pause();

        vm.startPrank(relayer);
        lp.cancelSettlement(ORDER_ID_1);
        lp.emergencyRefund(ORDER_ID_1);
        vm.stopPrank();

        uint256 before = usdc.balanceOf(refundAddr);
        vm.prank(refundAddr);
        lp.executeRefundTransfer(ORDER_ID_1, address(usdc), _noPermit());

        assertEq(usdc.balanceOf(refundAddr) - before, 10_000e6);
    }
}

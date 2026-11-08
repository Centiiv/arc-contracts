// SPDX-License-Identifier: UNLICENSED
// © 2026 Centiiv Technologies. All rights reserved.


pragma solidity ^0.8.20;

import "./CentiivTestBase.sol";

/// @notice Event assertions for the order lifecycle. The mutation run killed
///         16 mutants by deleting `emit` statements because no test asserted
///         logs; these cover every event on the state-changing paths.
contract LiquidityProviderEventsTest is CentiivTestBase {
    function testOrderCreatedEmits() public {
        Types.OrderParams memory params = _params(ORDER_ID_1, sender, 10_000e6, Types.ProtocolFees.Basic);
        params.intentSig = _signIntent(params, 0, block.timestamp + 1 hours);

        vm.expectEmit(true, true, false, true);
        emit LiquidityProvider.OrderCreated(ORDER_ID_1, sender, 10_000e6, 40e6, 1, bytes32(uint256(42)));

        vm.prank(relayer);
        lp.createOrder(params);
    }

    function testOrderSettledEmits() public {
        _createRelayerOrder(ORDER_ID_1, 10_000e6, Types.ProtocolFees.Basic);

        vm.expectEmit(true, true, false, true);
        emit LiquidityProvider.OrderSettled(ORDER_ID_1, lpNode, Types.MAX_BPS, 400);

        vm.prank(relayer);
        lp.settle(ORDER_ID_1, lpNode, Types.MAX_BPS);
    }

    function testSettlementTransferredEmits() public {
        _createRelayerOrder(ORDER_ID_1, 10_000e6, Types.ProtocolFees.Basic);
        vm.prank(relayer);
        lp.settle(ORDER_ID_1, lpNode, Types.MAX_BPS);

        vm.expectEmit(true, false, false, true);
        emit LiquidityProvider.SettlementTransferred(ORDER_ID_1, Types.MAX_BPS);

        vm.prank(lpNode);
        lp.executeSettlementTransfer(ORDER_ID_1, address(usdc), _noPermit());
    }

    function testSettlementCancelledEmits() public {
        _createRelayerOrder(ORDER_ID_1, 10_000e6, Types.ProtocolFees.Basic);
        vm.prank(relayer);
        lp.settle(ORDER_ID_1, lpNode, Types.MAX_BPS);

        vm.expectEmit(true, false, false, true);
        emit ILiquidityProvider.SettlementCancelled(ORDER_ID_1);

        vm.prank(relayer);
        lp.cancelSettlement(ORDER_ID_1);
    }

    function testOrderRefundedEmits() public {
        _createRelayerOrder(ORDER_ID_1, 10_000e6, Types.ProtocolFees.Basic);

        vm.expectEmit(true, false, false, true);
        emit LiquidityProvider.OrderRefundedEvent(ORDER_ID_1);

        vm.prank(relayer);
        lp.refund(ORDER_ID_1);
    }

    function testRefundTransferredEmits() public {
        _createRelayerOrder(ORDER_ID_1, 10_000e6, Types.ProtocolFees.Basic);
        vm.prank(relayer);
        lp.refund(ORDER_ID_1);

        vm.expectEmit(true, false, false, true);
        emit LiquidityProvider.RefundTransferred(ORDER_ID_1, 10_000e6);

        vm.prank(refundAddr);
        lp.executeRefundTransfer(ORDER_ID_1, address(usdc), _noPermit());
    }

    function testEmergencyRefundEmits() public {
        _createRelayerOrder(ORDER_ID_1, 10_000e6, Types.ProtocolFees.Basic);

        vm.prank(admin1);
        lm.pause();

        vm.expectEmit(true, false, false, true);
        emit LiquidityProvider.EmergencyRefund(ORDER_ID_1);

        vm.prank(relayer);
        lp.emergencyRefund(ORDER_ID_1);
    }

    function testTierFeeUpdatedEmits() public {
        vm.expectEmit(true, false, false, true);
        emit LiquidityProvider.TierFeeUpdated(uint8(Types.ProtocolFees.Alpha), 350);

        vm.prank(admin1);
        lp.updateTierFee(uint8(Types.ProtocolFees.Alpha), 350);
    }
}

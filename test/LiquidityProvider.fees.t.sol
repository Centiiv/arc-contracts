// SPDX-License-Identifier: UNLICENSED
// © 2026 Centiiv Technologies. All rights reserved.


pragma solidity ^0.8.20;

import "./CentiivTestBase.sol";

/// @notice 5.2.3 (zero-rated tier) and 5.2.5 (per-slice ceiling rounding).
contract LiquidityProviderFeesTest is CentiivTestBase {
    function _ceilDiv(int256 a, int256 b) internal pure returns (int256) {
        return a == 0 ? int256(0) : ((a - 1) / b) + 1;
    }

    // ------------------------------------------------- zero-rated tier (5.2.3)

    function testZeroRatedTierCreatesOrderWithZeroFee() public {
        vm.prank(admin1);
        lp.updateTierFee(uint8(Types.ProtocolFees.Basic), 0);

        Types.OrderParams memory params = _params(ORDER_ID_1, sender, 10_000e6, Types.ProtocolFees.Basic);
        params.intentSig = _signIntent(params, 0, block.timestamp + 1 hours);

        vm.prank(relayer);
        lp.createOrder(params);

        Types.Order memory order = lp.getOrderInfo(ORDER_ID_1);
        assertEq(order.protocolFee, 0);
        assertEq(order.feeBps, 0);
        assertEq(order.amount, 10_000e6);
    }

    function testZeroRatedTierSettlesWithoutFee() public {
        vm.prank(admin1);
        lp.updateTierFee(uint8(Types.ProtocolFees.Basic), 0);

        _createRelayerOrder(ORDER_ID_1, 10_000e6, Types.ProtocolFees.Basic);

        vm.prank(relayer);
        lp.settle(ORDER_ID_1, lpNode, Types.MAX_BPS);

        (, int256 psProtocolFee, int256 psTransferAmount,,) = lp.pendingSettlements(ORDER_ID_1);
        assertEq(psProtocolFee, 0);
        assertEq(psTransferAmount, 10_000e6);

        uint256 treasuryBefore = usdc.balanceOf(treasury);
        vm.prank(lpNode);
        lp.executeSettlementTransfer(ORDER_ID_1, address(usdc), _noPermit());

        assertEq(usdc.balanceOf(treasury), treasuryBefore);
        assertEq(lp.getOrderInfo(ORDER_ID_1).feesCollected, 0);
    }

    function testZeroRatedTierDoesNotAffectOtherTiers() public {
        vm.prank(admin1);
        lp.updateTierFee(uint8(Types.ProtocolFees.Basic), 0);

        _createRelayerOrder(ORDER_ID_1, 10_000e6, Types.ProtocolFees.Alpha);
        assertEq(lp.getOrderInfo(ORDER_ID_1).feeBps, 300);
        assertEq(lp.getOrderInfo(ORDER_ID_1).protocolFee, 30e6);
    }

    // -------------------------------------------------- ceiling rounding (5.2.5)

    function testCreationFeeRoundsUpOnRemainder() public {
        // 251 * 400 / 100_000 = 1.004 → 2
        Types.OrderParams memory params = _params(ORDER_ID_1, sender, 251, Types.ProtocolFees.Basic);
        params.intentSig = _signIntent(params, 0, block.timestamp + 1 hours);

        vm.prank(relayer);
        lp.createOrder(params);

        assertEq(lp.getOrderInfo(ORDER_ID_1).protocolFee, 2);
    }

    function testCreationFeeIsExactWhenDivisible() public {
        // 250 * 400 / 100_000 = 1 exactly
        Types.OrderParams memory params = _params(ORDER_ID_1, sender, 250, Types.ProtocolFees.Basic);
        params.intentSig = _signIntent(params, 0, block.timestamp + 1 hours);

        vm.prank(relayer);
        lp.createOrder(params);

        assertEq(lp.getOrderInfo(ORDER_ID_1).protocolFee, 1);
    }

    function testSettlementSliceFeeRoundsUp() public {
        _createRelayerOrder(ORDER_ID_1, 251, Types.ProtocolFees.Basic);

        vm.prank(relayer);
        lp.settle(ORDER_ID_1, lpNode, Types.MAX_BPS, 400);

        (, int256 psProtocolFee, int256 psTransferAmount,,) = lp.pendingSettlements(ORDER_ID_1);
        assertEq(psProtocolFee, 2);
        assertEq(psTransferAmount, 249);
    }

    function testAggregateFeesStayWithinRoundingBound() public {
        int256 total = 1_000_000;
        _createRelayerOrder(ORDER_ID_1, total, Types.ProtocolFees.Basic);

        uint256 slices;
        while (lp.getOrderInfo(ORDER_ID_1).currentBps >= 251) {
            vm.prank(relayer);
            lp.settle(ORDER_ID_1, lpNode, 251, 400);

            vm.prank(lpNode);
            lp.executeSettlementTransfer(ORDER_ID_1, address(usdc), _noPermit());
            slices++;
        }

        Types.Order memory order = lp.getOrderInfo(ORDER_ID_1);
        int256 settledAmount = total - order.amount;
        int256 proportional = _ceilDiv(settledAmount * 400, Types.MAX_BPS);

        // Documented bound: at most n - 1 base units above the proportional fee.
        assertLe(order.feesCollected, proportional + int256(slices) - 1);
        // And never below it: the protocol does not lose on rounding.
        assertGe(order.feesCollected, proportional);
    }
}

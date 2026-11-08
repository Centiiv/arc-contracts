// SPDX-License-Identifier: UNLICENSED
// © 2026 Centiiv Technologies. All rights reserved.


pragma solidity ^0.8.20;

import "../CentiivTestBase.sol";

/// @notice Auditor PoC for 5.1.3. These tests pin the *accepted* behaviour:
///         on-ramp orders pay into the LP node's own wallet, so they reserve
///         nothing on-chain. Isolation is enforced off-chain by the routing
///         lease engine; the residual is documented in AUDIT_RESPONSE.md §3.3.
contract OnrampSharedEscrowTest is CentiivTestBase {
    MockERC20 internal token;

    function setUp() public override {
        super.setUp();

        token = new MockERC20("Test USD", "TUSD");
        vm.prank(admin1);
        lm.setTokenSupported(address(token), true);

        token.mint(lpNode, 1000e6);
        vm.prank(lpNode);
        token.approve(address(lp), type(uint256).max);
    }

    function _onrampParams(bytes32 orderId, int256 amount) internal view returns (Types.OrderParams memory params) {
        params = _params(orderId, lpNode, amount, Types.ProtocolFees.Basic, address(token));
        params.temporaryWalletAddress = lpNode;
        params.refundAddress = lpNode;
    }

    function testPoc_OnrampOrderReservesNothing() public {
        vm.prank(lpNode);
        lp.createOrder(_onrampParams(ORDER_ID_1, 600e6));

        assertEq(token.balanceOf(lpNode), 1000e6, "self-transfer reserves no funds");
        assertEq(lp.getOrderInfo(ORDER_ID_1).amount, 600e6);
    }

    function testPoc_TwoOrdersCanDependOnTheSameFunds() public {
        vm.startPrank(lpNode);
        lp.createOrder(_onrampParams(ORDER_ID_1, 600e6));
        lp.createOrder(_onrampParams(ORDER_ID_2, 600e6));
        vm.stopPrank();

        // Both orders exist even though the wallet only holds 600e6.
        assertEq(token.balanceOf(lpNode), 1000e6);
        assertEq(lp.getOrderInfo(ORDER_ID_1).amount + lp.getOrderInfo(ORDER_ID_2).amount, 1200e6);

        // Pay the first order out to a *different* LP so the sender's wallet
        // actually decreases, exposing that order 2 was never funded.
        address otherLp = address(0xCC);
        vm.prank(relayer);
        lp.settle(ORDER_ID_1, otherLp, Types.MAX_BPS);
        vm.prank(otherLp);
        lp.executeSettlementTransfer(ORDER_ID_1, address(token), _noPermit());

        assertLt(token.balanceOf(lpNode), 600e6, "first order consumed the shared balance");

        vm.prank(relayer);
        lp.settle(ORDER_ID_2, lpNode, Types.MAX_BPS);
        vm.prank(lpNode);
        vm.expectRevert(); // insufficient balance — the accepted residual (site b)
        lp.executeSettlementTransfer(ORDER_ID_2, address(token), _noPermit());
    }

    function testPoc_OfframpOrderDoesUseADistinctEscrowWallet() public {
        // Contrast: the relayer path moves funds into the named temp wallet.
        Types.OrderParams memory params = _params(ORDER_ID_1, sender, 1000e6, Types.ProtocolFees.Basic);
        params.intentSig = _signIntent(params, 0, block.timestamp + 1 hours);

        uint256 tempBefore = usdc.balanceOf(tempWallet);
        uint256 senderBefore = usdc.balanceOf(sender);

        vm.prank(relayer);
        lp.createOrder(params);

        assertEq(usdc.balanceOf(tempWallet) - tempBefore, 1000e6);
        assertEq(senderBefore - usdc.balanceOf(sender), 1000e6);
        assertEq(lp.getOrderInfo(ORDER_ID_1).temporaryWalletAddress, tempWallet);
    }
}

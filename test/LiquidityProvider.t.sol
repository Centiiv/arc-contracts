// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../../src/LiquidityManager.sol";
import "../../src/LiquidityProvider.sol";
import "../../src/libraries/Types.sol";
import "./mocks/MockERC20.sol";

contract LiquidityProviderTest is Test {
    LiquidityManager public lm;
    LiquidityProvider public lp;
    MockERC20 public usdc;

    address public admin1 = address(0xA1);
    address public admin2 = address(0xA2);
    address public treasury = address(0xB1);
    address public relayer = address(0xB2);
    address public sender = address(0xC1);
    address public tempWallet = address(0xC2);
    address public lpNode = address(0xC3);
    address public refundAddr = address(0xC4);
    address public nonAdmin = address(0xD1);

    bytes32 constant ORDER_ID_1 = bytes32(uint256(1));
    bytes32 constant ORDER_ID_2 = bytes32(uint256(2));

    function setUp() public {
        vm.startPrank(admin1);
        lm = new LiquidityManager();
        lm.initialize(admin1, admin2, treasury, relayer);

        lp = new LiquidityProvider();
        usdc = new MockERC20("USD Coin", "USDC");
        lp.initialize(address(usdc), address(lm));
        vm.stopPrank();

        usdc.mint(sender, 10_000e6);
        usdc.mint(tempWallet, 10_000e6);

        vm.startPrank(sender);
        usdc.approve(address(lp), type(uint256).max);
        vm.stopPrank();

        vm.startPrank(tempWallet);
        usdc.approve(address(lp), type(uint256).max);
        vm.stopPrank();
    }

    function _createOrder(
        bytes32 orderId,
        address _sender,
        int256 amount,
        Types.ProtocolFees feeTier
    ) internal returns (Types.OrderParams memory) {
        Types.OrderParams memory params = Types.OrderParams({
            orderId: orderId,
            token: address(usdc),
            sender: _sender,
            amount: amount,
            rate: 1,
            temporaryWalletAddress: tempWallet,
            refundAddress: refundAddr,
            messageHash: bytes32(uint256(42)),
            protocolFee: feeTier
        });
        return params;
    }

    function testInitialize() public view {
        assertEq(lp.usdc(), address(usdc));
        assertEq(lp.settingsContract(), address(lm));
        assertEq(lp.tierFees(uint8(Types.ProtocolFees.Basic)), 400);
        assertEq(lp.tierFees(uint8(Types.ProtocolFees.Alpha)), 300);
        assertEq(lp.tierFees(uint8(Types.ProtocolFees.Ultimate)), 200);
    }

    function testCreateOrder() public {
        Types.OrderParams memory params = _createOrder(ORDER_ID_1, sender, 1000e6, Types.ProtocolFees.Basic);

        usdc.approve(address(lp), 1000e6);

        vm.prank(relayer);
        lp.createOrder(params);

        Types.Order memory order = lp.getOrderInfo(ORDER_ID_1);
        assertEq(order.orderId, ORDER_ID_1);
        assertEq(order.sender, sender);
        assertEq(order.amount, 1000e6);
        assertEq(order.currentBps, Types.MAX_BPS);
        assertFalse(order.isFulfilled);
        assertFalse(order.isRefunded);
        assertEq(order.feeBps, 400);
    }

    function testCreateOrderTransfersTokensToTempWallet() public {
        Types.OrderParams memory params = _createOrder(ORDER_ID_1, sender, 1000e6, Types.ProtocolFees.Basic);

        usdc.approve(address(lp), 1000e6);

        vm.prank(relayer);
        lp.createOrder(params);

        assertEq(usdc.balanceOf(tempWallet), 10_000e6 + 1000e6);
    }

    function testCreateOrderCalculatesFeeCorrectly() public {
        Types.OrderParams memory params = _createOrder(ORDER_ID_1, sender, 10_000e6, Types.ProtocolFees.Basic);

        usdc.approve(address(lp), 10_000e6);

        vm.prank(relayer);
        lp.createOrder(params);

        Types.Order memory order = lp.getOrderInfo(ORDER_ID_1);
        // 10_000e6 * 400 / 100_000 = 40e6
        assertEq(order.protocolFee, 40e6);
    }

    function testCreateOrderAlphaFee() public {
        Types.OrderParams memory params = _createOrder(ORDER_ID_1, sender, 10_000e6, Types.ProtocolFees.Alpha);

        usdc.approve(address(lp), 10_000e6);

        vm.prank(relayer);
        lp.createOrder(params);

        Types.Order memory order = lp.getOrderInfo(ORDER_ID_1);
        // 10_000e6 * 300 / 100_000 = 30e6
        assertEq(order.protocolFee, 30e6);
    }

    function testCreateOrderUltimateFee() public {
        Types.OrderParams memory params = _createOrder(ORDER_ID_1, sender, 10_000e6, Types.ProtocolFees.Ultimate);

        usdc.approve(address(lp), 10_000e6);

        vm.prank(relayer);
        lp.createOrder(params);

        Types.Order memory order = lp.getOrderInfo(ORDER_ID_1);
        // 10_000e6 * 200 / 100_000 = 20e6
        assertEq(order.protocolFee, 20e6);
    }

    function testCreateOrderFeeRoundsUp() public {
        // 250 * 400 / 100000 = 1 (exact, no remainder)
        Types.OrderParams memory params = _createOrder(ORDER_ID_1, sender, 250, Types.ProtocolFees.Basic);

        usdc.approve(address(lp), 250);

        vm.prank(relayer);
        lp.createOrder(params);

        Types.Order memory order = lp.getOrderInfo(ORDER_ID_1);
        assertEq(order.protocolFee, 1);
    }

    function testCreateOrderAmountBelowMinimum() public {
        Types.OrderParams memory params = _createOrder(ORDER_ID_1, sender, 249, Types.ProtocolFees.Basic);

        usdc.approve(address(lp), 249);

        vm.prank(relayer);
        vm.expectRevert();
        lp.createOrder(params);
    }

    function testCreateOrderRevertsIfNotRelayer() public {
        Types.OrderParams memory params = _createOrder(ORDER_ID_1, sender, 1000e6, Types.ProtocolFees.Basic);

        vm.prank(nonAdmin);
        vm.expectRevert();
        lp.createOrder(params);
    }

    function testCreateOrderRevertsIfPaused() public {
        vm.prank(admin1);
        lm.pause();

        Types.OrderParams memory params = _createOrder(ORDER_ID_1, sender, 1000e6, Types.ProtocolFees.Basic);

        vm.prank(relayer);
        vm.expectRevert();
        lp.createOrder(params);
    }

    function testCreateOrderRevertsIfDuplicate() public {
        Types.OrderParams memory params = _createOrder(ORDER_ID_1, sender, 1000e6, Types.ProtocolFees.Basic);
        usdc.approve(address(lp), 2000e6);

        vm.startPrank(relayer);
        lp.createOrder(params);
        vm.expectRevert();
        lp.createOrder(params);
        vm.stopPrank();
    }

    function testCreateOrderRevertsIfZeroAmount() public {
        Types.OrderParams memory params = _createOrder(ORDER_ID_1, sender, 0, Types.ProtocolFees.Basic);

        vm.prank(relayer);
        vm.expectRevert();
        lp.createOrder(params);
    }

    function testCreateOrderRevertsIfZeroMessageHash() public {
        Types.OrderParams memory params = Types.OrderParams({
            orderId: ORDER_ID_1,
            token: address(usdc),
            sender: sender,
            amount: 1000e6,
            rate: 1,
            temporaryWalletAddress: tempWallet,
            refundAddress: refundAddr,
            messageHash: bytes32(0),
            protocolFee: Types.ProtocolFees.Basic
        });

        usdc.approve(address(lp), 1000e6);

        vm.prank(relayer);
        vm.expectRevert();
        lp.createOrder(params);
    }

    function testSettleFull() public {
        Types.OrderParams memory params = _createOrder(ORDER_ID_1, sender, 10_000e6, Types.ProtocolFees.Basic);
        usdc.approve(address(lp), 10_000e6);

        vm.prank(relayer);
        lp.createOrder(params);

        vm.prank(relayer);
        lp.settle(ORDER_ID_1, lpNode, Types.MAX_BPS);

        Types.Order memory order = lp.getOrderInfo(ORDER_ID_1);
        assertTrue(order.isFulfilled);
        assertEq(order.currentBps, 0);
        assertEq(order.amount, 0);
    }

    function testSettlePartial() public {
        Types.OrderParams memory params = _createOrder(ORDER_ID_1, sender, 10_000e6, Types.ProtocolFees.Basic);
        usdc.approve(address(lp), 10_000e6);

        vm.prank(relayer);
        lp.createOrder(params);

        int256 halfBps = Types.MAX_BPS / 2;
        vm.prank(relayer);
        lp.settle(ORDER_ID_1, lpNode, halfBps);

        Types.Order memory order = lp.getOrderInfo(ORDER_ID_1);
        assertFalse(order.isFulfilled);
        assertEq(order.currentBps, Types.MAX_BPS - halfBps);
    }

    function testSettleCreatesPendingSettlement() public {
        Types.OrderParams memory params = _createOrder(ORDER_ID_1, sender, 10_000e6, Types.ProtocolFees.Basic);
        usdc.approve(address(lp), 10_000e6);

        vm.prank(relayer);
        lp.createOrder(params);

        vm.prank(relayer);
        lp.settle(ORDER_ID_1, lpNode, Types.MAX_BPS);

        (bytes32 psOrderId,,) = lp.pendingSettlements(ORDER_ID_1);
        assertEq(psOrderId, ORDER_ID_1);
    }

    function testSettleRevertsIfPendingExists() public {
        Types.OrderParams memory params = _createOrder(ORDER_ID_1, sender, 10_000e6, Types.ProtocolFees.Basic);
        usdc.approve(address(lp), 10_000e6);

        vm.startPrank(relayer);
        lp.createOrder(params);
        lp.settle(ORDER_ID_1, lpNode, Types.MAX_BPS / 2);
        vm.expectRevert();
        lp.settle(ORDER_ID_1, lpNode, Types.MAX_BPS / 2);
        vm.stopPrank();
    }

    function testSettleRevertsIfNotRelayer() public {
        Types.OrderParams memory params = _createOrder(ORDER_ID_1, sender, 10_000e6, Types.ProtocolFees.Basic);
        usdc.approve(address(lp), 10_000e6);

        vm.prank(relayer);
        lp.createOrder(params);

        vm.prank(nonAdmin);
        vm.expectRevert();
        lp.settle(ORDER_ID_1, lpNode, Types.MAX_BPS);
    }

    function testSettleRevertsIfInvalidPercent() public {
        Types.OrderParams memory params = _createOrder(ORDER_ID_1, sender, 10_000e6, Types.ProtocolFees.Basic);
        usdc.approve(address(lp), 10_000e6);

        vm.prank(relayer);
        lp.createOrder(params);

        vm.prank(relayer);
        vm.expectRevert();
        lp.settle(ORDER_ID_1, lpNode, 0);
    }

    function testSettleRevertsIfExceedsBps() public {
        Types.OrderParams memory params = _createOrder(ORDER_ID_1, sender, 10_000e6, Types.ProtocolFees.Basic);
        usdc.approve(address(lp), 10_000e6);

        vm.prank(relayer);
        lp.createOrder(params);

        vm.prank(relayer);
        vm.expectRevert();
        lp.settle(ORDER_ID_1, lpNode, Types.MAX_BPS + 1);
    }

    function testSettleRevertsIfOrderNotFound() public {
        vm.prank(relayer);
        vm.expectRevert();
        lp.settle(ORDER_ID_1, lpNode, Types.MAX_BPS);
    }

    function testSettleRevertsIfAlreadyFulfilled() public {
        Types.OrderParams memory params = _createOrder(ORDER_ID_1, sender, 10_000e6, Types.ProtocolFees.Basic);
        usdc.approve(address(lp), 10_000e6);

        vm.startPrank(relayer);
        lp.createOrder(params);
        lp.settle(ORDER_ID_1, lpNode, Types.MAX_BPS);
        vm.expectRevert();
        lp.settle(ORDER_ID_1, lpNode, Types.MAX_BPS / 2);
        vm.stopPrank();
    }

    function testSettleRevertsIfRefunded() public {
        Types.OrderParams memory params = _createOrder(ORDER_ID_1, sender, 10_000e6, Types.ProtocolFees.Basic);
        usdc.approve(address(lp), 10_000e6);

        vm.startPrank(relayer);
        lp.createOrder(params);
        lp.refund(ORDER_ID_1);
        vm.expectRevert();
        lp.settle(ORDER_ID_1, lpNode, Types.MAX_BPS);
        vm.stopPrank();
    }

    function testExecuteSettlementTransfer() public {
        Types.OrderParams memory params = _createOrder(ORDER_ID_1, sender, 10_000e6, Types.ProtocolFees.Basic);
        usdc.approve(address(lp), 10_000e6);

        vm.startPrank(relayer);
        lp.createOrder(params);
        lp.settle(ORDER_ID_1, lpNode, Types.MAX_BPS);
        vm.stopPrank();

        uint256 lpBalBefore = usdc.balanceOf(lpNode);
        uint256 treasuryBalBefore = usdc.balanceOf(treasury);

        vm.prank(tempWallet);
        lp.executeSettlementTransfer(ORDER_ID_1, address(usdc));

        uint256 lpBalAfter = usdc.balanceOf(lpNode);
        uint256 treasuryBalAfter = usdc.balanceOf(treasury);

        // fee = 10_000e6 * 400 / 100_000 = 40e6, lp gets 10_000e6 - 40e6 = 9_960e6
        assertEq(treasuryBalAfter - treasuryBalBefore, 40e6);
        assertEq(lpBalAfter - lpBalBefore, 10_000e6 - 40e6);
    }

    function testExecuteSettlementTransferRevertsIfNotTempWallet() public {
        Types.OrderParams memory params = _createOrder(ORDER_ID_1, sender, 10_000e6, Types.ProtocolFees.Basic);
        usdc.approve(address(lp), 10_000e6);

        vm.startPrank(relayer);
        lp.createOrder(params);
        lp.settle(ORDER_ID_1, lpNode, Types.MAX_BPS);
        vm.stopPrank();

        vm.prank(nonAdmin);
        vm.expectRevert();
        lp.executeSettlementTransfer(ORDER_ID_1, address(usdc));
    }

    function testExecuteSettlementTransferRevertsIfNoPending() public {
        Types.OrderParams memory params = _createOrder(ORDER_ID_1, sender, 10_000e6, Types.ProtocolFees.Basic);
        usdc.approve(address(lp), 10_000e6);

        vm.prank(relayer);
        lp.createOrder(params);

        vm.prank(tempWallet);
        vm.expectRevert();
        lp.executeSettlementTransfer(ORDER_ID_1, address(usdc));
    }

    function testRefund() public {
        Types.OrderParams memory params = _createOrder(ORDER_ID_1, sender, 10_000e6, Types.ProtocolFees.Basic);
        usdc.approve(address(lp), 10_000e6);

        vm.prank(relayer);
        lp.createOrder(params);

        vm.prank(relayer);
        lp.refund(ORDER_ID_1);

        Types.Order memory order = lp.getOrderInfo(ORDER_ID_1);
        assertTrue(order.isRefunded);
        assertEq(order.currentBps, 0);
        assertEq(order.amount, 0);
    }

    function testRefundCreatesPendingRefund() public {
        Types.OrderParams memory params = _createOrder(ORDER_ID_1, sender, 10_000e6, Types.ProtocolFees.Basic);
        usdc.approve(address(lp), 10_000e6);

        vm.prank(relayer);
        lp.createOrder(params);

        vm.prank(relayer);
        lp.refund(ORDER_ID_1);

        (bytes32 prOrderId, int256 refundAmount) = lp.pendingRefunds(ORDER_ID_1);
        assertEq(prOrderId, ORDER_ID_1);
        assertEq(refundAmount, 10_000e6);
    }

    function testExecuteRefundTransfer() public {
        Types.OrderParams memory params = _createOrder(ORDER_ID_1, sender, 10_000e6, Types.ProtocolFees.Basic);
        usdc.approve(address(lp), 10_000e6);

        vm.prank(relayer);
        lp.createOrder(params);

        vm.prank(relayer);
        lp.refund(ORDER_ID_1);

        uint256 refundBalBefore = usdc.balanceOf(refundAddr);

        vm.prank(tempWallet);
        lp.executeRefundTransfer(ORDER_ID_1, address(usdc));

        uint256 refundBalAfter = usdc.balanceOf(refundAddr);
        assertEq(refundBalAfter - refundBalBefore, 10_000e6);
    }

    function testExecuteRefundTransferRevertsIfNotTempWallet() public {
        Types.OrderParams memory params = _createOrder(ORDER_ID_1, sender, 10_000e6, Types.ProtocolFees.Basic);
        usdc.approve(address(lp), 10_000e6);

        vm.startPrank(relayer);
        lp.createOrder(params);
        lp.refund(ORDER_ID_1);
        vm.stopPrank();

        vm.prank(nonAdmin);
        vm.expectRevert();
        lp.executeRefundTransfer(ORDER_ID_1, address(usdc));
    }

    function testEmergencyRefund() public {
        vm.prank(admin1);
        lm.pause();

        Types.OrderParams memory params = _createOrder(ORDER_ID_1, sender, 10_000e6, Types.ProtocolFees.Basic);
        usdc.approve(address(lp), 10_000e6);

        vm.prank(relayer);
        lp.createOrder(params);

        vm.prank(relayer);
        lp.emergencyRefund(ORDER_ID_1);

        Types.Order memory order = lp.getOrderInfo(ORDER_ID_1);
        assertTrue(order.isRefunded);
        assertEq(order.amount, 0);
    }

    function testEmergencyRefundRevertsIfNotPaused() public {
        Types.OrderParams memory params = _createOrder(ORDER_ID_1, sender, 10_000e6, Types.ProtocolFees.Basic);
        usdc.approve(address(lp), 10_000e6);

        vm.prank(relayer);
        lp.createOrder(params);

        vm.prank(relayer);
        vm.expectRevert();
        lp.emergencyRefund(ORDER_ID_1);
    }

    function testEmergencyRefundRevertsIfNotRelayer() public {
        vm.prank(admin1);
        lm.pause();

        Types.OrderParams memory params = _createOrder(ORDER_ID_1, sender, 10_000e6, Types.ProtocolFees.Basic);
        usdc.approve(address(lp), 10_000e6);

        vm.prank(relayer);
        lp.createOrder(params);

        vm.prank(nonAdmin);
        vm.expectRevert();
        lp.emergencyRefund(ORDER_ID_1);
    }

    function testEmergencyRefundRevertsIfAlreadyFulfilled() public {
        vm.prank(admin1);
        lm.pause();

        Types.OrderParams memory params = _createOrder(ORDER_ID_1, sender, 10_000e6, Types.ProtocolFees.Basic);
        usdc.approve(address(lp), 10_000e6);

        vm.startPrank(relayer);
        lp.createOrder(params);
        lp.settle(ORDER_ID_1, lpNode, Types.MAX_BPS);

        vm.expectRevert();
        lp.emergencyRefund(ORDER_ID_1);
        vm.stopPrank();
    }

    function testGetTokenBalance() public view {
        assertEq(lp.getTokenBalance(sender), 10_000e6);
    }

    function testUpdateTierFee() public {
        vm.prank(admin1);
        lp.updateTierFee(uint8(Types.ProtocolFees.Basic), 500);
        assertEq(lp.getTierFee(uint8(Types.ProtocolFees.Basic)), 500);
    }

    function testUpdateTierFeeRevertsIfNonAdmin() public {
        vm.prank(nonAdmin);
        vm.expectRevert();
        lp.updateTierFee(uint8(Types.ProtocolFees.Basic), 500);
    }

    function testUpdateTierFeeRevertsIfInvalid() public {
        vm.prank(admin1);
        vm.expectRevert();
        lp.updateTierFee(uint8(Types.ProtocolFees.Basic), 10_001);
    }

    function testUpdateSettingsContract() public {
        LiquidityManager newLm;
        vm.prank(admin1);
        newLm = new LiquidityManager();
        vm.prank(admin1);
        newLm.initialize(admin1, admin2, treasury, relayer);

        vm.prank(admin1);
        lp.updateSettingsContract(address(newLm));
        assertEq(lp.settingsContract(), address(newLm));
    }

    function testUpdateSettingsContractRevertsIfNonAdmin() public {
        vm.prank(nonAdmin);
        vm.expectRevert();
        lp.updateSettingsContract(address(0xE1));
    }

    function testFullSettlementFlow() public {
        Types.OrderParams memory params = _createOrder(ORDER_ID_1, sender, 10_000e6, Types.ProtocolFees.Basic);
        usdc.approve(address(lp), 10_000e6);

        vm.prank(relayer);
        lp.createOrder(params);

        vm.prank(relayer);
        lp.settle(ORDER_ID_1, lpNode, Types.MAX_BPS);

        uint256 treasuryBefore = usdc.balanceOf(treasury);
        uint256 lpBefore = usdc.balanceOf(lpNode);

        vm.prank(tempWallet);
        lp.executeSettlementTransfer(ORDER_ID_1, address(usdc));

        assertEq(usdc.balanceOf(treasury) - treasuryBefore, 40e6);
        assertEq(usdc.balanceOf(lpNode) - lpBefore, 10_000e6 - 40e6);
    }

    function testPartialSettleThenRefund() public {
        Types.OrderParams memory params = _createOrder(ORDER_ID_1, sender, 10_000e6, Types.ProtocolFees.Basic);
        usdc.approve(address(lp), 10_000e6);

        vm.startPrank(relayer);
        lp.createOrder(params);

        // Settle 50%
        lp.settle(ORDER_ID_1, lpNode, Types.MAX_BPS / 2);

        vm.prank(tempWallet);
        lp.executeSettlementTransfer(ORDER_ID_1, address(usdc));

        // Now refund remaining
        lp.refund(ORDER_ID_1);

        vm.prank(tempWallet);
        lp.executeRefundTransfer(ORDER_ID_1, address(usdc));
        vm.stopPrank();

        Types.Order memory order = lp.getOrderInfo(ORDER_ID_1);
        assertTrue(order.isRefunded);
        assertEq(order.amount, 0);
    }

    function testMultipleOrders() public {
        Types.OrderParams memory params1 = _createOrder(ORDER_ID_1, sender, 5000e6, Types.ProtocolFees.Basic);
        Types.OrderParams memory params2 = _createOrder(ORDER_ID_2, sender, 3000e6, Types.ProtocolFees.Alpha);

        usdc.approve(address(lp), 8000e6);

        vm.startPrank(relayer);
        lp.createOrder(params1);
        lp.createOrder(params2);

        lp.settle(ORDER_ID_1, lpNode, Types.MAX_BPS);
        lp.settle(ORDER_ID_2, lpNode, Types.MAX_BPS);
        vm.stopPrank();

        assertTrue(lp.getOrderInfo(ORDER_ID_1).isFulfilled);
        assertTrue(lp.getOrderInfo(ORDER_ID_2).isFulfilled);
    }
}

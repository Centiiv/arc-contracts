// SPDX-License-Identifier: UNLICENSED
// © 2026 Centiiv Technologies. All rights reserved.
//
// NOTICE: All information contained herein is, and remains the property of
// Centiiv Technologies. The intellectual and technical concepts contained
// herein are proprietary to Centiiv Technologies and are protected by trade
// secret, copyright, and other applicable laws.
//
// Dissemination, reproduction, modification, copying, or reverse engineering
// of this material in whole or in part is strictly forbidden unless prior
// written permission is obtained from Centiiv Technologies.


pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../src/LiquidityManager.sol";
import "../src/LiquidityProvider.sol";
import "../src/libraries/Types.sol";
import "./mocks/MockERC20.sol";
import "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import "@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol";

contract LiquidityProviderV2 is LiquidityProvider {
    function version() external pure returns (string memory) {
        return "2.0.0";
    }
}

contract LiquidityProviderTest is Test {
    LiquidityManager public lm;
    LiquidityProvider public lp;
    LiquidityProviderV2 public lpV2;
    MockERC20 public usdc;
    MockERC20 public eurc;
    ProxyAdmin public lmProxyAdmin;
    ProxyAdmin public lpProxyAdmin;
    TransparentUpgradeableProxy public lmProxy;
    TransparentUpgradeableProxy public lpProxy;

    address public admin1 = address(0xA1);
    address public admin2 = address(0xA2);
    address public treasury = address(0xB1);
    address public relayer = address(0xB2);
    address public sender = address(0xC1);
    address public tempWallet;
    uint256 constant TEMP_WALLET_PK = 0xA11CE;
    address public lpNode = address(0xC3);
    address public refundAddr = address(0xC4);
    address public nonAdmin = address(0xD1);

    bytes32 constant ORDER_ID_1 = bytes32(uint256(1));
    bytes32 constant ORDER_ID_2 = bytes32(uint256(2));
    bytes32 constant ADMIN_SLOT = 0xb53127684a568b3173ae13b9f8a6016e243e63b6e8ee1178d6a717850b5d6103;
    bytes32 constant PERMIT_TYPEHASH =
        keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)");

    function setUp() public {
        tempWallet = vm.addr(TEMP_WALLET_PK);
        usdc = new MockERC20("USD Coin", "USDC");
        eurc = new MockERC20("Euro Coin", "EURC");

        LiquidityManager lmImpl = new LiquidityManager();
        bytes memory lmInit = abi.encodeCall(
            LiquidityManager.initialize,
            (admin1, admin2, treasury, relayer, address(usdc), address(eurc))
        );
        lmProxy = new TransparentUpgradeableProxy(address(lmImpl), admin1, lmInit);
        lmProxyAdmin = _getProxyAdmin(address(lmProxy));
        lm = LiquidityManager(address(lmProxy));

        LiquidityProvider lpImpl = new LiquidityProvider();
        bytes memory lpInit = abi.encodeCall(
            LiquidityProvider.initialize,
            (address(usdc), address(lmProxy))
        );
        lpProxy = new TransparentUpgradeableProxy(address(lpImpl), admin1, lpInit);
        lpProxyAdmin = _getProxyAdmin(address(lpProxy));
        lp = LiquidityProvider(address(lpProxy));

        usdc.mint(sender, 10_000e6);
        usdc.mint(tempWallet, 10_000e6);
        eurc.mint(sender, 10_000e6);
        eurc.mint(tempWallet, 10_000e6);

        vm.startPrank(sender);
        usdc.approve(address(lp), type(uint256).max);
        eurc.approve(address(lp), type(uint256).max);
        vm.stopPrank();

        vm.startPrank(tempWallet);
        usdc.approve(address(lp), type(uint256).max);
        eurc.approve(address(lp), type(uint256).max);
        vm.stopPrank();
    }

    function _getProxyAdmin(address proxy) internal view returns (ProxyAdmin) {
        bytes32 slotValue = vm.load(proxy, ADMIN_SLOT);
        address adminAddr;
        assembly { adminAddr := slotValue }
        return ProxyAdmin(adminAddr);
    }

    function _signPermit(
        address token,
        address owner,
        address spender,
        uint256 value,
        uint256 deadline
    ) internal returns (Types.PermitSig memory) {
        uint256 nonce = MockERC20(token).nonces(owner);
        bytes32 structHash = keccak256(abi.encode(PERMIT_TYPEHASH, owner, spender, value, nonce, deadline));
        bytes32 digest = keccak256(
            abi.encodePacked("\x19\x01", MockERC20(token).DOMAIN_SEPARATOR(), structHash)
        );
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(TEMP_WALLET_PK, digest);
        return Types.PermitSig({deadline: deadline, v: v, r: r, s: s});
    }

    function _noPermit() internal pure returns (Types.PermitSig memory) {
        return Types.PermitSig({deadline: 0, v: 0, r: bytes32(0), s: bytes32(0)});
    }

    function _createOrder(
        bytes32 orderId,
        address _sender,
        int256 amount,
        Types.ProtocolFees feeTier
    ) internal returns (Types.OrderParams memory) {
        return _createOrder(orderId, _sender, amount, feeTier, address(usdc));
    }

    function _createOrder(
        bytes32 orderId,
        address _sender,
        int256 amount,
        Types.ProtocolFees feeTier,
        address token
    ) internal returns (Types.OrderParams memory) {
        Types.OrderParams memory params = Types.OrderParams({
            orderId: orderId,
            token: token,
            sender: _sender,
            amount: amount,
            rate: 1,
            temporaryWalletAddress: tempWallet,
            refundAddress: refundAddr,
            messageHash: bytes32(uint256(42)),
            protocolFee: feeTier,
            permitSig: _noPermit()
        });
        return params;
    }

    function testInitialize() public view {
        assertEq(lp.usdc(), address(usdc));
        assertEq(lp.settingsContract(), address(lmProxy));
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

    function testCreateOrderRevertsIfUnauthorizedCaller() public {
        Types.OrderParams memory params = _createOrder(ORDER_ID_1, sender, 1000e6, Types.ProtocolFees.Basic);
        usdc.approve(address(lp), 1000e6);

        vm.prank(nonAdmin);
        vm.expectRevert(Unauthorized.selector);
        lp.createOrder(params);
    }

    function testCreateOrderRevertsIfSenderTargetsForeignWallet() public {
        Types.OrderParams memory params = _createOrder(ORDER_ID_1, sender, 1000e6, Types.ProtocolFees.Basic);
        usdc.approve(address(lp), 1000e6);

        vm.prank(sender);
        vm.expectRevert(InvalidParameter.selector);
        lp.createOrder(params);
    }

    function testCreateOrderBySenderToOwnWallet() public {
        Types.OrderParams memory params = _createOrder(ORDER_ID_1, sender, 1000e6, Types.ProtocolFees.Basic);
        params.temporaryWalletAddress = sender;
        usdc.approve(address(lp), 1000e6);

        vm.prank(sender);
        lp.createOrder(params);

        Types.Order memory order = lp.getOrderInfo(ORDER_ID_1);
        assertEq(order.temporaryWalletAddress, sender);
        assertEq(order.amount, 1000e6);
        assertEq(usdc.balanceOf(sender), 10_000e6);
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
            protocolFee: Types.ProtocolFees.Basic,
            permitSig: _noPermit()
        });

        usdc.approve(address(lp), 1000e6);

        vm.prank(relayer);
        vm.expectRevert();
        lp.createOrder(params);
    }

    function testCreateOrderWithPermit() public {
        // Remove pre-approval so the permit in OrderParams is the only allowance source
        vm.prank(tempWallet);
        usdc.approve(address(lp), 0);

        Types.OrderParams memory params = _createOrder(ORDER_ID_1, tempWallet, 1000e6, Types.ProtocolFees.Basic);
        params.permitSig = _signPermit(
            address(usdc),
            tempWallet,
            address(lp),
            1000e6,
            block.timestamp + 1 hours
        );

        vm.prank(relayer);
        lp.createOrder(params);

        Types.Order memory order = lp.getOrderInfo(ORDER_ID_1);
        assertEq(order.amount, 1000e6);
        assertEq(usdc.balanceOf(tempWallet), 10_000e6);
        assertEq(usdc.nonces(tempWallet), 1);
        // permit set 1000e6, transferFrom consumed it in the same tx
        assertEq(usdc.allowance(tempWallet, address(lp)), 0);
    }

    function testCreateOrderRevertsIfPermitExpired() public {
        vm.prank(tempWallet);
        usdc.approve(address(lp), 0);

        Types.OrderParams memory params = _createOrder(ORDER_ID_1, tempWallet, 1000e6, Types.ProtocolFees.Basic);
        params.permitSig = _signPermit(
            address(usdc),
            tempWallet,
            address(lp),
            1000e6,
            block.timestamp - 1
        );

        vm.prank(relayer);
        vm.expectRevert(TransferFailed.selector);
        lp.createOrder(params);
    }

    function testCreateOrderRevertsIfWrongPermitSigner() public {
        vm.prank(sender);
        usdc.approve(address(lp), 0);

        Types.OrderParams memory params = _createOrder(ORDER_ID_1, sender, 1000e6, Types.ProtocolFees.Basic);
        // Signed with TEMP_WALLET_PK while owner is `sender` → recovery mismatch
        params.permitSig = _signPermit(
            address(usdc),
            sender,
            address(lp),
            1000e6,
            block.timestamp + 1 hours
        );

        vm.prank(relayer);
        vm.expectRevert(TransferFailed.selector);
        lp.createOrder(params);
    }

    function testCreateOrderPermitSkippedWhenNoSig() public {
        // Zeroed permitSig must not touch allowance — approval still required
        vm.prank(tempWallet);
        usdc.approve(address(lp), 0);

        Types.OrderParams memory params = _createOrder(ORDER_ID_1, tempWallet, 1000e6, Types.ProtocolFees.Basic);

        vm.prank(relayer);
        vm.expectRevert("insufficient allowance");
        lp.createOrder(params);
    }

    function testCreateOrderSucceedsIfPermitFrontRun() public {
        vm.prank(tempWallet);
        usdc.approve(address(lp), 0);

        Types.OrderParams memory params = _createOrder(ORDER_ID_1, tempWallet, 1000e6, Types.ProtocolFees.Basic);
        params.permitSig = _signPermit(
            address(usdc),
            tempWallet,
            address(lp),
            1000e6,
            block.timestamp + 1 hours
        );

        // Attacker front-runs the permit, consuming the nonce
        usdc.permit(
            tempWallet,
            address(lp),
            1000e6,
            params.permitSig.deadline,
            params.permitSig.v,
            params.permitSig.r,
            params.permitSig.s
        );
        assertEq(usdc.allowance(tempWallet, address(lp)), 1000e6);
        assertEq(usdc.nonces(tempWallet), 1);

        // The now-stale permit must be skipped, not re-applied
        vm.prank(relayer);
        lp.createOrder(params);

        Types.Order memory order = lp.getOrderInfo(ORDER_ID_1);
        assertEq(order.amount, 1000e6);
        assertEq(usdc.nonces(tempWallet), 1);
        assertEq(usdc.allowance(tempWallet, address(lp)), 0);
    }

    function testExecuteSettlementTransferSucceedsIfPermitFrontRun() public {
        vm.prank(tempWallet);
        usdc.approve(address(lp), 0);

        Types.OrderParams memory params = _createOrder(ORDER_ID_1, sender, 10_000e6, Types.ProtocolFees.Basic);
        vm.prank(sender);
        usdc.approve(address(lp), 10_000e6);

        vm.startPrank(relayer);
        lp.createOrder(params);
        lp.settle(ORDER_ID_1, lpNode, Types.MAX_BPS);
        vm.stopPrank();

        vm.prank(tempWallet);
        usdc.approve(address(lp), 0);

        (, int256 psProtocolFee, int256 psTransferAmount,,) = lp.pendingSettlements(ORDER_ID_1);
        uint256 totalAmount = uint256(psProtocolFee) + uint256(psTransferAmount);
        Types.PermitSig memory permitSig = _signPermit(
            address(usdc),
            tempWallet,
            address(lp),
            totalAmount,
            block.timestamp + 1 hours
        );

        // Attacker front-runs the permit, consuming the nonce
        usdc.permit(
            tempWallet,
            address(lp),
            totalAmount,
            permitSig.deadline,
            permitSig.v,
            permitSig.r,
            permitSig.s
        );
        assertEq(usdc.nonces(tempWallet), 1);

        vm.prank(lpNode);
        lp.executeSettlementTransfer(ORDER_ID_1, address(usdc), permitSig);

        assertEq(usdc.balanceOf(treasury), 40e6);
        assertEq(usdc.balanceOf(lpNode), 10_000e6 - 40e6);
        (bytes32 psOrderId,,,,) = lp.pendingSettlements(ORDER_ID_1);
        assertEq(psOrderId, bytes32(0));
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

        (bytes32 psOrderId,,,,) = lp.pendingSettlements(ORDER_ID_1);
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

    function testSettleAtCapChargesFullFee() public {
        Types.OrderParams memory params = _createOrder(ORDER_ID_1, sender, 10_000e6, Types.ProtocolFees.Basic);
        usdc.approve(address(lp), 10_000e6);

        vm.startPrank(relayer);
        lp.createOrder(params);
        lp.settle(ORDER_ID_1, lpNode, Types.MAX_BPS, 400);
        vm.stopPrank();

        (, int256 psProtocolFee, int256 psTransferAmount,,) = lp.pendingSettlements(ORDER_ID_1);
        assertEq(psProtocolFee, 40e6);
        assertEq(psTransferAmount, 10_000e6 - 40e6);
    }

    function testSettleWithoutFeeOverrideUsesSnapshottedFee() public {
        Types.OrderParams memory params = _createOrder(ORDER_ID_1, sender, 10_000e6, Types.ProtocolFees.Basic);
        usdc.approve(address(lp), 10_000e6);

        vm.startPrank(relayer);
        lp.createOrder(params);
        lp.settle(ORDER_ID_1, lpNode, Types.MAX_BPS);
        vm.stopPrank();

        (, int256 psProtocolFee, int256 psTransferAmount,,) = lp.pendingSettlements(ORDER_ID_1);
        // defaults to order.feeBps (400): 10_000e6 * 400 / 100_000 = 40e6
        assertEq(psProtocolFee, 40e6);
        assertEq(psTransferAmount, 10_000e6 - 40e6);
    }

    function testSettleWithDiscountedFee() public {
        Types.OrderParams memory params = _createOrder(ORDER_ID_1, sender, 10_000e6, Types.ProtocolFees.Basic);
        usdc.approve(address(lp), 10_000e6);

        vm.startPrank(relayer);
        lp.createOrder(params);
        lp.settle(ORDER_ID_1, lpNode, Types.MAX_BPS, 200);
        vm.stopPrank();

        (, int256 psProtocolFee, int256 psTransferAmount,,) = lp.pendingSettlements(ORDER_ID_1);
        // fee = 10_000e6 * 200 / 100_000 = 20e6
        assertEq(psProtocolFee, 20e6);
        assertEq(psTransferAmount, 10_000e6 - 20e6);

        uint256 treasuryBefore = usdc.balanceOf(treasury);
        uint256 lpBefore = usdc.balanceOf(lpNode);

        vm.prank(lpNode);
        lp.executeSettlementTransfer(ORDER_ID_1, address(usdc), _noPermit());

        assertEq(usdc.balanceOf(treasury) - treasuryBefore, 20e6);
        assertEq(usdc.balanceOf(lpNode) - lpBefore, 10_000e6 - 20e6);
    }

    function testSettleWithZeroFee() public {
        Types.OrderParams memory params = _createOrder(ORDER_ID_1, sender, 10_000e6, Types.ProtocolFees.Basic);
        usdc.approve(address(lp), 10_000e6);

        vm.startPrank(relayer);
        lp.createOrder(params);
        lp.settle(ORDER_ID_1, lpNode, Types.MAX_BPS, 0);
        vm.stopPrank();

        (, int256 psProtocolFee, int256 psTransferAmount,,) = lp.pendingSettlements(ORDER_ID_1);
        assertEq(psProtocolFee, 0);
        assertEq(psTransferAmount, 10_000e6);

        uint256 treasuryBefore = usdc.balanceOf(treasury);
        uint256 lpBefore = usdc.balanceOf(lpNode);

        vm.prank(lpNode);
        lp.executeSettlementTransfer(ORDER_ID_1, address(usdc), _noPermit());

        assertEq(usdc.balanceOf(treasury), treasuryBefore);
        assertEq(usdc.balanceOf(lpNode) - lpBefore, 10_000e6);
    }

    function testSettleRevertsIfFeeExceedsCap() public {
        Types.OrderParams memory params = _createOrder(ORDER_ID_1, sender, 10_000e6, Types.ProtocolFees.Basic);
        usdc.approve(address(lp), 10_000e6);

        vm.prank(relayer);
        lp.createOrder(params);

        vm.prank(relayer);
        vm.expectRevert(FeeExceedsCap.selector);
        lp.settle(ORDER_ID_1, lpNode, Types.MAX_BPS, 401);
    }

    function testSettleRevertsIfNegativeFee() public {
        Types.OrderParams memory params = _createOrder(ORDER_ID_1, sender, 10_000e6, Types.ProtocolFees.Basic);
        usdc.approve(address(lp), 10_000e6);

        vm.prank(relayer);
        lp.createOrder(params);

        vm.prank(relayer);
        vm.expectRevert(FeeExceedsCap.selector);
        lp.settle(ORDER_ID_1, lpNode, Types.MAX_BPS, -1);
    }

    function testSettleCapFrozenAfterTierFeeUpdate() public {
        Types.OrderParams memory params = _createOrder(ORDER_ID_1, sender, 10_000e6, Types.ProtocolFees.Basic);
        usdc.approve(address(lp), 10_000e6);

        vm.prank(relayer);
        lp.createOrder(params);

        vm.prank(admin1);
        lp.updateTierFee(uint8(Types.ProtocolFees.Basic), 1000);

        Types.Order memory order = lp.getOrderInfo(ORDER_ID_1);
        assertEq(order.feeBps, 400);

        vm.prank(relayer);
        vm.expectRevert(FeeExceedsCap.selector);
        lp.settle(ORDER_ID_1, lpNode, Types.MAX_BPS, 401);

        vm.prank(relayer);
        lp.settle(ORDER_ID_1, lpNode, Types.MAX_BPS, 400);
        assertTrue(lp.getOrderInfo(ORDER_ID_1).isFulfilled);
    }

    function testPartialSettlementsWithDifferentAppliedFees() public {
        Types.OrderParams memory params = _createOrder(ORDER_ID_1, sender, 10_000e6, Types.ProtocolFees.Basic);
        usdc.approve(address(lp), 10_000e6);

        vm.startPrank(relayer);
        lp.createOrder(params);

        // First half at full cap: 5_000e6 * 400 / 100_000 = 20e6
        lp.settle(ORDER_ID_1, lpNode, Types.MAX_BPS / 2, 400);
        vm.stopPrank();

        vm.prank(lpNode);
        lp.executeSettlementTransfer(ORDER_ID_1, address(usdc), _noPermit());

        vm.prank(relayer);
        lp.settle(ORDER_ID_1, lpNode, Types.MAX_BPS / 2, 100);

        vm.prank(lpNode);
        lp.executeSettlementTransfer(ORDER_ID_1, address(usdc), _noPermit());

        Types.Order memory order = lp.getOrderInfo(ORDER_ID_1);
        assertTrue(order.isFulfilled);
        // 20e6 + (5_000e6 * 100 / 100_000 = 5e6) = 25e6
        assertEq(order.feesCollected, 25e6);
        assertEq(usdc.balanceOf(treasury), 25e6);
        assertEq(usdc.balanceOf(lpNode), 10_000e6 - 25e6);
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

        vm.prank(lpNode);
        lp.executeSettlementTransfer(ORDER_ID_1, address(usdc), _noPermit());

        uint256 lpBalAfter = usdc.balanceOf(lpNode);
        uint256 treasuryBalAfter = usdc.balanceOf(treasury);

        // fee = 10_000e6 * 400 / 100_000 = 40e6, lp gets 10_000e6 - 40e6 = 9_960e6
        assertEq(treasuryBalAfter - treasuryBalBefore, 40e6);
        assertEq(lpBalAfter - lpBalBefore, 10_000e6 - 40e6);
    }

    function testExecuteSettlementTransferByRelayer() public {
        Types.OrderParams memory params = _createOrder(ORDER_ID_1, sender, 10_000e6, Types.ProtocolFees.Basic);
        usdc.approve(address(lp), 10_000e6);

        vm.startPrank(relayer);
        lp.createOrder(params);
        lp.settle(ORDER_ID_1, lpNode, Types.MAX_BPS);
        lp.executeSettlementTransfer(ORDER_ID_1, address(usdc), _noPermit());
        vm.stopPrank();

        assertEq(usdc.balanceOf(treasury), 40e6);
        assertEq(usdc.balanceOf(lpNode), 10_000e6 - 40e6);
    }

    function testExecuteSettlementTransferWithPermit() public {
        // Remove pre-approval so permit is the only authorization path
        vm.prank(tempWallet);
        usdc.approve(address(lp), 0);

        Types.OrderParams memory params = _createOrder(ORDER_ID_1, sender, 10_000e6, Types.ProtocolFees.Basic);
        vm.prank(sender);
        usdc.approve(address(lp), 10_000e6);

        vm.startPrank(relayer);
        lp.createOrder(params);
        lp.settle(ORDER_ID_1, lpNode, Types.MAX_BPS);
        vm.stopPrank();

        (, int256 psProtocolFee, int256 psTransferAmount,,) = lp.pendingSettlements(ORDER_ID_1);
        uint256 totalAmount = uint256(psProtocolFee) + uint256(psTransferAmount);
        Types.PermitSig memory permitSig = _signPermit(
            address(usdc),
            tempWallet,
            address(lp),
            totalAmount,
            block.timestamp + 1 hours
        );

        uint256 lpBalBefore = usdc.balanceOf(lpNode);
        uint256 treasuryBalBefore = usdc.balanceOf(treasury);

        vm.prank(lpNode);
        lp.executeSettlementTransfer(ORDER_ID_1, address(usdc), permitSig);

        assertEq(usdc.balanceOf(treasury) - treasuryBalBefore, 40e6);
        assertEq(usdc.balanceOf(lpNode) - lpBalBefore, 10_000e6 - 40e6);
        assertEq(usdc.nonces(tempWallet), 1);
    }

    function testExecuteSettlementTransferRevertsIfUnauthorizedCaller() public {
        Types.OrderParams memory params = _createOrder(ORDER_ID_1, sender, 10_000e6, Types.ProtocolFees.Basic);
        usdc.approve(address(lp), 10_000e6);

        vm.startPrank(relayer);
        lp.createOrder(params);
        lp.settle(ORDER_ID_1, lpNode, Types.MAX_BPS);
        vm.stopPrank();

        vm.prank(nonAdmin);
        vm.expectRevert();
        lp.executeSettlementTransfer(ORDER_ID_1, address(usdc), _noPermit());
    }

    function testExecuteSettlementTransferByTempWallet() public {
        Types.OrderParams memory params = _createOrder(ORDER_ID_1, sender, 10_000e6, Types.ProtocolFees.Basic);
        usdc.approve(address(lp), 10_000e6);

        vm.startPrank(relayer);
        lp.createOrder(params);
        lp.settle(ORDER_ID_1, lpNode, Types.MAX_BPS);
        vm.stopPrank();

        uint256 lpBalBefore = usdc.balanceOf(lpNode);
        uint256 treasuryBalBefore = usdc.balanceOf(treasury);

        vm.prank(tempWallet);
        lp.executeSettlementTransfer(ORDER_ID_1, address(usdc), _noPermit());

        assertEq(usdc.balanceOf(treasury) - treasuryBalBefore, 40e6);
        assertEq(usdc.balanceOf(lpNode) - lpBalBefore, 10_000e6 - 40e6);
    }

    function testExecuteSettlementTransferRevertsIfWrongToken() public {
        Types.OrderParams memory params = _createOrder(ORDER_ID_1, sender, 10_000e6, Types.ProtocolFees.Basic);
        usdc.approve(address(lp), 10_000e6);

        vm.startPrank(relayer);
        lp.createOrder(params);
        lp.settle(ORDER_ID_1, lpNode, Types.MAX_BPS);
        vm.stopPrank();

        vm.prank(lpNode);
        vm.expectRevert();
        lp.executeSettlementTransfer(ORDER_ID_1, address(0xDEAD), _noPermit());
    }

    function testExecuteSettlementTransferRevertsIfNoPending() public {
        Types.OrderParams memory params = _createOrder(ORDER_ID_1, sender, 10_000e6, Types.ProtocolFees.Basic);
        usdc.approve(address(lp), 10_000e6);

        vm.prank(relayer);
        lp.createOrder(params);

        vm.prank(lpNode);
        vm.expectRevert();
        lp.executeSettlementTransfer(ORDER_ID_1, address(usdc), _noPermit());
    }

    function testCancelSettlementRestoresOrderState() public {
        Types.OrderParams memory params = _createOrder(ORDER_ID_1, sender, 10_000e6, Types.ProtocolFees.Basic);
        usdc.approve(address(lp), 10_000e6);

        vm.startPrank(relayer);
        lp.createOrder(params);
        lp.settle(ORDER_ID_1, lpNode, Types.MAX_BPS / 2);
        vm.stopPrank();

        Types.Order memory beforeCancel = lp.getOrderInfo(ORDER_ID_1);
        assertEq(beforeCancel.amount, 5_000e6);
        assertEq(beforeCancel.currentBps, Types.MAX_BPS - Types.MAX_BPS / 2);
        assertEq(beforeCancel.feesCollected, 20e6);

        vm.expectEmit(true, false, false, true);
        emit ILiquidityProvider.SettlementCancelled(ORDER_ID_1);
        vm.prank(relayer);
        lp.cancelSettlement(ORDER_ID_1);

        (bytes32 psOrderId,,,,) = lp.pendingSettlements(ORDER_ID_1);
        assertEq(psOrderId, bytes32(0));

        Types.Order memory afterCancel = lp.getOrderInfo(ORDER_ID_1);
        assertEq(afterCancel.amount, 10_000e6);
        assertEq(afterCancel.currentBps, Types.MAX_BPS);
        assertEq(afterCancel.feesCollected, 0);
        assertFalse(afterCancel.isFulfilled);
        assertFalse(afterCancel.isRefunded);
    }

    function testCancelSettlementByAdmin1() public {
        Types.OrderParams memory params = _createOrder(ORDER_ID_1, sender, 10_000e6, Types.ProtocolFees.Basic);
        usdc.approve(address(lp), 10_000e6);

        vm.startPrank(relayer);
        lp.createOrder(params);
        lp.settle(ORDER_ID_1, lpNode, Types.MAX_BPS / 2);
        vm.stopPrank();

        vm.prank(admin1);
        lp.cancelSettlement(ORDER_ID_1);

        (bytes32 psOrderId,,,,) = lp.pendingSettlements(ORDER_ID_1);
        assertEq(psOrderId, bytes32(0));
        assertEq(lp.getOrderInfo(ORDER_ID_1).amount, 10_000e6);
    }

    function testCancelSettlementByAdmin2() public {
        Types.OrderParams memory params = _createOrder(ORDER_ID_1, sender, 10_000e6, Types.ProtocolFees.Basic);
        usdc.approve(address(lp), 10_000e6);

        vm.startPrank(relayer);
        lp.createOrder(params);
        lp.settle(ORDER_ID_1, lpNode, Types.MAX_BPS / 2);
        vm.stopPrank();

        vm.prank(admin2);
        lp.cancelSettlement(ORDER_ID_1);

        (bytes32 psOrderId,,,,) = lp.pendingSettlements(ORDER_ID_1);
        assertEq(psOrderId, bytes32(0));
        assertEq(lp.getOrderInfo(ORDER_ID_1).amount, 10_000e6);
    }

    function testCancelSettlementAfterFullSettleClearsFulfilled() public {
        Types.OrderParams memory params = _createOrder(ORDER_ID_1, sender, 10_000e6, Types.ProtocolFees.Basic);
        usdc.approve(address(lp), 10_000e6);

        vm.startPrank(relayer);
        lp.createOrder(params);
        lp.settle(ORDER_ID_1, lpNode, Types.MAX_BPS);
        vm.stopPrank();

        assertTrue(lp.getOrderInfo(ORDER_ID_1).isFulfilled);

        vm.prank(relayer);
        lp.cancelSettlement(ORDER_ID_1);

        Types.Order memory order = lp.getOrderInfo(ORDER_ID_1);
        assertFalse(order.isFulfilled);
        assertEq(order.amount, 10_000e6);
        assertEq(order.currentBps, Types.MAX_BPS);
        assertEq(order.feesCollected, 0);

        (bytes32 psOrderId,,,,) = lp.pendingSettlements(ORDER_ID_1);
        assertEq(psOrderId, bytes32(0));
    }

    function testCancelSettlementThenSettleAgain() public {
        Types.OrderParams memory params = _createOrder(ORDER_ID_1, sender, 10_000e6, Types.ProtocolFees.Basic);
        usdc.approve(address(lp), 10_000e6);

        vm.startPrank(relayer);
        lp.createOrder(params);
        lp.settle(ORDER_ID_1, lpNode, Types.MAX_BPS / 2);
        lp.cancelSettlement(ORDER_ID_1);

        lp.settle(ORDER_ID_1, lpNode, Types.MAX_BPS);
        vm.stopPrank();

        assertTrue(lp.getOrderInfo(ORDER_ID_1).isFulfilled);

        uint256 treasuryBefore = usdc.balanceOf(treasury);
        uint256 lpBalBefore = usdc.balanceOf(lpNode);

        vm.prank(lpNode);
        lp.executeSettlementTransfer(ORDER_ID_1, address(usdc), _noPermit());

        assertEq(usdc.balanceOf(treasury) - treasuryBefore, 40e6);
        assertEq(usdc.balanceOf(lpNode) - lpBalBefore, 10_000e6 - 40e6);
    }

    function testCancelSettlementRevertsIfUnauthorized() public {
        Types.OrderParams memory params = _createOrder(ORDER_ID_1, sender, 10_000e6, Types.ProtocolFees.Basic);
        usdc.approve(address(lp), 10_000e6);

        vm.startPrank(relayer);
        lp.createOrder(params);
        lp.settle(ORDER_ID_1, lpNode, Types.MAX_BPS / 2);
        vm.stopPrank();

        vm.prank(nonAdmin);
        vm.expectRevert(Unauthorized.selector);
        lp.cancelSettlement(ORDER_ID_1);

        vm.prank(sender);
        vm.expectRevert(Unauthorized.selector);
        lp.cancelSettlement(ORDER_ID_1);
    }

    function testCancelSettlementRevertsIfNoPendingSettlement() public {
        Types.OrderParams memory params = _createOrder(ORDER_ID_1, sender, 10_000e6, Types.ProtocolFees.Basic);
        usdc.approve(address(lp), 10_000e6);

        vm.prank(relayer);
        lp.createOrder(params);

        vm.prank(relayer);
        vm.expectRevert(NoPendingSettlement.selector);
        lp.cancelSettlement(ORDER_ID_1);
    }

    function testCancelSettlementRevertsIfPaused() public {
        Types.OrderParams memory params = _createOrder(ORDER_ID_1, sender, 10_000e6, Types.ProtocolFees.Basic);
        usdc.approve(address(lp), 10_000e6);

        vm.startPrank(relayer);
        lp.createOrder(params);
        lp.settle(ORDER_ID_1, lpNode, Types.MAX_BPS / 2);
        vm.stopPrank();

        vm.prank(admin1);
        lm.pause();

        vm.prank(relayer);
        vm.expectRevert(Paused.selector);
        lp.cancelSettlement(ORDER_ID_1);
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

        vm.prank(refundAddr);
        lp.executeRefundTransfer(ORDER_ID_1, address(usdc), _noPermit());

        uint256 refundBalAfter = usdc.balanceOf(refundAddr);
        assertEq(refundBalAfter - refundBalBefore, 10_000e6);
    }

    function testExecuteRefundTransferByRelayer() public {
        Types.OrderParams memory params = _createOrder(ORDER_ID_1, sender, 10_000e6, Types.ProtocolFees.Basic);
        usdc.approve(address(lp), 10_000e6);

        vm.startPrank(relayer);
        lp.createOrder(params);
        lp.refund(ORDER_ID_1);
        lp.executeRefundTransfer(ORDER_ID_1, address(usdc), _noPermit());
        vm.stopPrank();

        assertEq(usdc.balanceOf(refundAddr), 10_000e6);
    }

    function testExecuteRefundTransferWithPermit() public {
        vm.prank(tempWallet);
        usdc.approve(address(lp), 0);

        Types.OrderParams memory params = _createOrder(ORDER_ID_1, sender, 10_000e6, Types.ProtocolFees.Basic);
        vm.prank(sender);
        usdc.approve(address(lp), 10_000e6);

        vm.startPrank(relayer);
        lp.createOrder(params);
        lp.refund(ORDER_ID_1);
        vm.stopPrank();

        (, int256 refundAmount) = lp.pendingRefunds(ORDER_ID_1);
        Types.PermitSig memory permitSig = _signPermit(
            address(usdc),
            tempWallet,
            address(lp),
            uint256(refundAmount),
            block.timestamp + 1 hours
        );

        vm.prank(refundAddr);
        lp.executeRefundTransfer(ORDER_ID_1, address(usdc), permitSig);

        assertEq(usdc.balanceOf(refundAddr), 10_000e6);
        assertEq(usdc.nonces(tempWallet), 1);
    }

    function testExecuteRefundTransferRevertsIfUnauthorizedCaller() public {
        Types.OrderParams memory params = _createOrder(ORDER_ID_1, sender, 10_000e6, Types.ProtocolFees.Basic);
        usdc.approve(address(lp), 10_000e6);

        vm.startPrank(relayer);
        lp.createOrder(params);
        lp.refund(ORDER_ID_1);
        vm.stopPrank();

        vm.prank(nonAdmin);
        vm.expectRevert();
        lp.executeRefundTransfer(ORDER_ID_1, address(usdc), _noPermit());

        vm.prank(lpNode);
        vm.expectRevert();
        lp.executeRefundTransfer(ORDER_ID_1, address(usdc), _noPermit());
    }

    function testExecuteRefundTransferByTempWallet() public {
        Types.OrderParams memory params = _createOrder(ORDER_ID_1, sender, 10_000e6, Types.ProtocolFees.Basic);
        usdc.approve(address(lp), 10_000e6);

        vm.startPrank(relayer);
        lp.createOrder(params);
        lp.refund(ORDER_ID_1);
        vm.stopPrank();

        vm.prank(tempWallet);
        lp.executeRefundTransfer(ORDER_ID_1, address(usdc), _noPermit());

        assertEq(usdc.balanceOf(refundAddr), 10_000e6);
    }

    function testEmergencyRefund() public {
        Types.OrderParams memory params = _createOrder(ORDER_ID_1, sender, 10_000e6, Types.ProtocolFees.Basic);
        usdc.approve(address(lp), 10_000e6);

        vm.prank(relayer);
        lp.createOrder(params);

        vm.prank(admin1);
        lm.pause();

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
        Types.OrderParams memory params = _createOrder(ORDER_ID_1, sender, 10_000e6, Types.ProtocolFees.Basic);
        usdc.approve(address(lp), 10_000e6);

        vm.prank(relayer);
        lp.createOrder(params);

        vm.prank(admin1);
        lm.pause();

        vm.prank(nonAdmin);
        vm.expectRevert();
        lp.emergencyRefund(ORDER_ID_1);
    }

    function testEmergencyRefundByAdmin1WhenPaused() public {
        Types.OrderParams memory params = _createOrder(ORDER_ID_1, sender, 10_000e6, Types.ProtocolFees.Basic);
        usdc.approve(address(lp), 10_000e6);

        vm.prank(relayer);
        lp.createOrder(params);

        vm.prank(admin2);
        lm.pause();

        vm.prank(admin1);
        lp.emergencyRefund(ORDER_ID_1);

        Types.Order memory order = lp.getOrderInfo(ORDER_ID_1);
        assertTrue(order.isRefunded);
        assertEq(order.amount, 0);

        (bytes32 prOrderId, int256 refundAmount) = lp.pendingRefunds(ORDER_ID_1);
        assertEq(prOrderId, ORDER_ID_1);
        assertEq(refundAmount, 10_000e6);
    }

    function testEmergencyRefundByAdmin2WhenPaused() public {
        Types.OrderParams memory params = _createOrder(ORDER_ID_1, sender, 10_000e6, Types.ProtocolFees.Basic);
        usdc.approve(address(lp), 10_000e6);

        vm.prank(relayer);
        lp.createOrder(params);

        vm.prank(admin1);
        lm.pause();

        vm.prank(admin2);
        lp.emergencyRefund(ORDER_ID_1);

        Types.Order memory order = lp.getOrderInfo(ORDER_ID_1);
        assertTrue(order.isRefunded);
        assertEq(order.amount, 0);
    }

    function testEmergencyRefundThenExecuteTransferAsAdmin() public {
        Types.OrderParams memory params = _createOrder(ORDER_ID_1, sender, 10_000e6, Types.ProtocolFees.Basic);
        usdc.approve(address(lp), 10_000e6);

        vm.prank(relayer);
        lp.createOrder(params);

        vm.prank(admin1);
        lm.pause();

        vm.prank(admin2);
        lp.emergencyRefund(ORDER_ID_1);

        vm.prank(refundAddr);
        lp.executeRefundTransfer(ORDER_ID_1, address(usdc), _noPermit());

        assertEq(usdc.balanceOf(refundAddr), 10_000e6);
    }

    function testEmergencyRefundRevertsIfAlreadyFulfilled() public {
        Types.OrderParams memory params = _createOrder(ORDER_ID_1, sender, 10_000e6, Types.ProtocolFees.Basic);
        usdc.approve(address(lp), 10_000e6);

        vm.startPrank(relayer);
        lp.createOrder(params);
        lp.settle(ORDER_ID_1, lpNode, Types.MAX_BPS);
        vm.stopPrank();

        vm.prank(admin1);
        lm.pause();

        vm.prank(relayer);
        vm.expectRevert();
        lp.emergencyRefund(ORDER_ID_1);
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
        LiquidityManager newLmImpl = new LiquidityManager();
        bytes memory init = abi.encodeCall(
            LiquidityManager.initialize,
            (admin1, admin2, treasury, relayer, address(usdc), address(eurc))
        );
        TransparentUpgradeableProxy newLmProxy = new TransparentUpgradeableProxy(
            address(newLmImpl), admin1, init
        );

        vm.prank(admin1);
        lp.updateSettingsContract(address(newLmProxy));
        assertEq(lp.settingsContract(), address(newLmProxy));
    }

    function testUpdateSettingsContractRevertsIfNonAdmin() public {
        vm.prank(nonAdmin);
        vm.expectRevert();
        lp.updateSettingsContract(address(0xE1));
    }

    function testUpdateSettingsContractEmitsEvent() public {
        LiquidityManager newLmImpl = new LiquidityManager();
        bytes memory init = abi.encodeCall(
            LiquidityManager.initialize,
            (admin1, admin2, treasury, relayer, address(usdc), address(eurc))
        );
        TransparentUpgradeableProxy newLmProxy = new TransparentUpgradeableProxy(
            address(newLmImpl), admin1, init
        );

        address oldSettings = lp.settingsContract();

        vm.expectEmit(true, true, false, true);
        emit ILiquidityProvider.SettingsContractUpdated(oldSettings, address(newLmProxy));
        vm.prank(admin1);
        lp.updateSettingsContract(address(newLmProxy));

        assertEq(lp.settingsContract(), address(newLmProxy));
    }

    function testUpdateSettingsContractRevertsIfAdmin2() public {
        LiquidityManager newLmImpl = new LiquidityManager();
        bytes memory init = abi.encodeCall(
            LiquidityManager.initialize,
            (admin1, admin2, treasury, relayer, address(usdc), address(eurc))
        );
        TransparentUpgradeableProxy newLmProxy = new TransparentUpgradeableProxy(
            address(newLmImpl), admin1, init
        );

        vm.prank(admin2);
        vm.expectRevert(Unauthorized.selector);
        lp.updateSettingsContract(address(newLmProxy));
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

        vm.prank(lpNode);
        lp.executeSettlementTransfer(ORDER_ID_1, address(usdc), _noPermit());

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
        vm.stopPrank();

        vm.prank(lpNode);
        lp.executeSettlementTransfer(ORDER_ID_1, address(usdc), _noPermit());

        // Now refund remaining
        vm.prank(relayer);
        lp.refund(ORDER_ID_1);

        vm.prank(refundAddr);
        lp.executeRefundTransfer(ORDER_ID_1, address(usdc), _noPermit());

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

    function testUpgrade() public {
        lpV2 = new LiquidityProviderV2();

        vm.prank(admin1);
        lpProxyAdmin.upgradeAndCall(ITransparentUpgradeableProxy(address(lpProxy)), address(lpV2), "");

        LiquidityProvider upgraded = LiquidityProvider(address(lpProxy));
        assertEq(upgraded.usdc(), address(usdc));
        assertEq(upgraded.settingsContract(), address(lmProxy));
    }

    function testUpgradePreservesState() public {
        Types.OrderParams memory params = _createOrder(ORDER_ID_1, sender, 10_000e6, Types.ProtocolFees.Basic);
        usdc.approve(address(lp), 10_000e6);

        vm.prank(relayer);
        lp.createOrder(params);

        lpV2 = new LiquidityProviderV2();

        vm.prank(admin1);
        lpProxyAdmin.upgradeAndCall(ITransparentUpgradeableProxy(address(lpProxy)), address(lpV2), "");

        LiquidityProvider upgraded = LiquidityProvider(address(lpProxy));
        Types.Order memory order = upgraded.getOrderInfo(ORDER_ID_1);
        assertEq(order.orderId, ORDER_ID_1);
        assertEq(order.amount, 10_000e6);
        assertEq(order.sender, sender);
    }

    function testUpgradePreservesTierFees() public {
        vm.prank(admin1);
        lp.updateTierFee(uint8(Types.ProtocolFees.Basic), 500);

        lpV2 = new LiquidityProviderV2();

        vm.prank(admin1);
        lpProxyAdmin.upgradeAndCall(ITransparentUpgradeableProxy(address(lpProxy)), address(lpV2), "");

        LiquidityProvider upgraded = LiquidityProvider(address(lpProxy));
        assertEq(upgraded.getTierFee(uint8(Types.ProtocolFees.Basic)), 500);
    }

    function testUpgradeRevertsIfNotProxyAdmin() public {
        lpV2 = new LiquidityProviderV2();

        vm.prank(nonAdmin);
        vm.expectRevert();
        ITransparentUpgradeableProxy(address(lpProxy)).upgradeToAndCall(address(lpV2), "");
    }

    function testUpgradeToNewVersion() public {
        lpV2 = new LiquidityProviderV2();

        vm.prank(admin1);
        lpProxyAdmin.upgradeAndCall(ITransparentUpgradeableProxy(address(lpProxy)), address(lpV2), "");

        LiquidityProviderV2 upgraded = LiquidityProviderV2(address(lpProxy));
        assertEq(upgraded.version(), "2.0.0");
    }

    // --- Multi-token (USDC + EURC) support ---

    function testSupportedTokensSeededAtInitialize() public view {
        assertTrue(lm.isTokenSupported(address(usdc)));
        assertTrue(lm.isTokenSupported(address(eurc)));
        assertFalse(lm.isTokenSupported(address(0xDEAD)));
    }

    function testCreateOrderRevertsIfTokenNotSupported() public {
        MockERC20 unsupported = new MockERC20("Scam Token", "SCAM");

        Types.OrderParams memory params = _createOrder(
            ORDER_ID_1, sender, 1000e6, Types.ProtocolFees.Basic, address(unsupported)
        );

        vm.prank(relayer);
        vm.expectRevert(TokenNotSupported.selector);
        lp.createOrder(params);
    }

    function testCreateOrderSucceedsAfterEnablingToken() public {
        MockERC20 newToken = new MockERC20("New Token", "NEW");
        newToken.mint(sender, 1000e6);

        vm.startPrank(sender);
        newToken.approve(address(lp), type(uint256).max);
        vm.stopPrank();

        Types.OrderParams memory params = _createOrder(
            ORDER_ID_1, sender, 1000e6, Types.ProtocolFees.Basic, address(newToken)
        );

        vm.prank(relayer);
        vm.expectRevert(TokenNotSupported.selector);
        lp.createOrder(params);

        vm.prank(admin1);
        lm.setTokenSupported(address(newToken), true);

        vm.prank(relayer);
        lp.createOrder(params);

        Types.Order memory order = lp.getOrderInfo(ORDER_ID_1);
        assertEq(order.token, address(newToken));
    }

    function testEurcCreateOrder() public {
        Types.OrderParams memory params = _createOrder(
            ORDER_ID_1, sender, 1000e6, Types.ProtocolFees.Basic, address(eurc)
        );

        vm.prank(relayer);
        lp.createOrder(params);

        Types.Order memory order = lp.getOrderInfo(ORDER_ID_1);
        assertEq(order.token, address(eurc));
        assertEq(order.amount, 1000e6);
        assertEq(eurc.balanceOf(tempWallet), 10_000e6 + 1000e6);
    }

    function testEurcFullSettlementFlow() public {
        Types.OrderParams memory params = _createOrder(
            ORDER_ID_1, sender, 10_000e6, Types.ProtocolFees.Basic, address(eurc)
        );

        vm.prank(relayer);
        lp.createOrder(params);

        vm.prank(relayer);
        lp.settle(ORDER_ID_1, lpNode, Types.MAX_BPS);

        uint256 treasuryBefore = eurc.balanceOf(treasury);
        uint256 lpBefore = eurc.balanceOf(lpNode);

        vm.prank(lpNode);
        lp.executeSettlementTransfer(ORDER_ID_1, address(eurc), _noPermit());

        assertEq(eurc.balanceOf(treasury) - treasuryBefore, 40e6);
        assertEq(eurc.balanceOf(lpNode) - lpBefore, 10_000e6 - 40e6);
    }

    function testEurcRefundFlow() public {
        Types.OrderParams memory params = _createOrder(
            ORDER_ID_1, sender, 1000e6, Types.ProtocolFees.Basic, address(eurc)
        );

        uint256 refundBefore = eurc.balanceOf(refundAddr);

        vm.prank(relayer);
        lp.createOrder(params);

        vm.prank(relayer);
        lp.refund(ORDER_ID_1);

        vm.prank(refundAddr);
        lp.executeRefundTransfer(ORDER_ID_1, address(eurc), _noPermit());

        assertEq(eurc.balanceOf(refundAddr) - refundBefore, 1000e6);
        assertTrue(lp.getOrderInfo(ORDER_ID_1).isRefunded);
    }

    function testEurcSettlementRevertsIfExecutedWithUsdcToken() public {
        Types.OrderParams memory params = _createOrder(
            ORDER_ID_1, sender, 10_000e6, Types.ProtocolFees.Basic, address(eurc)
        );

        vm.prank(relayer);
        lp.createOrder(params);

        vm.prank(relayer);
        lp.settle(ORDER_ID_1, lpNode, Types.MAX_BPS);

        vm.prank(lpNode);
        vm.expectRevert(InvalidParameter.selector);
        lp.executeSettlementTransfer(ORDER_ID_1, address(usdc), _noPermit());
    }

    function testUsdcSettlementRevertsIfExecutedWithEurcToken() public {
        Types.OrderParams memory params = _createOrder(ORDER_ID_1, sender, 10_000e6, Types.ProtocolFees.Basic);

        vm.prank(relayer);
        lp.createOrder(params);

        vm.prank(relayer);
        lp.settle(ORDER_ID_1, lpNode, Types.MAX_BPS);

        vm.prank(lpNode);
        vm.expectRevert(InvalidParameter.selector);
        lp.executeSettlementTransfer(ORDER_ID_1, address(eurc), _noPermit());
    }

    function testGetTokenBalanceWithToken() public view {
        assertEq(lp.getTokenBalance(sender, address(usdc)), 10_000e6);
        assertEq(lp.getTokenBalance(sender, address(eurc)), 10_000e6);
        assertEq(lp.getTokenBalance(sender, address(usdc)), lp.getTokenBalance(sender));
    }

    function testGetTokenBalanceWithZeroTokenReverts() public {
        vm.expectRevert(ZeroAddress.selector);
        lp.getTokenBalance(sender, address(0));
    }
}

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

/// @notice Shared fixture for the audit-remediation test suites. Mirrors the
///         production topology: both implementations behind
///         TransparentUpgradeableProxy, with an independent ProxyAdmin each.
abstract contract CentiivTestBase is Test {
    LiquidityManager public lm;
    LiquidityProvider public lp;
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
    address public lpNode = address(0xC3);
    address public refundAddr = address(0xC4);
    address public nonAdmin = address(0xD1);

    uint256 internal constant TEMP_WALLET_PK = 0xA11CE;
    address public tempWallet;

    // Order senders need a known key so tests can produce EIP-712 intents.
    uint256 internal constant SENDER_PK = 0xC0FFEE;
    address public sender;

    bytes32 public constant ORDER_ID_1 = bytes32(uint256(1));
    bytes32 public constant ORDER_ID_2 = bytes32(uint256(2));

    bytes32 internal constant ADMIN_SLOT =
        0xb53127684a568b3173ae13b9f8a6016e243e63b6e8ee1178d6a717850b5d6103;

    bytes32 internal constant PERMIT_TYPEHASH =
        keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)");

    bytes32 internal constant EIP712_DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");

    bytes32 internal constant ORDER_INTENT_TYPEHASH = keccak256(
        "OrderIntent(bytes32 orderId,address token,int256 amount,address temporaryWalletAddress,address refundAddress,uint8 protocolFee,uint256 deadline,uint256 nonce)"
    );

    string internal constant EIP712_NAME = "CentiivLiquidityProvider";
    string internal constant EIP712_VERSION = "1";

    function setUp() public virtual {
        tempWallet = vm.addr(TEMP_WALLET_PK);
        sender = vm.addr(SENDER_PK);

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

        usdc.mint(sender, 100_000e6);
        usdc.mint(tempWallet, 100_000e6);
        usdc.mint(lpNode, 100_000e6);
        eurc.mint(sender, 100_000e6);
        eurc.mint(tempWallet, 100_000e6);

        vm.startPrank(sender);
        usdc.approve(address(lp), type(uint256).max);
        eurc.approve(address(lp), type(uint256).max);
        vm.stopPrank();

        vm.startPrank(tempWallet);
        usdc.approve(address(lp), type(uint256).max);
        eurc.approve(address(lp), type(uint256).max);
        vm.stopPrank();

        vm.startPrank(lpNode);
        usdc.approve(address(lp), type(uint256).max);
        vm.stopPrank();
    }

    function _getProxyAdmin(address proxy) internal view returns (ProxyAdmin) {
        bytes32 slotValue = vm.load(proxy, ADMIN_SLOT);
        address adminAddr;
        assembly {
            adminAddr := slotValue
        }
        return ProxyAdmin(adminAddr);
    }

    // ---------------------------------------------------------------- params

    function _params(
        bytes32 orderId,
        address orderSender,
        int256 amount,
        Types.ProtocolFees feeTier,
        address token
    ) internal view returns (Types.OrderParams memory) {
        return Types.OrderParams({
            orderId: orderId,
            token: token,
            sender: orderSender,
            amount: amount,
            rate: 1,
            temporaryWalletAddress: tempWallet,
            refundAddress: refundAddr,
            messageHash: bytes32(uint256(42)),
            protocolFee: feeTier,
            permitSig: _noPermit(),
            intentSig: _noIntent()
        });
    }

    function _params(
        bytes32 orderId,
        address orderSender,
        int256 amount,
        Types.ProtocolFees feeTier
    ) internal view returns (Types.OrderParams memory) {
        return _params(orderId, orderSender, amount, feeTier, address(usdc));
    }

    function _noPermit() internal pure returns (Types.PermitSig memory) {
        return Types.PermitSig({deadline: 0, v: 0, r: bytes32(0), s: bytes32(0)});
    }

    function _noIntent() internal pure returns (Types.OrderIntentSig memory) {
        return Types.OrderIntentSig({deadline: 0, nonce: 0, v: 0, r: bytes32(0), s: bytes32(0)});
    }

    // ------------------------------------------------------------- signatures

    function _signPermit(
        address token,
        address owner,
        address spender,
        uint256 value,
        uint256 deadline,
        uint256 ownerPk
    ) internal view returns (Types.PermitSig memory) {
        uint256 nonce = MockERC20(token).nonces(owner);
        bytes32 structHash = keccak256(abi.encode(PERMIT_TYPEHASH, owner, spender, value, nonce, deadline));
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", MockERC20(token).DOMAIN_SEPARATOR(), structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(ownerPk, digest);
        return Types.PermitSig({deadline: deadline, v: v, r: r, s: s});
    }

    function _signPermit(
        address token,
        address owner,
        address spender,
        uint256 value,
        uint256 deadline
    ) internal view returns (Types.PermitSig memory) {
        return _signPermit(token, owner, spender, value, deadline, TEMP_WALLET_PK);
    }

    function _domainSeparator() internal view returns (bytes32) {
        return keccak256(
            abi.encode(
                EIP712_DOMAIN_TYPEHASH,
                keccak256(bytes(EIP712_NAME)),
                keccak256(bytes(EIP712_VERSION)),
                block.chainid,
                address(lp)
            )
        );
    }

    function _intentStructHash(
        Types.OrderParams memory params,
        uint256 deadline,
        uint256 nonce
    ) internal pure returns (bytes32) {
        return keccak256(
            abi.encode(
                ORDER_INTENT_TYPEHASH,
                params.orderId,
                params.token,
                params.amount,
                params.temporaryWalletAddress,
                params.refundAddress,
                uint8(params.protocolFee),
                deadline,
                nonce
            )
        );
    }

    function _intentDigest(
        Types.OrderParams memory params,
        uint256 deadline,
        uint256 nonce
    ) internal view returns (bytes32) {
        return keccak256(
            abi.encodePacked("\x19\x01", _domainSeparator(), _intentStructHash(params, deadline, nonce))
        );
    }

    /// @notice Signs an intent for the params as they currently stand.
    function _signIntent(
        Types.OrderParams memory params,
        uint256 signerPk,
        uint256 nonce,
        uint256 deadline
    ) internal view returns (Types.OrderIntentSig memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerPk, _intentDigest(params, deadline, nonce));
        return Types.OrderIntentSig({deadline: deadline, nonce: nonce, v: v, r: r, s: s});
    }

    function _signIntent(
        Types.OrderParams memory params,
        uint256 nonce,
        uint256 deadline
    ) internal view returns (Types.OrderIntentSig memory) {
        return _signIntent(params, SENDER_PK, nonce, deadline);
    }

    // ----------------------------------------------------------------- flows

    /// @notice Relayer creates an off-ramp order for `sender` with a valid intent.
    function _createRelayerOrder(
        bytes32 orderId,
        int256 amount,
        Types.ProtocolFees feeTier
    ) internal returns (Types.OrderParams memory params) {
        params = _params(orderId, sender, amount, feeTier);
        params.intentSig = _signIntent(params, 0, block.timestamp + 1 hours);

        vm.prank(relayer);
        lp.createOrder(params);
    }

    /// @notice LP node creates an on-ramp order paying into its own wallet.
    function _createOnrampOrder(bytes32 orderId, int256 amount) internal returns (Types.OrderParams memory params) {
        params = _params(orderId, lpNode, amount, Types.ProtocolFees.Basic);
        params.temporaryWalletAddress = lpNode;
        params.refundAddress = lpNode;

        vm.prank(lpNode);
        lp.createOrder(params);
    }
}

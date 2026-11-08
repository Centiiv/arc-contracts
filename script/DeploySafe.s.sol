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

import "forge-std/Script.sol";

interface ISafeProxyFactory {
    function createProxyWithNonce(
        address singleton,
        bytes calldata initializer,
        uint256 saltNonce
    ) external returns (address proxy);
}

interface ISafe {
    function VERSION() external view returns (string memory);
    function getThreshold() external view returns (uint256);
    function getOwners() external view returns (address[] memory);
    function isOwner(address owner) external view returns (bool);
}

/// @notice Deploys a Safe v1.4.1 proxy on Arc.
///
///         The Safe **singleton, proxy factory and fallback handler are already
///         deployed at their canonical addresses** on Arc mainnet (5042) and
///         testnet (5042002). You do not deploy the Safe implementation again;
///         you create one proxy per Safe through the canonical factory. This
///         keeps the address derivation identical to every other Safe chain and
///         lets Safe{Wallet}/the Safe SDK recognise the account.
///
///         Usage:
///           SAFE_ADMIN1=0x.. SAFE_ADMIN2=0x.. SAFE_RECOVERY=0x.. \
///           PRIVATE_KEY=0x.. \
///           forge script script/DeploySafe.s.sol:DeploySafeScript \
///             --rpc-url https://rpc.mainnet.arc.io --broadcast -vv
///
///         The deployer pays a few cents of USDC gas. The resulting proxy is
///         the Safe address used for SAFE_ADDRESS in Governance.s.sol.
contract DeploySafeScript is Script {
    // Canonical Safe v1.4.1 deployments (safe-deployments, chain 5042 and
    // 5042002 are registered as "canonical").
    address internal constant CANONICAL_SAFE = 0x41675C099F32341bf84BFc5382aF534df5C7461a;
    address internal constant CANONICAL_SAFE_L2 = 0x29fcB43b46531BcA003ddC8FCB67FFE91900C762;
    address internal constant CANONICAL_PROXY_FACTORY = 0x4e1DCf7AD4e460CfD30791CCC4F9c8a4f820ec67;
    address internal constant CANONICAL_FALLBACK_HANDLER = 0xfd0732Dc9E303f09fCEf3a7388Ad10A83459Ec99;

    uint256 internal constant ARC_MAINNET = 5042;
    uint256 internal constant ARC_TESTNET = 5042002;

    function run() external returns (address safe) {
        address admin1 = vm.envAddress("SAFE_ADMIN1");
        address admin2 = vm.envAddress("SAFE_ADMIN2");
        address recovery = vm.envAddress("SAFE_RECOVERY");
        uint256 threshold = vm.envOr("SAFE_THRESHOLD", uint256(2));

        address singleton = vm.envOr("SAFE_SINGLETON", _defaultSingleton());
        address factory = vm.envOr("SAFE_PROXY_FACTORY", CANONICAL_PROXY_FACTORY);
        address fallbackHandler = vm.envOr("SAFE_FALLBACK_HANDLER", CANONICAL_FALLBACK_HANDLER);
        uint256 saltNonce = vm.envOr("SAFE_SALT_NONCE", uint256(0));

        _validateOwners(admin1, admin2, recovery, threshold);

        address[] memory owners = new address[](3);
        owners[0] = admin1;
        owners[1] = admin2;
        owners[2] = recovery;

        // Safe.setup(owners, threshold, to, data, fallbackHandler,
        //            paymentToken, payment, paymentReceiver)
        bytes memory initializer = abi.encodeWithSignature(
            "setup(address[],uint256,address,bytes,address,address,uint256,address)",
            owners,
            threshold,
            address(0),
            bytes(""),
            fallbackHandler,
            address(0),
            uint256(0),
            address(0)
        );

        vm.startBroadcast(vm.envUint("PRIVATE_KEY"));
        safe = ISafeProxyFactory(factory).createProxyWithNonce(singleton, initializer, saltNonce);
        vm.stopBroadcast();

        console.log("Safe proxy:", safe);
        console.log("  singleton:", singleton);
        console.log("  factory:", factory);
        console.log("  fallback handler:", fallbackHandler);
        console.log("  threshold:", threshold);
        console.log("");
        console.log("Verify and fund it, then set SAFE_ADDRESS=%s", safe);
    }

    /// @notice Read-only post-deployment check against a live Safe.
    function verify() external view {
        address safe = vm.envAddress("SAFE_ADDRESS");
        ISafe account = ISafe(safe);

        address[] memory owners = account.getOwners();
        console.log("Safe:", safe);
        console.log("VERSION:", account.VERSION());
        console.log("threshold:", account.getThreshold());
        for (uint256 i = 0; i < owners.length; i++) {
            console.log("owner:", owners[i]);
        }

        address singleton;
        bytes32 slot0 = vm.load(safe, bytes32(uint256(0)));
        assembly {
            singleton := slot0
        }
        console.log("singleton (slot 0):", singleton);
    }

    /// @notice Prints the initializer so it can be compared with the Safe UI /
    ///         SDK before broadcasting.
    function printInitializer() external view {
        address admin1 = vm.envAddress("SAFE_ADMIN1");
        address admin2 = vm.envAddress("SAFE_ADMIN2");
        address recovery = vm.envAddress("SAFE_RECOVERY");
        uint256 threshold = vm.envOr("SAFE_THRESHOLD", uint256(2));
        address fallbackHandler = vm.envOr("SAFE_FALLBACK_HANDLER", CANONICAL_FALLBACK_HANDLER);

        _validateOwners(admin1, admin2, recovery, threshold);

        address[] memory owners = new address[](3);
        owners[0] = admin1;
        owners[1] = admin2;
        owners[2] = recovery;

        bytes memory initializer = abi.encodeWithSignature(
            "setup(address[],uint256,address,bytes,address,address,uint256,address)",
            owners,
            threshold,
            address(0),
            bytes(""),
            fallbackHandler,
            address(0),
            uint256(0),
            address(0)
        );

        console.logBytes(initializer);
        console.log("singleton:", vm.envOr("SAFE_SINGLETON", CANONICAL_SAFE));
        console.log("factory:", CANONICAL_PROXY_FACTORY);
    }

    function _defaultSingleton() internal view returns (address) {
        if (block.chainid == ARC_MAINNET || block.chainid == ARC_TESTNET) {
            // Standard Safe. Use CANONICAL_SAFE_L2 if you prefer the SafeL2
            // event set; both are canonical on Arc.
            return CANONICAL_SAFE;
        }
        revert(
            "Unsupported chain: set SAFE_SINGLETON / SAFE_PROXY_FACTORY explicitly"
        );
    }

    function _validateOwners(
        address admin1,
        address admin2,
        address recovery,
        uint256 threshold
    ) internal pure {
        require(admin1 != address(0), "SAFE_ADMIN1 is zero");
        require(admin2 != address(0), "SAFE_ADMIN2 is zero");
        require(recovery != address(0), "SAFE_RECOVERY is zero");
        require(admin1 != admin2, "admin1 == admin2");
        require(admin1 != recovery, "admin1 == recovery");
        require(admin2 != recovery, "admin2 == recovery");
        require(threshold >= 2 && threshold <= 3, "threshold must be 2 or 3");
    }
}

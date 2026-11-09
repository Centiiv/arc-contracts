// SPDX-License-Identifier: UNLICENSED
// © 2026 Centiiv Technologies. All rights reserved.


pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/governance/TimelockController.sol";
import "@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol";
import "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";

interface ISafeAccount {
    function VERSION() external view returns (string memory);
    function getThreshold() external view returns (uint256);
    function getOwners() external view returns (address[] memory);
    function isOwner(address owner) external view returns (bool);
}

interface ISafeProxyFactory {
    function createProxyWithNonce(
        address singleton,
        bytes calldata initializer,
        uint256 saltNonce
    ) external returns (address proxy);
}

interface ILiquidityManagerAdmin {
    function admin1() external view returns (address);
    function admin2() external view returns (address);
    function transferAdmin1(address newAdmin) external;
    function acceptAdmin1() external;
    function pause() external;
    function unpause() external;
}

/// @notice End-to-end rehearsal of the Wave 3 migration against **live Arc
///         mainnet state**, on a local fork. It deploys a real Safe through the
///         canonical factory, moves both ProxyAdmins from the EOA to the Safe
///         and then to the timelock, rotates `admin1`, and executes a no-op
///         upgrade through the 2-hour delay.
///
///         Nothing is broadcast. Requires ARC_MAINNET_RPC_URL; skipped when the
///         variable is unset so CI does not depend on a public RPC.
///
///           ARC_MAINNET_RPC_URL=https://rpc.mainnet.arc.io \
///             forge test --match-contract GovernanceMainnetForkTest -vv
contract GovernanceMainnetForkTest is Test {
    address internal constant LM_PROXY = 0xB648061376a696Daafb17D8107B18872ecC6889B;
    address internal constant LP_PROXY = 0x7A343A92B580f47A3Cb473dacB43F09f9467033f;
    address internal constant LM_PROXY_ADMIN = 0xd454D48FbeA2bD631Cdf70a3a11089AC9d1e4f84;
    address internal constant LP_PROXY_ADMIN = 0x588a5Ece2ab68D61eD48674a0FE37a2F3f8F0C89;

    // Canonical Safe v1.5.0 deployments on Arc (safe-deployments).
    address internal constant SAFE_SINGLETON = 0xFf51A5898e281Db6DfC7855790607438dF2ca44b;
    address internal constant SAFE_PROXY_FACTORY = 0x14F2982D601c9458F93bd70B218933A6f8165e7b;
    address internal constant SAFE_FALLBACK_HANDLER = 0x3EfCBb83A4A7AfcB4F68D501E2c2203a38be77f4;

    bytes32 internal constant IMPLEMENTATION_SLOT =
        0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;

    address internal admin1;
    address internal admin2;

    function setUp() public {
        string memory rpc = vm.envOr("ARC_MAINNET_RPC_URL", string(""));
        if (bytes(rpc).length == 0) {
            vm.skip(true);
            return;
        }
        vm.createSelectFork(rpc);
        admin1 = ILiquidityManagerAdmin(LM_PROXY).admin1();
        admin2 = ILiquidityManagerAdmin(LM_PROXY).admin2();
    }

    function testFullWave3MigrationRehearsal() public {
        // The live deployment still has the original EOA in both roles.
        assertEq(ProxyAdmin(LM_PROXY_ADMIN).owner(), admin1);
        assertEq(ProxyAdmin(LP_PROXY_ADMIN).owner(), admin1);
        assertEq(ILiquidityManagerAdmin(LM_PROXY).admin1(), admin1);

        // 1. Deploy a real 2-of-3 Safe through the canonical factory.
        address recovery = vm.addr(0xC0FFEE);
        address[] memory owners = new address[](3);
        owners[0] = admin1;
        owners[1] = admin2;
        owners[2] = recovery;

        bytes memory initializer = abi.encodeWithSignature(
            "setup(address[],uint256,address,bytes,address,address,uint256,address)",
            owners,
            uint256(2),
            address(0),
            bytes(""),
            SAFE_FALLBACK_HANDLER,
            address(0),
            uint256(0),
            address(0)
        );
        address safe = ISafeProxyFactory(SAFE_PROXY_FACTORY).createProxyWithNonce(
            SAFE_SINGLETON,
            initializer,
            uint256(0)
        );

        assertEq(ISafeAccount(safe).VERSION(), "1.5.0");
        assertEq(ISafeAccount(safe).getThreshold(), 2);
        address[] memory actualOwners = ISafeAccount(safe).getOwners();
        assertEq(actualOwners.length, 3);
        assertTrue(ISafeAccount(safe).isOwner(admin1));
        assertTrue(ISafeAccount(safe).isOwner(admin2));
        assertTrue(ISafeAccount(safe).isOwner(recovery));

        // 2. Deploy the timelock with no external admin.
        address[] memory proposers = new address[](1);
        proposers[0] = safe;
        address[] memory executors = new address[](1);
        executors[0] = safe;
        TimelockController timelock =
            new TimelockController(2 hours, proposers, executors, address(0));
        assertEq(timelock.getMinDelay(), 2 hours);
        assertFalse(timelock.hasRole(timelock.DEFAULT_ADMIN_ROLE(), safe));

        // 3. EOA -> Safe for both ProxyAdmins (the original admin1 key).
        vm.startPrank(admin1);
        ProxyAdmin(LM_PROXY_ADMIN).transferOwnership(safe);
        ProxyAdmin(LP_PROXY_ADMIN).transferOwnership(safe);
        vm.stopPrank();
        assertEq(ProxyAdmin(LM_PROXY_ADMIN).owner(), safe);
        assertEq(ProxyAdmin(LP_PROXY_ADMIN).owner(), safe);

        // 4. Safe -> timelock.
        vm.startPrank(safe);
        ProxyAdmin(LM_PROXY_ADMIN).transferOwnership(address(timelock));
        ProxyAdmin(LP_PROXY_ADMIN).transferOwnership(address(timelock));
        vm.stopPrank();
        assertEq(ProxyAdmin(LM_PROXY_ADMIN).owner(), address(timelock));
        assertEq(ProxyAdmin(LP_PROXY_ADMIN).owner(), address(timelock));

        // 5. Rotate admin1 to the Safe (propose from EOA, accept from Safe).
        vm.prank(admin1);
        ILiquidityManagerAdmin(LM_PROXY).transferAdmin1(safe);
        vm.prank(safe);
        ILiquidityManagerAdmin(LM_PROXY).acceptAdmin1();
        assertEq(ILiquidityManagerAdmin(LM_PROXY).admin1(), safe);

        // The old admin can no longer pause; the Safe can.
        vm.prank(admin1);
        vm.expectRevert();
        ILiquidityManagerAdmin(LM_PROXY).pause();

        vm.prank(safe);
        ILiquidityManagerAdmin(LM_PROXY).pause();
        vm.prank(safe);
        ILiquidityManagerAdmin(LM_PROXY).unpause();

        // 6. A real proxy upgrade now has to pass the 2-hour delay.
        address currentImplementation =
            address(uint160(uint256(vm.load(LP_PROXY, IMPLEMENTATION_SLOT))));

        address[] memory targets = new address[](1);
        targets[0] = LP_PROXY_ADMIN;
        uint256[] memory values = new uint256[](1);
        bytes[] memory payloads = new bytes[](1);
        payloads[0] = abi.encodeCall(
            ProxyAdmin.upgradeAndCall,
            (ITransparentUpgradeableProxy(LP_PROXY), currentImplementation, "")
        );
        bytes32 salt = keccak256("centiiv-wave3-rehearsal");

        vm.prank(safe);
        timelock.scheduleBatch(targets, values, payloads, bytes32(0), salt, 2 hours);

        bytes32 operationId = timelock.hashOperationBatch(
            targets,
            values,
            payloads,
            bytes32(0),
            salt
        );
        assertTrue(timelock.isOperationPending(operationId));

        // Too early.
        vm.prank(safe);
        vm.expectRevert();
        timelock.executeBatch(targets, values, payloads, bytes32(0), salt);

        vm.warp(block.timestamp + 2 hours);
        vm.prank(safe);
        timelock.executeBatch(targets, values, payloads, bytes32(0), salt);

        // No-op: the implementation is unchanged, but the call went through the
        // timelock and the ProxyAdmin accepted it.
        assertEq(
            address(uint160(uint256(vm.load(LP_PROXY, IMPLEMENTATION_SLOT)))),
            currentImplementation
        );
        assertTrue(timelock.isOperationDone(operationId));
    }
}

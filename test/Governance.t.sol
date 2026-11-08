// SPDX-License-Identifier: UNLICENSED
// © 2026 Centiiv Technologies. All rights reserved.


pragma solidity ^0.8.20;

import "./CentiivTestBase.sol";
import "@openzeppelin/contracts/governance/TimelockController.sol";

contract LiquidityProviderV2 is LiquidityProvider {
    function version() external pure returns (string memory) {
        return "2.0.0";
    }
}

/// @notice Rehearsal for the Wave 3 topology. `admin1` stands in for the Safe;
///         the point is to prove the ownership chain and the 2-hour delay, not
///         Gnosis Safe signature collection.
contract GovernanceTest is CentiivTestBase {
    TimelockController internal timelock;

    uint256 internal constant MIN_DELAY = 2 hours;
    bytes32 internal constant SALT = keccak256("centiiv-governance-test");

    function setUp() public override {
        super.setUp();

        address[] memory proposers = new address[](1);
        proposers[0] = admin1;
        address[] memory executors = new address[](1);
        executors[0] = admin1;

        timelock = new TimelockController(MIN_DELAY, proposers, executors, address(0));
    }

    function _transferProxyAdminsToTimelock() internal {
        vm.startPrank(admin1);
        lpProxyAdmin.transferOwnership(address(timelock));
        lmProxyAdmin.transferOwnership(address(timelock));
        vm.stopPrank();
    }

    function _scheduleLpUpgrade(address implementation)
        internal
        view
        returns (address[] memory targets, uint256[] memory values, bytes[] memory payloads)
    {
        targets = new address[](1);
        targets[0] = address(lpProxyAdmin);
        values = new uint256[](1);
        payloads = new bytes[](1);
        payloads[0] = abi.encodeCall(
            ProxyAdmin.upgradeAndCall,
            (ITransparentUpgradeableProxy(address(lpProxy)), implementation, "")
        );
    }

    function _execute(
        address[] memory targets,
        uint256[] memory values,
        bytes[] memory payloads
    ) internal {
        vm.prank(admin1);
        timelock.executeBatch(targets, values, payloads, bytes32(0), SALT);
    }

    function testTimelockHasNoExternalAdmin() public view {
        assertEq(timelock.getMinDelay(), MIN_DELAY);
        assertTrue(timelock.hasRole(timelock.PROPOSER_ROLE(), admin1));
        assertTrue(timelock.hasRole(timelock.EXECUTOR_ROLE(), admin1));
        assertTrue(timelock.hasRole(timelock.CANCELLER_ROLE(), admin1));

        // admin = address(0): only the timelock administers itself, so any
        // delay/role change must itself wait out the delay.
        assertFalse(timelock.hasRole(timelock.DEFAULT_ADMIN_ROLE(), admin1));
        assertTrue(timelock.hasRole(timelock.DEFAULT_ADMIN_ROLE(), address(timelock)));
    }

    function testProxyAdminOwnershipMovesToTimelock() public {
        _transferProxyAdminsToTimelock();

        assertEq(lpProxyAdmin.owner(), address(timelock));
        assertEq(lmProxyAdmin.owner(), address(timelock));
    }

    function testDirectUpgradeRevertsAfterOwnershipTransfer() public {
        _transferProxyAdminsToTimelock();

        LiquidityProviderV2 next = new LiquidityProviderV2();

        vm.prank(admin1);
        vm.expectRevert();
        lpProxyAdmin.upgradeAndCall(
            ITransparentUpgradeableProxy(address(lpProxy)),
            address(next),
            ""
        );
    }

    function testUpgradeWaitsForTheDelay() public {
        _transferProxyAdminsToTimelock();
        LiquidityProviderV2 next = new LiquidityProviderV2();

        (
            address[] memory targets,
            uint256[] memory values,
            bytes[] memory payloads
        ) = _scheduleLpUpgrade(address(next));

        vm.prank(admin1);
        timelock.scheduleBatch(targets, values, payloads, bytes32(0), SALT, MIN_DELAY);

        // Too early.
        vm.prank(admin1);
        vm.expectRevert();
        timelock.executeBatch(targets, values, payloads, bytes32(0), SALT);

        vm.warp(block.timestamp + MIN_DELAY);
        _execute(targets, values, payloads);

        assertEq(LiquidityProviderV2(address(lpProxy)).version(), "2.0.0");
    }

    function testNonProposerCannotSchedule() public {
        address[] memory targets = new address[](0);
        uint256[] memory values = new uint256[](0);
        bytes[] memory payloads = new bytes[](0);

        vm.prank(nonAdmin);
        vm.expectRevert();
        timelock.scheduleBatch(targets, values, payloads, bytes32(0), SALT, MIN_DELAY);
    }

    function testAdmin1RotationRequiresTheNewSigner() public {
        address newSafe = address(0x5AFE);

        vm.prank(admin1);
        lm.transferAdmin1(newSafe);
        assertEq(lm.pendingAdmin1(), newSafe);

        // The old admin cannot complete the rotation.
        vm.prank(admin1);
        vm.expectRevert(NoPendingAdminLM.selector);
        lm.acceptAdmin1();

        vm.prank(newSafe);
        lm.acceptAdmin1();
        assertEq(lm.admin1(), newSafe);

        // Pause is now a Safe-only (quorum) action.
        vm.prank(admin1);
        vm.expectRevert(UnauthorizedLM.selector);
        lm.pause();

        vm.prank(newSafe);
        lm.pause();
        assertTrue(lm.paused());
    }
}

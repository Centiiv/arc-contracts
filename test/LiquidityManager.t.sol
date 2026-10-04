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
import "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import "@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol";

contract LiquidityManagerV2 is LiquidityManager {
    function version() external pure returns (string memory) {
        return "2.0.0";
    }
}

contract LiquidityManagerTest is Test {
    LiquidityManager public lm;
    LiquidityManagerV2 public lmV2;
    ProxyAdmin public proxyAdmin;
    TransparentUpgradeableProxy public lmProxy;

    address public admin1 = address(0xA1);
    address public admin2 = address(0xA2);
    address public treasury = address(0xB1);
    address public relayer = address(0xB2);
    address public newAdmin = address(0xC1);
    address public nonAdmin = address(0xD1);

    bytes32 constant ADMIN_SLOT = 0xb53127684a568b3173ae13b9f8a6016e243e63b6e8ee1178d6a717850b5d6103;

    function setUp() public {
        LiquidityManager lmImpl = new LiquidityManager();
        bytes memory init = abi.encodeCall(
            LiquidityManager.initialize,
            (admin1, admin2, treasury, relayer)
        );
        lmProxy = new TransparentUpgradeableProxy(address(lmImpl), admin1, init);
        address proxyAdminAddr;
        bytes32 slotValue = vm.load(address(lmProxy), ADMIN_SLOT);
        assembly { proxyAdminAddr := slotValue }
        proxyAdmin = ProxyAdmin(proxyAdminAddr);
        lm = LiquidityManager(address(lmProxy));
    }

    function testInitialize() public view {
        assertEq(lm.getAdmin1(), admin1);
        assertEq(lm.getAdmin2(), admin2);
        assertEq(lm.getTreasuryAddress(), treasury);
        assertEq(lm.getRelayerAddress(), relayer);
        assertFalse(lm.paused());
    }

    function testInitializeRevertsIfAlreadyInitialized() public {
        vm.expectRevert();
        vm.prank(admin1);
        lm.initialize(admin1, admin2, treasury, relayer);
    }

    function testInitializeRevertsIfAdminsEqual() public {
        LiquidityManager lmImpl = new LiquidityManager();
        bytes memory init = abi.encodeCall(
            LiquidityManager.initialize,
            (admin1, admin1, treasury, relayer)
        );

        vm.expectRevert(AdminSlotConflictLM.selector);
        new TransparentUpgradeableProxy(address(lmImpl), admin1, init);
    }

    function testPause() public {
        vm.prank(admin1);
        lm.pause();
        assertTrue(lm.paused());
    }

    function testUnpause() public {
        vm.prank(admin1);
        lm.pause();
        vm.prank(admin2);
        lm.unpause();
        assertFalse(lm.paused());
    }

    function testPauseRevertsIfNonAdmin() public {
        vm.prank(nonAdmin);
        vm.expectRevert();
        lm.pause();
    }

    function testUnpauseRevertsIfNonAdmin() public {
        vm.prank(admin1);
        lm.pause();
        vm.prank(nonAdmin);
        vm.expectRevert();
        lm.unpause();
    }

    function testTransferAdmin1() public {
        vm.prank(admin1);
        lm.transferAdmin1(newAdmin);
        assertEq(lm.pendingAdmin1(), newAdmin);
    }

    function testAcceptAdmin1() public {
        vm.prank(admin1);
        lm.transferAdmin1(newAdmin);
        vm.prank(newAdmin);
        lm.acceptAdmin1();
        assertEq(lm.getAdmin1(), newAdmin);
    }

    function testTransferAdmin1RevertsIfNotAdmin1() public {
        vm.prank(nonAdmin);
        vm.expectRevert();
        lm.transferAdmin1(newAdmin);
    }

    function testTransferAdmin1RevertsIfConflict() public {
        vm.prank(admin1);
        vm.expectRevert();
        lm.transferAdmin1(admin2);
    }

    function testTransferAdmin1RevertsIfSame() public {
        vm.prank(admin1);
        vm.expectRevert();
        lm.transferAdmin1(admin1);
    }

    function testAcceptAdmin1RevertsIfNoPending() public {
        vm.prank(newAdmin);
        vm.expectRevert();
        lm.acceptAdmin1();
    }

    function testAcceptAdmin1RevertsIfNotPending() public {
        vm.prank(admin1);
        lm.transferAdmin1(newAdmin);
        vm.prank(nonAdmin);
        vm.expectRevert();
        lm.acceptAdmin1();
    }

    function testAcceptAdmin1RevertsIfPendingIsAdmin2() public {
        vm.prank(admin1);
        lm.transferAdmin1(newAdmin);
        assertEq(lm.pendingAdmin1(), newAdmin);

        vm.prank(admin2);
        lm.transferAdmin2(newAdmin);
        vm.prank(newAdmin);
        lm.acceptAdmin2();
        assertEq(lm.getAdmin2(), newAdmin);

        vm.prank(newAdmin);
        vm.expectRevert(AdminSlotConflictLM.selector);
        lm.acceptAdmin1();

        assertEq(lm.getAdmin1(), admin1);
        assertEq(lm.pendingAdmin1(), newAdmin);
    }

    function testTransferAdmin2() public {
        vm.prank(admin2);
        lm.transferAdmin2(newAdmin);
        assertEq(lm.pendingAdmin2(), newAdmin);
    }

    function testAcceptAdmin2() public {
        vm.prank(admin2);
        lm.transferAdmin2(newAdmin);
        vm.prank(newAdmin);
        lm.acceptAdmin2();
        assertEq(lm.getAdmin2(), newAdmin);
    }

    function testTransferAdmin2RevertsIfNotAdmin2() public {
        vm.prank(nonAdmin);
        vm.expectRevert();
        lm.transferAdmin2(newAdmin);
    }

    function testTransferAdmin2RevertsIfConflict() public {
        vm.prank(admin2);
        vm.expectRevert();
        lm.transferAdmin2(admin1);
    }

    function testAcceptAdmin2RevertsIfPendingIsAdmin1() public {
        vm.prank(admin2);
        lm.transferAdmin2(newAdmin);
        assertEq(lm.pendingAdmin2(), newAdmin);

        vm.prank(admin1);
        lm.transferAdmin1(newAdmin);
        vm.prank(newAdmin);
        lm.acceptAdmin1();
        assertEq(lm.getAdmin1(), newAdmin);

        vm.prank(newAdmin);
        vm.expectRevert(AdminSlotConflictLM.selector);
        lm.acceptAdmin2();

        assertEq(lm.getAdmin2(), admin2);
        assertEq(lm.pendingAdmin2(), newAdmin);
    }

    function testUpdateTreasury() public {
        address newTreasury = address(0xE1);
        vm.prank(admin1);
        lm.updateProtocolAddress(0, newTreasury);
        assertEq(lm.getTreasuryAddress(), newTreasury);
    }

    function testUpdateRelayer() public {
        address newRelayer = address(0xE2);
        vm.prank(admin1);
        lm.updateProtocolAddress(1, newRelayer);
        assertEq(lm.getRelayerAddress(), newRelayer);
    }

    function testUpdateProtocolAddressRevertsIfZero() public {
        vm.prank(admin1);
        vm.expectRevert();
        lm.updateProtocolAddress(0, address(0));
    }

    function testUpdateProtocolAddressRevertsIfSame() public {
        vm.prank(admin1);
        vm.expectRevert();
        lm.updateProtocolAddress(0, treasury);
    }

    function testUpdateProtocolAddressRevertsIfNonAdmin() public {
        vm.prank(nonAdmin);
        vm.expectRevert();
        lm.updateProtocolAddress(0, address(0xE1));
    }

    function testUpdateProtocolAddressRevertsIfInvalidType() public {
        vm.prank(admin1);
        vm.expectRevert();
        lm.updateProtocolAddress(99, address(0xE1));
    }

    function testUpgrade() public {
        lmV2 = new LiquidityManagerV2();

        vm.prank(admin1);
        proxyAdmin.upgradeAndCall(ITransparentUpgradeableProxy(address(lmProxy)), address(lmV2), "");

        LiquidityManager upgraded = LiquidityManager(address(lmProxy));
        assertEq(upgraded.getAdmin1(), admin1);
        assertEq(upgraded.getTreasuryAddress(), treasury);
        assertEq(upgraded.getRelayerAddress(), relayer);
    }

    function testUpgradePreservesState() public {
        vm.prank(admin1);
        lm.pause();

        lmV2 = new LiquidityManagerV2();

        vm.prank(admin1);
        proxyAdmin.upgradeAndCall(ITransparentUpgradeableProxy(address(lmProxy)), address(lmV2), "");

        LiquidityManager upgraded = LiquidityManager(address(lmProxy));
        assertTrue(upgraded.paused());
    }

    function testUpgradeRevertsIfNotProxyAdmin() public {
        lmV2 = new LiquidityManagerV2();

        vm.prank(nonAdmin);
        vm.expectRevert();
        ITransparentUpgradeableProxy(address(lmProxy)).upgradeToAndCall(address(lmV2), "");
    }

    function testUpgradeToNewVersion() public {
        lmV2 = new LiquidityManagerV2();

        vm.prank(admin1);
        proxyAdmin.upgradeAndCall(ITransparentUpgradeableProxy(address(lmProxy)), address(lmV2), "");

        LiquidityManagerV2 upgraded = LiquidityManagerV2(address(lmProxy));
        assertEq(upgraded.version(), "2.0.0");
    }
}

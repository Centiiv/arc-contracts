// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../../src/LiquidityManager.sol";

contract LiquidityManagerTest is Test {
    LiquidityManager public lm;

    address public admin1 = address(0xA1);
    address public admin2 = address(0xA2);
    address public treasury = address(0xB1);
    address public relayer = address(0xB2);
    address public newAdmin = address(0xC1);
    address public nonAdmin = address(0xD1);

    function setUp() public {
        vm.prank(admin1);
        lm = new LiquidityManager();
        vm.prank(admin1);
        lm.initialize(admin1, admin2, treasury, relayer);
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
}

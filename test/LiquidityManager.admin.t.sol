// SPDX-License-Identifier: UNLICENSED
// © 2026 Centiiv Technologies. All rights reserved.


pragma solidity ^0.8.20;

import "./CentiivTestBase.sol";

/// @notice Rotation symmetry and event coverage for `LiquidityManager`. The
///         audit mutation run found the `acceptAdmin2` pending gate untested.
contract LiquidityManagerAdminTest is CentiivTestBase {
    address internal newAdmin = address(0xE9);

    // ------------------------------------------------------- acceptAdmin2 gate

    function testAcceptAdmin2RevertsIfNoPendingAdmin() public {
        vm.prank(newAdmin);
        vm.expectRevert(NoPendingAdminLM.selector);
        lm.acceptAdmin2();
    }

    function testAcceptAdmin2RevertsIfCallerIsNotPendingAdmin() public {
        vm.prank(admin2);
        lm.transferAdmin2(newAdmin);

        vm.prank(nonAdmin);
        vm.expectRevert(NoPendingAdminLM.selector);
        lm.acceptAdmin2();

        assertEq(lm.admin2(), admin2);
        assertEq(lm.pendingAdmin2(), newAdmin);
    }

    function testAcceptAdmin2SucceedsForPendingAdmin() public {
        vm.prank(admin2);
        lm.transferAdmin2(newAdmin);

        vm.prank(newAdmin);
        lm.acceptAdmin2();

        assertEq(lm.admin2(), newAdmin);
        assertEq(lm.pendingAdmin2(), address(0));
    }

    function testAcceptAdmin1RevertsIfNoPendingAdmin() public {
        vm.prank(newAdmin);
        vm.expectRevert(NoPendingAdminLM.selector);
        lm.acceptAdmin1();
    }

    function testAcceptAdmin1RevertsIfCallerIsNotPendingAdmin() public {
        vm.prank(admin1);
        lm.transferAdmin1(newAdmin);

        vm.prank(nonAdmin);
        vm.expectRevert(NoPendingAdminLM.selector);
        lm.acceptAdmin1();

        assertEq(lm.admin1(), admin1);
    }

    // ---------------------------------------------------------------- events

    function testTransferAdmin1EmitsProposal() public {
        vm.expectEmit(true, false, false, true);
        emit LiquidityManager.AdminTransferProposed(1, newAdmin);

        vm.prank(admin1);
        lm.transferAdmin1(newAdmin);
    }

    function testAcceptAdmin1EmitsTransfer() public {
        vm.prank(admin1);
        lm.transferAdmin1(newAdmin);

        vm.expectEmit(true, false, false, true);
        emit LiquidityManager.AdminTransferred(1, newAdmin);

        vm.prank(newAdmin);
        lm.acceptAdmin1();
    }

    function testTransferAdmin2EmitsProposal() public {
        vm.expectEmit(true, false, false, true);
        emit LiquidityManager.AdminTransferProposed(2, newAdmin);

        vm.prank(admin2);
        lm.transferAdmin2(newAdmin);
    }

    function testAcceptAdmin2EmitsTransfer() public {
        vm.prank(admin2);
        lm.transferAdmin2(newAdmin);

        vm.expectEmit(true, false, false, true);
        emit LiquidityManager.AdminTransferred(2, newAdmin);

        vm.prank(newAdmin);
        lm.acceptAdmin2();
    }

    function testPauseEmitsEvent() public {
        vm.expectEmit(false, false, false, true);
        emit LiquidityManager.PausedEvent();

        vm.prank(admin1);
        lm.pause();
    }

    function testUnpauseEmitsEvent() public {
        vm.prank(admin1);
        lm.pause();

        vm.expectEmit(false, false, false, true);
        emit LiquidityManager.UnpausedEvent();

        vm.prank(admin2);
        lm.unpause();
    }

    function testUpdateProtocolAddressEmitsEvent() public {
        address newTreasury = address(0xE1);

        vm.expectEmit(true, false, false, true);
        emit LiquidityManager.ProtocolAddressUpdated(0, newTreasury);

        vm.prank(admin1);
        lm.updateProtocolAddress(0, newTreasury);
    }

    // -------------------------------------------------------------- authority

    function testBothAdminsCanPause() public {
        vm.prank(admin2);
        lm.pause();
        assertTrue(lm.paused());

        vm.prank(admin1);
        lm.unpause();
        assertFalse(lm.paused());
    }

    function testBothAdminsCanUpdateTierFee() public {
        vm.prank(admin2);
        lp.updateTierFee(uint8(Types.ProtocolFees.Basic), 450);
        assertEq(lp.getTierFee(uint8(Types.ProtocolFees.Basic)), 450);

        vm.prank(admin1);
        lp.updateTierFee(uint8(Types.ProtocolFees.Basic), 400);
        assertEq(lp.getTierFee(uint8(Types.ProtocolFees.Basic)), 400);
    }

    function testNonAdminCannotRotateAdmin2() public {
        vm.prank(nonAdmin);
        vm.expectRevert(UnauthorizedLM.selector);
        lm.transferAdmin2(newAdmin);
    }

    function testNewAdmin2GainsOperationalAuthority() public {
        vm.prank(admin2);
        lm.transferAdmin2(newAdmin);
        vm.prank(newAdmin);
        lm.acceptAdmin2();

        vm.prank(newAdmin);
        lm.pause();
        assertTrue(lm.paused());
    }
}

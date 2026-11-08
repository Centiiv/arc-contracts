// SPDX-License-Identifier: UNLICENSED
// © 2026 Centiiv Technologies. All rights reserved.


pragma solidity ^0.8.20;

import "./CentiivTestBase.sol";

/// @notice Mutation coverage for `LiquidityManager.initialize` validation
///         branches, which the audit's mutation run flagged as a blind spot.
contract LiquidityManagerInitializeTest is CentiivTestBase {
    function _deploy(
        address _admin1,
        address _admin2,
        address _treasury,
        address _relayer,
        address _usdc,
        address _eurc
    ) internal returns (TransparentUpgradeableProxy proxy, LiquidityManager deployed) {
        LiquidityManager impl = new LiquidityManager();
        bytes memory init = abi.encodeCall(
            LiquidityManager.initialize,
            (_admin1, _admin2, _treasury, _relayer, _usdc, _eurc)
        );
        proxy = new TransparentUpgradeableProxy(address(impl), _admin1, init);
        deployed = LiquidityManager(address(proxy));
    }

    function testInitializeSetsAllRoles() public view {
        assertEq(lm.admin1(), admin1);
        assertEq(lm.admin2(), admin2);
        assertEq(lm.treasury(), treasury);
        assertEq(lm.relayer(), relayer);
        assertFalse(lm.paused());
        assertEq(lm.pendingAdmin1(), address(0));
        assertEq(lm.pendingAdmin2(), address(0));
    }

    function testInitializeSeedsUsdcAndEurc() public view {
        assertTrue(lm.isTokenSupported(address(usdc)));
        assertTrue(lm.isTokenSupported(address(eurc)));
    }

    function testInitializeRevertsIfAdmin1Zero() public {
        LiquidityManager impl = new LiquidityManager();
        bytes memory init = abi.encodeCall(
            LiquidityManager.initialize,
            (address(0), admin2, treasury, relayer, address(usdc), address(eurc))
        );

        vm.expectRevert(ZeroAddressLM.selector);
        new TransparentUpgradeableProxy(address(impl), admin1, init);
    }

    function testInitializeRevertsIfAdmin2Zero() public {
        LiquidityManager impl = new LiquidityManager();
        bytes memory init = abi.encodeCall(
            LiquidityManager.initialize,
            (admin1, address(0), treasury, relayer, address(usdc), address(eurc))
        );

        vm.expectRevert(ZeroAddressLM.selector);
        new TransparentUpgradeableProxy(address(impl), admin1, init);
    }

    function testInitializeRevertsIfTreasuryZero() public {
        LiquidityManager impl = new LiquidityManager();
        bytes memory init = abi.encodeCall(
            LiquidityManager.initialize,
            (admin1, admin2, address(0), relayer, address(usdc), address(eurc))
        );

        vm.expectRevert(ZeroAddressLM.selector);
        new TransparentUpgradeableProxy(address(impl), admin1, init);
    }

    function testInitializeRevertsIfRelayerZero() public {
        LiquidityManager impl = new LiquidityManager();
        bytes memory init = abi.encodeCall(
            LiquidityManager.initialize,
            (admin1, admin2, treasury, address(0), address(usdc), address(eurc))
        );

        vm.expectRevert(ZeroAddressLM.selector);
        new TransparentUpgradeableProxy(address(impl), admin1, init);
    }

    function testInitializeRevertsIfUsdcZero() public {
        LiquidityManager impl = new LiquidityManager();
        bytes memory init = abi.encodeCall(
            LiquidityManager.initialize,
            (admin1, admin2, treasury, relayer, address(0), address(eurc))
        );

        vm.expectRevert(ZeroAddressLM.selector);
        new TransparentUpgradeableProxy(address(impl), admin1, init);
    }

    function testInitializeRevertsIfAdminsEqual() public {
        LiquidityManager impl = new LiquidityManager();
        bytes memory init = abi.encodeCall(
            LiquidityManager.initialize,
            (admin1, admin1, treasury, relayer, address(usdc), address(eurc))
        );

        vm.expectRevert(AdminSlotConflictLM.selector);
        new TransparentUpgradeableProxy(address(impl), admin1, init);
    }

    function testInitializeRevertsIfCalledTwice() public {
        vm.expectRevert();
        lm.initialize(admin1, admin2, treasury, relayer, address(usdc), address(eurc));
    }

    function testInitializeWithZeroEurcSeedsUsdcOnly() public {
        (, LiquidityManager deployed) =
            _deploy(admin1, admin2, treasury, relayer, address(usdc), address(0));

        assertTrue(deployed.isTokenSupported(address(usdc)));
        assertFalse(deployed.isTokenSupported(address(eurc)));
    }

    function testInitializeEmitsUsdcSupportedEvent() public {
        LiquidityManager impl = new LiquidityManager();
        bytes memory init = abi.encodeCall(
            LiquidityManager.initialize,
            (admin1, admin2, treasury, relayer, address(usdc), address(eurc))
        );

        vm.expectEmit(true, false, false, true);
        emit LiquidityManager.TokenSupportedUpdated(address(usdc), true);

        vm.expectEmit(true, false, false, true);
        emit LiquidityManager.TokenSupportedUpdated(address(eurc), true);

        new TransparentUpgradeableProxy(address(impl), admin1, init);
    }
}

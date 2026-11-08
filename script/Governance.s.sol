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
import "../src/LiquidityManager.sol";
import "../src/LiquidityProvider.sol";
import "@openzeppelin/contracts/governance/TimelockController.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol";
import "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";

/// @notice Wave 3 governance migration (see GOVERNANCE_MIGRATION.md).
///
///         Target topology:
///
///             Safe (2-of-3)
///               └── TimelockController (2h)
///                     └── ProxyAdmin (LM) ──> LiquidityManager proxy
///                     └── ProxyAdmin (LP) ──> LiquidityProvider proxy
///
///         The timelock is deployed with `admin = address(0)`. OpenZeppelin
///         still grants DEFAULT_ADMIN_ROLE to the timelock itself, so every
///         later role or delay change must itself pass the 2-hour delay.
///         There is no external admin key to renounce.
///
///         Foundry cannot sign Gnosis Safe transactions. The `print*` helpers
///         emit the exact calldata to paste into Safe{Wallet}'s Transaction
///         Builder; `run()` only deploys the timelock.
contract GovernanceScript is Script {
    uint256 internal constant DEFAULT_MIN_DELAY = 2 hours;

    function run() external returns (TimelockController timelock) {
        address safe = vm.envAddress("SAFE_ADDRESS");
        uint256 minDelay = vm.envOr("TIMELOCK_MIN_DELAY", DEFAULT_MIN_DELAY);

        address[] memory proposers = new address[](1);
        proposers[0] = safe;
        address[] memory executors = new address[](1);
        executors[0] = safe;

        vm.startBroadcast(vm.envUint("PRIVATE_KEY"));
        timelock = new TimelockController(minDelay, proposers, executors, address(0));
        vm.stopBroadcast();

        console.log("TimelockController:", address(timelock));
        console.log("  minDelay (seconds):", minDelay);
        console.log("  PROPOSER/CANCELLER/EXECUTOR: Safe", safe);
        console.log("  DEFAULT_ADMIN_ROLE: timelock itself (no external admin)");
        console.log("");
        console.log("Next: move both ProxyAdmins from the original admin1 EOA to the Safe.");
        console.log("Run:  forge script script/Governance.s.sol:GovernanceScript --sig printProxyAdminTransfers");
    }

    /// @notice Transactions 1 and 2, sent **by the original admin1 EOA** as a
    ///         direct transaction (not through the Safe). The Safe cannot drive
    ///         a ProxyAdmin it does not own yet.
    function printProxyAdminTransfers() external view {
        address lmProxyAdmin = vm.envAddress("LM_PROXY_ADMIN");
        address lpProxyAdmin = vm.envAddress("LP_PROXY_ADMIN");
        address safe = vm.envAddress("SAFE_ADDRESS");

        console.log("=== EOA transaction 1/2: LM ProxyAdmin -> Safe ===");
        console.log("from: original admin1 EOA");
        console.log("to:  ", lmProxyAdmin);
        console.log("value: 0");
        console.log("data:");
        console.logBytes(abi.encodeCall(Ownable.transferOwnership, (safe)));

        console.log("");
        console.log("=== EOA transaction 2/2: LP ProxyAdmin -> Safe ===");
        console.log("from: original admin1 EOA");
        console.log("to:  ", lpProxyAdmin);
        console.log("value: 0");
        console.log("data:");
        console.logBytes(abi.encodeCall(Ownable.transferOwnership, (safe)));

        console.log("");
        console.log("Do this before the key can be lost. Then prove Safe control.");
    }

    /// @notice Safe transactions 3 and 4: ProxyAdmin ownership moves from the
    ///         Safe to the timelock. After these execute, every upgrade waits.
    function printTimelockTransfers() external view {
        address lmProxyAdmin = vm.envAddress("LM_PROXY_ADMIN");
        address lpProxyAdmin = vm.envAddress("LP_PROXY_ADMIN");
        address timelock = vm.envAddress("TIMELOCK");

        console.log("=== Safe transaction 3/4: LM ProxyAdmin -> Timelock ===");
        console.log("to:  ", lmProxyAdmin);
        console.log("value: 0");
        console.log("data:");
        console.logBytes(abi.encodeCall(Ownable.transferOwnership, (timelock)));

        console.log("");
        console.log("=== Safe transaction 4/4: LP ProxyAdmin -> Timelock ===");
        console.log("to:  ", lpProxyAdmin);
        console.log("value: 0");
        console.log("data:");
        console.logBytes(abi.encodeCall(Ownable.transferOwnership, (timelock)));
    }

    /// @notice Safe no-op upgrade, used to prove the Safe can drive the
    ///         ProxyAdmin before ownership moves to the timelock. Set
    ///         `PROXY_ADMIN`, `PROXY` and `IMPLEMENTATION` (the current one).
    function printNoopUpgrade() external view {
        address proxyAdmin = vm.envAddress("PROXY_ADMIN");
        address proxy = vm.envAddress("PROXY");
        address implementation = vm.envAddress("IMPLEMENTATION");

        console.log("=== Safe transaction: no-op upgrade (prove control) ===");
        console.log("to:  ", proxyAdmin);
        console.log("value: 0");
        console.log("data:");
        console.logBytes(
            abi.encodeCall(
                ProxyAdmin.upgradeAndCall,
                (ITransparentUpgradeableProxy(proxy), implementation, "")
            )
        );
        console.log("Expect an Upgraded event with the unchanged implementation.");
    }

    /// @notice Admin rotation is two transactions by two different signers.
    ///         1. current admin1 EOA calls transferAdmin1(Safe)
    ///         2. the Safe calls acceptAdmin1()
    function printAdmin1Rotation() external view {
        address lmProxy = vm.envAddress("LM_PROXY");
        address safe = vm.envAddress("SAFE_ADDRESS");

        console.log("=== Step 1: current admin1 EOA (direct transaction) ===");
        console.log("to:  ", lmProxy);
        console.log("value: 0");
        console.log("data:");
        console.logBytes(abi.encodeCall(LiquidityManager.transferAdmin1, (safe)));

        console.log("");
        console.log("=== Step 2: Safe transaction ===");
        console.log("to:  ", lmProxy);
        console.log("value: 0");
        console.log("data:");
        console.logBytes(abi.encodeCall(LiquidityManager.acceptAdmin1, ()));
    }

    /// @notice Example of a real timelocked upgrade. Run from the Safe:
    ///         `TIMELOCK`, `PROXY`, `IMPLEMENTATION` and `SALT` come from env.
    function printUpgradeSchedule() external view {
        address timelockAddr = vm.envAddress("TIMELOCK");
        address proxy = vm.envAddress("PROXY");
        address implementation = vm.envAddress("IMPLEMENTATION");
        bytes32 salt = vm.envOr("SALT", keccak256("centiiv-upgrade"));

        TimelockController timelock = TimelockController(payable(timelockAddr));
        ProxyAdmin proxyAdmin = ProxyAdmin(vm.envAddress("PROXY_ADMIN"));

        address[] memory targets = new address[](1);
        targets[0] = address(proxyAdmin);
        uint256[] memory values = new uint256[](1);
        bytes[] memory payloads = new bytes[](1);
        payloads[0] = abi.encodeCall(
            ProxyAdmin.upgradeAndCall,
            (ITransparentUpgradeableProxy(proxy), implementation, "")
        );

        bytes32 id = timelock.hashOperationBatch(targets, values, payloads, bytes32(0), salt);

        console.log("=== Safe transaction: schedule upgrade ===");
        console.log("to:  ", timelockAddr);
        console.log("value: 0");
        console.log("data:");
        console.logBytes(
            abi.encodeCall(
                TimelockController.scheduleBatch,
                (targets, values, payloads, bytes32(0), salt, timelock.getMinDelay())
            )
        );
        console.log("");
        console.log("Operation id:");
        console.logBytes32(id);
        console.log("Earliest execution (unix):");
        console.log(block.timestamp + timelock.getMinDelay());
    }

    /// @notice Read-only checklist. Run after each migration step.
    function verify() external view {
        address lmProxyAdmin = vm.envAddress("LM_PROXY_ADMIN");
        address lpProxyAdmin = vm.envAddress("LP_PROXY_ADMIN");
        address lmProxy = vm.envAddress("LM_PROXY");
        address safe = vm.envAddress("SAFE_ADDRESS");

        address lmOwner = ProxyAdmin(lmProxyAdmin).owner();
        address lpOwner = ProxyAdmin(lpProxyAdmin).owner();
        address admin1 = LiquidityManager(lmProxy).admin1();

        console.log("LM ProxyAdmin owner:", lmOwner);
        console.log("LP ProxyAdmin owner:", lpOwner);
        console.log("LiquidityManager admin1:", admin1);
        console.log("Expected Safe:", safe);

        address timelock = vm.envOr("TIMELOCK", address(0));
        if (timelock != address(0)) {
            TimelockController controller = TimelockController(payable(timelock));
            console.log("");
            console.log("Timelock minDelay:", controller.getMinDelay());
            console.log(
                "Safe has PROPOSER_ROLE:",
                controller.hasRole(controller.PROPOSER_ROLE(), safe)
            );
            console.log(
                "Safe has EXECUTOR_ROLE:",
                controller.hasRole(controller.EXECUTOR_ROLE(), safe)
            );
            console.log(
                "Safe has DEFAULT_ADMIN_ROLE (must be false):",
                controller.hasRole(controller.DEFAULT_ADMIN_ROLE(), safe)
            );
        }
    }
}

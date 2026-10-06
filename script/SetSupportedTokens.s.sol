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

/// @notice Seeds LiquidityManager's supported-token registry on an ALREADY
///         deployed proxy (initialize() cannot re-run). Must be executed by
///         admin1 or admin2, and — when gating LiquidityProvider.createOrder —
///         BEFORE the new LiquidityProvider implementation goes live.
///
/// Required env:  LM_PROXY, USDC, PRIVATE_KEY (admin key)
/// Optional env:  EURC (skipped when unset/zero)
contract SetSupportedTokens is Script {
    function run() external {
        address lmProxyAddr = vm.envAddress("LM_PROXY");
        address usdc = vm.envAddress("USDC");
        address eurc = vm.envOr("EURC", address(0));

        LiquidityManager lm = LiquidityManager(lmProxyAddr);

        vm.startBroadcast(vm.envUint("PRIVATE_KEY"));

        lm.setTokenSupported(usdc, true);
        if (eurc != address(0)) {
            lm.setTokenSupported(eurc, true);
        }

        vm.stopBroadcast();

        console.log("LiquidityManager token registry seeded on:", lmProxyAddr);
        console.log("  supported: USDC", usdc);
        if (eurc != address(0)) {
            console.log("  supported: EURC", eurc);
        }
    }
}

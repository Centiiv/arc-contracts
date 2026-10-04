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
import "@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol";
import "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";

contract UpgradeScript is Script {
    function run() external {
        address lmProxyAdminAddr = vm.envAddress("LM_PROXY_ADMIN");
        address lpProxyAdminAddr = vm.envAddress("LP_PROXY_ADMIN");
        address lmProxyAddr = vm.envAddress("LM_PROXY");
        address lpProxyAddr = vm.envAddress("LP_PROXY");

        vm.startBroadcast(vm.envUint("PRIVATE_KEY"));

        LiquidityManager lmImpl = new LiquidityManager();
        LiquidityProvider lpImpl = new LiquidityProvider();

        vm.stopBroadcast();

        console.log("New LiquidityManager implementation:", address(lmImpl));
        console.log("New LiquidityProvider implementation:", address(lpImpl));

        ProxyAdmin lmProxyAdmin = ProxyAdmin(lmProxyAdminAddr);
        ProxyAdmin lpProxyAdmin = ProxyAdmin(lpProxyAdminAddr);

        vm.startBroadcast(vm.envUint("PRIVATE_KEY"));

        lmProxyAdmin.upgradeAndCall(
            ITransparentUpgradeableProxy(lmProxyAddr),
            address(lmImpl),
            ""
        );

        lpProxyAdmin.upgradeAndCall(
            ITransparentUpgradeableProxy(lpProxyAddr),
            address(lpImpl),
            ""
        );

        vm.stopBroadcast();

        console.log("LiquidityManager proxy upgraded:", lmProxyAddr);
        console.log("LiquidityProvider proxy upgraded:", lpProxyAddr);
    }

    function runLM() external {
        address proxyAdminAddr = vm.envAddress("LM_PROXY_ADMIN");
        address lmProxyAddr = vm.envAddress("LM_PROXY");

        vm.startBroadcast(vm.envUint("PRIVATE_KEY"));

        LiquidityManager lmImpl = new LiquidityManager();
        ProxyAdmin(proxyAdminAddr).upgradeAndCall(
            ITransparentUpgradeableProxy(lmProxyAddr),
            address(lmImpl),
            ""
        );

        vm.stopBroadcast();

        console.log("LiquidityManager upgraded:", lmProxyAddr);
        console.log("New implementation:", address(lmImpl));
    }

    function runLP() external {
        address proxyAdminAddr = vm.envAddress("LP_PROXY_ADMIN");
        address lpProxyAddr = vm.envAddress("LP_PROXY");

        vm.startBroadcast(vm.envUint("PRIVATE_KEY"));

        LiquidityProvider lpImpl = new LiquidityProvider();
        ProxyAdmin(proxyAdminAddr).upgradeAndCall(
            ITransparentUpgradeableProxy(lpProxyAddr),
            address(lpImpl),
            ""
        );

        vm.stopBroadcast();

        console.log("LiquidityProvider upgraded:", lpProxyAddr);
        console.log("New implementation:", address(lpImpl));
    }
}

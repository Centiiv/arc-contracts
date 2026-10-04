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
import "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";

contract DeployScript is Script {
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address admin1 = vm.envAddress("ADMIN1");
        address admin2 = vm.envAddress("ADMIN2");
        address treasury = vm.envAddress("TREASURY");
        address relayer = vm.envAddress("RELAYER");
        address usdc = vm.envAddress("USDC");

        vm.startBroadcast(deployerPrivateKey);

        LiquidityManager lmImpl = new LiquidityManager();
        LiquidityProvider lpImpl = new LiquidityProvider();

        bytes memory lmInit = abi.encodeCall(
            LiquidityManager.initialize,
            (admin1, admin2, treasury, relayer)
        );
        TransparentUpgradeableProxy lmProxy = new TransparentUpgradeableProxy(
            address(lmImpl),
            admin1,
            lmInit
        );

        bytes memory lpInit = abi.encodeCall(
            LiquidityProvider.initialize,
            (usdc, address(lmProxy))
        );
        TransparentUpgradeableProxy lpProxy = new TransparentUpgradeableProxy(
            address(lpImpl),
            admin1,
            lpInit
        );

        vm.stopBroadcast();

        console.log("LiquidityManager implementation:", address(lmImpl));
        console.log("LiquidityManager proxy:         ", address(lmProxy));
        console.log("LiquidityProvider implementation:", address(lpImpl));
        console.log("LiquidityProvider proxy:         ", address(lpProxy));

        bytes32 ADMIN_SLOT = 0xb53127684a568b3173ae13b9f8a6016e243e63b6e8ee1178d6a717850b5d6103;
        address lmProxyAdmin = address(uint160(uint256(vm.load(address(lmProxy), ADMIN_SLOT))));
        address lpProxyAdmin = address(uint160(uint256(vm.load(address(lpProxy), ADMIN_SLOT))));

        console.log("LM ProxyAdmin:                  ", lmProxyAdmin);
        console.log("LP ProxyAdmin:                  ", lpProxyAdmin);
        console.log("");
        console.log("Save these for .env.upgrade:");
        console.log("  LM_PROXY_ADMIN=%s", lmProxyAdmin);
        console.log("  LP_PROXY_ADMIN=%s", lpProxyAdmin);
        console.log("  LM_PROXY=%s", address(lmProxy));
        console.log("  LP_PROXY=%s", address(lpProxy));
    }
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "../src/LiquidityManager.sol";
import "../src/LiquidityProvider.sol";

contract DeployScript is Script {
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address admin1 = vm.envAddress("ADMIN1");
        address admin2 = vm.envAddress("ADMIN2");
        address treasury = vm.envAddress("TREASURY");
        address relayer = vm.envAddress("RELAYER");
        address usdc = vm.envAddress("USDC");

        vm.startBroadcast(deployerPrivateKey);

        LiquidityManager lm = new LiquidityManager();
        lm.initialize(admin1, admin2, treasury, relayer);

        LiquidityProvider lp = new LiquidityProvider();
        lp.initialize(usdc, address(lm));

        vm.stopBroadcast();

        console.log("LiquidityManager deployed at:", address(lm));
        console.log("LiquidityProvider deployed at:", address(lp));
    }
}

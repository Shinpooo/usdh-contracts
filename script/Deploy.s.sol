// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import {Script, console2} from "forge-std/Script.sol";
import {USDHVault} from "../src/USDHVault.sol";

contract DeployScript is Script {
    function setUp() public {}

    function run() public {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        
        vm.startBroadcast(deployerPrivateKey);
        
        // Deploy the vault contract with constructor arguments
        USDHVault vault = new USDHVault(
            0x7b79995e5f793A07Bc00c21412e50Ecae098E7f9,  // weth
            0x694AA1769357215DE4FAC081bf1f309aDC325306,  // chainlink
            60,  // minCollateralRatio
            80,  // safeCollateralRatio
            500, // liquidationPenalty
            0x1D706ef5eA8630bac5c278bd6e2d2b7fa3489600   // treasury
        );
        
        console2.log("=== Deployment Info ===");
        console2.log("Network: Sepolia");
        console2.log("USDHVault deployed to:", address(vault));
        console2.log("====================");
        
        vm.stopBroadcast();
    }
} 
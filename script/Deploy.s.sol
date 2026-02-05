// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console} from "forge-std/Script.sol";
import {IERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {AxiomVault} from "../src/AxiomVault.sol";
import {EscrowFactory} from "../src/EscrowFactory.sol";
import {PitchRegistry} from "../src/PitchRegistry.sol";

/**
 * @title Deploy Script for Axiom Ventures Contracts
 * @dev Deploys all core infrastructure contracts to Base network
 */
contract Deploy is Script {
    // Base Mainnet USDC address
    address constant USDC_BASE_MAINNET = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    
    // Base Sepolia USDC address (for testing)
    address constant USDC_BASE_SEPOLIA = 0x036CbD53842c5426634e7929541eC2318f3dCF7e;
    
    // Safe multi-sig addresses (2/3 setup)
    address constant AXIOM_ADDRESS = 0x523Eff3dB03938eaa31a5a6FBd41E3B9d23edde5;
    address constant HARDWARE_WALLET = 0x0D9945F0a591094927df47DB12ACB1081cE9F0F6;
    address constant MELTED_VAULT = 0xcbC7E8A39A0Ec84d6B0e8e0dd98655F348ECD44F;
    
    // Initial configuration
    uint256 constant INITIAL_SUBMIT_FEE = 10e6; // $10 USDC (6 decimals)

    function run() public {
        uint256 deployerPrivateKey = vm.envUint("NET_PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);
        
        console.log("Deployer address:", deployer);
        console.log("Chain ID:", block.chainid);

        // Determine USDC address based on chain
        address usdcAddress;
        if (block.chainid == 8453) {
            usdcAddress = USDC_BASE_MAINNET;
            console.log("Deploying to Base Mainnet");
        } else if (block.chainid == 84532) {
            usdcAddress = USDC_BASE_SEPOLIA;
            console.log("Deploying to Base Sepolia");
        } else {
            revert("Unsupported chain ID");
        }
        
        console.log("USDC address:", usdcAddress);

        vm.startBroadcast(deployerPrivateKey);

        // Deploy AxiomVault
        console.log("\n=== Deploying AxiomVault ===");
        AxiomVault vault = new AxiomVault(
            IERC20(usdcAddress),
            deployer // Initial owner, will be transferred to Safe later
        );
        console.log("AxiomVault deployed at:", address(vault));

        // Deploy EscrowFactory
        console.log("\n=== Deploying EscrowFactory ===");
        EscrowFactory escrowFactory = new EscrowFactory(
            IERC20(usdcAddress),
            address(vault)
        );
        console.log("EscrowFactory deployed at:", address(escrowFactory));

        // Deploy PitchRegistry
        console.log("\n=== Deploying PitchRegistry ===");
        PitchRegistry pitchRegistry = new PitchRegistry(
            IERC20(usdcAddress),
            INITIAL_SUBMIT_FEE,
            deployer // Initial owner, will be transferred to Safe later
        );
        console.log("PitchRegistry deployed at:", address(pitchRegistry));

        vm.stopBroadcast();

        // Log deployment summary
        console.log("\n=== DEPLOYMENT SUMMARY ===");
        console.log("Network: ", _getNetworkName(block.chainid));
        console.log("USDC Token:", usdcAddress);
        console.log("Deployer:", deployer);
        console.log("\nContracts:");
        console.log("- AxiomVault:     ", address(vault));
        console.log("- EscrowFactory:  ", address(escrowFactory));
        console.log("- PitchRegistry:  ", address(pitchRegistry));
        console.log("\nNext Steps:");
        console.log("1. Transfer ownership of AxiomVault to Safe multi-sig");
        console.log("2. Transfer ownership of PitchRegistry to Safe multi-sig");
        console.log("3. Verify contracts on Basescan");
        console.log("4. Test deposit/withdraw flows");
        console.log("\nSafe Multi-sig addresses:");
        console.log("- Axiom:     ", AXIOM_ADDRESS);
        console.log("- Hardware:  ", HARDWARE_WALLET);
        console.log("- Melted:    ", MELTED_VAULT);
        
        if (block.chainid == 84532) {
            console.log("\nWARNING: This is TESTNET deployment. After testing, deploy to MAINNET.");
        } else {
            console.log("\nMAINNET deployment complete!");
        }

    }

    function _getNetworkName(uint256 chainId) internal pure returns (string memory) {
        if (chainId == 8453) return "Base Mainnet";
        if (chainId == 84532) return "Base Sepolia";
        return "Unknown";
    }
}
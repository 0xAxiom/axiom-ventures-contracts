// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";

import {AgentRegistry} from "../src/v2/AgentRegistry.sol";
import {DDAttestation} from "../src/v2/DDAttestation.sol";
import {InvestmentRouter} from "../src/v2/InvestmentRouter.sol";
import {FundTransparency} from "../src/v2/FundTransparency.sol";
import {PitchRegistry} from "../src/PitchRegistry.sol";
import {AxiomVault} from "../src/AxiomVault.sol";
import {EscrowFactory} from "../src/EscrowFactory.sol";

/**
 * @title DeployV2
 * @dev Deployment script for V2 infrastructure layer
 * @notice Deploys AgentRegistry, DDAttestation, InvestmentRouter, and FundTransparency
 * @author Axiom Ventures
 */
contract DeployV2 is Script {
    // V1 Contract addresses (Base mainnet)
    address constant PITCH_REGISTRY = 0xCB83fA753429870fc3E233A1175CB99e90BDE449;
    address constant ESCROW_FACTORY = 0xD33df145B5fEbc10d5cf3B359c724ba259bF7077;
    address constant AXIOM_VAULT = 0xaC40CC75f4227417B66EF7cD0CEf1dA439493255;
    
    // Configuration
    address constant MULTISIG_OWNER = 0x523Eff3dB03938eaa31a5a6FBd41E3B9d23edde5; // Axiom deployer
    uint256 constant INITIAL_REGISTRATION_FEE = 0; // Free registration for launch
    
    // Oracle addresses (to be authorized for DD attestations)
    address[] initialOracles = [
        0x1234567890123456789012345678901234567890, // Replace with actual oracle addresses
        0x2345678901234567890123456789012345678901
    ];

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        vm.startBroadcast(deployerPrivateKey);
        
        console.log("=== Deploying Axiom Ventures V2 Infrastructure ===");
        console.log("Deployer:", vm.addr(deployerPrivateKey));
        console.log("Owner (Multisig):", MULTISIG_OWNER);
        console.log("");
        
        // Deploy AgentRegistry
        console.log("1. Deploying AgentRegistry...");
        AgentRegistry agentRegistry = new AgentRegistry(MULTISIG_OWNER);
        console.log("   AgentRegistry deployed at:", address(agentRegistry));
        
        // Set registration fee if needed
        if (INITIAL_REGISTRATION_FEE > 0) {
            console.log("   Setting registration fee to:", INITIAL_REGISTRATION_FEE);
            // Note: This would need to be done by the multisig after deployment
            // agentRegistry.setRegistrationFee(INITIAL_REGISTRATION_FEE);
        }
        
        // Deploy DDAttestation
        console.log("2. Deploying DDAttestation...");
        DDAttestation ddAttestation = new DDAttestation(MULTISIG_OWNER);
        console.log("   DDAttestation deployed at:", address(ddAttestation));
        
        // Note: Oracle authorization would need to be done by multisig after deployment
        console.log("   Oracles to authorize (post-deployment):");
        for (uint i = 0; i < initialOracles.length; i++) {
            console.log("   -", initialOracles[i]);
        }
        
        // Deploy InvestmentRouter
        console.log("3. Deploying InvestmentRouter...");
        InvestmentRouter router = new InvestmentRouter(
            agentRegistry,
            ddAttestation,
            PitchRegistry(PITCH_REGISTRY),
            AxiomVault(AXIOM_VAULT),
            EscrowFactory(ESCROW_FACTORY),
            MULTISIG_OWNER
        );
        console.log("   InvestmentRouter deployed at:", address(router));
        
        // Deploy FundTransparency
        console.log("4. Deploying FundTransparency...");
        FundTransparency transparency = new FundTransparency(
            agentRegistry,
            ddAttestation,
            router,
            PitchRegistry(PITCH_REGISTRY),
            AxiomVault(AXIOM_VAULT),
            EscrowFactory(ESCROW_FACTORY)
        );
        console.log("   FundTransparency deployed at:", address(transparency));
        
        vm.stopBroadcast();
        
        console.log("");
        console.log("=== Deployment Summary ===");
        console.log("AgentRegistry:     ", address(agentRegistry));
        console.log("DDAttestation:     ", address(ddAttestation));
        console.log("InvestmentRouter:  ", address(router));
        console.log("FundTransparency:  ", address(transparency));
        console.log("");
        
        console.log("=== V1 Contract References ===");
        console.log("PitchRegistry:     ", PITCH_REGISTRY);
        console.log("EscrowFactory:     ", ESCROW_FACTORY);
        console.log("AxiomVault:        ", AXIOM_VAULT);
        console.log("");
        
        console.log("=== Post-Deployment Actions Required ===");
        console.log("1. Transfer ownership verification (all contracts should be owned by multisig)");
        console.log("2. Authorize oracles in DDAttestation:");
        for (uint i = 0; i < initialOracles.length; i++) {
            console.log("   ddAttestation.addOracle(%s)", initialOracles[i]);
        }
        if (INITIAL_REGISTRATION_FEE > 0) {
            console.log("3. Set registration fee: agentRegistry.setRegistrationFee(%s)", INITIAL_REGISTRATION_FEE);
        }
        console.log("4. Verify contract addresses in frontend/scripts");
        console.log("5. Test end-to-end pipeline on testnet first");
        console.log("");
        
        // Generate contract verification commands
        console.log("=== Contract Verification Commands ===");
        _printVerificationCommands(
            address(agentRegistry),
            address(ddAttestation),
            address(router),
            address(transparency)
        );
        
        // Generate frontend config
        console.log("=== Frontend Configuration ===");
        _printFrontendConfig(
            address(agentRegistry),
            address(ddAttestation),
            address(router),
            address(transparency)
        );
    }

    function _printVerificationCommands(
        address agentRegistry,
        address ddAttestation,
        address router,
        address transparency
    ) internal pure {
        console.log("forge verify-contract %s src/v2/AgentRegistry.sol:AgentRegistry \\", agentRegistry);
        console.log("  --constructor-args $(cast abi-encode \"constructor(address)\" %s) \\", MULTISIG_OWNER);
        console.log("  --chain-id 8453");
        console.log("");
        
        console.log("forge verify-contract %s src/v2/DDAttestation.sol:DDAttestation \\", ddAttestation);
        console.log("  --constructor-args $(cast abi-encode \"constructor(address)\" %s) \\", MULTISIG_OWNER);
        console.log("  --chain-id 8453");
        console.log("");
        
        console.log("forge verify-contract");
        console.log("  InvestmentRouter:", router);
        console.log("  --chain-id 8453");
        console.log("");
        
        console.log("forge verify-contract");
        console.log("  FundTransparency:", transparency);
        console.log("  --chain-id 8453");
    }

    function _printFrontendConfig(
        address agentRegistry,
        address ddAttestation,
        address router,
        address transparency
    ) internal pure {
        console.log("// V2 Contract Addresses (Base Mainnet)");
        console.log("export const CONTRACTS = {");
        console.log("  // V2 Contracts");
        console.log("  AGENT_REGISTRY: '%s',", agentRegistry);
        console.log("  DD_ATTESTATION: '%s',", ddAttestation);
        console.log("  INVESTMENT_ROUTER: '%s',", router);
        console.log("  FUND_TRANSPARENCY: '%s',", transparency);
        console.log("  // V1 Contracts");
        console.log("  PITCH_REGISTRY: '%s',", PITCH_REGISTRY);
        console.log("  ESCROW_FACTORY: '%s',", ESCROW_FACTORY);
        console.log("  AXIOM_VAULT: '%s',", AXIOM_VAULT);
        console.log("  // Token");
        console.log("  USDC: '0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913'");
        console.log("};");
    }

    // Helper function to deploy to testnet
    function deployToTestnet() external {
        uint256 deployerPrivateKey = vm.envUint("TESTNET_PRIVATE_KEY");
        vm.startBroadcast(deployerPrivateKey);
        
        address testOwner = vm.addr(deployerPrivateKey); // Use deployer as owner for testing
        
        console.log("=== Testnet Deployment ===");
        console.log("Deployer/Owner:", testOwner);
        
        // For testnet, we'd need to deploy mock V1 contracts or use different addresses
        // This is a simplified version for demonstration
        
        AgentRegistry agentRegistry = new AgentRegistry(testOwner);
        DDAttestation ddAttestation = new DDAttestation(testOwner);
        
        // Would need actual V1 testnet addresses here
        console.log("AgentRegistry (testnet):", address(agentRegistry));
        console.log("DDAttestation (testnet):", address(ddAttestation));
        
        vm.stopBroadcast();
    }
}
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console} from "forge-std/Script.sol";
import {IERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";

import {EscrowFactoryV2} from "../src/v2.1/EscrowFactoryV2.sol";
import {InvestmentRouterV2} from "../src/v2.1/InvestmentRouterV2.sol";
import {FundTransparencyV2} from "../src/v2.1/FundTransparencyV2.sol";

import {AgentRegistry} from "../src/v2/AgentRegistry.sol";
import {DDAttestation} from "../src/v2/DDAttestation.sol";
import {PitchRegistry} from "../src/PitchRegistry.sol";
import {AxiomVault} from "../src/AxiomVault.sol";
import {EscrowFactory} from "../src/EscrowFactory.sol";

/**
 * @title DeployV2_1
 * @dev Deployment script for Axiom Ventures V2.1 contract upgrades
 * @notice Deploys EscrowFactoryV2, InvestmentRouterV2, and FundTransparencyV2
 */
contract DeployV2_1 is Script {
    // Base mainnet addresses
    address public constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address public constant AXIOM_VAULT = 0xaC40CC75f4227417B66EF7cD0CEf1dA439493255;
    address public constant ESCROW_FACTORY_V1 = 0xD33df145B5fEbc10d5cf3B359c724ba259bF7077;
    address public constant PITCH_REGISTRY = 0xCB83fA753429870fc3E233A1175CB99e90BDE449;
    address public constant AGENT_REGISTRY = 0x28BC26cC963238A0Fb65Afa334cc84100287De31;
    address public constant DD_ATTESTATION = 0xAFB554111B26E2074aE686BaE77991fA5dcBe149;
    address public constant SAFE_MULTISIG = 0x5766f573Cc516E3CA0D05a4848EF048636008271;
    address public constant DEPLOYER = 0x523Eff3dB03938eaa31a5a6FBd41E3B9d23edde5;

    // Deployed contract addresses (will be set during deployment)
    EscrowFactoryV2 public escrowFactoryV2;
    InvestmentRouterV2 public investmentRouterV2;
    FundTransparencyV2 public fundTransparencyV2;

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("NET_PRIVATE_KEY");
        vm.startBroadcast(deployerPrivateKey);

        console.log("=== Axiom Ventures V2.1 Deployment ===");
        console.log("Deployer:", DEPLOYER);
        console.log("Safe Multisig:", SAFE_MULTISIG);
        console.log("Network: Base Mainnet");
        console.log("");

        // 1. Deploy EscrowFactoryV2
        console.log("1. Deploying EscrowFactoryV2...");
        escrowFactoryV2 = new EscrowFactoryV2(
            IERC20(USDC),
            SAFE_MULTISIG,  // escrowOwner (Safe will own created escrows)
            DEPLOYER        // initialOwner (deployer initially, will transfer to Safe)
        );
        console.log("   EscrowFactoryV2 deployed at:", address(escrowFactoryV2));

        // 2. Deploy InvestmentRouterV2
        console.log("2. Deploying InvestmentRouterV2...");
        investmentRouterV2 = new InvestmentRouterV2(
            AgentRegistry(AGENT_REGISTRY),
            DDAttestation(DD_ATTESTATION),
            PitchRegistry(PITCH_REGISTRY),
            AxiomVault(AXIOM_VAULT),
            escrowFactoryV2,
            DEPLOYER        // initialOwner (deployer initially, will transfer to Safe)
        );
        console.log("   InvestmentRouterV2 deployed at:", address(investmentRouterV2));

        // 3. Deploy FundTransparencyV2
        console.log("3. Deploying FundTransparencyV2...");
        fundTransparencyV2 = new FundTransparencyV2(
            AgentRegistry(AGENT_REGISTRY),
            DDAttestation(DD_ATTESTATION),
            investmentRouterV2,
            PitchRegistry(PITCH_REGISTRY),
            AxiomVault(AXIOM_VAULT),
            EscrowFactory(ESCROW_FACTORY_V1),
            escrowFactoryV2
        );
        console.log("   FundTransparencyV2 deployed at:", address(fundTransparencyV2));

        // 4. Configure EscrowFactoryV2 to authorize the router
        console.log("4. Configuring EscrowFactoryV2...");
        escrowFactoryV2.setRouter(address(investmentRouterV2));
        console.log("   Router authorized in EscrowFactoryV2");

        // 5. Transfer ownership to Safe multisig
        console.log("5. Transferring ownership to Safe...");
        escrowFactoryV2.transferOwnership(SAFE_MULTISIG);
        investmentRouterV2.transferOwnership(SAFE_MULTISIG);
        console.log("   Ownership transferred to Safe");

        vm.stopBroadcast();

        // Summary
        console.log("");
        console.log("=== Deployment Complete ===");
        console.log("EscrowFactoryV2:     ", address(escrowFactoryV2));
        console.log("InvestmentRouterV2:  ", address(investmentRouterV2));
        console.log("FundTransparencyV2:  ", address(fundTransparencyV2));
        console.log("");
        console.log("=== Configuration ===");
        console.log("- EscrowFactoryV2 creates escrows owned by Safe");
        console.log("- InvestmentRouterV2 authorized in EscrowFactoryV2");
        console.log("- Ownership transferred to Safe multisig");
        console.log("- FundTransparencyV2 reads from both V1 and V2 factories");
        console.log("");
        console.log("=== Next Steps ===");
        console.log("1. Verify contracts on Etherscan");
        console.log("2. Update frontend to use new contract addresses");
        console.log("3. Test funding flow with Safe multisig");
        console.log("4. Monitor gas usage and performance");

        // Verification info for manual verification
        console.log("");
        console.log("=== Verification Commands ===");
        console.log("forge verify-contract");
        console.log("  Address:", address(escrowFactoryV2));
        console.log("  Contract: src/v2.1/EscrowFactoryV2.sol:EscrowFactoryV2");
        console.log("  Use constructor args for USDC, SAFE, DEPLOYER");
        console.log("");
    }

    // Helper function to verify deployment succeeded
    function verifyDeployment() external view {
        require(address(escrowFactoryV2) != address(0), "EscrowFactoryV2 not deployed");
        require(address(investmentRouterV2) != address(0), "InvestmentRouterV2 not deployed");
        require(address(fundTransparencyV2) != address(0), "FundTransparencyV2 not deployed");
        
        // Verify configuration
        require(escrowFactoryV2.escrowOwner() == SAFE_MULTISIG, "EscrowFactoryV2 escrowOwner incorrect");
        require(escrowFactoryV2.owner() == SAFE_MULTISIG, "EscrowFactoryV2 owner incorrect");
        require(investmentRouterV2.owner() == SAFE_MULTISIG, "InvestmentRouterV2 owner incorrect");
        require(escrowFactoryV2.authorizedRouter() == address(investmentRouterV2), "Router not authorized");
        
        // Verify contract references
        require(address(investmentRouterV2.escrowFactory()) == address(escrowFactoryV2), "Router factory reference incorrect");
        require(address(fundTransparencyV2.escrowFactoryV2()) == address(escrowFactoryV2), "Transparency V2 factory reference incorrect");
        require(address(fundTransparencyV2.escrowFactoryV1()) == ESCROW_FACTORY_V1, "Transparency V1 factory reference incorrect");
        require(address(fundTransparencyV2.investmentRouter()) == address(investmentRouterV2), "Transparency router reference incorrect");
    }
}
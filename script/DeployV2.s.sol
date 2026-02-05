// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console} from "forge-std/Script.sol";
import {AgentRegistry} from "../src/v2/AgentRegistry.sol";
import {DDAttestation} from "../src/v2/DDAttestation.sol";
import {InvestmentRouter} from "../src/v2/InvestmentRouter.sol";
import {FundTransparency} from "../src/v2/FundTransparency.sol";
import {PitchRegistry} from "../src/PitchRegistry.sol";
import {AxiomVault} from "../src/AxiomVault.sol";
import {EscrowFactory} from "../src/EscrowFactory.sol";

contract DeployV2 is Script {
    // V1 contracts (deployed + verified on Base)
    address constant VAULT = 0xaC40CC75f4227417B66EF7cD0CEf1dA439493255;
    address constant ESCROW_FACTORY = 0xD33df145B5fEbc10d5cf3B359c724ba259bF7077;
    address constant PITCH_REGISTRY = 0xCB83fA753429870fc3E233A1175CB99e90BDE449;
    
    // Safe multi-sig (2/3) — final owner
    address constant SAFE = 0x5766f573Cc516E3CA0D05a4848EF048636008271;

    function run() external {
        uint256 deployerKey = vm.envUint("NET_PRIVATE_KEY");
        address deployer = vm.addr(deployerKey);
        
        console.log("Deployer:", deployer);
        console.log("Safe:", SAFE);
        
        vm.startBroadcast(deployerKey);

        // 1. AgentRegistry (owner = deployer initially, transfer to Safe after)
        AgentRegistry agentRegistry = new AgentRegistry(deployer);
        console.log("AgentRegistry:", address(agentRegistry));

        // 2. DDAttestation (owner = deployer initially)
        DDAttestation ddAttestation = new DDAttestation(deployer);
        console.log("DDAttestation:", address(ddAttestation));

        // 3. InvestmentRouter (needs all V1 + V2 addresses)
        InvestmentRouter investmentRouter = new InvestmentRouter(
            agentRegistry,
            ddAttestation,
            PitchRegistry(PITCH_REGISTRY),
            AxiomVault(VAULT),
            EscrowFactory(ESCROW_FACTORY),
            deployer
        );
        console.log("InvestmentRouter:", address(investmentRouter));

        // 4. FundTransparency (view-only, no owner)
        FundTransparency fundTransparency = new FundTransparency(
            agentRegistry,
            ddAttestation,
            investmentRouter,
            PitchRegistry(PITCH_REGISTRY),
            AxiomVault(VAULT),
            EscrowFactory(ESCROW_FACTORY)
        );
        console.log("FundTransparency:", address(fundTransparency));

        // 5. Transfer ownership to Safe
        agentRegistry.transferOwnership(SAFE);
        console.log("AgentRegistry ownership -> Safe");
        
        ddAttestation.transferOwnership(SAFE);
        console.log("DDAttestation ownership -> Safe");
        
        investmentRouter.transferOwnership(SAFE);
        console.log("InvestmentRouter ownership -> Safe");

        vm.stopBroadcast();

        // Summary
        console.log("\n=== V2 Deployment Summary ===");
        console.log("AgentRegistry:    ", address(agentRegistry));
        console.log("DDAttestation:    ", address(ddAttestation));
        console.log("InvestmentRouter: ", address(investmentRouter));
        console.log("FundTransparency: ", address(fundTransparency));
        console.log("All owned by Safe:", SAFE);
    }
}

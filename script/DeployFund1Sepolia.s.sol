// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console} from "forge-std/Script.sol";
import {AxiomVenturesFund1} from "../src/v4/AxiomVenturesFund1.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

contract DeployFund1Sepolia is Script {
    // Testnet addresses (using Axiom wallet for all roles in testnet)
    address constant SAFE = 0x523Eff3dB03938eaa31a5a6FBd41E3B9d23edde5;
    address constant METADATA_ADMIN = 0x523Eff3dB03938eaa31a5a6FBd41E3B9d23edde5;
    
    // Clanker Vault on Base Sepolia (using mainnet address for now, will need to verify)
    address constant CLANKER_VAULT = 0x8E845EAd15737bF71904A30BdDD3aEE76d6ADF6C;

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("NET_PRIVATE_KEY");
        
        vm.startBroadcast(deployerPrivateKey);

        // Deploy implementation
        AxiomVenturesFund1 implementation = new AxiomVenturesFund1();
        console.log("Implementation deployed at:", address(implementation));

        // Deploy proxy
        bytes memory initData = abi.encodeWithSelector(
            AxiomVenturesFund1.initialize.selector,
            SAFE,
            METADATA_ADMIN,
            CLANKER_VAULT
        );
        
        ERC1967Proxy proxy = new ERC1967Proxy(address(implementation), initData);
        console.log("Proxy deployed at:", address(proxy));
        
        // Verify initialization
        AxiomVenturesFund1 fund = AxiomVenturesFund1(address(proxy));
        console.log("Fund initialized:");
        console.log("  - Safe:", fund.safe());
        console.log("  - Metadata Admin:", fund.metadataAdmin());
        console.log("  - Clanker Vault:", fund.clankerVault());
        console.log("  - Deposits Open:", fund.depositsOpen());
        console.log("  - Trading Enabled:", fund.tradingEnabled());

        vm.stopBroadcast();
    }
}

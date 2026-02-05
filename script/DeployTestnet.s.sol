// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console} from "forge-std/Script.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

// Mock USDC for testing
contract MockUSDC is ERC20 {
    constructor() ERC20("Mock USDC", "USDC") {}
    
    function decimals() public pure override returns (uint8) {
        return 6;
    }
    
    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

// Testnet version of the fund that accepts configurable USDC
contract AxiomVenturesFund1Testnet {
    // ... we'll just use the existing contract but etch mock USDC
}

contract DeployTestnet is Script {
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("NET_PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);
        
        console.log("Deployer:", deployer);
        
        vm.startBroadcast(deployerPrivateKey);

        // Deploy mock USDC
        MockUSDC mockUsdc = new MockUSDC();
        console.log("Mock USDC deployed at:", address(mockUsdc));
        
        // Mint some USDC to deployer
        mockUsdc.mint(deployer, 100_000e6); // 100K USDC
        console.log("Minted 100K USDC to deployer");
        console.log("Deployer USDC balance:", mockUsdc.balanceOf(deployer));

        vm.stopBroadcast();
        
        console.log("");
        console.log("=== Next Steps ===");
        console.log("The fund contract expects USDC at 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913");
        console.log("But we deployed mock USDC at:", address(mockUsdc));
        console.log("");
        console.log("To test, we need to redeploy the fund with a testnet USDC address.");
    }
}

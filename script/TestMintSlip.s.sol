// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console} from "forge-std/Script.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

// Simple mock USDC for testing
contract MockUSDC is ERC20 {
    constructor() ERC20("Mock USDC", "USDC") {
        _mint(msg.sender, 1_000_000e6); // 1M USDC
    }
    
    function decimals() public pure override returns (uint8) {
        return 6;
    }
    
    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

interface IAxiomVenturesFund1 {
    function deposit(uint256 count) external;
    function totalMinted() external view returns (uint256);
    function ownerOf(uint256 tokenId) external view returns (address);
    function balanceOf(address owner) external view returns (uint256);
    function tradingEnabled() external view returns (bool);
    function slipsMintedBy(address wallet) external view returns (uint256);
}

contract TestMintSlip is Script {
    // Fund contract on Base Sepolia
    address constant FUND = 0x8dfbf933ce6beb86BF2C0624Ec6915cFc481F55B;
    
    // Real USDC address that the contract expects
    address constant USDC_ADDRESS = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    
    uint256 constant SLIP_PRICE = 1010e6; // $1,010

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("NET_PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);
        
        console.log("Deployer:", deployer);
        
        vm.startBroadcast(deployerPrivateKey);

        // Deploy mock USDC at the expected address using CREATE2 or just deploy and use
        MockUSDC mockUsdc = new MockUSDC();
        console.log("Mock USDC deployed at:", address(mockUsdc));
        console.log("Deployer USDC balance:", mockUsdc.balanceOf(deployer));
        
        // We need to deploy mock USDC at the exact address the contract expects
        // Since we can't do that easily, let's check if there's code at USDC_ADDRESS
        uint256 codeSize;
        assembly {
            codeSize := extcodesize(0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913)
        }
        console.log("Code at USDC address:", codeSize);

        vm.stopBroadcast();
    }
}

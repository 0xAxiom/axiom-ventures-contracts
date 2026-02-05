// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console} from "forge-std/Script.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {AxiomVenturesFund1Testnet} from "../src/v4/AxiomVenturesFund1Testnet.sol";

contract MockUSDC is ERC20 {
    constructor() ERC20("Mock USDC", "USDC") {}
    
    function decimals() public pure override returns (uint8) {
        return 6;
    }
    
    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract DeployAndMintTestnet is Script {
    uint256 constant SLIP_PRICE = 1010e6;

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("NET_PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);
        
        console.log("=== Deployer ===");
        console.log("Address:", deployer);
        
        vm.startBroadcast(deployerPrivateKey);

        // 1. Deploy mock USDC
        MockUSDC mockUsdc = new MockUSDC();
        console.log("");
        console.log("=== Mock USDC ===");
        console.log("Address:", address(mockUsdc));
        
        // 2. Mint USDC to deployer
        mockUsdc.mint(deployer, 50_000e6); // 50K USDC
        console.log("Minted 50,000 USDC to deployer");

        // 3. Deploy fund implementation
        AxiomVenturesFund1Testnet implementation = new AxiomVenturesFund1Testnet();
        console.log("");
        console.log("=== Fund Implementation ===");
        console.log("Address:", address(implementation));

        // 4. Deploy proxy
        bytes memory initData = abi.encodeWithSelector(
            AxiomVenturesFund1Testnet.initialize.selector,
            deployer, // safe = deployer for testnet
            address(mockUsdc)
        );
        
        ERC1967Proxy proxy = new ERC1967Proxy(address(implementation), initData);
        AxiomVenturesFund1Testnet fund = AxiomVenturesFund1Testnet(address(proxy));
        
        console.log("");
        console.log("=== Fund Proxy ===");
        console.log("Address:", address(proxy));
        console.log("USDC:", address(fund.usdc()));
        console.log("Deposits Open:", fund.depositsOpen());
        console.log("Trading Enabled:", fund.tradingEnabled());

        // 5. Approve USDC
        mockUsdc.approve(address(fund), type(uint256).max);
        console.log("");
        console.log("=== Approved USDC ===");

        // 6. Mint 1 NFT slip!
        console.log("");
        console.log("=== Minting 1 NFT Slip ===");
        console.log("Cost: 1,010 USDC");
        
        fund.deposit(1);
        
        console.log("");
        console.log("=== SUCCESS! ===");
        console.log("Total Minted:", fund.totalMinted());
        console.log("Deployer NFT Balance:", fund.balanceOf(deployer));
        console.log("Owner of Token #0:", fund.ownerOf(0));
        console.log("Slips minted by deployer:", fund.slipsMintedBy(deployer));
        console.log("Deployer USDC remaining:", mockUsdc.balanceOf(deployer) / 1e6, "USDC");

        vm.stopBroadcast();
        
        console.log("");
        console.log("=== View on Basescan ===");
        console.log("https://sepolia.basescan.org/address/[FUND_ADDRESS]");
        console.log("Fund address above:", address(proxy));
        console.log("Mock USDC address:", address(mockUsdc));
    }
}

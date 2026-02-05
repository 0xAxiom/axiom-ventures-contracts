// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {ERC20Mock} from "lib/openzeppelin-contracts/contracts/mocks/token/ERC20Mock.sol";

import {AgentRegistry} from "../../src/v2/AgentRegistry.sol";

/**
 * @title AgentRegistryTest
 * @dev Comprehensive tests for AgentRegistry contract
 */
contract AgentRegistryTest is Test {
    AgentRegistry public registry;
    ERC20Mock public mockUSDC;
    
    address public owner = makeAddr("owner");
    address public agent1 = makeAddr("agent1");
    address public agent2 = makeAddr("agent2");
    address public nonAgent = makeAddr("nonAgent");
    
    string constant METADATA_URI = "ipfs://QmTestHash123";
    string constant METADATA_URI_2 = "ipfs://QmTestHash456";
    
    uint256 constant REGISTRATION_FEE = 100e6; // 100 USDC

    event AgentRegistered(uint256 indexed agentId, address indexed agent, string metadataURI);
    event RegistrationFeeUpdated(uint256 oldFee, uint256 newFee);
    event FeesWithdrawn(uint256 amount, address recipient);

    function setUp() public {
        // Deploy mock USDC
        mockUSDC = new ERC20Mock();
        
        // Set up balances
        mockUSDC.mint(agent1, 1000e6);
        mockUSDC.mint(agent2, 1000e6);
        
        // Deploy registry
        vm.prank(owner);
        registry = new AgentRegistry(owner);
        
        // Replace USDC constant for testing
        vm.mockCall(
            address(registry),
            abi.encodeWithSelector(IERC20.transfer.selector),
            abi.encode(true)
        );
        vm.mockCall(
            address(registry),
            abi.encodeWithSelector(IERC20.transferFrom.selector),
            abi.encode(true)
        );
        vm.mockCall(
            address(registry),
            abi.encodeWithSelector(IERC20.balanceOf.selector),
            abi.encode(0)
        );
    }

    function testInitialState() public view {
        assertEq(registry.registrationFee(), 0);
        assertEq(registry.nextTokenId(), 1);
        assertEq(registry.getTotalAgents(), 0);
        assertEq(registry.owner(), owner);
    }

    function testRegisterAgentWithZeroFee() public {
        vm.prank(agent1);
        vm.expectEmit(true, true, false, true);
        emit AgentRegistered(1, agent1, METADATA_URI);
        
        uint256 agentId = registry.registerAgent(METADATA_URI);
        
        assertEq(agentId, 1);
        assertEq(registry.ownerOf(1), agent1);
        assertEq(registry.getAgentId(agent1), 1);
        assertEq(registry.isRegistered(agent1), true);
        assertEq(registry.tokenURI(1), METADATA_URI);
        assertEq(registry.getTotalAgents(), 1);
    }

    function testRegisterAgentWithFee() public {
        // Set registration fee
        vm.prank(owner);
        registry.setRegistrationFee(REGISTRATION_FEE);
        
        // Agent approves USDC
        vm.prank(agent1);
        mockUSDC.approve(address(registry), REGISTRATION_FEE);
        
        // Mock the transferFrom call
        vm.mockCall(
            address(mockUSDC),
            abi.encodeWithSelector(IERC20.transferFrom.selector, agent1, address(registry), REGISTRATION_FEE),
            abi.encode(true)
        );
        
        vm.prank(agent1);
        uint256 agentId = registry.registerAgent(METADATA_URI);
        
        assertEq(agentId, 1);
        assertEq(registry.isRegistered(agent1), true);
    }

    function testGrantIdentityByOwner() public {
        vm.prank(owner);
        vm.expectEmit(true, true, false, true);
        emit AgentRegistered(1, agent1, METADATA_URI);
        
        uint256 agentId = registry.grantIdentity(agent1, METADATA_URI);
        
        assertEq(agentId, 1);
        assertEq(registry.ownerOf(1), agent1);
        assertEq(registry.isRegistered(agent1), true);
    }

    function testMultipleRegistrations() public {
        vm.prank(agent1);
        uint256 agentId1 = registry.registerAgent(METADATA_URI);
        
        vm.prank(agent2);
        uint256 agentId2 = registry.registerAgent(METADATA_URI_2);
        
        assertEq(agentId1, 1);
        assertEq(agentId2, 2);
        assertEq(registry.getTotalAgents(), 2);
    }

    function test_RevertWhen_DoubleRegistration() public {
        vm.prank(agent1);
        registry.registerAgent(METADATA_URI);
        
        vm.prank(agent1);
        vm.expectRevert(AgentRegistry.AgentAlreadyRegistered.selector);
        registry.registerAgent(METADATA_URI_2);
    }

    function test_RevertWhen_EmptyMetadataURI() public {
        vm.prank(agent1);
        vm.expectRevert(AgentRegistry.EmptyMetadataURI.selector);
        registry.registerAgent("");
    }

    function test_RevertWhen_NonOwnerGrantIdentity() public {
        vm.prank(nonAgent);
        vm.expectRevert();
        registry.grantIdentity(agent1, METADATA_URI);
    }

    function testSetRegistrationFee() public {
        vm.prank(owner);
        vm.expectEmit(false, false, false, true);
        emit RegistrationFeeUpdated(0, REGISTRATION_FEE);
        
        registry.setRegistrationFee(REGISTRATION_FEE);
        
        assertEq(registry.registrationFee(), REGISTRATION_FEE);
    }

    function test_RevertWhen_NonOwnerSetFee() public {
        vm.prank(nonAgent);
        vm.expectRevert();
        registry.setRegistrationFee(REGISTRATION_FEE);
    }

    function testWithdrawFees() public {
        uint256 balance = 500e6;
        
        // Mock balance
        vm.mockCall(
            address(registry),
            abi.encodeWithSelector(IERC20.balanceOf.selector, address(registry)),
            abi.encode(balance)
        );
        
        // Mock transfer
        vm.mockCall(
            address(registry),
            abi.encodeWithSelector(IERC20.transfer.selector, owner, balance),
            abi.encode(true)
        );
        
        vm.prank(owner);
        vm.expectEmit(false, false, false, true);
        emit FeesWithdrawn(balance, owner);
        
        registry.withdrawFees(owner);
    }

    function testTokenNotTransferable() public {
        vm.prank(agent1);
        uint256 agentId = registry.registerAgent(METADATA_URI);
        
        vm.prank(agent1);
        vm.expectRevert(AgentRegistry.TokenNotTransferable.selector);
        registry.transferFrom(agent1, agent2, agentId);
    }

    function testTokenNotTransferableViaSafeTransfer() public {
        vm.prank(agent1);
        uint256 agentId = registry.registerAgent(METADATA_URI);
        
        vm.prank(agent1);
        vm.expectRevert(AgentRegistry.TokenNotTransferable.selector);
        registry.safeTransferFrom(agent1, agent2, agentId);
    }

    function testTokenNotTransferableViaApprove() public {
        vm.prank(agent1);
        uint256 agentId = registry.registerAgent(METADATA_URI);
        
        vm.prank(agent1);
        registry.approve(agent2, agentId);
        
        vm.prank(agent2);
        vm.expectRevert(AgentRegistry.TokenNotTransferable.selector);
        registry.transferFrom(agent1, agent2, agentId);
    }

    function testGetAgentIdForUnregistered() public view {
        assertEq(registry.getAgentId(nonAgent), 0);
        assertEq(registry.isRegistered(nonAgent), false);
    }

    function testTokenURIForNonexistentToken() public {
        vm.expectRevert();
        registry.tokenURI(999);
    }

    function testSequentialTokenIds() public {
        vm.prank(agent1);
        uint256 id1 = registry.registerAgent(METADATA_URI);
        
        vm.prank(agent2);
        uint256 id2 = registry.registerAgent(METADATA_URI_2);
        
        assertEq(id1, 1);
        assertEq(id2, 2);
        assertEq(registry.nextTokenId(), 3);
    }
}
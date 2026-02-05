# Axiom Ventures Fund 1 — Contract Specification

## Overview
ERC-721 LP slips representing ownership in Axiom Ventures Fund 1. Each slip = 1/2000th of the fund's agent token portfolio.

## Core Parameters
| Parameter | Value |
|-----------|-------|
| Total Slips | 2,000 |
| Public Slips | 1,980 |
| Fund Manager Slips | 20 (1%) |
| Slip Price | $1,000 USDC |
| Max Raise | $1,980,000 |
| Network | Base |

## Addresses
| Role | Address |
|------|---------|
| Safe (upgrades + funds) | `0x5766f573Cc516E3CA0D05a4848EF048636008271` |
| Metadata Admin (OpenSea) | `0xa898136F9a6071cef30aF26905feFF1FD1714593` |
| USDC (Base) | `0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913` |
| Clanker Vault | `0x8e845ead15737bf71904a30bddd3aee76d6adf6c` |

## Fee Structure
- **Deposit Fee:** 1% → auto-minted as fund manager slips (every 99 public = 1 FM)
- **Distribution Fee:** 1% of token claims → Safe

## Contract Architecture

### Inheritance
```
AxiomVenturesFund1
├── ERC721Upgradeable
├── OwnableUpgradeable (for OpenSea)
├── UUPSUpgradeable
├── EIP2981 (royalties)
└── ReentrancyGuardUpgradeable
```

### Storage
```solidity
address public safe;                    // Multi-sig for funds + upgrades
address public metadataAdmin;           // For OpenSea management
address public clankerVault;            // Can be updated if Clanker changes
bool public upgradesLocked;             // One-way lock for upgrades
bool public depositsOpen;               // Can pause deposits

uint256 public totalMinted;             // Total slips minted (public + FM)
uint256 public publicSlipsMinted;       // Public slips only
uint256 public fundManagerSlipsMinted;  // FM slips only

address[] public agentTokens;           // Tracked agent tokens
mapping(address => bool) public isAgentToken;

mapping(uint256 => mapping(address => bool)) public claimed; // slipId => token => claimed
```

### Functions

#### Deposit Phase
```solidity
function deposit(uint256 count) external nonReentrant {
    require(depositsOpen, "Deposits closed");
    require(publicSlipsMinted + count <= 1980, "Exceeds max");
    
    // Transfer USDC to Safe
    USDC.transferFrom(msg.sender, safe, count * 1000e6);
    
    for (uint i = 0; i < count; i++) {
        // Mint to depositor
        _mint(msg.sender, totalMinted++);
        publicSlipsMinted++;
        
        // Every 99 public slips, mint 1 to Safe
        if (publicSlipsMinted % 99 == 0 && fundManagerSlipsMinted < 20) {
            _mint(safe, totalMinted++);
            fundManagerSlipsMinted++;
        }
    }
}
```

#### Clanker Integration
```solidity
function claimFromClanker(address agentToken) external {
    IClankerVault(clankerVault).claim(agentToken);
    
    if (!isAgentToken[agentToken]) {
        agentTokens.push(agentToken);
        isAgentToken[agentToken] = true;
    }
    
    emit TokensClaimed(agentToken, IERC20(agentToken).balanceOf(address(this)));
}
```

#### LP Token Claims
```solidity
function claimAllTokens(uint256 slipId) external nonReentrant {
    require(ownerOf(slipId) == msg.sender, "Not owner");
    
    for (uint i = 0; i < agentTokens.length; i++) {
        address token = agentTokens[i];
        if (!claimed[slipId][token]) {
            _claimSingleToken(slipId, token);
        }
    }
}

function _claimSingleToken(uint256 slipId, address token) internal {
    claimed[slipId][token] = true;
    
    uint256 balance = IERC20(token).balanceOf(address(this));
    uint256 share = balance / 2000;
    uint256 fee = share / 100; // 1%
    
    IERC20(token).transfer(safe, fee);
    IERC20(token).transfer(ownerOf(slipId), share - fee);
    
    emit TokenClaimed(slipId, token, share - fee);
}

function claimSingleToken(uint256 slipId, address token) external nonReentrant {
    require(ownerOf(slipId) == msg.sender, "Not owner");
    require(!claimed[slipId][token], "Already claimed");
    _claimSingleToken(slipId, token);
}
```

#### Admin Functions
```solidity
// Safe only
function setClankerVault(address _vault) external onlySafe;
function setDepositsOpen(bool _open) external onlySafe;
function setMetadataAdmin(address _admin) external onlySafe;
function lockUpgrades() external onlySafe; // Irreversible

// Metadata admin only (OpenSea)
function setContractURI(string calldata _uri) external onlyMetadataAdmin;

// UUPS
function _authorizeUpgrade(address) internal override onlySafe {
    require(!upgradesLocked, "Upgrades locked");
}
```

#### View Functions
```solidity
function owner() public view returns (address); // Returns metadataAdmin for OpenSea
function contractURI() public view returns (string memory);
function tokenURI(uint256 tokenId) public view returns (string memory);
function getClaimableTokens(uint256 slipId) external view returns (address[] memory, uint256[] memory);
function amountClaimable(uint256 slipId, address token) external view returns (uint256);
```

### On-Chain SVG
```solidity
function tokenURI(uint256 tokenId) public view override returns (string memory) {
    require(_exists(tokenId), "Nonexistent");
    
    string memory svg = _generateSVG(tokenId);
    string memory json = string(abi.encodePacked(
        '{"name":"Axiom Ventures Fund 1 #', _toString(tokenId),
        '","description":"LP slip for 1/2000th of Fund 1",',
        '"image":"data:image/svg+xml;base64,', Base64.encode(bytes(svg)), '",',
        '"attributes":[{"trait_type":"Fund","value":"Fund 1"},{"trait_type":"Network","value":"Base"}]}'
    ));
    
    return string(abi.encodePacked('data:application/json;base64,', Base64.encode(bytes(json))));
}
```

## Lifecycle

1. **Deploy** — Initialize with Safe + metadataAdmin, depositsOpen = true
2. **Deposit Phase** — LPs deposit USDC, receive NFTs, FM slips auto-minted
3. **Close Deposits** — Once full (2000) or manually closed
4. **Investment Phase** — Safe invests in agents via Bankr, sets contract as beneficiary
5. **Vesting Phase** — Tokens vest in Clanker Vault over 3 months
6. **Claim Phase** — Anyone can call claimFromClanker(), LPs claim their shares
7. **Lock Upgrades** — Once stable, call lockUpgrades() to make immutable

## Security Considerations

1. **Reentrancy** — ReentrancyGuard on all external state-changing functions
2. **UUPS Safety** — Disable constructors, proper storage gaps
3. **Claim Math** — Fixed divisor (2000) prevents race conditions
4. **Fee-on-Transfer** — Not supported, document clearly
5. **Access Control** — Safe for critical, metadataAdmin for cosmetic

## Gas Estimates
- Deploy: ~3M gas
- Deposit (1 slip): ~150K gas  
- Deposit (10 slips): ~800K gas
- claimFromClanker: ~80K gas
- claimAllTokens (100 agents): ~2M gas (batched)
- claimSingleToken: ~60K gas

## Dependencies
- @openzeppelin/contracts-upgradeable v5.x
- solady (Base64, LibString)

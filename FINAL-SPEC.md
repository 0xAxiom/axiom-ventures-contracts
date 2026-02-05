# Axiom Ventures Fund 1 — Final Contract Specification

## Contract Overview
**Name:** AxiomVenturesFund1  
**Type:** ERC-721 + UUPS Upgradeable  
**Purpose:** LP slips representing 1/2000th ownership in agent token portfolio

---

## Parameters

| Parameter | Value |
|-----------|-------|
| Total Slips | 2,000 |
| Public Slips | 1,980 |
| Fund Manager Slips | 20 (1%) |
| Slip Price | 1,000 USDC |
| Distribution Fee | 1% |
| Network | Base Mainnet |

---

## Addresses

| Role | Address |
|------|---------|
| Safe (funds + upgrades) | `0x5766f573Cc516E3CA0D05a4848EF048636008271` |
| Metadata Admin (OpenSea) | `0xa898136F9a6071cef30aF26905feFF1FD1714593` |
| USDC (Base) | `0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913` |
| Clanker Vault | `0x8e845ead15737bf71904a30bddd3aee76d6adf6c` |

---

## Deposit Phase

### Logic
1. LP calls `deposit(count)` with USDC approval
2. Contract transfers `count × 1000 USDC` to Safe
3. Contract mints `count` NFT slips to LP
4. Every 99 public slips minted → auto-mint 1 slip to Safe (fund manager fee)

### Math Check
- 99 public → 1 FM = 100 total (repeat 20 times)
- 1,980 public → 20 FM = 2,000 total ✓

### Constraints
- `depositsOpen` must be true
- Cannot exceed 1,980 public slips
- USDC approval required

---

## Clanker Integration

### Setting Beneficiary
When launching agents via Bankr, set `VaultExtensionData.admin` = our contract address

### Claim Function (Permissionless)
```solidity
function claimFromClanker(address token) external
```
- Anyone can call
- Calls `IClankerVault(clankerVault).claim(token)`
- Tokens flow from Clanker Vault → our contract
- Tracks `totalReceived[token] += received`
- Adds token to `agentTokens[]` if new

### Batch Claim
```solidity
function claimAllFromClanker() external
```
- Loops through all known `agentTokens`
- Calls `claimFromClanker()` for each
- Gas intensive but convenient

---

## LP Token Claims

### Entitlement Calculation
```
entitlement = totalReceived[token] / 2000
owed = entitlement - claimed[slipId][token]
fee = owed / 100  (1%)
payout = owed - fee
```

### Single Token Claim
```solidity
function claimSingleToken(uint256 slipId, address token) external
```
- Only NFT owner can call
- Calculates owed amount
- Sends 1% to Safe
- Sends 99% to caller
- Updates `claimed[slipId][token]`

### Batch Claim
```solidity
function claimAllTokens(uint256 slipId) external
```
- Loops through all `agentTokens`
- Claims each where owed > 0

### Key Properties
- ✅ Fair regardless of claim timing
- ✅ Handles partial vesting (claim now, claim more later)
- ✅ No race conditions (fixed /2000 divisor)
- ✅ No sweep — tokens belong to NFT holder forever

---

## Admin Functions

### Safe Only
| Function | Purpose |
|----------|---------|
| `setClankerVault(address)` | Update if Clanker changes |
| `setMetadataAdmin(address)` | Rotate OpenSea admin |
| `setDepositsOpen(bool)` | Open/close deposits |
| `addAgentToken(address)` | Manually add token if needed |
| `lockUpgrades()` | Permanently disable upgrades |

### Metadata Admin Only
| Function | Purpose |
|----------|---------|
| `setContractURI(string)` | Update collection metadata |

### UUPS
| Function | Purpose |
|----------|---------|
| `_authorizeUpgrade()` | Safe only, respects `upgradesLocked` |

---

## View Functions

| Function | Returns |
|----------|---------|
| `owner()` | metadataAdmin (for OpenSea) |
| `tokenURI(tokenId)` | On-chain SVG + JSON |
| `contractURI()` | Collection metadata |
| `getAgentTokens()` | All tracked tokens |
| `getClaimable(slipId)` | (tokens[], amounts[]) |
| `totalReceived(token)` | Cumulative received |
| `claimed(slipId, token)` | Amount claimed |

---

## On-Chain SVG

### Design
- Dark background (#0a0a0a)
- "AXIOM VENTURES" / "Fund 1 · Base"
- Large slip number in lime (#84cc16)
- "1 of 2,000" / "$1,000 USDC"

### Generation
- `_generateSVG(tokenId)` builds SVG string
- Base64 encoded in tokenURI
- ~2KB per image, acceptable gas cost

---

## Storage Layout

```solidity
// Slot 0-50: OpenZeppelin upgradeable base contracts

// Custom storage
address public safe;
address public metadataAdmin;
address public clankerVault;
string public contractMetadataURI;

bool public depositsOpen;
bool public upgradesLocked;

uint256 public totalMinted;
uint256 public publicSlipsMinted;
uint256 public fundManagerSlipsMinted;

address[] public agentTokens;
mapping(address => bool) public isAgentToken;
mapping(address => uint256) public totalReceived;
mapping(uint256 => mapping(address => uint256)) public claimed;

// Storage gap for future upgrades
uint256[40] private __gap;
```

---

## Security Checklist

- [x] ReentrancyGuard on all state-changing externals
- [x] Checks-effects-interactions pattern
- [x] No sweep function (tokens belong to NFT holders)
- [x] UUPS with onlySafe authorization
- [x] Lockable upgrades (one-way)
- [x] Separate metadataAdmin (low privilege)
- [x] Fixed /2000 divisor (no race conditions)
- [x] Storage gap for upgrades
- [x] _disableInitializers() in constructor
- [x] Input validation on all parameters

---

## Events

```solidity
event Deposited(address indexed depositor, uint256 count, uint256 firstSlipId);
event FundManagerSlipMinted(uint256 slipId);
event TokensClaimedFromClanker(address indexed token, uint256 amount);
event TokenClaimed(uint256 indexed slipId, address indexed token, uint256 amount, uint256 fee);
event DepositsOpenChanged(bool open);
event ClankerVaultUpdated(address oldVault, address newVault);
event MetadataAdminUpdated(address oldAdmin, address newAdmin);
event UpgradesPermanentlyLocked();
```

---

## Lifecycle

```
1. DEPLOY
   └── Initialize with Safe + metadataAdmin
   └── depositsOpen = true

2. DEPOSIT PHASE
   └── LPs deposit USDC, receive NFTs
   └── FM slips auto-minted every 99 public
   └── Ends when 1,980 public sold OR manually closed

3. INVESTMENT PHASE
   └── Safe invests in agents via Bankr
   └── Contract address set as beneficiary
   └── 100 agents × $20K = $2M deployed

4. VESTING PHASE
   └── Tokens vest in Clanker (2wk cliff + 3mo linear)
   └── Anyone calls claimAllFromClanker() periodically
   └── Tokens accumulate in contract

5. CLAIM PHASE
   └── Slip holders call claimAllTokens(slipId)
   └── Receive 1/2000th of each token (minus 1% fee)
   └── Can claim anytime, as often as needed

6. MATURITY
   └── After 3+ months, most tokens vested
   └── Safe calls lockUpgrades() to finalize
   └── Contract becomes fully immutable
```

---

## Gas Estimates

| Operation | Estimated Gas |
|-----------|---------------|
| Deploy (proxy + impl) | ~4M |
| deposit(1) | ~180K |
| deposit(10) | ~900K |
| claimFromClanker(1 token) | ~100K |
| claimAllFromClanker(100 tokens) | ~3M |
| claimSingleToken | ~80K |
| claimAllTokens(100 tokens) | ~3M |

---

## Dependencies

```
@openzeppelin/contracts-upgradeable ^5.0.0
├── ERC721Upgradeable
├── OwnableUpgradeable  
├── UUPSUpgradeable
├── ReentrancyGuardUpgradeable
└── ERC2981Upgradeable

solady
├── Base64
└── LibString
```

# Axiom Ventures Fund 1 — Final Contract Specification (v2)

## Overview
**Name:** AxiomVenturesFund1  
**Type:** ERC-721 + ERC-2981 + UUPS Upgradeable  
**Purpose:** LP slips representing 1/200th ownership in agent token portfolio

---

## Fund Parameters

| Parameter | Value |
|-----------|-------|
| Total Slips | 200 |
| Slip Price | $1,010 USDC |
| Total Raise | $202,000 |
| Entry FDV | $100,000 per agent |
| Agents | 20 |
| Network | Base Mainnet |

---

## Fee Structure

| Fee | Rate | Destination | Purpose |
|-----|------|-------------|---------|
| Deposit Fee | 1% | Safe | Buy & burn $AXIOM |
| Distribution Fee | 1% | Safe | Operating costs |
| Royalty (secondary) | 2.5% | Safe | 50% burn, 50% operating |

---

## Addresses

| Role | Address |
|------|---------|
| Safe (funds + upgrades) | `0x5766f573Cc516E3CA0D05a4848EF048636008271` |
| Metadata Admin (OpenSea) | `0xa898136F9a6071cef30aF26905feFF1FD1714593` |
| USDC (Base) | `0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913` |
| Clanker Vault | `0x8e845ead15737bf71904a30bddd3aee76d6adf6c` |

---

## Trading Lock

- **Default:** Trading DISABLED
- **Enabled:** Automatically when all 200 slips sold
- **Override:** Safe can enable early via `enableTrading()`
- **Safe bypass:** Safe can always transfer (for distributions)

---

## Deposit Phase

### Logic
1. LP calls `deposit(count)` with USDC approval
2. Contract transfers `count × 1,010 USDC` to Safe
3. Contract mints `count` NFT slips to LP
4. Event emits fee amount (1% = $10.10/slip for burns)

### Constraints
- `depositsOpen` must be true
- Cannot exceed 200 slips total
- USDC approval required

### Auto-Sellout
When `totalMinted == 200`:
- `tradingEnabled` set to true
- `TradingEnabled` event emitted

---

## Clanker Integration

### Setting Beneficiary
When launching agents via Bankr, set `VaultExtensionData.admin` = contract address

### Claim Function (Permissionless)
```solidity
function claimFromClanker(address token) external
```
- Anyone can call
- Calls `IClankerVault(clankerVault).claim(token)`
- Tokens flow from Clanker Vault → contract
- Tracks `totalReceived[token] += received`
- Updates `accumulatedPerShare[token]` (dividend pattern)
- Adds token to `agentTokens[]` if new

### Batch Claim
```solidity
function claimFromClankerBatch(uint256 startIdx, uint256 count) external
```
- Claims up to `count` tokens starting at index
- MAX_BATCH_SIZE = 50

---

## LP Token Claims (Accumulated Dividends)

### Entitlement Calculation
```
pending = (accumulatedPerShare[token] - rewardDebt[slipId][token]) / PRECISION
fee = pending * 1%
payout = pending - fee
```

### Key Properties
- ✅ Late depositors don't get retroactive rewards
- ✅ Fair regardless of claim timing
- ✅ No precision loss (1e18 scaling)
- ✅ Handles partial vesting (claim now, claim more later)

### Single Token Claim
```solidity
function claimSingleToken(uint256 slipId, address token) external
```

### Batch Claim
```solidity
function claimTokensBatch(uint256 slipId, uint256 startIdx, uint256 count) external
```

---

## View Functions (For Secondary Market)

### Get All Claimable
```solidity
function getClaimableAll(uint256 slipId) external view 
    returns (address[] memory tokens, uint256[] memory amounts)
```

### Get Claim History
```solidity
function getClaimHistory(uint256 slipId) external view 
    returns (address[] memory tokens, uint256[] memory amounts)
```

### Get Token Status
```solidity
function getTokenStatus(uint256 slipId) external view returns (
    uint256 numPendingTokens,
    uint256 numClaimedTokens,
    uint256 totalAgentTokens
)
```

---

## Admin Functions

### Safe Only
| Function | Purpose |
|----------|---------|
| `setClankerVault(address)` | Update vault address |
| `setMetadataAdmin(address)` | Rotate OpenSea admin |
| `setDepositsOpen(bool)` | Open/close deposits |
| `setPaused(bool)` | Emergency pause |
| `enableTrading()` | Enable trading early |
| `addAgentToken(address)` | Manually add token |
| `lockUpgrades()` | Permanently disable upgrades |

### Metadata Admin Only
| Function | Purpose |
|----------|---------|
| `setContractURI(string)` | Update collection metadata |

---

## On-Chain SVG

### Design
- Dark background (#0a0a0a)
- "AXIOM VENTURES" / "Fund 1"
- Large slip number in lime (#84cc16)
- "1 of 200" / "$1,010 USDC"
- "$100K FDV Entry" / "20 AI Agents"
- Trading status badge (LOCKED/TRADEABLE)

### Dynamic Attributes
- Pending Claims count
- Claimed Tokens count
- Trading status

---

## Royalties (EIP-2981)

- **Rate:** 2.5% (250 basis points)
- **Receiver:** Safe
- **Implementation:** ERC2981Upgradeable
- **Manual split:** Safe executes burns with 50%

---

## Security

- [x] ReentrancyGuard on all state-changing externals
- [x] Checks-effects-interactions pattern
- [x] UUPS with onlySafe authorization
- [x] Lockable upgrades (one-way)
- [x] Separate metadataAdmin (low privilege)
- [x] Accumulated dividends (no precision loss)
- [x] Batch pagination (MAX_BATCH_SIZE=50)
- [x] Trading lock until sold out
- [x] Storage gap for upgrades
- [x] _disableInitializers() in constructor

---

## Events

```solidity
event Deposited(address indexed depositor, uint256 count, uint256 firstSlipId, uint256 feeAmount);
event TokensClaimedFromClanker(address indexed token, uint256 amount);
event TokenClaimed(uint256 indexed slipId, address indexed token, uint256 amount, uint256 fee);
event DepositsOpenChanged(bool open);
event PausedChanged(bool paused);
event TradingEnabled();
event ClankerVaultUpdated(address oldVault, address newVault);
event MetadataAdminUpdated(address oldAdmin, address newAdmin);
event AgentTokenAdded(address token);
event UpgradesPermanentlyLocked();
event ClankerClaimFailed(address token, bytes reason);
```

---

## Lifecycle

```
1. DEPLOY
   └── Initialize with Safe + metadataAdmin + clankerVault
   └── depositsOpen = true, tradingEnabled = false

2. DEPOSIT PHASE
   └── LPs deposit $1,010 USDC, receive NFT slips
   └── 1% ($10.10) goes to burn fund
   └── Ends when 200 sold OR manually closed
   └── Trading auto-enables on sellout

3. INVESTMENT PHASE
   └── Safe invests in agents via Bankr
   └── Contract address set as beneficiary
   └── 20 agents × $10K = $200K deployed

4. VESTING PHASE
   └── Tokens vest in Clanker (2wk cliff + 3mo linear)
   └── Anyone calls claimFromClanker() periodically
   └── Accumulated dividends updated

5. CLAIM PHASE
   └── Slip holders call claimSingleToken/claimTokensBatch
   └── Receive 1/200th of each token (minus 1% fee)
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
| deposit(1) | ~160K |
| deposit(10) | ~400K |
| claimFromClanker(1 token) | ~230K |
| claimFromClankerBatch(20) | ~1M |
| claimSingleToken | ~100K |
| claimTokensBatch(20) | ~700K |

---

## Test Coverage

34 tests covering:
- Initialization
- Deposits & fees
- Trading lock mechanics
- Clanker claims
- LP claims & dividends
- View functions
- Admin functions
- Late depositor fairness

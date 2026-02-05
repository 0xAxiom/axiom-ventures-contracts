# Axiom Ventures — Architecture

## Overview

Axiom Ventures Fund 1 uses a single ERC-721 contract to manage LP participation. Each NFT "slip" represents 1/2000th ownership and is tradeable on secondary markets.

## Core Components

### 1. AxiomVenturesFund1 (ERC-721 + UUPS)
**Status:** Ready for deployment

The main contract handles:
- LP deposits (USDC → Safe, mint NFT)
- Fund manager slip allocation (1 per 99 public)
- Token claiming from Clanker Vault
- Token distribution to slip holders
- On-chain SVG metadata

### 2. Safe Multi-Sig (2/3)
**Address:** `0x5766f573Cc516E3CA0D05a4848EF048636008271`

Treasury and admin control:
- Receives USDC from deposits
- Invests in agents via Bankr
- Can upgrade contract (until locked)
- Can pause in emergencies

### 3. Clanker Vault (External)
**Address:** `0x8e845ead15737bf71904a30bddd3aee76d6adf6c`

Token vesting infrastructure:
- Receives 20% of agent tokens at launch
- Vests over 3 months (2-week cliff + linear)
- Our contract calls `claim(token)` to pull vested tokens

### 4. Metadata Admin (EOA)
**Address:** `0xa898136F9a6071cef30aF26905feFF1FD1714593`

OpenSea collection management:
- Sets collection metadata URI
- Returns as `owner()` for OpenSea
- Cannot touch funds or upgrade contract

## Token Flow

```
1. DEPOSIT PHASE
   LP deposits $1,000 USDC
        ↓
   Contract mints ERC-721 slip
        ↓
   USDC forwarded to Safe
        ↓
   Every 99 public slips → 1 FM slip to Safe

2. INVESTMENT PHASE
   Safe invests $20K per agent via Bankr
        ↓
   20% of agent tokens → Clanker Vault
   (our contract address as beneficiary)

3. VESTING PHASE
   Tokens vest in Clanker Vault
        ↓
   Anyone calls claimFromClanker(token)
        ↓
   Tokens flow into our contract
        ↓
   accumulatedPerShare[token] updated

4. CLAIM PHASE
   LP calls claimTokensBatch(slipId, start, count)
        ↓
   For each token: pending = (accumulated - debt) / 1e18
        ↓
   1% fee → Safe
        ↓
   99% → LP
```

## Dividend Distribution Pattern

We use the "MasterChef" accumulated dividends pattern:

```solidity
// When tokens arrive from Clanker:
accumulatedPerShare[token] += (received * 1e18) / 2000;

// When LP claims:
pending = (accumulatedPerShare[token] - rewardDebt[slipId][token]) / 1e18;
rewardDebt[slipId][token] = accumulatedPerShare[token];
```

This ensures:
- No precision loss (scaled by 1e18)
- Fair distribution regardless of claim timing
- Supports partial vesting (claim now, more later)
- No race conditions

## Fee Structure

| Fee | Amount | Mechanism |
|-----|--------|-----------|
| Deposit | 1% | Auto-mints as FM slips (20 total) |
| Distribution | 1% | Taken on token claims → Safe |
| Management | 0% | None |
| Performance | 0% | None |

## Security Model

### Access Control
- **Safe:** Upgrades, pause, vault address, add tokens
- **MetadataAdmin:** Collection URI only
- **Anyone:** Deposit, claim from Clanker, batch operations

### Upgrade Safety
1. Deploy as UUPS proxy
2. Safe can upgrade if bugs found
3. Call `lockUpgrades()` to permanently disable
4. `upgradesLocked` is irreversible

### Emergency Controls
- `setPaused(true)` stops deposits and claims
- Safe can always withdraw stuck tokens (if needed, via upgrade)
- No sweep function — LP tokens belong to them forever

## Gas Considerations

| Operation | Estimated Gas |
|-----------|---------------|
| Deploy (proxy + impl) | ~4M |
| deposit(1) | ~180K |
| deposit(10) | ~900K |
| claimFromClanker | ~100K |
| claimTokensBatch(50) | ~1.5M |

Batch operations capped at 50 to prevent gas limit issues.

## NFT Metadata

On-chain SVG stored in contract:
- Dark minimal design (#0a0a0a background)
- Lime accent (#84cc16) for slip number
- Shows: "AXIOM VENTURES", "Fund 1", slip #, "1 of 2,000"
- No external dependencies (IPFS not needed)

## Links

- Contract: `src/v4/AxiomVenturesFund1.sol`
- Tests: `test/v4/AxiomVenturesFund1.t.sol`
- Spec: `FINAL-SPEC.md`
- Audits: `audits/`

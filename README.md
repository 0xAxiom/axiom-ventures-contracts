# Axiom Ventures Contracts

Smart contracts for Axiom Ventures — an AI agent seed fund on Base.

## Overview

Axiom Ventures invests $20K into 100 AI agents at token launch in exchange for 20% of their token supply. LPs participate via ERC-721 "slip" NFTs, each representing 1/2000th of the fund's token portfolio.

## Contracts

### v4 — Fund 1 (Current)

| Contract | Description |
|----------|-------------|
| `AxiomVenturesFund1.sol` | ERC-721 LP slips with integrated token distribution |

**Key Features:**
- **ERC-721 LP Slips:** Each slip is an NFT, tradeable on OpenSea
- **UUPS Upgradeable:** Can be upgraded by Safe multi-sig, then permanently locked
- **Accumulated Dividends:** MasterChef-style token distribution (no precision loss)
- **Permissionless Claims:** Anyone can trigger Clanker vault claims
- **On-chain SVG:** NFT artwork stored entirely on-chain

### Architecture

```
LP deposits $1,000 USDC
        │
        ▼
┌─────────────────────────────────────────────────┐
│           AxiomVenturesFund1                    │
│                                                 │
│  • Mints ERC-721 slip to LP                    │
│  • Forwards USDC to Safe multi-sig             │
│  • Auto-mints 1 FM slip per 99 public          │
│  • Tracks accumulated dividends per token       │
│  • Distributes tokens to slip holders          │
└─────────────────────────────────────────────────┘
        │                           │
        ▼                           ▼
   Safe Multi-sig              Clanker Vault
   (holds USDC,                (vests agent
    invests in agents)          tokens)
```

### Addresses

| Contract | Address |
|----------|---------|
| AxiomVenturesFund1 | *Not yet deployed* |
| Safe Multi-sig | `0x5766f573Cc516E3CA0D05a4848EF048636008271` |
| Metadata Admin | `0xa898136F9a6071cef30aF26905feFF1FD1714593` |
| Clanker Vault | `0x8e845ead15737bf71904a30bddd3aee76d6adf6c` |

## Development

### Prerequisites

- [Foundry](https://book.getfoundry.sh/getting-started/installation)
- Node.js 18+

### Install

```bash
git clone https://github.com/0xAxiom/axiom-ventures-contracts.git
cd axiom-ventures-contracts
forge install
```

### Build

```bash
forge build
```

### Test

```bash
# All tests
forge test

# v4 tests only
forge test --match-path test/v4/*.sol -vv

# With gas report
forge test --gas-report
```

### Deploy

```bash
# Deploy to Base mainnet
forge script script/DeployFund1.s.sol --rpc-url base --broadcast --verify
```

## Fund Parameters

| Parameter | Value |
|-----------|-------|
| Total Slips | 2,000 |
| Public Slips | 1,980 |
| Fund Manager Slips | 20 (1%) |
| Slip Price | $1,000 USDC |
| Max Raise | $1,980,000 |
| Distribution Fee | 1% |
| Agents Funded | 100 |
| Investment per Agent | $20,000 |

## Security

- [x] Reentrancy protection
- [x] Access control (Safe + MetadataAdmin)
- [x] UUPS with lockable upgrades
- [x] Accumulated dividends (no precision loss)
- [x] Batch pagination (gas limit protection)
- [x] Emergency pause
- [x] Comprehensive test suite (22 tests)

### Audits

- `audits/axiom-fund1-security-audit.md` — Initial audit
- `audits/axiom-fund1-audit-v2.md` — Post-fix review

## License

MIT

## Links

- Website: [axiomventures.xyz](https://axiomventures.xyz)
- Twitter: [@AxiomBot](https://twitter.com/AxiomBot)
- GitHub: [github.com/0xAxiom](https://github.com/0xAxiom)

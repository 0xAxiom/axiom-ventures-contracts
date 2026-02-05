# Axiom Ventures — Architecture

## Overview

Axiom Ventures is a simple fund that invests $20K into AI agents at token launch in exchange for 20% of their token supply. The architecture prioritizes simplicity and battle-tested infrastructure.

## Core Components

### 1. AxiomVault (ERC-4626)
**Address:** `0xac40cc75f4227417b66ef7cd0cef1da439493255`

Standard ERC-4626 vault for LP deposits:
- LPs deposit USDC, receive avFUND1 shares
- 1% of deposits allocated as fund manager LP slips (aligned incentives)
- Shares represent pro-rata claim on vested agent tokens
- Verified on Basescan

### 2. Safe Multi-Sig (2/3)
**Address:** `0x5766f573Cc516E3CA0D05a4848EF048636008271`

Treasury control:
- All fund operations require 2 of 3 signatures
- Human oversight on material decisions
- Controls USDC deployment to agents

### 3. Bankr's Clanker Vault (External)
**Address:** `0x8e845ead15737bf71904a30bddd3aee76d6adf6c`

Token vesting infrastructure (not our contract):
- Battle-tested with 1000+ transactions
- 2-week cliff + 3-month linear vest
- Immutable vesting schedules
- Handles 20% token allocation from each agent launch

## Investment Flow

```
1. LP deposits USDC → AxiomVault
2. Fund reviews agent pitches (off-chain DD)
3. Approved agent launches via Bankr
4. At launch: 20% tokens → Clanker Vault, $20K USDC → agent wallet
5. Tokens vest over 3 months
6. Fund claims vested tokens, distributes to LPs pro-rata
```

## Fee Structure

| Fee | Amount | Mechanism |
|-----|--------|-----------|
| Deposit | 1% | Allocated as fund manager LP slips |
| Distribution | 1% | Retained on token claims |
| Management | 0% | None |
| Performance | 0% | None |

## What We Don't Need

The previous architecture included complex contracts (AgentRegistry, DDAttestation, InvestmentRouter, EscrowFactory, MilestoneEscrow) for on-chain DD verification and milestone-based funding. 

**We removed all of this** because:
- Bankr's Clanker Vault handles vesting natively
- Off-chain DD is faster and more thorough
- Simple token-at-launch model eliminates milestone complexity
- Less code = less attack surface

## Security

- AxiomVault: Standard ERC-4626, verified on Basescan
- Multi-sig: 2/3 threshold prevents single points of failure
- Clanker Vault: Immutable, battle-tested, not our code
- No custom vesting logic to audit

## Links

- Vault: [Basescan](https://basescan.org/address/0xac40cc75f4227417b66ef7cd0cef1da439493255)
- Safe: [Basescan](https://basescan.org/address/0x5766f573Cc516E3CA0D05a4848EF048636008271)
- Clanker Vault: [Basescan](https://basescan.org/address/0x8e845ead15737bf71904a30bddd3aee76d6adf6c)
- Source: [GitHub](https://github.com/0xAxiom/axiom-ventures-contracts)

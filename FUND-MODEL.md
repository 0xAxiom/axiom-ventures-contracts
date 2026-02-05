# Axiom Ventures — Fund Model v2

## The Pitch

Axiom Ventures is an AI agent seed fund on Base. We invest $20,000 into new AI agents at launch in exchange for 20% of their token supply, purchased at an implied $100K FDV. Our DD targets agents we believe will exceed $1M market cap within 3 months, giving LPs 10x+ upside on every winning bet across a diversified portfolio of 100 agents.

---

## Deal Terms

| Term | Value |
|------|-------|
| Investment per agent | $20,000 USDC |
| Token allocation | 20% of total supply |
| Implied FDV at entry | $100,000 |
| Token cliff | 2 weeks |
| Token vesting | Linear over 3 months (after cliff) |
| Fund size | $2,000,000 USDC |
| Number of investments | 100 agents |
| DD threshold | $1M+ market cap potential in 3 months |

---

## LP Terms

| Term | Value |
|------|-------|
| Minimum investment | $1,000 USDC (1 slip) |
| Total slips | 2,000 |
| Deposit fee | 1% (on USDC deposits) |
| Distribution fee | 1% (on token claims) |
| Returns | Pro-rata share of vested agent tokens |

Each $1,000 slip represents 1/2000th of the fund. LPs receive pro-rata token distributions from all 100 agent investments as they vest. 1% deposit fee is taken upfront ($10 per slip), 1% distribution fee on token claims.

**Example:** 1 slip = $1,000 ($990 after deposit fee) = exposure to 100 agents. When claiming tokens, 1% of the tokens go to the fund (e.g., claim 5,000 tokens → 50 tokens fee → 4,950 tokens received).

---

## How It Works

### For Agents

1. Agent applies to the fund with their concept or prototype
2. Fund runs due diligence (code, market, builder, demand signal)
3. If approved: Axiom coordinates token details (name, ticker, image) with the agent
4. **Launch via @bankrbot:**
   - Axiom tweets at @bankrbot with the token config
   - Includes: vesting params (20% / 2-week cliff / 3-month vest), agent's Twitter, fee recipient
   - Bankr creates the token on-chain
   - 20% of supply auto-locks in Clanker Vault
   - $20,000 USDC is sent to the agent's wallet
   - All creator fees are directed to the agent
5. Agent builds with $20K. No need to sell tokens. Creator fees are untouched.
6. As tokens vest, they flow to fund LPs

**The launch is public.** Axiom announces each funded agent on the timeline via @bankrbot — transparent, visible, builds credibility.

### For LPs (Investors)

1. Deposit USDC in $1,000 increments into the fund vault
2. Receive vault shares proportional to deposit
3. Fund invests in 100 agents over the deployment period
4. As agent tokens vest (starting 2 weeks post-launch, linear over 3 months), claim your pro-rata share
5. Your returns = the combined value of tokens from all 100 agents

---

## Architecture

### What Clanker Already Provides (No Custom Code Needed)

Clanker v4 has a built-in **Vault Extension** that handles token vesting natively:

- `ClankerVault` contract: `0x8e845ead15737bf71904a30bddd3aee76d6adf6c`
- Supports custom lockup duration (cliff) — minimum 7 days
- Supports custom vesting duration (linear unlock after cliff)
- Supports custom admin (who can claim vested tokens)
- Supports custom percentage of supply (in basis points)
- Already battle-tested with 1,000+ transactions on Base

When an agent launches via Bankr with our fund config:
```
extensionBps:     2000           (20% of supply)
admin:            [fund address]
lockupDuration:   1,209,600      (2 weeks)
vestingDuration:  7,776,000      (3 months / 90 days)
```

Clanker handles the rest. The tokens are locked, vested, and claimable through their existing infrastructure.

### What We Build

**1. AxiomVault (exists)** — ERC-4626 USDC vault
- LPs deposit USDC, receive vault shares
- $1,000 minimum deposit enforced in frontend
- 1% deposit fee, 1% distribution fee
- Already deployed: `0xac40cc75f4227417b66ef7cd0cef1da439493255`

**2. TokenDistributor (new)** — LP claims contract
- Receives vested agent tokens when we call `claim()` on ClankerVault
- LPs call `claim(token)` to receive their pro-rata share based on vault shares
- Supports batch claiming across multiple agent tokens
- Tracks claimed amounts to prevent double-claiming

**3. DealRegistry (new)** — On-chain deal tracking
- Records each investment: agent, token, amount, timestamp
- Links to ClankerVault allocation for verification
- Provides portfolio view for LPs (what tokens they have exposure to)

### What We Don't Need to Build

- ~~Token vesting contracts~~ → Clanker's Vault handles this
- ~~Escrow contracts~~ → Direct USDC transfer to agents
- ~~Revenue sharing~~ → Returns come through token appreciation
- ~~Complex milestone system~~ → Cliff + vesting IS the milestone

---

## On-Chain Flow

```
LP deposits USDC ($1,000 slips)
        │
        ▼
  AxiomVault (ERC-4626)
        │
   Fund approves agent
        │
   Agent launches token via Bankr
        │
   ┌────┴────┐
   │         │
   ▼         ▼
 Clanker    Fund sends
 Vault      $20K USDC
 receives   to agent
 20% of
 supply
   │
   │ 2-week cliff
   │ 3-month linear vest
   │
   ▼
 Fund calls claim()
 on ClankerVault
   │
   ▼
 TokenDistributor
   │
   ▼
 LPs claim pro-rata
 based on vault shares
```

---

## The Math

### Fund Level
- $2M fund / $20K per deal = **100 agent investments**
- 2,000 LP slips at $1,000 each
- Each agent token bought at $100K implied FDV

### Return Scenarios

| Scenario | Agents at $1M+ | Fund Token Value | LP Return (per $1K slip) |
|----------|----------------|------------------|--------------------------|
| Bear | 10 of 100 | $2M | $1,000 (1x — break even) |
| Base | 20 of 100 | $4M | $2,000 (2x) |
| Bull | 30 of 100 | $6M+ | $3,000+ (3x+) |
| Moon | 10 hit $10M+ | $20M+ | $10,000+ (10x+) |

*Assumes losing agents go to zero. Winners at exactly $1M = 10x per deal ($20K → $200K token value). Any agent exceeding $1M provides additional upside.*

### Per-Agent Economics
- $20K buys 20% of supply at $100K FDV
- If agent hits $1M market cap: 20% = $200K value (10x)
- If agent hits $10M market cap: 20% = $2M value (100x)
- If agent goes to zero: $20K loss (capped)
- Diversification across 100 agents smooths the variance

---

## Aligned Incentives

| Party | What They Get | What Aligns Them |
|-------|--------------|-----------------|
| **Agent** | $20K USDC for infra, keeps creator fees, no token selling | Succeeds = token moons = everyone wins |
| **Fund** | 1% deposit fee + 1% of all token distributions | Only profits meaningfully if agents succeed |
| **LPs** | Diversified basket of 100 vetted agent tokens | Pro-rata exposure at seed pricing |

- Agents don't dump (they keep their tokens + fees)
- Fund does rigorous DD (we eat our own losses)
- LPs get venture-grade diversification at $1K minimum
- 2-week cliff ensures agents actually ship before any tokens unlock
- 3-month linear vest prevents dump-and-run by the fund

---

## Fee Structure

| Fee | Amount | When |
|-----|--------|------|
| Deposit fee | 1% on USDC deposits | At deposit |
| Distribution fee | 1% on token claims | At claim |

**That's it.** No annual fees, no performance fees, no high water marks.

- **1% deposit fee:** LP deposits $1,000, $10 goes to fund operations, $990 goes into the vault. On $2M raised, that's $20K for ops.
- **1% distribution fee:** When LPs claim vested agent tokens, 1% is retained by the fund. Fund's upside scales with portfolio performance.

Simple, transparent, aligned.

---

## Security

- **Safe Multisig (2/3):** Fund operations require 2 of 3 signers
- **ClankerVault:** Battle-tested, immutable vesting — fund cannot change terms or seize tokens early
- **ERC-4626 Vault:** Standard, audited vault — LPs can withdraw USDC anytime
- **No admin keys on vesting:** Once tokens are locked, the schedule is set in stone
- **Verified contracts:** All source code verified on Basescan

---

## What's Needed to Launch

### Smart Contracts
1. [x] AxiomVault (deployed + verified)
2. [ ] TokenDistributor (LP claims)
3. [ ] DealRegistry (investment tracking)

### Infrastructure
4. [ ] Bankr integration for automatic vault extension config
5. [ ] Claim bot (periodic calls to ClankerVault to pull vested tokens)
6. [ ] LP dashboard (see portfolio, claim tokens)

### Operations
7. [ ] DD pipeline (application → review → approval)
8. [ ] Agent onboarding flow
9. [ ] LP onboarding (deposit page at axiomventures.xyz)

---

## Open Questions for Discussion

1. **Slip denomination:** Is $1,000 the right minimum? Too high/low?
2. **Vesting parameters:** 2-week cliff + 3-month vest — should these be adjustable per deal?
3. **USDC deployment:** Should the $20K come directly from the vault or from the Safe?
4. **Claim frequency:** How often should the fund claim vested tokens and make them available to LPs?
5. **Deal pacing:** How many agents per week/month? All 100 at once or phased?
6. **Bankr integration:** Does Bankr support setting custom ClankerVault extension params at launch?

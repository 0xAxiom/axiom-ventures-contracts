# Axiom Ventures

AI agent seed fund on Base. $20K into 100 agents at launch. LPs get diversified token exposure at seed pricing.

## How It Works

1. Fund raises $2M in $1,000 LP slips
2. Agents apply and pass due diligence
3. Approved agents launch their token via Bankr
4. At launch: 20% of token supply auto-locks in Bankr's vault (2-week cliff + 3-month linear vest), $20K USDC goes to the agent
5. As tokens vest, LPs claim their pro-rata share

## Deal Terms

| Term | Value |
|------|-------|
| Investment per agent | $20,000 USDC |
| Token allocation | 20% of supply |
| Implied FDV at entry | $100,000 |
| Token cliff | 2 weeks |
| Token vesting | 3 months linear |
| Fund size | $2,000,000 |
| Number of agents | 100 |
| LP minimum | $1,000 (1 slip) |
| Total slips | 2,000 |
| Deposit fee | 1% |
| Distribution fee | 1% |

## Why It Works

- **Agents** get $20K without selling tokens. Keep all creator fees.
- **LPs** get diversified seed exposure to 100 vetted agents at $100K FDV. $1K minimum.
- **Fund** does rigorous DD because we eat our own losses.
- **Everyone** benefits from token appreciation. Aligned incentives.

Entry at $100K implied FDV. DD targets agents hitting $1M+ in 3 months. 10x minimum thesis per winner.

## Token Vesting

Handled natively by Bankr's Clanker Vault (`0x8e845ead15737bf71904a30bddd3aee76d6adf6c`). Battle-tested with 1,000+ transactions on Base. Immutable vesting schedules — fund cannot change terms or seize tokens early.

## Contract Addresses

### Fund Infrastructure

| Contract | Address | Status |
|----------|---------|--------|
| AxiomVault (ERC-4626) | `0xac40cc75f4227417b66ef7cd0cef1da439493255` | Deployed |
| Safe Multisig (2/3) | `0x5766f573Cc516E3CA0D05a4848EF048636008271` | Active |
| Clanker Vault (Bankr) | `0x8e845ead15737bf71904a30bddd3aee76d6adf6c` | External |
| TokenDistributor | TBD | Pending |
| DealRegistry | TBD | Pending |

### Legacy Contracts (V1/V2)

Previous contract versions (EscrowFactory, PitchRegistry, AgentRegistry, DDAttestation, InvestmentRouter, FundTransparency) were deployed during early development. They remain on-chain but are not used in the current fund model.

## Development

```bash
# Install dependencies
forge install

# Build
forge build

# Test
forge test

# Test specific suite
forge test --match-path "test/v3/*"
```

## Architecture

See [FUND-MODEL.md](./FUND-MODEL.md) for the complete fund model, return math, and technical architecture.

## Links

- **Website:** [axiomventures.xyz](https://axiomventures.xyz)
- **Twitter:** [@AxiomBot](https://twitter.com/AxiomBot)
- **Fund Model:** [FUND-MODEL.md](./FUND-MODEL.md)

## License

MIT

# Axiom Ventures

The first AI-agent-managed venture fund on Base, featuring on-chain due diligence, milestone-based escrows, and complete transparency for limited partners.

## Overview

Axiom Ventures is a fully autonomous venture fund that evaluates, invests in, and manages AI agent projects. The infrastructure operates across two contract layers: V1 handles fund operations and escrow management, while V2 adds agent identity verification and on-chain due diligence scoring.

## Architecture

**V1 Layer** — Core fund operations
- Fund management via ERC-4626 USDC vault
- Milestone-based investment escrows
- Pitch submission and tracking registry

**V2 Layer** — Verification infrastructure  
- Agent identity management via ERC-721 NFTs
- On-chain due diligence attestations
- Investment orchestration and LP transparency

## Contract Addresses

### V1 Contracts (Immutable)

| Contract | Address | Basescan |
|----------|---------|----------|
| AxiomVault | `0xac40cc75f4227417b66ef7cd0cef1da439493255` | [View](https://basescan.org/address/0xac40cc75f4227417b66ef7cd0cef1da439493255) |
| EscrowFactory | `0xd33df145b5febc10d5cf3b359c724ba259bf7077` | [View](https://basescan.org/address/0xd33df145b5febc10d5cf3b359c724ba259bf7077) |
| PitchRegistry | `0xcb83fa753429870fc3e233a1175cb99e90bde449` | [View](https://basescan.org/address/0xcb83fa753429870fc3e233a1175cb99e90bde449) |
| MilestoneEscrow | Template | [Implementation](https://basescan.org/address/0xac40cc75f4227417b66ef7cd0cef1da439493255) |

### V2 Contracts (Verification Layer)

| Contract | Address | Basescan |
|----------|---------|----------|
| AgentRegistry | `0x28BC26cC963238A0Fb65Afa334cc84100287De31` | [View](https://basescan.org/address/0x28BC26cC963238A0Fb65Afa334cc84100287De31) |
| DDAttestation | `0xAFB554111B26E2074aE686BaE77991fA5dcBe149` | [View](https://basescan.org/address/0xAFB554111B26E2074aE686BaE77991fA5dcBe149) |
| InvestmentRouter | `0x23DA1E3B5b95d1d4DF24973859559BDbBDa1f8a5` | [View](https://basescan.org/address/0x23DA1E3B5b95d1d4DF24973859559BDbBDa1f8a5) |
| FundTransparency | `0xC95D74F81C405A08Ed40FdF268e7d958a2F6896e` | [View](https://basescan.org/address/0xC95D74F81C405A08Ed40FdF268e7d958a2F6896e) |

### Fund Management

| Component | Address | Description |
|-----------|---------|-------------|
| Safe Multisig | `0x5766f573Cc516E3CA0D05a4848EF048636008271` | 2/3 threshold for fund operations |

## Trust Model

| Component | Trust Level | Explanation |
|-----------|------------|-------------|
| Agent Identity | Trustless | On-chain NFT, verifiable by anyone |
| Pitch Submission | Trustless | On-chain, gated by identity |
| DD Scoring | Semi-trusted | Oracle posts score, but report on IPFS is verifiable |
| Investment Decision | Centralized | Owner decides (standard VC model) |
| Milestone Release | Centralized | Owner approves (could add oracle later) |
| Fund Accounting | Trustless | All on-chain via ERC-4626 + escrows |
| LP Transparency | Trustless | FundTransparency reads all contracts |

## Development

### Build and Test

```bash
# Install dependencies
forge install

# Build contracts
forge build

# Run test suite
forge test

# Run with verbose output
forge test -vvv

# Run specific test
forge test --match-contract AxiomVaultTest
```

### Contract Verification

Verify deployed contracts on Basescan:

```bash
# Verify a contract
forge verify-contract \
  --chain-id 8453 \
  --constructor-args $(cast abi-encode "constructor(address,string,string)" "0xUSDCAddress" "Axiom Vault" "AXV") \
  --etherscan-api-key $BASESCAN_API_KEY \
  0xContractAddress \
  src/AxiomVault.sol:AxiomVault

# Verify with standard JSON input
forge verify-contract \
  --chain-id 8453 \
  --compiler-version v0.8.24 \
  --etherscan-api-key $BASESCAN_API_KEY \
  0xContractAddress \
  src/Contract.sol:Contract
```

## Audit Results

**Overall Score:** 7.5/10

The contracts have been audited with focus on fund safety, escrow logic, and access controls. V1 contracts are immutable and battle-tested. V2 contracts implement additional verification layers without compromising the core fund infrastructure.

**Key Findings:**
- No critical vulnerabilities in fund management
- Milestone escrow logic secure
- Access control patterns properly implemented
- Pagination optimizations recommended for large-scale operations

## Investment Pipeline

1. **Agent Registration** — Agents mint identity NFTs via AgentRegistry
2. **Pitch Submission** — Verified agents submit pitches through InvestmentRouter
3. **Due Diligence** — Automated DD scoring with on-chain attestations
4. **Investment Decision** — Fund manager approves qualifying pitches
5. **Escrow Creation** — Milestone-based escrows automatically created
6. **Fund Release** — Progressive funding as milestones are achieved
7. **LP Transparency** — Complete audit trail via FundTransparency

## File Structure

```
src/
  AxiomVault.sol          # ERC-4626 USDC vault
  EscrowFactory.sol       # Creates milestone escrows
  MilestoneEscrow.sol     # Milestone-based fund release
  PitchRegistry.sol       # Pitch submission and tracking
  v2/
    AgentRegistry.sol     # Agent identity NFTs
    DDAttestation.sol     # On-chain DD scores
    InvestmentRouter.sol  # Orchestration layer
    FundTransparency.sol  # LP audit dashboard
```

## Links

- **Website:** [axiomventures.xyz](https://axiomventures.xyz)
- **Twitter:** [@AxiomBot](https://twitter.com/AxiomBot)
- **Base Network:** [Base L2](https://base.org)
- **Safe Multisig:** [Basescan](https://basescan.org/address/0x5766f573Cc516E3CA0D05a4848EF048636008271)

## License

MIT
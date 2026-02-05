# Axiom Ventures — Verifiable Infrastructure Architecture

## Design Principles
1. **Trustless verification** — every decision recorded on-chain with proof
2. **Seamless pipeline** — pitch → DD → fund → escrow in one connected flow
3. **Composable** — new contracts layer on top of deployed+verified V1 contracts
4. **No gaps** — LPs can trace every dollar from deposit to investment to milestone

## Current Contracts (Deployed + Verified on Base Mainnet)
| Contract | Address | Role |
|----------|---------|------|
| AxiomVault | `0xac40cc75f4227417b66ef7cd0cef1da439493255` | ERC-4626 USDC vault |
| EscrowFactory | `0xd33df145b5febc10d5cf3b359c724ba259bf7077` | Creates milestone escrows |
| PitchRegistry | `0xcb83fa753429870fc3e233a1175cb99e90bde449` | Pitch submission + tracking |
| MilestoneEscrow | (per-investment) | Milestone-based fund release |

**Limitation:** V1 contracts are immutable. EscrowFactory.createEscrow() is `onlyVault` (hardcoded to AxiomVault address). New contracts compose alongside V1, not replace them.

## New Contracts (V2 Layer)

### 1. AgentRegistry (ERC-721)
On-chain agent identity. Every agent that pitches must hold an identity NFT.

```
- mint(address agent, string metadataURI) → onlyOwner
- selfRegister(string metadataURI) → public, costs registration fee
- tokenURI returns IPFS metadata (name, description, links, contracts)
- balanceOf(agent) > 0 = verified agent
```

**Why:** The pitch page promises ERC-8004 identity verification. This delivers it.

### 2. DDAttestation (EAS-style)
On-chain due diligence scores. Every scored pitch has verifiable attestation.

```
- attest(uint256 pitchId, uint8 score, bytes32 reportHash) → onlyOracle
- getAttestation(pitchId) → (score, reportHash, timestamp, oracle)
- score: 0-100 composite
- reportHash: IPFS hash of full DD report
- oracle: address that submitted the attestation
```

**Why:** Pitch page promises automated DD scoring. Scores must live on-chain.

### 3. InvestmentRouter
The orchestration layer. Connects identity → pitch → DD → funding → escrow.

```
Pipeline:
1. submitPitch(agentId, ...) 
   → requires AgentRegistry.ownerOf(agentId) == msg.sender
   → calls PitchRegistry.submitPitch()
   → records agentId ↔ pitchId mapping

2. fundPitch(pitchId, milestoneAmounts, milestoneDescs, deadline)
   → onlyOwner (fund manager)
   → requires DDAttestation.getAttestation(pitchId).score >= MIN_SCORE
   → requires PitchRegistry.getPitch(pitchId).status == Approved
   → pulls USDC from vault (via approval)
   → calls EscrowFactory.createEscrow() [*see note]
   → records pitchId ↔ escrowAddress
   → emits InvestmentMade(pitchId, escrowAddress, amount)

3. getInvestment(pitchId) → full audit trail
   → agent identity, pitch details, DD score, escrow address, milestone status
```

**Note on EscrowFactory:** Since createEscrow is `onlyVault`, InvestmentRouter can't call it directly. Two options:
- A) Deploy EscrowFactoryV2 that accepts InvestmentRouter as authorized caller
- B) InvestmentRouter records the mapping, vault owner creates escrow separately, then InvestmentRouter.linkEscrow(pitchId, escrowAddress) connects them

Option B is simpler and keeps V1 contracts untouched. The "trustless" part is that the linkage is on-chain and verifiable — LPs can confirm escrow params match the pitch.

### 4. FundTransparency (View-only aggregator)
Read-only contract that provides a single entry point for LPs to audit everything.

```
- getPortfolio() → all funded pitches with escrow status
- getInvestmentDetail(pitchId) → agent, DD score, escrow, milestones
- getTotalDeployed() → sum of all active escrows
- getTotalReturned() → sum of all clawed-back/recovered funds
- getVaultHealth() → total assets, deployed, reserved, available
```

**Why:** LPs need one place to see everything. This is the "Bloomberg terminal" for the fund.

## Complete Flow (Trustless Pipeline)

```
Agent                    Axiom                         LP
  │                        │                            │
  │ 1. Register            │                            │
  │ ──AgentRegistry.mint──→│                            │
  │ ←──NFT minted──────────│                            │
  │                        │                            │
  │ 2. Submit Pitch        │                            │
  │ ──InvestmentRouter─────│                            │
  │   .submitPitch()       │                            │
  │   (verifies NFT)       │                            │
  │ ←──pitchId─────────────│                            │
  │                        │                            │
  │                        │ 3. Auto DD                 │
  │                        │ ──DDAttestation.attest()──→│ (visible on-chain)
  │                        │                            │
  │                        │ 4. Fund Pitch              │
  │                        │ ──InvestmentRouter         │
  │                        │   .fundPitch()             │
  │                        │   (checks DD score ≥ 65)   │
  │                        │   (creates escrow)         │
  │                        │   (records linkage)        │
  │                        │                            │
  │ 5. Hit Milestone       │                            │
  │ ──────────────────────→│                            │
  │                        │ ──MilestoneEscrow          │
  │                        │   .releaseMilestone()      │
  │ ←──USDC released───────│                            │
  │                        │                            │
  │                        │                            │ 6. Audit
  │                        │                            │ ──FundTransparency
  │                        │                            │   .getPortfolio()
  │                        │                            │ (sees everything)
```

## Trust Assumptions (Honest Assessment)
| Component | Trust Level | Explanation |
|-----------|------------|-------------|
| Agent Identity | Trustless | On-chain NFT, verifiable by anyone |
| Pitch Submission | Trustless | On-chain, gated by identity |
| DD Scoring | Semi-trusted | Oracle posts score, but report on IPFS is verifiable |
| Investment Decision | Centralized | Owner decides (standard VC model) |
| Milestone Release | Centralized | Owner approves (could add oracle later) |
| Fund Accounting | Trustless | All on-chain via ERC-4626 + escrows |
| LP Transparency | Trustless | FundTransparency reads all contracts |

## Pagination Fixes (from audit)
While building V2 layer, also deploy:
- **EscrowFactoryV2** with paginated `autoClawbackExpiredEscrows(start, count)`
- Or add pagination helpers in FundTransparency

## File Structure
```
src/
  AxiomVault.sol          ← deployed (V1)
  EscrowFactory.sol       ← deployed (V1)
  MilestoneEscrow.sol     ← deployed (V1)
  PitchRegistry.sol       ← deployed (V1)
  v2/
    AgentRegistry.sol     ← NEW: agent identity NFTs
    DDAttestation.sol     ← NEW: on-chain DD scores
    InvestmentRouter.sol  ← NEW: orchestration layer
    FundTransparency.sol  ← NEW: LP audit dashboard
```

# SomniaSol Mafia (Diamond)

Hardhat + viem project for deploying and upgrading the `MafiaDiamond` contract with facets.

## Supported Networks

- `somnia` (mainnet)
- `somnia_testnet`
- `avalanche_fuji` (Avalanche C-Chain testnet)
- `avalanche` (Avalanche C-Chain mainnet)

## Setup

Create `.env` in project root:

```bash
PRIVATE_KEY=0x...
SOMNIA_TESTNET_RPC_URL=https://dream-rpc.somnia.network/
AVALANCHE_FUJI_RPC_URL=https://api.avax-test.network/ext/bc/C/rpc
ETHERSCAN_API_KEY=your_key_optional
```

Install dependencies:

```bash
npm install
```

## Deploy

Somnia testnet:

```bash
npx hardhat run scripts/deploy-diamond.ts --network somnia_testnet
```

Avalanche Fuji:

```bash
npx hardhat run scripts/deploy-diamond.ts --network avalanche_fuji
```

Fuji faucet:

- https://build.avax.network/console/primary-network/faucet

## Tests

```bash
npx hardhat test
```

## Frontend

Frontend chain config is in `frontend/contracts.ts`.
Use `SOMNIA_TESTNET` or `AVALANCHE_FUJI` with your `DIAMOND_ADDRESS` after deployment.

## More Details

See `DEPLOYMENT.md` for architecture, GM mode, admin operations, and upgrade flow.

---

## 🚀 Recent Features (v1.1)

### 🏅 Tournament System
- **Freeroll & Buy-in**: Support for both organizer-funded and player-funded tournaments.
- **Weighted Payouts**: Winners receive shares based on status (Alive 2x, Dead 1x).
- **Anti-Spam**: Per-organizer tournament limits and registration deadlines.

### 🛡️ Advanced Security
- **Cross-Facet Reentrancy Guard**: Shared storage-level lock for Diamond proxy protection.
- **ZK Replay Protection**: Nullifiers prevent reuse of the same proof.
- **Front-running Protection**: Payouts restricted to winners/GM.
- **Timelock Withdrawal**: 24h delay for platform fee withdrawals.
- **Spectator Safety**: Obfuscated events to prevent role leaks in block explorers.

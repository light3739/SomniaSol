# SomniaSol Mafia — Deployment & Architecture Guide

## Quick Deploy to Avalanche Fuji (C-Chain Testnet)

1. Add env vars in `.env`:

```bash
PRIVATE_KEY=0x...
AVALANCHE_FUJI_RPC_URL=https://api.avax-test.network/ext/bc/C/rpc
ETHERSCAN_API_KEY=your_api_key_optional
```

2. Get test AVAX from faucet:

- https://build.avax.network/console/primary-network/faucet

3. Deploy:

```bash
npx hardhat run scripts/deploy-diamond.ts --network avalanche_fuji
```

4. Verify (optional):

```bash
npx hardhat verify --network avalanche_fuji <DEPLOYED_CONTRACT_ADDRESS> <CONSTRUCTOR_ARGS_IF_ANY>
```

Notes:
- `MafiaDiamond` has constructor arg: owner address.
- Most frontend calls should go through the deployed Diamond proxy address.

## Deployed Contracts (Avalanche Fuji — chainId 43113)

| Contract | Address | Verified |
|---|---|---|
| **MafiaDiamond** (proxy) | `0x3c1bd1923f8318247e2b60e41b0f280391c4e1e1` | [✅](https://testnet.snowtrace.io/address/0x3c1bd1923f8318247e2b60e41b0f280391c4e1e1#code) |
| Groth16Verifier | `0x32d3612009c2d30c71c19d2548822e1eecb8d165` | [✅](https://testnet.snowtrace.io/address/0x32d3612009c2d30c71c19d2548822e1eecb8d165#code) |
| LobbyFacet | `0xb718ba5b6bccfa418f2971ea094f5b52a105c049` | [✅](https://testnet.snowtrace.io/address/0xb718ba5b6bccfa418f2971ea094f5b52a105c049#code) |
| ShuffleFacet | `0xffa18547fde97a6d2f4df8af0ac545db9f5ae789` | [✅](https://testnet.snowtrace.io/address/0xffa18547fde97a6d2f4df8af0ac545db9f5ae789#code) |
| VotingFacet | `0x78616f773e7d9fef5dd7c6583dc642b238033a61` | [✅](https://testnet.snowtrace.io/address/0x78616f773e7d9fef5dd7c6583dc642b238033a61#code) |
| NightFacet | `0x72d4cfa33b2e7e6cce4a85bbd31147659f04a3be` | [✅](https://testnet.snowtrace.io/address/0x72d4cfa33b2e7e6cce4a85bbd31147659f04a3be#code) |
| GameEndFacet | `0xca5556d70fbb02544a1418c31cbc1a032d9676d8` | [✅](https://testnet.snowtrace.io/address/0xca5556d70fbb02544a1418c31cbc1a032d9676d8#code) |

**Owner:** `0x30e123bda62a8dae0b12f18770085505bf982a2b`

---

## Deployed Contracts (Somnia Testnet — chainId 50312)

| Contract | Address | Verified |
|---|---|---|
| **MafiaDiamond** (proxy) | `0xb34f8430f8a755c8c1bdc9dd19f14e263fc3f6b1` | [✅](https://shannon-explorer.somnia.network/address/0xb34f8430f8a755c8c1bdc9dd19f14e263fc3f6b1#code) |
| Groth16Verifier | `0xfa208d4ce645c9ce9c1957267d172d3627b9bd94` | [✅](https://shannon-explorer.somnia.network/address/0xfa208d4ce645c9ce9c1957267d172d3627b9bd94#code) |
| LobbyFacet | `0x5e0b3dbc999dc367c8f403bcf6169d6a599025ab` | [✅](https://shannon-explorer.somnia.network/address/0x5e0b3dbc999dc367c8f403bcf6169d6a599025ab#code) |
| ShuffleFacet | `0x08d216915a693a9715cbaecfd34ebff272fd28ea` | [✅](https://shannon-explorer.somnia.network/address/0x08d216915a693a9715cbaecfd34ebff272fd28ea#code) |
| VotingFacet | `0xc1bd63870d30fa3d7f724dddeb28d6b0be3ca331` | ✅ |
| NightFacet | `0x4a3609c0acecf27b5cb02b11bd53a3ecf23dff60` | [✅](https://shannon-explorer.somnia.network/address/0x4a3609c0acecf27b5cb02b11bd53a3ecf23dff60#code) |
| GameEndFacet | `0xdbe019aef9864e859f069f2936a502e5ff051bc9` | [✅](https://shannon-explorer.somnia.network/address/0xdbe019aef9864e859f069f2936a502e5ff051bc9#code) |

**Owner:** `0x30e123bda62a8dae0b12f18770085505bf982a2b`

---

## Architecture: Diamond Proxy

```
Frontend  ──►  MafiaDiamond (0xb34f...)  ──delegatecall──►  Facets
                    │
                    ├── LobbyFacet     (create/join rooms, admin, session keys, views)
                    ├── ShuffleFacet   (deck commit/reveal, role assignment)
                    ├── VotingFacet    (day voting, elimination, timeout, refunds)
                    ├── NightFacet     (night actions: decentralized OR Game Master)
                    └── GameEndFacet   (ZK Groth16 endgame verification)
```

**Frontend interacts with ONE address** — `MafiaDiamond`. All function calls are routed to the correct facet automatically via `delegatecall`.

---

## Frontend Integration

### What to copy

Copy the entire `frontend/` folder to your frontend project:

```
frontend/
├── contracts.ts              # TypeScript config: addresses, ABI, chain definition
├── MafiaDiamondABI.json      # Merged ABI (all facets) — import this
├── abis.json                 # Individual per-facet ABIs (optional, for reference)
└── deployed-addresses.json   # Raw addresses JSON
```

### Usage with viem

```typescript
import { createPublicClient, createWalletClient, http, custom, parseEther } from 'viem';
import { DIAMOND_ADDRESS, DIAMOND_ABI, SOMNIA_TESTNET } from './frontend/contracts';

// Read client
const publicClient = createPublicClient({
  chain: SOMNIA_TESTNET,
  transport: http(),
});

// Write client (MetaMask / injected wallet)
const walletClient = createWalletClient({
  chain: SOMNIA_TESTNET,
  transport: custom(window.ethereum!),
});

// ─── Read example ───
const room = await publicClient.readContract({
  address: DIAMOND_ADDRESS,
  abi: DIAMOND_ABI,
  functionName: 'getRoom',
  args: [1n],
});

// ─── Write example ───
const hash = await walletClient.writeContract({
  address: DIAMOND_ADDRESS,
  abi: DIAMOND_ABI,
  functionName: 'createAndJoin',
  args: [5, false],          // maxPlayers, useGameMaster
  value: parseEther('0.01'), // deposit
});

// ─── Listen to events ───
const unwatch = publicClient.watchContractEvent({
  address: DIAMOND_ADDRESS,
  abi: DIAMOND_ABI,
  eventName: 'PlayerJoined',
  onLogs: (logs) => console.log(logs),
});
```

---

## Game Master (GM) Mode

### What is GM mode?

In **decentralized mode** (`useGameMaster = false`), night actions use commit-reveal on-chain. This works but leaks role info through events (who submitted a kill commit, a heal commit, etc.).

In **GM mode** (`useGameMaster = true`), a trusted server collects night actions off-chain and submits a single `resolveNightAsGameMaster(roomId, killTarget, healTarget)` transaction. This hides *who* performed each action — only the result is visible on-chain.

### Setup Steps

#### 1. Set the GM address on-chain

The contract owner calls `setGameMaster(address)` to register the GM's wallet:

```typescript
await walletClient.writeContract({
  address: DIAMOND_ADDRESS,
  abi: DIAMOND_ABI,
  functionName: 'setGameMaster',
  args: ['0xGM_WALLET_ADDRESS'],
});
```

#### 2. Build the GM server

A minimal Node.js/Express server:

```
gm-server/
├── index.ts          # Express app
├── game-state.ts     # Track active rooms, night actions
└── chain.ts          # viem client for submitting resolveNightAsGameMaster
```

**Core logic:**

```typescript
// chain.ts — GM wallet client
import { createWalletClient, http } from 'viem';
import { privateKeyToAccount } from 'viem/accounts';
import { DIAMOND_ADDRESS, DIAMOND_ABI, SOMNIA_TESTNET } from '../frontend/contracts';

const account = privateKeyToAccount(process.env.GM_PRIVATE_KEY as `0x${string}`);

export const gmClient = createWalletClient({
  account,
  chain: SOMNIA_TESTNET,
  transport: http(),
});

export async function resolveNight(roomId: bigint, killTarget: number, healTarget: number) {
  return gmClient.writeContract({
    address: DIAMOND_ADDRESS,
    abi: DIAMOND_ABI,
    functionName: 'resolveNightAsGameMaster',
    args: [roomId, killTarget, healTarget],
  });
}
```

```typescript
// index.ts — Express endpoints
import express from 'express';
import { resolveNight } from './chain';

const app = express();
app.use(express.json());

// In-memory night action storage (per room)
const nightActions: Map<bigint, { kills: Map<string, number>; heals: Map<string, number> }> = new Map();

// Player submits their night action privately to GM
app.post('/night-action', async (req, res) => {
  const { roomId, playerAddress, actionType, targetIndex, signature } = req.body;

  // 1. Verify signature (player signed: roomId + actionType + targetIndex)
  // 2. Verify player is alive & has the claimed role (read contract state)
  // 3. Store action

  const room = nightActions.get(BigInt(roomId)) || { kills: new Map(), heals: new Map() };
  if (actionType === 'kill') room.kills.set(playerAddress, targetIndex);
  if (actionType === 'heal') room.heals.set(playerAddress, targetIndex);
  nightActions.set(BigInt(roomId), room);

  res.json({ ok: true });
});

// GM resolves night when all actions are in (or timeout)
app.post('/resolve-night', async (req, res) => {
  const { roomId } = req.body;
  const room = nightActions.get(BigInt(roomId));
  if (!room) return res.status(400).json({ error: 'no actions' });

  // Mafia consensus: majority target
  const killVotes = [...room.kills.values()];
  const killTarget = majorityVote(killVotes); // implement majority logic

  // Doctor heal
  const healTarget = room.heals.size > 0 ? [...room.heals.values()][0] : 255; // 255 = no heal

  const hash = await resolveNight(BigInt(roomId), killTarget, healTarget);
  nightActions.delete(BigInt(roomId));

  res.json({ txHash: hash });
});

app.listen(3001, () => console.log('GM server on :3001'));
```

#### 3. Frontend integration

When a room uses GM mode, the frontend sends night actions to the GM server instead of calling contract functions:

```typescript
// Instead of on-chain commitNightAction...
if (room.useGameMaster) {
  // Sign the action locally
  const signature = await walletClient.signMessage({
    message: `night:${roomId}:kill:${targetIndex}`,
  });
  // Send to GM server
  await fetch('https://your-gm-server.com/night-action', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ roomId, playerAddress, actionType: 'kill', targetIndex, signature }),
  });
} else {
  // Decentralized: commit on-chain
  await walletClient.writeContract({ ... commitNightAction ... });
}
```

#### 4. Run

```bash
cd gm-server
npm install express viem
GM_PRIVATE_KEY=0x... npx tsx index.ts
```

### Security notes for GM

- The GM wallet **must** be the address registered via `setGameMaster()`
- The GM can only call `resolveNightAsGameMaster()` — no admin access
- The GM can lie about kill/heal targets (trust tradeoff for privacy)
- For production: run GM in AWS Nitro Enclave (TEE) so nobody — not even you — can see the private logic
- The contract validates that `msg.sender == gameMaster` and the room has `useGameMaster == true`

---

## Admin Functions (Owner only)

| Function | Purpose |
|---|---|
| `setZkVerifier(address)` | Set ZK verifier contract address |
| `setGameMaster(address)` | Set/change GM wallet |
| `setDefaultDeposit(uint256)` | Default deposit for new rooms |
| `pause()` / `unpause()` | Emergency pause/unpause all game actions |
| `withdrawFees(address)` | Withdraw accumulated protocol fees |
| `transferOwnership(address)` | Transfer Diamond ownership |
| `addFacet(address, bytes4[])` | Register new facet selectors |
| `replaceFacet(address, bytes4[])` | Upgrade facet implementation |
| `removeSelectors(bytes4[])` | Remove function selectors |

---

## Upgrading Facets

To upgrade a facet (e.g., fix a bug in VotingFacet):

1. Deploy new facet: `npx hardhat run scripts/deploy-new-facet.ts --network somnia_testnet`
2. Call `replaceFacet(newAddress, selectors)` on Diamond — this redirects those function selectors to the new implementation
3. Verify the new facet on explorer
4. **No state migration needed** — Diamond storage persists across upgrades

---

## Testing

```bash
# Run all 84 tests (23 happy + 61 adversarial)
npx hardhat test

# Run specific test file
npx hardhat test test/MafiaDiamond.ts
npx hardhat test test/MafiaDiamond.adversarial.ts
```

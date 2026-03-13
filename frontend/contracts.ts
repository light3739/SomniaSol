/**
 * SomniaSol Mafia — Frontend Contract Config
 *
 * Usage with viem:
 *   import { DIAMOND_ADDRESS, DIAMOND_ABI, SOMNIA_TESTNET } from './contracts';
 *   const client = createPublicClient({ chain: SOMNIA_TESTNET, transport: http() });
 *   const walletClient = createWalletClient({ chain: SOMNIA_TESTNET, transport: custom(window.ethereum) });
 *
 *   // ALL calls go to DIAMOND_ADDRESS with DIAMOND_ABI
 *   const room = await client.readContract({ address: DIAMOND_ADDRESS, abi: DIAMOND_ABI, functionName: 'getRoom', args: [1n] });
 *   await walletClient.writeContract({ address: DIAMOND_ADDRESS, abi: DIAMOND_ABI, functionName: 'createAndJoin', args: [5, false], value: parseEther('0.01') });
 */

import { defineChain } from 'viem';
import MafiaDiamondABI from './MafiaDiamondABI.json';

// ─── Chain ────────────────────────────────────────────────
export const SOMNIA_TESTNET = defineChain({
  id: 50312,
  name: 'Somnia Testnet',
  nativeCurrency: { name: 'STT', symbol: 'STT', decimals: 18 },
  rpcUrls: { default: { http: ['https://dream-rpc.somnia.network/'] } },
  blockExplorers: { default: { name: 'Explorer', url: 'https://shannon-explorer.somnia.network' } },
  testnet: true,
});

export const AVALANCHE_FUJI = defineChain({
  id: 43113,
  name: 'Avalanche Fuji C-Chain',
  nativeCurrency: { name: 'Avalanche', symbol: 'AVAX', decimals: 18 },
  rpcUrls: { default: { http: ['https://api.avax-test.network/ext/bc/C/rpc'] } },
  blockExplorers: { default: { name: 'Snowtrace', url: 'https://testnet.snowtrace.io' } },
  testnet: true,
});

// ─── Unified Frontend Config (all in one file) ───────────
export const NETWORKS = {
  somnia_testnet: SOMNIA_TESTNET,
  avalanche_fuji: AVALANCHE_FUJI,
} as const;

export type SupportedNetwork = keyof typeof NETWORKS;

export const DEPLOYMENTS = {
  somnia_testnet: {
    chain: SOMNIA_TESTNET,
    chainId: 50312,
    explorer: 'https://shannon-explorer.somnia.network',
    contracts: {
      MafiaDiamond: '0xb34f8430f8a755c8c1bdc9dd19f14e263fc3f6b1',
      Groth16Verifier: '0xfa208d4ce645c9ce9c1957267d172d3627b9bd94',
      LobbyFacet: '0x5e0b3dbc999dc367c8f403bcf6169d6a599025ab',
      ShuffleFacet: '0x08d216915a693a9715cbaecfd34ebff272fd28ea',
      VotingFacet: '0xc1bd63870d30fa3d7f724dddeb28d6b0be3ca331',
      NightFacet: '0x4a3609c0acecf27b5cb02b11bd53a3ecf23dff60',
      GameEndFacet: '0xdbe019aef9864e859f069f2936a502e5ff051bc9',
    },
  },
  avalanche_fuji: {
    chain: AVALANCHE_FUJI,
    chainId: 43113,
    explorer: 'https://testnet.snowtrace.io',
    contracts: {
      MafiaDiamond: '0x3c1bd1923f8318247e2b60e41b0f280391c4e1e1',
      Groth16Verifier: '0x5a4dec55540a158cce68c30b6d21a0f1be0fcdad',
      LobbyFacet: '0xb718ba5b6bccfa418f2971ea094f5b52a105c049',
      ShuffleFacet: '0xffa18547fde97a6d2f4df8af0ac545db9f5ae789',
      VotingFacet: '0x78616f773e7d9fef5dd7c6583dc642b238033a61',
      NightFacet: '0x72d4cfa33b2e7e6cce4a85bbd31147659f04a3be',
      GameEndFacet: '0xcb5a455e35f82e607b0f77a1d6f0fff45db68cc4',

    },
  },
} as const;

/** Change this value when switching frontend environment */
export const ACTIVE_NETWORK: SupportedNetwork = 'avalanche_fuji';

export const ACTIVE_DEPLOYMENT = DEPLOYMENTS[ACTIVE_NETWORK];

export function getDeployment(network: SupportedNetwork) {
  return DEPLOYMENTS[network];
}

// Backward-compatible exports used across frontend/gm-server
/** The single address your frontend talks to for ALL game functions */
export const DIAMOND_ADDRESS = ACTIVE_DEPLOYMENT.contracts.MafiaDiamond;

/** Facet implementation addresses (for reference only, not used in calls) */
export const FACETS = {
  LobbyFacet: ACTIVE_DEPLOYMENT.contracts.LobbyFacet,
  ShuffleFacet: ACTIVE_DEPLOYMENT.contracts.ShuffleFacet,
  VotingFacet: ACTIVE_DEPLOYMENT.contracts.VotingFacet,
  NightFacet: ACTIVE_DEPLOYMENT.contracts.NightFacet,
  GameEndFacet: ACTIVE_DEPLOYMENT.contracts.GameEndFacet,
} as const;

export const ZK_VERIFIER = ACTIVE_DEPLOYMENT.contracts.Groth16Verifier;

// ─── ABI ──────────────────────────────────────────────────
/** Merged ABI from all facets — use with DIAMOND_ADDRESS */
export const DIAMOND_ABI = MafiaDiamondABI;

// ─── Function → Facet mapping (for debugging) ────────────
export const FUNCTION_MAP = {
  // LobbyFacet
  createAndJoin: 'LobbyFacet',
  joinRoom: 'LobbyFacet',
  startGame: 'LobbyFacet',
  setZkVerifier: 'LobbyFacet',
  setGameMaster: 'LobbyFacet',
  setDefaultDeposit: 'LobbyFacet',
  pause: 'LobbyFacet',
  unpause: 'LobbyFacet',
  withdrawFees: 'LobbyFacet',
  registerSessionKey: 'LobbyFacet',
  getPlayers: 'LobbyFacet',
  getRoom: 'LobbyFacet',
  getDeck: 'LobbyFacet',
  getPlayerDeposit: 'LobbyFacet',
  isSessionKeyValid: 'LobbyFacet',

  // ShuffleFacet
  commitDeck: 'ShuffleFacet',
  revealDeck: 'ShuffleFacet',
  shareKeysToAll: 'ShuffleFacet',
  commitAndConfirmRole: 'ShuffleFacet',
  commitRole: 'ShuffleFacet',
  confirmRole: 'ShuffleFacet',

  // VotingFacet
  startVoting: 'VotingFacet',
  vote: 'VotingFacet',
  revealRole: 'VotingFacet',
  endGameAutomatically: 'VotingFacet',
  forcePhaseTimeout: 'VotingFacet',
  claimRefund: 'VotingFacet',

  // NightFacet
  commitNightAction: 'NightFacet',
  revealNightAction: 'NightFacet',
  sendMafiaMessage: 'NightFacet',
  commitMafiaTarget: 'NightFacet',
  revealMafiaTarget: 'NightFacet',
  endNight: 'NightFacet',
  resolveNightAsGameMaster: 'NightFacet',

  // GameEndFacet
  endGameZK: 'GameEndFacet',
} as const;

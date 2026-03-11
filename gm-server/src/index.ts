import express from 'express';
import cors from 'cors';
import { verifyMessage, type Address } from 'viem';
import {
  getRoom,
  getPlayers,
  hasCommittedRole,
  getSessionKey,
  getRevealedDeckCard,
  resolveNight,
  assertChainConfigOrThrow,
  GM_ADDRESS,
  DIAMOND_ADDRESS,
  GamePhase,
  FLAGS,
  ACTION_TO_ROLE,
} from './chain.js';
import {
  getOrCreateNightState,
  clearNightState,
  getNightState,
  getAllNightStates,
  calculateMafiaConsensus,
  getDoctorHeal,
  type NightAction,
} from './game-state.js';
import { eciesEncrypt } from './ecies.js';

const ALLOWED_ORIGINS = [
  'https://mafiaonchain.live',
  'https://www.mafiaonchain.live',
  'https://test.mafiaonchain.live',
  'http://localhost:3000',
  ...(process.env.CORS_EXTRA_ORIGIN ? [process.env.CORS_EXTRA_ORIGIN] : []),
];

const app = express();
app.use(cors({ origin: ALLOWED_ORIGINS }));
app.use(express.json());

const PORT = Number(process.env.PORT) || 3001;
const ZERO_ADDR = '0x0000000000000000000000000000000000000000' as Address;

// ─── SRA Key Store ────────────────────────────────────────
// roomId -> playerAddress(lowercase) -> decryptionKey (bigint as decimal string)
// In-memory: cleared on GM restart. Acceptable for testnet; add Redis for production.
const sraKeys = new Map<string, Map<string, string>>();

// ─── SRA Arithmetic ──────────────────────────────────────
// Must match PRIME in frontend shuffleService.ts exactly
const SRA_PRIME = BigInt(
  '0xFFFFFFFFFFFFFFFFC90FDAA22168C234C4C6628B80DC1CD1' +
  '29024E088A67CC74020BBEA63B139B22514A08798E3404DD' +
  'EF9519B3CD3A431B302B0A6DF25F14374FE1356D6D51C245' +
  'E485B576625E7EC6F44C42E9A637ED6B0BFF5CB6F406B7ED' +
  'EE386BFB5A899FA5AE9F24117C4B1FE649286651ECE65381' +
  'FFFFFFFFFFFFFFFF'
);

function modPow(base: bigint, exp: bigint, mod: bigint): bigint {
  let result = 1n;
  base = base % mod;
  while (exp > 0n) {
    if (exp % 2n === 1n) result = (result * base) % mod;
    exp = exp / 2n;
    base = (base * base) % mod;
  }
  return result;
}

// Must match getCardOffset() in frontend shuffleService.ts exactly
function getCardOffset(roomId: string): number {
  const id = parseInt(roomId) || 0;
  return 100 + ((id * 7919 + 104729) % 10000);
}

function cardValueToRole(rawNum: string, roomId: string): string {
  const offset = getCardOffset(roomId);
  const n = parseInt(rawNum) - offset;
  switch (n) {
    case 1: return 'MAFIA';
    case 2: return 'DOCTOR';
    case 3: return 'DETECTIVE';
    case 4: return 'CIVILIAN';
    default: return 'UNKNOWN';
  }
}

// ─── Investigation Proofs ────────────────────────────────
interface InvestigationProof {
  targetAddress: Address;
  timestamp: number;
}

const investigationProofs = new Map<string, Map<string, InvestigationProof>>();

function storeInvestigationProof(roomId: bigint, detective: Address, target: Address) {
  const roomKey = roomId.toString();
  let roomProofs = investigationProofs.get(roomKey);
  if (!roomProofs) {
    roomProofs = new Map<string, InvestigationProof>();
    investigationProofs.set(roomKey, roomProofs);
  }
  roomProofs.set(detective.toLowerCase(), { targetAddress: target, timestamp: Date.now() });
}

function getInvestigationProof(roomId: bigint, detective: Address): InvestigationProof | null {
  return investigationProofs.get(roomId.toString())?.get(detective.toLowerCase()) || null;
}

// ─── Signature Verification ──────────────────────────────
async function verifyAuthorizedSignature(params: {
  roomId: string;
  signature: `0x${string}`;
  playerAddress: string;
  signerAddress?: string;
  buildLegacyMessage: () => string;
  buildModernMessage: (nonce: string, timestamp: number) => string;
  nonce?: string;
  timestamp?: number;
}): Promise<{ ok: true; signer: string } | { ok: false; error: string; status: number }> {
  const {
    roomId, signature, playerAddress, signerAddress,
    buildLegacyMessage, buildModernMessage, nonce, timestamp,
  } = params;

  const normalizedPlayer = playerAddress.toLowerCase();
  const normalizedSigner = (signerAddress || playerAddress).toLowerCase();

  let valid = false;

  // 1) Modern format (nonce + timestamp)
  if (nonce && timestamp !== undefined) {
    const tsNum = Number(timestamp);
    if (Number.isFinite(tsNum)) {
      valid = await verifyMessage({
        address: normalizedSigner as Address,
        message: buildModernMessage(nonce, tsNum),
        signature,
      });
    }
  }

  // 2) Legacy fallback
  if (!valid) {
    valid = await verifyMessage({
      address: normalizedPlayer as Address,
      message: buildLegacyMessage(),
      signature,
    });
    if (valid) return { ok: true, signer: normalizedPlayer };
  }

  if (!valid) return { ok: false, error: 'Invalid signature', status: 401 };

  // 3) Session key verification
  if (normalizedSigner !== normalizedPlayer) {
    try {
      const session = await getSessionKey(normalizedPlayer as Address) as any;
      const sessionAddress = String(session.sessionAddress || '').toLowerCase();
      const expiresAt = Number(session.expiresAt || 0);
      const sessionRoomId = Number(session.roomId || 0);
      const isActive = Boolean(session.isActive);

      if (!sessionAddress || sessionAddress !== normalizedSigner)
        return { ok: false, error: 'Session key is not registered for this player', status: 403 };
      if (!isActive || expiresAt <= Math.floor(Date.now() / 1000))
        return { ok: false, error: 'Session key inactive or expired', status: 403 };
      if (sessionRoomId !== Number(BigInt(roomId)))
        return { ok: false, error: 'Session key room mismatch', status: 403 };
    } catch (e: any) {
      return { ok: false, error: `Session verification failed: ${e?.message || 'unknown'}`, status: 500 };
    }
  }

  return { ok: true, signer: normalizedSigner };
}

// ─── Health ───────────────────────────────────────────────
app.get('/health', (_req, res) => {
  res.json({
    status: 'ok',
    gm: GM_ADDRESS,
    diamond: DIAMOND_ADDRESS,
    activeRooms: getAllNightStates().size,
    uptime: process.uptime(),
  });
});

// ─── Submit SRA Decryption Key ────────────────────────────
// Players call this during REVEAL phase to hand their SRA decryption key to GM.
// The key is NEVER published on-chain — only dummy bytes go on-chain.
// GM uses collected keys to decrypt each player's card and serve their role via /my-role.
app.post('/submit-sra-key', async (req, res) => {
  try {
    const { roomId, playerAddress, sraKey, signature, signerAddress, nonce, timestamp } = req.body;

    if (!roomId || !playerAddress || !sraKey || !signature)
      return res.status(400).json({ error: 'Missing fields: roomId, playerAddress, sraKey, signature' });

    // Validate sraKey is a safe decimal bigint string (prevent injection)
    if (!/^\d+$/.test(String(sraKey)))
      return res.status(400).json({ error: 'sraKey must be a decimal bigint string' });

    // Verify signature
    const check = await verifyAuthorizedSignature({
      roomId: String(roomId),
      signature: signature as `0x${string}`,
      playerAddress: String(playerAddress),
      signerAddress, nonce,
      timestamp: timestamp !== undefined ? Number(timestamp) : undefined,
      buildLegacyMessage: () => `submit-key:${roomId}:${sraKey}`,
      buildModernMessage: (n, ts) => `submit-key:${roomId}:${sraKey}:${n}:${ts}`,
    });
    if (!check.ok) return res.status(check.status).json({ error: check.error });

    // Verify player is actually in this room (prevents key spam from non-participants)
    const rid = BigInt(roomId);
    const players = await getPlayers(rid);
    const player = players.find(p => p.wallet.toLowerCase() === playerAddress.toLowerCase());
    if (!player)
      return res.status(403).json({ error: 'Player not in room' });

    // Store key
    if (!sraKeys.has(String(roomId))) sraKeys.set(String(roomId), new Map());
    sraKeys.get(String(roomId))!.set(playerAddress.toLowerCase(), String(sraKey));

    const count = sraKeys.get(String(roomId))!.size;
    console.log(`[sra-key] Room ${roomId}: stored key from ${playerAddress} (${count}/${players.length} total)`);

    return res.json({ ok: true, keysCollected: count, keysNeeded: players.length });
  } catch (err: any) {
    console.error('[submit-sra-key] Error:', err.message);
    return res.status(500).json({ error: err.message });
  }
});

// ─── Get My Role ──────────────────────────────────────────
// Called by each player after AllKeysShared event.
// GM:
//   1. Verifies all SRA keys are present
//   2. Reads player's encrypted card from contract
//   3. Applies ALL collected SRA decryption keys (SRA is commutative)
//   4. Maps decrypted number → role string
//   5. Re-encrypts role with player's ECIES public key (only they can decrypt)
//   6. Returns { encrypted: EciesEncrypted }
app.get('/my-role/:roomId', async (req, res) => {
  try {
    const { roomId } = req.params;
    const { playerAddress, signature, signerAddress, nonce, timestamp } = req.query as Record<string, string>;

    if (!playerAddress || !signature)
      return res.status(400).json({ error: 'Missing query params: playerAddress, signature' });

    // 1. Verify signature
    const check = await verifyAuthorizedSignature({
      roomId,
      signature: signature as `0x${string}`,
      playerAddress,
      signerAddress,
      nonce,
      timestamp: timestamp !== undefined ? Number(timestamp) : undefined,
      buildLegacyMessage: () => `my-role:${roomId}:${playerAddress.toLowerCase()}`,
      buildModernMessage: (n, ts) => `my-role:${roomId}:${playerAddress.toLowerCase()}:${n}:${ts}`,
    });
    if (!check.ok) return res.status(check.status).json({ error: check.error });

    const rid = BigInt(roomId);

    // 2. Get player list and find requesting player's index
    const players = await getPlayers(rid);
    const myIndex = players.findIndex(
      p => p.wallet.toLowerCase() === playerAddress.toLowerCase()
    );
    if (myIndex === -1)
      return res.status(403).json({ error: 'Player not in room' });

    // 3. Check we have ALL players' SRA keys
    const roomKeys = sraKeys.get(String(roomId));
    const allAddresses = players.map(p => p.wallet.toLowerCase());
    const missingKeys = allAddresses.filter(a => !roomKeys?.has(a));

    if (missingKeys.length > 0) {
      console.log(`[my-role] Room ${roomId}: waiting for ${missingKeys.length} more keys from: ${missingKeys.join(', ')}`);
      return res.status(202).json({
        pending: true,
        keysCollected: roomKeys?.size ?? 0,
        keysNeeded: players.length,
      });
    }

    // 4. Read this player's encrypted card from contract
    let encryptedCard = await getRevealedDeckCard(rid, myIndex);
    if (!encryptedCard || encryptedCard === '')
      return res.status(500).json({ error: 'Deck card not found on-chain for this player index' });

    // 5. Apply ALL SRA decryption keys (order doesn't matter — SRA is commutative)
    // Each key was used to encrypt during the shuffle phase, so all must decrypt
    for (const [addr, keyStr] of roomKeys!.entries()) {
      try {
        const d = BigInt(keyStr);
        const v = BigInt(encryptedCard);
        encryptedCard = modPow(v, d, SRA_PRIME).toString();
      } catch (e) {
        console.error(`[my-role] Failed to apply SRA key from ${addr}:`, e);
        return res.status(500).json({ error: `SRA decryption failed for key from ${addr}` });
      }
    }

    // 6. Map decrypted number → role string
    const roleStr = cardValueToRole(encryptedCard, roomId);
    if (roleStr === 'UNKNOWN') {
      console.error(`[my-role] Room ${roomId}: unexpected card value "${encryptedCard}" for player ${playerAddress}. Offset: ${getCardOffset(roomId)}`);
      return res.status(500).json({
        error: 'Decryption produced unexpected value — possible key mismatch or missing key',
      });
    }

    // 7. Get player's ECIES public key (registered on-chain during joinRoom)
    const playerOnChain = players[myIndex];
    const pubKeyHex = (playerOnChain.publicKey as string).replace(/^0x/, '');

    if (!pubKeyHex || pubKeyHex.length < 130) {
      return res.status(500).json({
        error: 'Player has no valid ECIES public key registered on-chain. Re-join the room.',
      });
    }

    // 8. ECIES-encrypt role — only this player can decrypt with their private key
    const encrypted = await eciesEncrypt(roleStr, pubKeyHex);

    console.log(`[my-role] Room ${roomId}: served ${roleStr} to ${playerAddress} (ECIES-encrypted)`);
    return res.json({ encrypted });

  } catch (err: any) {
    console.error('[my-role] Error:', err.message);
    return res.status(500).json({ error: err.message });
  }
});

// ─── Investigation Proof (GM-verified) ───────────────────
app.post('/investigation-proof', async (req, res) => {
  try {
    const { roomId, detectiveAddress, targetAddress, signature, signerAddress, nonce, timestamp } = req.body;

    if (!roomId || !detectiveAddress || !targetAddress || !signature)
      return res.status(400).json({ error: 'Missing fields: roomId, detectiveAddress, targetAddress, signature' });

    const rid = BigInt(roomId);
    const detective = String(detectiveAddress).toLowerCase() as Address;
    const target = String(targetAddress).toLowerCase() as Address;
    const signer = (String(signerAddress || detectiveAddress)).toLowerCase() as Address;

    let valid = false;
    const legacyMessage = `investigate:${roomId}:${targetAddress}`;

    if (nonce && timestamp !== undefined) {
      const tsNum = Number(timestamp);
      if (Number.isFinite(tsNum)) {
        valid = await verifyMessage({
          address: signer,
          message: `investigate:${roomId}:${targetAddress}:${nonce}:${tsNum}`,
          signature: signature as `0x${string}`,
        });
      }
    }

    if (!valid) {
      valid = await verifyMessage({
        address: signer,
        message: legacyMessage,
        signature: signature as `0x${string}`,
      });
    }

    if (!valid) return res.status(401).json({ error: 'Invalid signature' });

    if (signer !== detective) {
      const session = await getSessionKey(detective) as any;
      const sessionAddress = String(session.sessionAddress || '').toLowerCase();
      const expiresAt = Number(session.expiresAt || 0);
      const sessionRoomId = Number(session.roomId || 0);
      const isActive = Boolean(session.isActive);

      if (!sessionAddress || sessionAddress !== signer)
        return res.status(403).json({ error: 'Session key is not registered for this detective' });
      if (!isActive || expiresAt <= Math.floor(Date.now() / 1000))
        return res.status(403).json({ error: 'Session key inactive or expired' });
      if (sessionRoomId !== Number(rid))
        return res.status(403).json({ error: 'Session key room mismatch' });
    }

    const proof = getInvestigationProof(rid, detective);
    if (!proof)
      return res.status(404).json({ error: 'No detective proof found for this room/night' });
    if (proof.targetAddress.toLowerCase() !== target)
      return res.status(403).json({ error: 'Investigation target mismatch' });

    return res.json({ ok: true, source: 'gm-proof', targetAddress: proof.targetAddress, timestamp: proof.timestamp });
  } catch (err: any) {
    console.error('[investigation-proof] Error:', err.message);
    return res.status(500).json({ error: err.message || 'Investigation proof check failed' });
  }
});

// ─── Submit Night Action ──────────────────────────────────
app.post('/night-action', async (req, res) => {
  try {
    const { roomId, playerAddress, actionType, targetAddress, signature, signerAddress, nonce, timestamp } = req.body;

    if (!roomId || !playerAddress || !actionType || !targetAddress || !signature)
      return res.status(400).json({ error: 'Missing fields: roomId, playerAddress, actionType, targetAddress, signature' });

    if (!['kill', 'heal', 'check'].includes(actionType))
      return res.status(400).json({ error: 'actionType must be: kill, heal, check' });

    const rid = BigInt(roomId);
    const room = await getRoom(rid);
    if (room.phase !== GamePhase.NIGHT)
      return res.status(400).json({ error: 'Room is not in NIGHT phase' });

    const players = await getPlayers(rid);
    const player = players.find(p => p.wallet.toLowerCase() === (playerAddress as string).toLowerCase());
    if (!player) return res.status(400).json({ error: 'Player not in room' });
    if (!(Number(player.flags) & FLAGS.ACTIVE)) return res.status(400).json({ error: 'Player is dead' });

    const target = players.find(p => p.wallet.toLowerCase() === (targetAddress as string).toLowerCase());
    if (!target) return res.status(400).json({ error: 'Target not in room' });
    if (actionType === 'kill' && !(Number(target.flags) & FLAGS.ACTIVE))
      return res.status(400).json({ error: 'Cannot kill dead player' });
    if (actionType === 'kill' && (playerAddress as string).toLowerCase() === (targetAddress as string).toLowerCase())
      return res.status(400).json({ error: 'Cannot target yourself' });

    const signatureCheck = await verifyAuthorizedSignature({
      roomId: String(roomId),
      signature: signature as `0x${string}`,
      playerAddress: String(playerAddress),
      signerAddress, nonce,
      timestamp: timestamp !== undefined ? Number(timestamp) : undefined,
      buildLegacyMessage: () => `night:${roomId}:${actionType}:${targetAddress}`,
      buildModernMessage: (n, ts) => `night:${roomId}:${actionType}:${targetAddress}:${n}:${ts}`,
    });
    if (!signatureCheck.ok)
      return res.status(signatureCheck.status).json({ error: signatureCheck.error });

    const committed = await hasCommittedRole(rid, playerAddress as Address);
    if (!committed)
      return res.status(403).json({ error: 'You have not committed a role on-chain' });

    const state = getOrCreateNightState(rid);
    if (state.resolved) return res.status(400).json({ error: 'Night already resolved' });

    const action: NightAction = {
      playerAddress: playerAddress as Address,
      actionType,
      targetAddress: targetAddress as Address,
      timestamp: Date.now(),
    };
    state.actions.set((playerAddress as string).toLowerCase(), action);

    if (actionType === 'check') {
      storeInvestigationProof(
        rid,
        (playerAddress as string).toLowerCase() as Address,
        (targetAddress as string).toLowerCase() as Address
      );
    }

    console.log(`[night] Room ${roomId}: ${player.nickname} (${actionType}) → ${target.nickname} | ${state.actions.size} actions total`);
    return res.json({ ok: true, actionsReceived: state.actions.size });
  } catch (err: any) {
    console.error('[night-action] Error:', err.message);
    return res.status(500).json({ error: err.message });
  }
});

// ─── Resolve Night ────────────────────────────────────────
app.post('/resolve-night', async (req, res) => {
  try {
    const { roomId, signature, callerAddress, signerAddress, nonce, timestamp } = req.body;
    if (!roomId) return res.status(400).json({ error: 'Missing roomId' });
    if (!signature || !callerAddress)
      return res.status(401).json({ error: 'Missing signature or callerAddress' });

    const signatureCheck = await verifyAuthorizedSignature({
      roomId: String(roomId),
      signature: signature as `0x${string}`,
      playerAddress: String(callerAddress),
      signerAddress, nonce,
      timestamp: timestamp !== undefined ? Number(timestamp) : undefined,
      buildLegacyMessage: () => `resolve-night:${roomId}`,
      buildModernMessage: (n, ts) => `resolve-night:${roomId}:${n}:${ts}`,
    });
    if (!signatureCheck.ok)
      return res.status(signatureCheck.status).json({ error: signatureCheck.error });

    const rid = BigInt(roomId);
    const state = getNightState(rid);
    if (!state || state.actions.size === 0)
      return res.status(400).json({ error: 'No night actions submitted' });
    if (state.resolved)
      return res.status(400).json({ error: 'Night already resolved' });

    const room = await getRoom(rid);
    if (room.phase !== GamePhase.NIGHT)
      return res.status(400).json({ error: 'Room is not in NIGHT phase' });

    const allActions = [...state.actions.values()];
    const killTarget = calculateMafiaConsensus(allActions);
    const healTarget = getDoctorHeal(allActions);

    console.log(`[resolve] Room ${roomId}: kill=${killTarget}, heal=${healTarget}, actions=${allActions.length}`);

    state.resolved = true;
    const { hash } = await resolveNight(rid, killTarget, healTarget);
    clearNightState(rid);

    return res.json({ ok: true, txHash: hash, killTarget, healTarget });
  } catch (err: any) {
    console.error('[resolve-night] Error:', err.message);
    const rid = BigInt(req.body.roomId);
    const state = getNightState(rid);
    if (state) state.resolved = false;
    return res.status(500).json({ error: err.message });
  }
});

// ─── Night Status ─────────────────────────────────────────
app.get('/night-status/:roomId', (req, res) => {
  const rid = BigInt(req.params.roomId);
  const state = getNightState(rid);
  if (!state) return res.json({ active: false, actionsReceived: 0 });
  return res.json({
    active: true,
    actionsReceived: state.actions.size,
    resolved: state.resolved,
    startedAt: state.nightStartedAt,
  });
});

// ─── Room Info ────────────────────────────────────────────
app.get('/room/:roomId', async (req, res) => {
  try {
    const rid = BigInt(req.params.roomId);
    const [room, players] = await Promise.all([getRoom(rid), getPlayers(rid)]);
    return res.json({
      room: {
        id: Number(room.id),
        host: room.host,
        name: room.name,
        phase: room.phase,
        phaseLabel: ['LOBBY', 'SHUFFLING', 'REVEAL', 'DAY', 'VOTING', 'NIGHT', 'ENDED'][room.phase],
        maxPlayers: room.maxPlayers,
        playersCount: room.playersCount,
        aliveCount: room.aliveCount,
        dayCount: room.dayCount,
      },
      players: players.map(p => ({
        wallet: p.wallet,
        nickname: p.nickname,
        active: !!(Number(p.flags) & FLAGS.ACTIVE),
      })),
    });
  } catch (err: any) {
    return res.status(500).json({ error: err.message });
  }
});

// ─── Start ────────────────────────────────────────────────
async function start() {
  try {
    await assertChainConfigOrThrow();
    app.listen(PORT, '0.0.0.0', () => {
      console.log(`\n🎭 Mafia GM Server running on port ${PORT}`);
      console.log(`   GM Address: ${GM_ADDRESS}`);
      console.log(`   Diamond:    ${DIAMOND_ADDRESS}`);
      console.log(`   Health:     http://0.0.0.0:${PORT}/health\n`);
    });
  } catch (error: any) {
    console.error('[startup] Failed to start GM server:', error?.message || error);
    process.exit(1);
  }
}

void start();

// gm-server/src/ecies.ts
// Node.js ECIES — EXACTLY matches frontend eciesService.ts:
// Curve: P-256 (prime256v1) | KDF: ECDH X-coord raw (32 bytes) | Cipher: AES-256-GCM
// Interface field names match frontend: { ephemeralPubkey, iv, ciphertext }

import { createECDH } from 'crypto';
import { webcrypto } from 'crypto';

const subtle = webcrypto.subtle;

export interface EciesEncrypted {
  /** 65-byte uncompressed P-256 point, hex, NO 0x prefix — matches frontend */
  ephemeralPubkey: string;
  /** 12-byte AES-GCM IV, hex */
  iv: string;
  /** ciphertext + 16-byte GCM authTag concatenated, hex */
  ciphertext: string;
}

function hexToBytes(hex: string): Uint8Array {
  const h = hex.startsWith('0x') ? hex.slice(2) : hex;
  const arr = new Uint8Array(h.length / 2);
  for (let i = 0; i < arr.length; i++)
    arr[i] = parseInt(h.slice(i * 2, i * 2 + 2), 16);
  return arr;
}

function bytesToHex(bytes: Uint8Array | Buffer): string {
  return Array.from(bytes)
    .map(b => b.toString(16).padStart(2, '0'))
    .join('');
}

/**
 * Encrypt `message` for a recipient identified by their P-256 public key.
 * recipientPubKeyHex: 65-byte uncompressed point hex (no 0x) — stored on-chain via getPlayers().publicKey
 *
 * Security properties:
 * - Each encryption uses a fresh ephemeral keypair → forward secrecy per message
 * - AES-256-GCM provides authenticated encryption (integrity + confidentiality)
 * - Shared secret = raw X-coordinate of ECDH result (matches WebCrypto deriveBits(256))
 */
export async function eciesEncrypt(
  message: string,
  recipientPubKeyHex: string
): Promise<EciesEncrypted> {
  // 1. Reconstruct recipient public key as raw bytes
  const pubKeyBytes = hexToBytes(recipientPubKeyHex);

  // 2. Generate ephemeral ECDH keypair on P-256
  const ecdh = createECDH('prime256v1');
  ecdh.generateKeys();

  // 3. Derive shared secret — ECDH X-coordinate (first 32 bytes)
  // Node computeSecret returns only the X-coord by default (matches WebCrypto deriveBits behavior)
  const sharedSecret = ecdh.computeSecret(Buffer.from(pubKeyBytes));
  // sharedSecret IS the X-coordinate (32 bytes) from Node's ECDH
  const sharedX = sharedSecret.subarray(0, 32);

  // 4. Import X-coord directly as AES-256-GCM key (mirrors: crypto.subtle.importKey('raw', sharedBits, {name:'AES-GCM'}))
  const aesKey = await subtle.importKey(
    'raw',
    sharedX,
    { name: 'AES-GCM' },
    false,
    ['encrypt']
  );

  // 5. Generate 12-byte IV and encrypt
  const ivBytes = new Uint8Array(12);
  webcrypto.getRandomValues(ivBytes);

  const encoder = new TextEncoder();
  const ciphertextBuf = await subtle.encrypt(
    { name: 'AES-GCM', iv: ivBytes },
    aesKey,
    encoder.encode(message)
  );

  return {
    ephemeralPubkey: bytesToHex(ecdh.getPublicKey()), // 65-byte uncompressed, no 0x
    iv: bytesToHex(ivBytes),
    ciphertext: bytesToHex(new Uint8Array(ciphertextBuf)), // ciphertext + 16-byte authTag
  };
}

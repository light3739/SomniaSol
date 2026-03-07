/**
 * Upgrade VotingFacet with AFK kick logic.
 * 
 * Changes:
 * - _finalizeVoting now kicks AFK players (didn't vote before timeout)
 * - startVoting uses VOTING_TIMEOUT (90s) instead of PHASE_TIMEOUT (3min)
 * - AFK players get deposit slashed
 *
 * Run: node scripts/upgrade-voting-afk.cjs
 */
const { createWalletClient, createPublicClient, http, parseAbi, toFunctionSelector } = require('viem');
const { privateKeyToAccount } = require('viem/accounts');
const fs = require('fs');
require('dotenv/config');

const account = privateKeyToAccount(`0x${process.env.PRIVATE_KEY}`);
const chain = {
    id: 50312,
    name: 'Somnia Testnet',
    nativeCurrency: { name: 'STT', symbol: 'STT', decimals: 18 },
    rpcUrls: { default: { http: ['https://dream-rpc.somnia.network/'] } },
};

const client = createWalletClient({ account, chain, transport: http('https://dream-rpc.somnia.network/') });
const pub = createPublicClient({ chain, transport: http('https://dream-rpc.somnia.network/') });

const DIAMOND = '0xb34f8430f8a755c8c1bdc9dd19f14e263fc3f6b1';
const diamondAbi = parseAbi([
    'function addFacet(address facet, bytes4[] calldata selectors)',
    'function replaceFacet(address facet, bytes4[] calldata selectors)',
]);

(async () => {
    console.log('=== VotingFacet AFK Upgrade ===');
    console.log('Deployer:', account.address);

    const balance = await pub.getBalance({ address: account.address });
    console.log('Balance:', (Number(balance) / 1e18).toFixed(4), 'STT');

    // Deploy new VotingFacet
    const votingArtifact = JSON.parse(
        fs.readFileSync('artifacts/contracts/facets/VotingFacet.sol/VotingFacet.json', 'utf-8')
    );

    console.log('\n1. Deploying new VotingFacet...');
    let hash = await client.deployContract({
        abi: votingArtifact.abi,
        bytecode: votingArtifact.bytecode,
    });
    let receipt = await pub.waitForTransactionReceipt({ hash });
    const newVoting = receipt.contractAddress;
    console.log('   New VotingFacet:', newVoting);

    // Get all function selectors from the ABI
    const allSelectors = votingArtifact.abi
        .filter(a => a.type === 'function')
        .map(a => toFunctionSelector(
            a.name + '(' + (a.inputs || []).map(i => i.type).join(',') + ')'
        ));

    console.log(`\n2. Replacing ${allSelectors.length} selectors on Diamond...`);

    hash = await client.writeContract({
        address: DIAMOND,
        abi: diamondAbi,
        functionName: 'replaceFacet',
        args: [newVoting, allSelectors],
    });
    receipt = await pub.waitForTransactionReceipt({ hash });
    console.log('   Status:', receipt.status);

    console.log('\n=== UPGRADE COMPLETE ===');
    console.log('New VotingFacet:', newVoting);
    console.log('\nChanges deployed:');
    console.log('  ✓ VOTING_TIMEOUT = 90 seconds (was PHASE_TIMEOUT = 3 min)');
    console.log('  ✓ AFK kick: players who don\'t vote get killed + deposit slashed');
    console.log('  ✓ Win condition checked after AFK kicks');
})().catch(e => {
    console.error('ERROR:', e.message || e);
    process.exit(1);
});

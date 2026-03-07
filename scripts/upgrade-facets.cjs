const { createWalletClient, createPublicClient, http, parseAbi, toFunctionSelector } = require('viem');
const { privateKeyToAccount } = require('viem/accounts');
const fs = require('fs');

const account = privateKeyToAccount(process.env.PRIVATE_KEY);
const chain = { id: 50312, name: 'Somnia Testnet', nativeCurrency: { name: 'STT', symbol: 'STT', decimals: 18 }, rpcUrls: { default: { http: ['https://dream-rpc.somnia.network/'] } } };
const client = createWalletClient({ account, chain, transport: http('https://dream-rpc.somnia.network/') });
const pub = createPublicClient({ chain, transport: http('https://dream-rpc.somnia.network/') });

const DIAMOND = '0xb34f8430f8a755c8c1bdc9dd19f14e263fc3f6b1';
const diamondAbi = parseAbi([
  'function addFacet(address facet, bytes4[] calldata selectors)',
  'function replaceFacet(address facet, bytes4[] calldata selectors)',
]);

const NEW_VOTING_SELECTORS = ['0x61ea2027','0xd23254b4','0xe851122d'];
const NEW_NIGHT_SELECTORS = ['0x669ead17','0xeb0fa6f8'];

(async () => {
  // Deploy new VotingFacet
  const votingArt = JSON.parse(fs.readFileSync('artifacts/contracts/facets/VotingFacet.sol/VotingFacet.json'));
  console.log('Deploying new VotingFacet...');
  let hash = await client.deployContract({ abi: votingArt.abi, bytecode: votingArt.bytecode });
  let receipt = await pub.waitForTransactionReceipt({ hash });
  const newVoting = receipt.contractAddress;
  console.log('New VotingFacet:', newVoting);

  // Deploy new NightFacet
  const nightArt = JSON.parse(fs.readFileSync('artifacts/contracts/facets/NightFacet.sol/NightFacet.json'));
  console.log('Deploying new NightFacet...');
  hash = await client.deployContract({ abi: nightArt.abi, bytecode: nightArt.bytecode });
  receipt = await pub.waitForTransactionReceipt({ hash });
  const newNight = receipt.contractAddress;
  console.log('New NightFacet:', newNight);

  // Existing selectors (all functions minus the new ones)
  const votingExisting = votingArt.abi
    .filter(a => a.type === 'function')
    .map(a => toFunctionSelector(a.name + '(' + (a.inputs||[]).map(i=>i.type).join(',') + ')'))
    .filter(s => !NEW_VOTING_SELECTORS.includes(s));

  const nightExisting = nightArt.abi
    .filter(a => a.type === 'function')
    .map(a => toFunctionSelector(a.name + '(' + (a.inputs||[]).map(i=>i.type).join(',') + ')'))
    .filter(s => !NEW_NIGHT_SELECTORS.includes(s));

  console.log('\nVoting existing selectors:', votingExisting.length);
  console.log('Night existing selectors:', nightExisting.length);

  // Replace existing selectors → new facet implementations
  console.log('\nReplace VotingFacet...');
  hash = await client.writeContract({ address: DIAMOND, abi: diamondAbi, functionName: 'replaceFacet', args: [newVoting, votingExisting] });
  receipt = await pub.waitForTransactionReceipt({ hash });
  console.log('Done:', receipt.status);

  console.log('Add VotingFacet new selectors...');
  hash = await client.writeContract({ address: DIAMOND, abi: diamondAbi, functionName: 'addFacet', args: [newVoting, NEW_VOTING_SELECTORS] });
  receipt = await pub.waitForTransactionReceipt({ hash });
  console.log('Done:', receipt.status);

  console.log('\nReplace NightFacet...');
  hash = await client.writeContract({ address: DIAMOND, abi: diamondAbi, functionName: 'replaceFacet', args: [newNight, nightExisting] });
  receipt = await pub.waitForTransactionReceipt({ hash });
  console.log('Done:', receipt.status);

  console.log('Add NightFacet new selectors...');
  hash = await client.writeContract({ address: DIAMOND, abi: diamondAbi, functionName: 'addFacet', args: [newNight, NEW_NIGHT_SELECTORS] });
  receipt = await pub.waitForTransactionReceipt({ hash });
  console.log('Done:', receipt.status);

  console.log('\n=== UPGRADE COMPLETE ===');
  console.log('New VotingFacet:', newVoting);
  console.log('New NightFacet:', newNight);
})().catch(e => { console.error(e.message || e); process.exit(1); });

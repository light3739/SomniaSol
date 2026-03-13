import { createWalletClient, createPublicClient, http, parseAbi, toFunctionSelector } from 'viem';
import { privateKeyToAccount } from 'viem/accounts';
import fs from 'fs';
import 'dotenv/config';

async function main() {
    const getSelector = toFunctionSelector;
    const PRIVATE_KEY = process.env.PRIVATE_KEY as `0x${string}`;
    const RPC_URL = "https://dream-rpc.somnia.network/";
    const DIAMOND_ADDRESS = "0xb34f8430f8a755c8c1bdc9dd19f14e263fc3f6b1";

    if (!PRIVATE_KEY) {
        throw new Error("PRIVATE_KEY not found in .env");
    }

    const account = privateKeyToAccount(PRIVATE_KEY);
    const chain = { 
        id: 50312, 
        name: 'Somnia Testnet', 
        nativeCurrency: { name: 'ST', symbol: 'ST', decimals: 18 }, 
        rpcUrls: { default: { http: [RPC_URL] } } 
    };

    const client = createWalletClient({ account, chain, transport: http() });
    const publicClient = createPublicClient({ chain, transport: http() });

    console.log(`Starting ZK-5 upgrade on Somnia Testnet...`);
    console.log(`Using account: ${account.address}`);
    console.log(`Diamond address: ${DIAMOND_ADDRESS}`);

    // 1. Deploy Verifier
    console.log("\n1. Deploying Verifier (5 signals)...");
    const verifierArt = JSON.parse(fs.readFileSync('artifacts/contracts/Verifier.sol/Groth16Verifier.json', 'utf8'));
    let hash = await client.deployContract({ 
        abi: verifierArt.abi, 
        bytecode: verifierArt.bytecode as `0x${string}` 
    });
    console.log("Deployment tx sent:", hash);
    let receipt = await publicClient.waitForTransactionReceipt({ hash });
    const verifierAddress = receipt.contractAddress!;
    console.log(`Verifier deployed at: ${verifierAddress}`);

    // 2. Deploy GameEndFacet
    console.log("\n2. Deploying GameEndFacet (5 signals)...");
    const facetArt = JSON.parse(fs.readFileSync('artifacts/contracts/facets/GameEndFacet.sol/GameEndFacet.json', 'utf8'));
    hash = await client.deployContract({ 
        abi: facetArt.abi, 
        bytecode: facetArt.bytecode as `0x${string}` 
    });
    console.log("Deployment tx sent:", hash);
    receipt = await publicClient.waitForTransactionReceipt({ hash });
    const facetAddress = receipt.contractAddress!;
    console.log(`GameEndFacet deployed at: ${facetAddress}`);

    // 3. Upgrade Diamond
    const diamondAbi = parseAbi([
        'function removeSelectors(bytes4[] calldata selectors) external',
        'function addFacet(address facet, bytes4[] calldata selectors) external',
        'function setZkVerifier(address verifier) external'
    ]);

    // OLD selector (currently on chain): endGameZK with 37 signals
    const oldSelector = getSelector('endGameZK(uint256,uint256[2],uint256[2][2],uint256[2],uint256[37])');
    // NEW selector (our new facet): endGameZK with 5 signals
    const newSelector = getSelector('endGameZK(uint256,uint256[2],uint256[2][2],uint256[2],uint256[5])');

    console.log(`\nOld selector (37): ${oldSelector}`);
    console.log(`New selector (5): ${newSelector}`);

    console.log("\n3. Removing old selector (37 inputs)...");
    try {
        hash = await client.writeContract({
            address: DIAMOND_ADDRESS,
            abi: diamondAbi,
            functionName: 'removeSelectors',
            args: [[oldSelector]]
        });
        console.log("Tx sent:", hash);
        await publicClient.waitForTransactionReceipt({ hash });
        console.log("Old selector removed.");
    } catch (e) {
        console.warn("Could not remove old selector (maybe already gone or different):", e.message);
    }

    console.log("\n4. Adding new facet and selector (5 inputs)...");
    hash = await client.writeContract({
        address: DIAMOND_ADDRESS,
        abi: diamondAbi,
        functionName: 'addFacet',
        args: [facetAddress, [newSelector]]
    });
    console.log("Tx sent:", hash);
    await publicClient.waitForTransactionReceipt({ hash });
    console.log("New facet added.");

    console.log("\n5. Updating ZK Verifier address...");
    hash = await client.writeContract({
        address: DIAMOND_ADDRESS,
        abi: diamondAbi,
        functionName: 'setZkVerifier',
        args: [verifierAddress]
    });
    console.log("Tx sent:", hash);
    await publicClient.waitForTransactionReceipt({ hash });
    console.log("ZK Verifier updated.");

    console.log("\n=== UPGRADE SUCCESSFUL ===");
    console.log(`New Verifier: ${verifierAddress}`);
    console.log(`New GameEndFacet: ${facetAddress}`);
}

main().catch(console.error);

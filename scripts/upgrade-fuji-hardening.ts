import { createWalletClient, createPublicClient, http, parseAbi, toFunctionSelector } from 'viem';
import { privateKeyToAccount } from 'viem/accounts';
import fs from 'fs';
import 'dotenv/config';

async function main() {
    const PRIVATE_KEY = process.env.PRIVATE_KEY as `0x${string}`;
    const RPC_URL = process.env.AVALANCHE_FUJI_RPC_URL || "https://api.avax-test.network/ext/bc/C/rpc";
    const DIAMOND_ADDRESS = "0x740d9e5095acc228860509e46cfac1b8a517998c";

    if (!PRIVATE_KEY) {
        throw new Error("PRIVATE_KEY not found in .env");
    }

    const account = privateKeyToAccount(PRIVATE_KEY);
    const chain = { 
        id: 43113, 
        name: 'Avalanche Fuji', 
        nativeCurrency: { name: 'AVAX', symbol: 'AVAX', decimals: 18 }, 
        rpcUrls: { default: { http: [RPC_URL] } } 
    };

    const client = createWalletClient({ account, chain, transport: http() });
    const publicClient = createPublicClient({ chain, transport: http() });

    console.log(`Starting Hardening upgrade on Avalanche Fuji...`);
    console.log(`Using account: ${account.address}`);
    console.log(`Diamond address: ${DIAMOND_ADDRESS}`);

    const deployFacet = async (name: string) => {
        console.log(`\nDeploying ${name}...`);
        const art = JSON.parse(fs.readFileSync(`artifacts/contracts/facets/${name}.sol/${name}.json`, 'utf8'));
        const hash = await client.deployContract({ 
            abi: art.abi, 
            bytecode: art.bytecode as `0x${string}` 
        });
        console.log(`Deployment tx sent: ${hash}`);
        const receipt = await publicClient.waitForTransactionReceipt({ hash });
        console.log(`${name} deployed at: ${receipt.contractAddress}`);
        return receipt.contractAddress!;
    };

    // 1. Deploy Facets
    const lobbyAddr = await deployFacet('LobbyFacet');
    const votingAddr = await deployFacet('VotingFacet');
    const nightAddr = await deployFacet('NightFacet');

    const diamondAbi = parseAbi([
        'function removeSelectors(bytes4[] calldata selectors) external',
        'function addFacet(address facet, bytes4[] calldata selectors) external'
    ]);

    const lobbySelectors = [
        'createAndJoin(string,uint8,string,bytes,address,bool,uint256)',
        'joinRoom(uint256,string,bytes,address,bytes)',
        'startGame(uint256)',
        'setZkVerifier(address)',
        'setGameMaster(address)',
        'setDefaultDeposit(uint128)',
        'pause()',
        'unpause()',
        'withdrawFees(address)',
        'revokeSessionKey()',
        'getPlayers(uint256)',
        'getRoom(uint256)',
        'getDeck(uint256)',
        'getPhaseDeadline(uint256)',
        'sessionKeys(address)',
        'nextRoomId()',
        'getKeyFromTo(uint256,address,address)',
        'getAllKeysForMe(uint256)',
        'getPlayerFlags(uint256,address)',
        'getPlayerDeposit(uint256,address)',
        'getDefaultDeposit()',
        'forcePhaseTimeout(uint256)'
    ].map(s => toFunctionSelector(s));

    const votingSelectors = [
        'startVoting(uint256)',
        'vote(uint256,address)',
        'finalizeVoting(uint256)'
    ].map(s => toFunctionSelector(s));

    const nightSelectors = [
        'mafiaMessage(uint256,string)',
        'commitMafiaTarget(uint256,bytes32)',
        'revealMafiaTarget(uint256,address,string)',
        'getMafiaConsensus(uint256)',
        'resolveNightAsGameMaster(uint256,address,address)'
    ].map(s => toFunctionSelector(s));

    // 2. Upgrade Diamond
    const upgrade = async (oldSelectors: `0x${string}`[], newFacet: `0x${string}`) => {
        console.log(`\nUpgrading facet to ${newFacet}...`);
        // Remove old
        try {
            const hash = await client.writeContract({
                address: DIAMOND_ADDRESS,
                abi: diamondAbi,
                functionName: 'removeSelectors',
                args: [oldSelectors]
            });
            console.log("Removal tx sent:", hash);
            await publicClient.waitForTransactionReceipt({ hash });
            console.log("Old selectors removed.");
        } catch (e: any) {
            console.warn("Removal warning (might be new cleanup):", e.message.slice(0, 100));
        }

        // Add new
        const hash = await client.writeContract({
            address: DIAMOND_ADDRESS,
            abi: diamondAbi,
            functionName: 'addFacet',
            args: [newFacet, oldSelectors]
        });
        console.log("Addition tx sent:", hash);
        await publicClient.waitForTransactionReceipt({ hash });
        console.log("Facet added.");
    };

    await upgrade(lobbySelectors, lobbyAddr);
    await upgrade(votingSelectors, votingAddr);
    await upgrade(nightSelectors, nightAddr);

    console.log("\n=== FUJI HARDENING UPGRADE SUCCESSFUL ===");
    console.log(`LobbyFacet: ${lobbyAddr}`);
    console.log(`VotingFacet: ${votingAddr}`);
    console.log(`NightFacet: ${nightAddr}`);
}

main().catch(console.error);

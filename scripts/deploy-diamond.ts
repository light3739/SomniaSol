import { network } from "hardhat";
import { toFunctionSelector, parseGwei } from "viem";

// ---- Function selectors for each facet ----

const LOBBY_SELECTORS = [
  toFunctionSelector("setZkVerifier(address)"),
  toFunctionSelector("setGameMaster(address)"),
  toFunctionSelector("setDefaultDeposit(uint128)"),
  toFunctionSelector("pause()"),
  toFunctionSelector("unpause()"),
  toFunctionSelector("withdrawFees()"),
  toFunctionSelector("revokeSessionKey()"),
  toFunctionSelector("createAndJoin(string,uint8,string,bytes,address)"),
  toFunctionSelector("joinRoom(uint256,string,bytes,address)"),
  toFunctionSelector("startGame(uint256)"),
  toFunctionSelector("getPlayers(uint256)"),
  toFunctionSelector("getRoom(uint256)"),
  toFunctionSelector("getDeck(uint256)"),
  toFunctionSelector("getPhaseDeadline(uint256)"),
  toFunctionSelector("sessionKeys(address)"),
  toFunctionSelector("nextRoomId()"),
  toFunctionSelector("getKeyFromTo(uint256,address,address)"),
  toFunctionSelector("getAllKeysForMe(uint256)"),
  toFunctionSelector("getPlayerFlags(uint256,address)"),
  toFunctionSelector("getPlayerDeposit(uint256,address)"),
  toFunctionSelector("getDefaultDeposit()"),
] as `0x${string}`[];

const SHUFFLE_SELECTORS = [
  toFunctionSelector("commitDeck(uint256,bytes32)"),
  toFunctionSelector("revealDeck(uint256,string[],string)"),
  toFunctionSelector("shareKeysToAll(uint256,address[],bytes[])"),
  toFunctionSelector("commitAndConfirmRole(uint256,bytes32)"),
  toFunctionSelector("commitRole(uint256,bytes32)"),
  toFunctionSelector("confirmRole(uint256)"),
  toFunctionSelector("getRevealedDeck(uint256,uint256)"),
] as `0x${string}`[];

const VOTING_SELECTORS = [
  toFunctionSelector("startVoting(uint256)"),
  toFunctionSelector("vote(uint256,address)"),
  toFunctionSelector("revealRole(uint256,uint8,string)"),
  toFunctionSelector("endGameAutomatically(uint256)"),
  toFunctionSelector("forcePhaseTimeout(uint256)"),
  toFunctionSelector("claimRefund(uint256)"),
  toFunctionSelector("getAliveMafiaCount(uint256)"),
  toFunctionSelector("getRevealedMafiaCount(uint256)"),
] as `0x${string}`[];

const NIGHT_SELECTORS = [
  toFunctionSelector("commitNightAction(uint256,bytes32)"),
  toFunctionSelector("revealNightAction(uint256,uint8,address,string)"),
  toFunctionSelector("sendMafiaMessage(uint256,bytes)"),
  toFunctionSelector("commitMafiaTarget(uint256,bytes32)"),
  toFunctionSelector("revealMafiaTarget(uint256,address,string)"),
  toFunctionSelector("endNight(uint256)"),
  toFunctionSelector("resolveNightAsGameMaster(uint256,address,address)"),
  toFunctionSelector("getMafiaChat(uint256)"),
  toFunctionSelector("getMafiaConsensus(uint256)"),
  toFunctionSelector("gameMaster()"),
] as `0x${string}`[];

const GAMEEND_SELECTORS = [
  toFunctionSelector("endGameZK(uint256,uint256[2],uint256[2][2],uint256[2],uint256[5])"),
] as `0x${string}`[];

const TOURNAMENT_SELECTORS = [
  toFunctionSelector("createTournament(string,uint128,uint8,uint8,bytes32,address,uint128)"),
  toFunctionSelector("cancelTournament(uint256)"),
  toFunctionSelector("joinTournament(uint256,string)"),
  toFunctionSelector("distributeMafiaPrizes(uint256)"),
  toFunctionSelector("toggleTournamentWhitelist(uint256,bool)"),
  toFunctionSelector("addToTournamentWhitelist(uint256,address[])"),
  toFunctionSelector("removeFromTournamentWhitelist(uint256,address[])"),
] as `0x${string}`[];

async function main() {
  const { viem } = await network.connect();
  const [admin] = await viem.getWalletClients();
  const publicClient = await viem.getPublicClient();
  const chain = publicClient.chain;
  const nativeSymbol = chain?.nativeCurrency?.symbol ?? "ETH";
  const chainId = chain?.id;
  const isSomnia = chainId === 5031 || chainId === 50312;

  console.log("=== MafiaDiamond Deploy ===");
  if (chain) {
    console.log("Chain:", `${chain.name} (${chain.id})`);
  }
  console.log("Deployer:", admin.account.address);

  const balance = await publicClient.getBalance({ address: admin.account.address });
  console.log("Balance:", (Number(balance) / 1e18).toFixed(4), nativeSymbol);

  const txOpts = {
    account: admin.account,
    ...(isSomnia ? { gasPrice: parseGwei("6") } : {}),
  };

  // 1. Deploy Verifier
  console.log("\n1. Deploying Groth16Verifier...");
  const verifier = await viem.deployContract("Groth16Verifier", [], txOpts);
  console.log("   Groth16Verifier:", verifier.address);

  // 2. Deploy Diamond
  console.log("2. Deploying MafiaDiamond...");
  const diamond = await viem.deployContract("MafiaDiamond", [admin.account.address], txOpts);
  console.log("   MafiaDiamond:", diamond.address);

  // 3. Deploy Facets
  console.log("3. Deploying Facets...");
  const lobbyFacet = await viem.deployContract("LobbyFacet", [], txOpts);
  console.log("   LobbyFacet:", lobbyFacet.address);

  const shuffleFacet = await viem.deployContract("ShuffleFacet", [], txOpts);
  console.log("   ShuffleFacet:", shuffleFacet.address);

  const votingFacet = await viem.deployContract("VotingFacet", [], txOpts);
  console.log("   VotingFacet:", votingFacet.address);

  const nightFacet = await viem.deployContract("NightFacet", [], txOpts);
  console.log("   NightFacet:", nightFacet.address);

  const gameEndFacet = await viem.deployContract("GameEndFacet", [], txOpts);
  console.log("   GameEndFacet:", gameEndFacet.address);

  const tournamentFacet = await viem.deployContract("TournamentFacet", [], txOpts);
  console.log("   TournamentFacet:", tournamentFacet.address);

  // 4. Register selectors
  console.log("4. Registering selectors...");
  const facets = [
    { name: "LobbyFacet", addr: lobbyFacet.address, sel: LOBBY_SELECTORS },
    { name: "ShuffleFacet", addr: shuffleFacet.address, sel: SHUFFLE_SELECTORS },
    { name: "VotingFacet", addr: votingFacet.address, sel: VOTING_SELECTORS },
    { name: "NightFacet", addr: nightFacet.address, sel: NIGHT_SELECTORS },
    { name: "GameEndFacet", addr: gameEndFacet.address, sel: GAMEEND_SELECTORS },
    { name: "TournamentFacet", addr: tournamentFacet.address, sel: TOURNAMENT_SELECTORS },
  ];

  for (const f of facets) {
    const hash = await diamond.write.addFacet([f.addr, f.sel], txOpts);
    await publicClient.waitForTransactionReceipt({ hash });
    console.log(`   ✓ ${f.name} (${f.sel.length} selectors)`);
  }

  // 5. Configure: set ZK verifier
  console.log("5. Configuring...");
  const lobby = await viem.getContractAt("LobbyFacet", diamond.address, { client: { wallet: admin } });

  const txZk = await lobby.write.setZkVerifier([verifier.address], txOpts);
  await publicClient.waitForTransactionReceipt({ hash: txZk });
  console.log("   ✓ ZK Verifier set");

  // Done
  console.log("\n=== DEPLOYMENT COMPLETE ===");
  console.log("Diamond (main address):", diamond.address);
  console.log("Verifier:              ", verifier.address);
  console.log("");
  console.log("Facets:");
  for (const f of facets) {
    console.log(`  ${f.name}: ${f.addr}`);
  }
  console.log("");
  console.log("All interactions go through Diamond address:", diamond.address);
  console.log("Save this address for your frontend!");
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});

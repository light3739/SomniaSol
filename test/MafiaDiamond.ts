import { describe, it } from "node:test";
import { expect } from "chai";
import { network } from "hardhat";
import {
  getAddress,
  keccak256,
  encodeAbiParameters,
  parseAbiParameters,
  toHex,
  zeroAddress,
  toFunctionSelector,
} from "viem";

const { viem, networkHelpers } = await network.connect();

// ---- Hash helpers for commit-reveal ----

function hashRole(role: number, salt: string): `0x${string}` {
  return keccak256(
    encodeAbiParameters(parseAbiParameters("uint8, string"), [role, salt])
  );
}

function hashNightAction(
  action: number,
  target: `0x${string}`,
  salt: string
): `0x${string}` {
  return keccak256(
    encodeAbiParameters(parseAbiParameters("uint8, address, string"), [
      action,
      target,
      salt,
    ])
  );
}

function hashMafiaTarget(
  target: `0x${string}`,
  salt: string
): `0x${string}` {
  return keccak256(
    encodeAbiParameters(parseAbiParameters("address, string"), [target, salt])
  );
}

function hashDeck(deck: string[], salt: string): `0x${string}` {
  return keccak256(
    encodeAbiParameters(parseAbiParameters("string[], string"), [deck, salt])
  );
}

// ---- Enums matching the contract ----

const GamePhase = {
  LOBBY: 0,
  SHUFFLING: 1,
  REVEAL: 2,
  DAY: 3,
  VOTING: 4,
  NIGHT: 5,
  ENDED: 6,
};
const NightActionType = { NONE: 0, KILL: 1, HEAL: 2, CHECK: 3 };
const Role = { NONE: 0, MAFIA: 1, DOCTOR: 2, DETECTIVE: 3, CITIZEN: 4 };

// ---- Function selectors for each facet ----

const LOBBY_SELECTORS: `0x${string}`[] = [
  toFunctionSelector("setZkVerifier(address)"),
  toFunctionSelector("setGameMaster(address)"),
  toFunctionSelector("setDefaultDeposit(uint128)"),
  toFunctionSelector("pause()"),
  toFunctionSelector("unpause()"),
  toFunctionSelector("withdrawFees()"),
  toFunctionSelector("revokeSessionKey()"),
  toFunctionSelector(
    "createAndJoin(string,uint8,string,bytes,address)"
  ),
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
];

const SHUFFLE_SELECTORS: `0x${string}`[] = [
  toFunctionSelector("commitDeck(uint256,bytes32)"),
  toFunctionSelector("revealDeck(uint256,string[],string)"),
  toFunctionSelector("shareKeysToAll(uint256,address[],bytes[])"),
  toFunctionSelector("commitAndConfirmRole(uint256,bytes32)"),
  toFunctionSelector("commitRole(uint256,bytes32)"),
  toFunctionSelector("confirmRole(uint256)"),
  toFunctionSelector("getRevealedDeck(uint256,uint256)"),
];

const VOTING_SELECTORS: `0x${string}`[] = [
  toFunctionSelector("startVoting(uint256)"),
  toFunctionSelector("vote(uint256,address)"),
  toFunctionSelector("revealRole(uint256,uint8,string)"),
  toFunctionSelector("endGameAutomatically(uint256)"),
  toFunctionSelector("forcePhaseTimeout(uint256)"),
  toFunctionSelector("claimRefund(uint256)"),
  toFunctionSelector("getAliveMafiaCount(uint256)"),
  toFunctionSelector("getRevealedMafiaCount(uint256)"),
];

const NIGHT_SELECTORS: `0x${string}`[] = [
  toFunctionSelector("commitNightAction(uint256,bytes32)"),
  toFunctionSelector("revealNightAction(uint256,uint8,address,string)"),
  toFunctionSelector("sendMafiaMessage(uint256,bytes)"),
  toFunctionSelector("commitMafiaTarget(uint256,bytes32)"),
  toFunctionSelector("revealMafiaTarget(uint256,address,string)"),
  toFunctionSelector("endNight(uint256)"),
  toFunctionSelector(
    "resolveNightAsGameMaster(uint256,address,address)"
  ),
  toFunctionSelector("getMafiaChat(uint256)"),
  toFunctionSelector("getMafiaConsensus(uint256)"),
  toFunctionSelector("gameMaster()"),
];

const GAMEEND_SELECTORS: `0x${string}`[] = [
  toFunctionSelector(
    "endGameZK(uint256,uint256[2],uint256[2][2],uint256[2],uint256[5])"
  ),
];

// ---- Main test suite ----

describe("MafiaDiamond", function () {
  /**
   * Deploy diamond + all facets + register selectors.
   * Returns typed contract clients at the diamond address for each facet ABI.
   */
  async function deployDiamondFixture() {
    const wallets = await viem.getWalletClients();
    const [owner, p1, p2, p3, p4, p5] = wallets;
    const publicClient = await viem.getPublicClient();

    // 1. Deploy Diamond proxy
    const diamond = await viem.deployContract("MafiaDiamond", [
      owner.account.address,
    ]);

    // 2. Deploy facets
    const lobbyFacet = await viem.deployContract("LobbyFacet");
    const shuffleFacet = await viem.deployContract("ShuffleFacet");
    const votingFacet = await viem.deployContract("VotingFacet");
    const nightFacet = await viem.deployContract("NightFacet");
    const gameEndFacet = await viem.deployContract("GameEndFacet");

    // 3. Register selectors
    await publicClient.waitForTransactionReceipt({
      hash: await diamond.write.addFacet([lobbyFacet.address, LOBBY_SELECTORS]),
    });
    await publicClient.waitForTransactionReceipt({
      hash: await diamond.write.addFacet([
        shuffleFacet.address,
        SHUFFLE_SELECTORS,
      ]),
    });
    await publicClient.waitForTransactionReceipt({
      hash: await diamond.write.addFacet([
        votingFacet.address,
        VOTING_SELECTORS,
      ]),
    });
    await publicClient.waitForTransactionReceipt({
      hash: await diamond.write.addFacet([
        nightFacet.address,
        NIGHT_SELECTORS,
      ]),
    });
    await publicClient.waitForTransactionReceipt({
      hash: await diamond.write.addFacet([
        gameEndFacet.address,
        GAMEEND_SELECTORS,
      ]),
    });

    // 4. Get typed clients at the diamond address
    const lobby = await viem.getContractAt("LobbyFacet", diamond.address);
    const shuffle = await viem.getContractAt("ShuffleFacet", diamond.address);
    const voting = await viem.getContractAt("VotingFacet", diamond.address);
    const night = await viem.getContractAt("NightFacet", diamond.address);
    const gameEnd = await viem.getContractAt("GameEndFacet", diamond.address);

    return {
      diamond,
      lobby,
      shuffle,
      voting,
      night,
      gameEnd,
      owner,
      p1,
      p2,
      p3,
      p4,
      p5,
      publicClient,
    };
  }

  // ---- Convenience: create room and join 4 players ----
  async function createFullRoom() {
    const fixture = await networkHelpers.loadFixture(deployDiamondFixture);
    const { lobby, owner, p1, p2, p3, publicClient } = fixture;

    // Owner creates and joins
    await publicClient.waitForTransactionReceipt({
      hash: await lobby.write.createAndJoin([
        "TestRoom",
        10,
        "Owner",
        toHex("pubkey_owner"),
        zeroAddress,
      ]),
    });

    // 3 more players join
    for (const [i, p] of [p1, p2, p3].entries()) {
      await publicClient.waitForTransactionReceipt({
        hash: await lobby.write.joinRoom(
          [1n, `Player${i + 1}`, toHex(`pubkey_p${i + 1}`), zeroAddress],
          { account: p.account }
        ),
      });
    }

    return fixture;
  }

  // ---- Convenience: advance through shuffling + reveal to DAY ----
  async function advanceToDay() {
    const fixture = await createFullRoom();
    const { lobby, shuffle, owner, p1, p2, p3, publicClient } = fixture;
    const players = [owner, p1, p2, p3];
    const deck = ["MAFIA", "DOCTOR", "DETECTIVE", "CITIZEN"];

    // Start game
    await publicClient.waitForTransactionReceipt({
      hash: await lobby.write.startGame([1n]),
    });

    // Each player commits and reveals deck in turn
    for (const p of players) {
      const salt = "salt_" + p.account.address.slice(0, 6);
      const dHash = hashDeck(deck, salt);
      await publicClient.waitForTransactionReceipt({
        hash: await shuffle.write.commitDeck([1n, dHash], {
          account: p.account,
        }),
      });
      await publicClient.waitForTransactionReceipt({
        hash: await shuffle.write.revealDeck([1n, deck, salt], {
          account: p.account,
        }),
      });
    }

    // REVEAL phase — share keys and confirm roles
    for (const p of players) {
      const others = players.filter(
        (o) => o.account.address !== p.account.address
      );
      const recipients = others.map(
        (o) => o.account.address as `0x${string}`
      );
      const keys = others.map((_, i) => toHex(`key_${i}`));

      await publicClient.waitForTransactionReceipt({
        hash: await shuffle.write.shareKeysToAll([1n, recipients, keys], {
          account: p.account,
        }),
      });
    }

    // Commit and confirm roles
    const roleAssignments = [
      { player: owner, role: Role.MAFIA, salt: "role_owner" },
      { player: p1, role: Role.DOCTOR, salt: "role_p1" },
      { player: p2, role: Role.DETECTIVE, salt: "role_p2" },
      { player: p3, role: Role.CITIZEN, salt: "role_p3" },
    ];

    for (const ra of roleAssignments) {
      const rHash = hashRole(ra.role, ra.salt);
      await publicClient.waitForTransactionReceipt({
        hash: await shuffle.write.commitAndConfirmRole([1n, rHash], {
          account: ra.player.account,
        }),
      });
    }

    return { ...fixture, roleAssignments };
  }

  // ===================== LOBBY TESTS =====================

  describe("Lobby Flow", function () {
    it("Should create a room and join the host", async function () {
      const { lobby, owner, publicClient } =
        await networkHelpers.loadFixture(deployDiamondFixture);

      await publicClient.waitForTransactionReceipt({
        hash: await lobby.write.createAndJoin([
          "TestRoom",
          10,
          "HostPlayer",
          toHex("my_public_key"),
          zeroAddress,
        ]),
      });

      const players = await lobby.read.getPlayers([1n]);
      expect(players.length).to.equal(1);
      expect(players[0].nickname).to.equal("HostPlayer");
      expect(getAddress(players[0].wallet)).to.equal(
        getAddress(owner.account.address)
      );
    });

    it("Should allow player to join room", async function () {
      const { lobby, p1, publicClient } =
        await networkHelpers.loadFixture(deployDiamondFixture);

      await publicClient.waitForTransactionReceipt({
        hash: await lobby.write.createAndJoin([
          "Room1",
          10,
          "Host",
          toHex("host_pk"),
          zeroAddress,
        ]),
      });

      await publicClient.waitForTransactionReceipt({
        hash: await lobby.write.joinRoom(
          [1n, "PlayerOne", toHex("p1_pk"), zeroAddress],
          { account: p1.account }
        ),
      });

      const players = await lobby.read.getPlayers([1n]);
      expect(players.length).to.equal(2);
      expect(players[1].nickname).to.equal("PlayerOne");
    });

    it("Should reject joining a full room", async function () {
      const { lobby, p1, p2, p3, p4, publicClient } =
        await networkHelpers.loadFixture(deployDiamondFixture);

      await publicClient.waitForTransactionReceipt({
        hash: await lobby.write.createAndJoin([
          "SmallRoom",
          4,
          "Host",
          toHex("pk"),
          zeroAddress,
        ]),
      });

      for (const p of [p1, p2, p3]) {
        await publicClient.waitForTransactionReceipt({
          hash: await lobby.write.joinRoom(
            [1n, "P", toHex("pk"), zeroAddress],
            { account: p.account }
          ),
        });
      }

      let failed = false;
      try {
        await lobby.write.joinRoom([1n, "P5", toHex("pk"), zeroAddress], {
          account: p4.account,
        });
      } catch {
        failed = true;
      }
      expect(failed).to.be.true;
    });

    it("Should reject invalid player count", async function () {
      const { lobby } =
        await networkHelpers.loadFixture(deployDiamondFixture);
      let failed = false;
      try {
        await lobby.write.createAndJoin([
          "Bad",
          2,
          "Host",
          toHex("pk"),
          zeroAddress,
        ]);
      } catch {
        failed = true;
      }
      expect(failed).to.be.true;
    });

    it("Should not start game with < 4 players", async function () {
      const { lobby, publicClient } =
        await networkHelpers.loadFixture(deployDiamondFixture);

      await publicClient.waitForTransactionReceipt({
        hash: await lobby.write.createAndJoin([
          "Room",
          10,
          "Host",
          toHex("pk"),
          zeroAddress,
        ]),
      });

      let failed = false;
      try {
        await lobby.write.startGame([1n]);
      } catch {
        failed = true;
      }
      expect(failed).to.be.true;
    });
  });

  // ===================== GAME START & SHUFFLE =====================

  describe("Game Start & Shuffling", function () {
    it("Should start game and enter SHUFFLING phase", async function () {
      const { lobby, publicClient } = await createFullRoom();

      await publicClient.waitForTransactionReceipt({
        hash: await lobby.write.startGame([1n]),
      });

      const room = await lobby.read.getRoom([1n]);
      expect(room.phase).to.equal(GamePhase.SHUFFLING);
    });

    it("Should process deck commit and reveal cycle", async function () {
      const { lobby, shuffle, owner, p1, p2, p3, publicClient } =
        await createFullRoom();
      const players = [owner, p1, p2, p3];
      const deck = ["MAFIA", "DOCTOR", "DETECTIVE", "CITIZEN"];

      await publicClient.waitForTransactionReceipt({
        hash: await lobby.write.startGame([1n]),
      });

      for (const p of players) {
        const salt =
          "shuffle_salt_" + p.account.address.slice(0, 6);
        const dHash = hashDeck(deck, salt);
        await publicClient.waitForTransactionReceipt({
          hash: await shuffle.write.commitDeck([1n, dHash], {
            account: p.account,
          }),
        });
        await publicClient.waitForTransactionReceipt({
          hash: await shuffle.write.revealDeck([1n, deck, salt], {
            account: p.account,
          }),
        });
      }

      const room = await lobby.read.getRoom([1n]);
      expect(room.phase).to.equal(GamePhase.REVEAL);
    });
  });

  // ===================== VOTING =====================

  describe("Voting", function () {
    it("Should transition DAY -> VOTING -> NIGHT", async function () {
      const { lobby, voting, owner, p1, p2, p3, publicClient } =
        await advanceToDay();

      let room = await lobby.read.getRoom([1n]);
      expect(room.phase).to.equal(GamePhase.DAY);

      // Start voting
      await publicClient.waitForTransactionReceipt({
        hash: await voting.write.startVoting([1n]),
      });
      room = await lobby.read.getRoom([1n]);
      expect(room.phase).to.equal(GamePhase.VOTING);

      // All vote for p3 (citizen)
      const target = p3.account.address as `0x${string}`;
      for (const p of [owner, p1, p2, p3]) {
        await publicClient.waitForTransactionReceipt({
          hash: await voting.write.vote([1n, target], {
            account: p.account,
          }),
        });
      }

      // p3 eliminated -> NIGHT
      room = await lobby.read.getRoom([1n]);
      expect(room.phase).to.equal(GamePhase.NIGHT);
      expect(room.aliveCount).to.equal(3);
    });

    it("Should allow changing vote", async function () {
      const { lobby, voting, owner, p1, p3, publicClient } =
        await advanceToDay();

      await publicClient.waitForTransactionReceipt({
        hash: await voting.write.startVoting([1n]),
      });

      // Owner votes for p1 first
      await publicClient.waitForTransactionReceipt({
        hash: await voting.write.vote([
          1n,
          p1.account.address as `0x${string}`,
        ]),
      });

      // Owner changes vote to p3
      await publicClient.waitForTransactionReceipt({
        hash: await voting.write.vote([
          1n,
          p3.account.address as `0x${string}`,
        ]),
      });

      const room = await lobby.read.getRoom([1n]);
      expect(room.votedCount).to.equal(1);
    });

    it("Should not eliminate on tie", async function () {
      const { lobby, voting, owner, p1, p2, p3, publicClient } =
        await advanceToDay();

      await publicClient.waitForTransactionReceipt({
        hash: await voting.write.startVoting([1n]),
      });

      const voteFor = async (voter: any, target: `0x${string}`) => {
        await publicClient.waitForTransactionReceipt({
          hash: await voting.write.vote([1n, target], {
            account: voter.account,
          }),
        });
      };

      // Split vote: owner+p1 vote p2, p2+p3 vote owner -> tie
      await voteFor(owner, p2.account.address as `0x${string}`);
      await voteFor(p1, p2.account.address as `0x${string}`);
      await voteFor(p2, owner.account.address as `0x${string}`);
      await voteFor(p3, owner.account.address as `0x${string}`);

      // Tie — no elimination, go to NIGHT
      const room = await lobby.read.getRoom([1n]);
      expect(room.phase).to.equal(GamePhase.NIGHT);
      expect(room.aliveCount).to.equal(4);
    });
  });

  // ===================== NIGHT & MAFIA CONSENSUS =====================

  describe("Night Phase & Mafia Consensus", function () {
    async function advanceToNight() {
      const result = await advanceToDay();
      const { lobby, voting, owner, p1, p2, p3, publicClient } = result;

      await publicClient.waitForTransactionReceipt({
        hash: await voting.write.startVoting([1n]),
      });

      // All vote for p3 (citizen) — eliminates p3
      const target = p3.account.address as `0x${string}`;
      for (const p of [owner, p1, p2, p3]) {
        await publicClient.waitForTransactionReceipt({
          hash: await voting.write.vote([1n, target], {
            account: p.account,
          }),
        });
      }

      // Now in NIGHT with 3 alive: owner(MAFIA), p1(DOCTOR), p2(DETECTIVE)
      return result;
    }

    it("Should handle mafia consensus correctly", async function () {
      const { lobby, night, owner, p1, p2, publicClient } =
        await advanceToNight();

      const room = await lobby.read.getRoom([1n]);
      expect(room.phase).to.equal(GamePhase.NIGHT);

      // Mafia (owner) commits target — kill p1 (doctor)
      const mafiaSalt = "mafia_salt_1";
      const mafiaTargetHash = hashMafiaTarget(
        p1.account.address as `0x${string}`,
        mafiaSalt
      );
      await publicClient.waitForTransactionReceipt({
        hash: await night.write.commitMafiaTarget([1n, mafiaTargetHash]),
      });

      // Mafia reveals target
      await publicClient.waitForTransactionReceipt({
        hash: await night.write.revealMafiaTarget([
          1n,
          p1.account.address as `0x${string}`,
          mafiaSalt,
        ]),
      });

      // Check consensus
      const consensus = await night.read.getMafiaConsensus([1n]);
      expect(getAddress(consensus[2])).to.equal(
        getAddress(p1.account.address)
      );

      // Doctor (p1) commits and reveals HEAL on p2
      const docSalt = "doc_salt";
      const docHash = hashNightAction(
        NightActionType.HEAL,
        p2.account.address as `0x${string}`,
        docSalt
      );
      await publicClient.waitForTransactionReceipt({
        hash: await night.write.commitNightAction([1n, docHash], {
          account: p1.account,
        }),
      });
      await publicClient.waitForTransactionReceipt({
        hash: await night.write.revealNightAction(
          [
            1n,
            NightActionType.HEAL,
            p2.account.address as `0x${string}`,
            docSalt,
          ],
          { account: p1.account }
        ),
      });

      // End night
      await publicClient.waitForTransactionReceipt({
        hash: await night.write.endNight([1n]),
      });

      // p1 was targeted by mafia AND NOT healed -> dead
      const roomAfter = await lobby.read.getRoom([1n]);
      expect(roomAfter.aliveCount).to.equal(2);
    });

    it("Should heal mafia target if doctor heals them", async function () {
      const { lobby, night, owner, p1, p2, publicClient } =
        await advanceToNight();

      // Mafia targets p1
      const mafiaSalt = "ms1";
      const mafiaHash = hashMafiaTarget(
        p1.account.address as `0x${string}`,
        mafiaSalt
      );
      await publicClient.waitForTransactionReceipt({
        hash: await night.write.commitMafiaTarget([1n, mafiaHash]),
      });
      await publicClient.waitForTransactionReceipt({
        hash: await night.write.revealMafiaTarget([
          1n,
          p1.account.address as `0x${string}`,
          mafiaSalt,
        ]),
      });

      // Doctor heals p1 (the mafia target!)
      const docSalt = "ds1";
      const docHash = hashNightAction(
        NightActionType.HEAL,
        p1.account.address as `0x${string}`,
        docSalt
      );
      await publicClient.waitForTransactionReceipt({
        hash: await night.write.commitNightAction([1n, docHash], {
          account: p1.account,
        }),
      });
      await publicClient.waitForTransactionReceipt({
        hash: await night.write.revealNightAction(
          [
            1n,
            NightActionType.HEAL,
            p1.account.address as `0x${string}`,
            docSalt,
          ],
          { account: p1.account }
        ),
      });

      await publicClient.waitForTransactionReceipt({
        hash: await night.write.endNight([1n]),
      });

      // Nobody dies — doctor healed the target
      const roomAfter = await lobby.read.getRoom([1n]);
      expect(roomAfter.aliveCount).to.equal(3);
    });

    it("Should not allow instant endNight (bug fix test)", async function () {
      const result = await advanceToDay();
      const { lobby, voting, night, owner, p1, p2, p3, publicClient } =
        result;

      // Go to night via tie vote
      await publicClient.waitForTransactionReceipt({
        hash: await voting.write.startVoting([1n]),
      });
      const voteFor = async (voter: any, target: `0x${string}`) => {
        await publicClient.waitForTransactionReceipt({
          hash: await voting.write.vote([1n, target], {
            account: voter.account,
          }),
        });
      };
      await voteFor(owner, p2.account.address as `0x${string}`);
      await voteFor(p1, p2.account.address as `0x${string}`);
      await voteFor(p2, owner.account.address as `0x${string}`);
      await voteFor(p3, owner.account.address as `0x${string}`);

      // Now in NIGHT — try instant endNight with no commits
      let failed = false;
      try {
        await night.write.endNight([1n]);
      } catch {
        failed = true;
      }
      expect(failed).to.be.true;
    });

    it("Mafia chat should not block consensus (chatter bug fix)", async function () {
      const { lobby, night, owner, p1, p2, publicClient } =
        await advanceToNight();

      // Mafia sends chat first
      await publicClient.waitForTransactionReceipt({
        hash: await night.write.sendMafiaMessage([
          1n,
          toHex("kill p2 tonight"),
        ]),
      });

      // Now mafia commits and reveals target
      const mafiaSalt = "ms_chat";
      const mafiaHash = hashMafiaTarget(
        p2.account.address as `0x${string}`,
        mafiaSalt
      );
      await publicClient.waitForTransactionReceipt({
        hash: await night.write.commitMafiaTarget([1n, mafiaHash]),
      });
      await publicClient.waitForTransactionReceipt({
        hash: await night.write.revealMafiaTarget([
          1n,
          p2.account.address as `0x${string}`,
          mafiaSalt,
        ]),
      });

      // Consensus should work
      const consensus = await night.read.getMafiaConsensus([1n]);
      expect(getAddress(consensus[2])).to.equal(
        getAddress(p2.account.address)
      );

      // End night
      await publicClient.waitForTransactionReceipt({
        hash: await night.write.endNight([1n]),
      });

      const roomAfter = await lobby.read.getRoom([1n]);
      expect(roomAfter.aliveCount).to.equal(2); // p2 killed
    });
  });

  // ===================== ROLE REVEAL & WIN CONDITIONS =====================

  describe("Role Reveal & Win Conditions", function () {
    it("Should punish mafia cheater on role reveal", async function () {
      const {
        lobby,
        voting,
        night,
        owner,
        p1,
        p2,
        p3,
        publicClient,
        roleAssignments,
      } = await advanceToDay();

      // Go to night via tie
      await publicClient.waitForTransactionReceipt({
        hash: await voting.write.startVoting([1n]),
      });

      const voteFor = async (voter: any, target: `0x${string}`) => {
        await publicClient.waitForTransactionReceipt({
          hash: await voting.write.vote([1n, target], {
            account: voter.account,
          }),
        });
      };
      await voteFor(owner, p2.account.address as `0x${string}`);
      await voteFor(p1, p2.account.address as `0x${string}`);
      await voteFor(p2, owner.account.address as `0x${string}`);
      await voteFor(p3, owner.account.address as `0x${string}`);

      // Night — p3 (citizen) sends mafia message (cheating!)
      await publicClient.waitForTransactionReceipt({
        hash: await night.write.sendMafiaMessage(
          [1n, toHex("I am mafia")],
          { account: p3.account }
        ),
      });

      // Mafia does their thing
      const ms = "ms2";
      const mh = hashMafiaTarget(
        p1.account.address as `0x${string}`,
        ms
      );
      await publicClient.waitForTransactionReceipt({
        hash: await night.write.commitMafiaTarget([1n, mh]),
      });
      await publicClient.waitForTransactionReceipt({
        hash: await night.write.revealMafiaTarget([
          1n,
          p1.account.address as `0x${string}`,
          ms,
        ]),
      });

      await publicClient.waitForTransactionReceipt({
        hash: await night.write.endNight([1n]),
      });

      // p3 reveals role — should be punished for claiming mafia
      const ra = roleAssignments.find((r) => r.player === p3)!;
      await publicClient.waitForTransactionReceipt({
        hash: await voting.write.revealRole([1n, ra.role, ra.salt], {
          account: p3.account,
        }),
      });

      // p3 should be eliminated (cheater punishment)
      const flags = await lobby.read.getPlayerFlags([
        1n,
        p3.account.address as `0x${string}`,
      ]);
      expect(flags[0]).to.be.false; // isActive = false
    });
  });

  // ===================== TIMEOUT =====================

  describe("Phase Timeouts", function () {
    it("Should kick shuffler on timeout", async function () {
      const { lobby, voting, owner, p1, publicClient } =
        await createFullRoom();

      await publicClient.waitForTransactionReceipt({
        hash: await lobby.write.startGame([1n]),
      });

      // Fast forward past deadline
      await networkHelpers.time.increase(BigInt(4 * 60)); // 4 min > PHASE_TIMEOUT

      await publicClient.waitForTransactionReceipt({
        hash: await voting.write.forcePhaseTimeout([1n], {
          account: p1.account,
        }),
      });

      // Owner (first shuffler) should be kicked
      const flags = await lobby.read.getPlayerFlags([
        1n,
        owner.account.address as `0x${string}`,
      ]);
      expect(flags[0]).to.be.false; // isActive = false
    });
  });

  // ===================== SESSION KEYS =====================

  describe("Session Keys", function () {
    it("Should register session key on createAndJoin", async function () {
      const { lobby, p1, publicClient } =
        await networkHelpers.loadFixture(deployDiamondFixture);

      const sessionAddr = p1.account.address as `0x${string}`;
      await publicClient.waitForTransactionReceipt({
        hash: await lobby.write.createAndJoin([
          "Room",
          10,
          "Host",
          toHex("pk"),
          sessionAddr,
        ]),
      });

      const wallets = await viem.getWalletClients();
      const ownerAddr = wallets[0].account.address as `0x${string}`;
      const sessionData = await lobby.read.sessionKeys([ownerAddr]);
      expect(getAddress(sessionData.sessionAddress)).to.equal(
        getAddress(sessionAddr)
      );
      expect(sessionData.isActive).to.be.true;
    });

    it("Should allow session key to act on behalf of main wallet", async function () {
      const { lobby, owner, p1, p2, p3, p4, publicClient } =
        await networkHelpers.loadFixture(deployDiamondFixture);

      const sessionAddr = p4.account.address as `0x${string}`;
      await publicClient.waitForTransactionReceipt({
        hash: await lobby.write.createAndJoin([
          "Room",
          10,
          "Host",
          toHex("pk"),
          sessionAddr,
        ]),
      });

      // Others join
      for (const p of [p1, p2, p3]) {
        await publicClient.waitForTransactionReceipt({
          hash: await lobby.write.joinRoom(
            [1n, "P", toHex("pk"), zeroAddress],
            { account: p.account }
          ),
        });
      }

      // Session key (p4) starts game on behalf of owner
      await publicClient.waitForTransactionReceipt({
        hash: await lobby.write.startGame([1n], { account: p4.account }),
      });

      const room = await lobby.read.getRoom([1n]);
      expect(room.phase).to.equal(GamePhase.SHUFFLING);
    });
  });

  // ===================== DIAMOND-SPECIFIC TESTS =====================

  describe("Diamond Proxy", function () {
    it("Should revert on unknown function selector", async function () {
      const { diamond, publicClient } =
        await networkHelpers.loadFixture(deployDiamondFixture);
      let failed = false;
      try {
        // Call a random selector that isn't registered
        await publicClient.call({
          to: diamond.address,
          data: "0xdeadbeef",
        });
      } catch {
        failed = true;
      }
      expect(failed).to.be.true;
    });

    it("Should only allow owner to add facets", async function () {
      const { diamond, p1 } =
        await networkHelpers.loadFixture(deployDiamondFixture);
      let failed = false;
      try {
        await diamond.write.addFacet([zeroAddress, []], {
          account: p1.account,
        });
      } catch {
        failed = true;
      }
      expect(failed).to.be.true;
    });
  });

  // ===================== GAME MASTER MODE =====================

  describe("Game Master Night Resolution", function () {
    it("Should resolve night via Game Master", async function () {
      const fixture = await advanceToDay();
      const { lobby, voting, night, owner, p1, p2, p3, publicClient } =
        fixture;

      // Set owner as game master
      await publicClient.waitForTransactionReceipt({
        hash: await lobby.write.setGameMaster([
          owner.account.address as `0x${string}`,
        ]),
      });

      // Go to night via voting
      await publicClient.waitForTransactionReceipt({
        hash: await voting.write.startVoting([1n]),
      });

      // All vote for p3 (citizen)
      const target = p3.account.address as `0x${string}`;
      for (const p of [owner, p1, p2, p3]) {
        await publicClient.waitForTransactionReceipt({
          hash: await voting.write.vote([1n, target], {
            account: p.account,
          }),
        });
      }

      // Now in NIGHT with 3 alive: owner(MAFIA), p1(DOCTOR), p2(DETECTIVE)
      const room = await lobby.read.getRoom([1n]);
      expect(room.phase).to.equal(GamePhase.NIGHT);

      // GM resolves night: kill p1, no heal
      await publicClient.waitForTransactionReceipt({
        hash: await night.write.resolveNightAsGameMaster([
          1n,
          p1.account.address as `0x${string}`,
          zeroAddress,
        ]),
      });

      const roomAfter = await lobby.read.getRoom([1n]);
      expect(roomAfter.phase).to.equal(GamePhase.DAY);
      expect(roomAfter.aliveCount).to.equal(2);
    });
  });

  // ===================== DEPOSIT SYSTEM =====================

  describe("Deposit System", function () {
    it("Should collect deposits on join", async function () {
      const { lobby, owner, p1, publicClient } =
        await networkHelpers.loadFixture(deployDiamondFixture);

      // Set default deposit
      await publicClient.waitForTransactionReceipt({
        hash: await lobby.write.setDefaultDeposit([1000n]),
      });

      // Create room with deposit
      await publicClient.waitForTransactionReceipt({
        hash: await lobby.write.createAndJoin(
          ["DepositRoom", 10, "Host", toHex("pk"), zeroAddress],
          { value: 1000n }
        ),
      });

      const deposit = await lobby.read.getPlayerDeposit([
        1n,
        owner.account.address as `0x${string}`,
      ]);
      expect(deposit).to.equal(1000n);

      // p1 joins with deposit
      await publicClient.waitForTransactionReceipt({
        hash: await lobby.write.joinRoom(
          [1n, "P1", toHex("pk"), zeroAddress],
          { account: p1.account, value: 1000n }
        ),
      });

      const depositP1 = await lobby.read.getPlayerDeposit([
        1n,
        p1.account.address as `0x${string}`,
      ]);
      expect(depositP1).to.equal(1000n);
    });

    it("Should reject join with insufficient deposit", async function () {
      const { lobby, p1, publicClient } =
        await networkHelpers.loadFixture(deployDiamondFixture);

      await publicClient.waitForTransactionReceipt({
        hash: await lobby.write.setDefaultDeposit([1000n]),
      });

      await publicClient.waitForTransactionReceipt({
        hash: await lobby.write.createAndJoin(
          ["DepositRoom", 10, "Host", toHex("pk"), zeroAddress],
          { value: 1000n }
        ),
      });

      // Try to join with insufficient deposit
      let failed = false;
      try {
        await lobby.write.joinRoom(
          [1n, "P1", toHex("pk"), zeroAddress],
          { account: p1.account, value: 500n }
        );
      } catch {
        failed = true;
      }
      expect(failed).to.be.true;
    });
  });
});

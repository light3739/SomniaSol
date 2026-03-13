// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "./MafiaTypes.sol";

/// @title MafiaStorage — Shared storage layout for all facets (Diamond storage pattern)
/// @dev All facets use `LibStorage.s()` to access the same storage slot, avoiding collisions.
library LibStorage {
    bytes32 constant STORAGE_SLOT = keccak256("mafia.game.storage.v1");

    struct Storage {
        // ---- Core game state ----
        mapping(uint256 => MafiaTypes.GameRoom) rooms;
        mapping(uint256 => MafiaTypes.Player[]) roomPlayers;
        mapping(uint256 => mapping(address => bool)) isPlayerInRoom;
        mapping(uint256 => mapping(address => uint8)) playerIndex;

        // ---- Shuffle / Deck ----
        mapping(uint256 => mapping(address => MafiaTypes.DeckCommit)) deckCommits;
        mapping(uint256 => string[]) revealedDeck;
        mapping(uint256 => mapping(address => mapping(address => bytes))) playerDeckKeys;

        // ---- Voting ----
        mapping(uint256 => mapping(address => address)) votes;
        mapping(uint256 => mapping(address => uint8)) voteCounts;

        // ---- Night ----
        mapping(uint256 => mapping(address => MafiaTypes.NightCommit)) nightCommits;
        mapping(uint256 => mapping(address => MafiaTypes.NightActionType)) revealedActions;
        mapping(uint256 => mapping(address => address)) revealedTargets;

        // ---- Roles ----
        mapping(uint256 => mapping(address => MafiaTypes.Role)) playerRoles;
        mapping(uint256 => mapping(address => bytes32)) roleCommits;

        // ---- Mafia coordination ----
        mapping(uint256 => MafiaTypes.MafiaMessage[]) mafiaChat;
        mapping(uint256 => mapping(address => MafiaTypes.MafiaTargetCommit)) mafiaTargetCommits;
        mapping(uint256 => uint8) mafiaCommittedCount;
        mapping(uint256 => uint8) mafiaRevealedCount;
        mapping(uint256 => address) mafiaConsensusTarget;

        // ---- Session keys ----
        mapping(address => MafiaTypes.SessionKey) sessionKeys;
        mapping(address => address) sessionToMain;
        mapping(address => bool) isRegisteredSession;

        // ---- Game Master ----
        address gameMaster;                     // trusted server for night actions
        mapping(uint256 => bool) nightSubmittedByGM; // GM already submitted night result

        // ---- Deposit / Slashing ----
        uint128 defaultDeposit;                 // global default deposit amount
        mapping(uint256 => mapping(address => uint128)) playerDeposits;  // per-player deposit
        mapping(uint256 => mapping(address => bool)) depositRefunded;

        // ---- ZK ----
        address zkVerifier;
        mapping(uint256 => bool) gameResult;    // true = mafia won, false = town won
        mapping(uint256 => bool) prizesClaimed; // track if prizes were distributed
        mapping(bytes32 => bool) proofNullifiers; // 🆕 Prevent ZK proof replay attacks

        // ---- Admin & Funds ----
        uint256 nextRoomId;
        uint256 nextTournamentId;
        mapping(uint256 => MafiaTypes.Tournament) tournaments;
        uint128 platformFeeBalance;             // Accumulated platform fees
        uint128 totalLockedFunds;               // Total funds locked in active games/tournaments
        mapping(address => uint8) activeTournaments; // 🆕 Track active tournaments per organizer to prevent spam
        uint32 feeWithdrawalReadyAt;            // 🆕 Timelock for fee withdrawal
        mapping(uint256 => mapping(address => bool)) isTournamentParticipant; // 🆕 Prevent double join
        mapping(uint256 => bool) tournamentWhitelistEnabled; // 🆕 Toggle for whitelist
        mapping(uint256 => mapping(address => bool)) tournamentWhitelist; // 🆕 Whitelisted addresses per tournament

        // ---- Reentrancy ----
        uint256 reentrancyStatus;

        // ---- Pause ----
        bool paused;

        // ---- Owner (synced from Diamond) ----
        address owner;
    }

    function s() internal pure returns (Storage storage ds) {
        bytes32 slot = STORAGE_SLOT;
        assembly { ds.slot := slot }
    }
}

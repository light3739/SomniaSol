// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @title MafiaTypes — Shared types for Mafia game
library MafiaTypes {
    enum GamePhase { LOBBY, SHUFFLING, REVEAL, DAY, VOTING, NIGHT, ENDED }
    enum NightActionType { NONE, KILL, HEAL, CHECK }
    enum Role { NONE, MAFIA, DOCTOR, DETECTIVE, CITIZEN }

    struct Player {
        address wallet;
        string nickname;
        bytes publicKey;
        uint32 flags;
    }

    struct GameRoom {
        uint64 id;
        address host;
        string name;
        GamePhase phase;
        uint8 maxPlayers;
        uint8 playersCount;
        uint8 aliveCount;
        uint16 dayCount;
        uint8 currentShufflerIndex;
        uint32 lastActionTimestamp;
        uint32 phaseDeadline;
        uint8 confirmedCount;
        uint8 votedCount;
        uint8 committedCount;
        uint8 revealedCount;
        uint8 keysSharedCount;
        uint128 depositPool;    // total ETH deposited for this room
        uint128 depositPerPlayer; // required deposit amount
        bool isPrivate;         // 🆕 Requires GM signature to join
        uint256 tournamentId;   // 0 = standalone, >0 = part of tournament
    }

    struct SessionKey {
        address sessionAddress;
        uint32 expiresAt;
        uint64 roomId;
        bool isActive;
    }

    struct NightCommit {
        bytes32 commitHash;
        bool revealed;
        uint32 commitTime;
    }

    struct DeckCommit {
        bytes32 commitHash;
        string[] deck;
        bool revealed;
    }

    struct MafiaMessage {
        bytes encryptedMessage;
        uint32 timestamp;
        address sender;
    }

    enum TournamentPhase { REGISTRATION, IN_PROGRESS, COMPLETED, CANCELLED }

    struct Tournament {
        uint256 id;
        address organizer;
        string name;
        uint128 buyIn;            // 0 = freeroll
        uint128 prizePool;        // Isolated tournament funds
        uint128 platformFeePool;  // Platform fee from this tournament
        address paymentToken;     // address(0) = native, otherwise ERC20
        uint8 maxPlayers;
        uint8 playersPerTable;
        uint8 currentRound;
        TournamentPhase phase;
        bytes32 passwordHash;     // 0x0 = open
        bool prizesClaimed;       // Have prizes been distributed?
        uint32 registrationDeadline; // 🆕 Timeout for tournament start
        address[] participants;
    }

    struct MafiaTargetCommit {
        bytes32 commitHash;
        address target;
        bool revealed;
    }
}

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

    struct MafiaTargetCommit {
        bytes32 commitHash;
        address target;
        bool revealed;
    }
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "../libraries/LibStorage.sol";
import "../libraries/LibGame.sol";
import "../libraries/MafiaTypes.sol";

/// @title ShuffleFacet — Deck commit/reveal, key sharing, role confirmation
contract ShuffleFacet {

    modifier nonReentrant() {
        LibGame.nonReentrantBefore();
        _;
        LibGame.nonReentrantAfter();
    }

    function commitDeck(uint256 roomId, bytes32 deckHash) external nonReentrant {
        LibGame.requireNotPaused();
        address player = LibGame.requireActiveParticipant(roomId);
        LibGame.requireBeforeDeadline(roomId);

        LibStorage.Storage storage ds = LibStorage.s();
        MafiaTypes.GameRoom storage room = ds.rooms[roomId];
        if (room.phase != MafiaTypes.GamePhase.SHUFFLING) revert LibGame.WrongPhase();
        if (ds.roomPlayers[roomId][room.currentShufflerIndex].wallet != player) revert LibGame.NotYourTurn();
        if (LibGame.hasFlag(roomId, player, LibGame.FLAG_DECK_COMMITTED)) revert LibGame.AlreadyCommitted();

        ds.deckCommits[roomId][player].commitHash = deckHash;
        ds.deckCommits[roomId][player].revealed = false;
        LibGame.setFlag(roomId, player, LibGame.FLAG_DECK_COMMITTED);

        emit LibGame.DeckCommitted(roomId, player, deckHash);
    }

    function revealDeck(uint256 roomId, string[] calldata deck, string calldata salt) external nonReentrant {
        LibGame.requireNotPaused();
        address player = LibGame.requireActiveParticipant(roomId);
        LibGame.requireBeforeDeadline(roomId);

        LibStorage.Storage storage ds = LibStorage.s();
        MafiaTypes.GameRoom storage room = ds.rooms[roomId];
        if (room.phase != MafiaTypes.GamePhase.SHUFFLING) revert LibGame.WrongPhase();

        bytes32 calculatedHash = keccak256(abi.encode(deck, salt));
        if (calculatedHash != ds.deckCommits[roomId][player].commitHash) revert LibGame.InvalidReveal();
        if (deck.length > LibGame.MAX_ARRAY_SIZE) revert LibGame.ArrayTooLarge();
        if (ds.revealedDeck[roomId].length == 0 && deck.length < room.playersCount) revert LibGame.InvalidDeckSize();
        if (ds.revealedDeck[roomId].length != 0 && deck.length != ds.revealedDeck[roomId].length) revert LibGame.InvalidDeckSize();

        ds.revealedDeck[roomId] = deck;
        ds.deckCommits[roomId][player].revealed = true;

        uint8 nextIndex = LibGame.findNextActive(roomId, room.currentShufflerIndex + 1);
        room.currentShufflerIndex = nextIndex;
        room.lastActionTimestamp = uint32(block.timestamp);
        room.phaseDeadline = uint32(block.timestamp + LibGame.PHASE_TIMEOUT);
        room.revealedCount++;

        emit LibGame.DeckRevealed(roomId, player, deck);

        if (nextIndex >= ds.roomPlayers[roomId].length) {
            LibGame.transitionToReveal(roomId);
        }
    }

    function shareKeysToAll(
        uint256 roomId,
        address[] calldata recipients,
        bytes[] calldata encryptedKeys
    ) external nonReentrant {
        LibGame.requireNotPaused();
        address player = LibGame.requireActiveParticipant(roomId);
        LibGame.requireBeforeDeadline(roomId);

        LibStorage.Storage storage ds = LibStorage.s();
        MafiaTypes.GameRoom storage room = ds.rooms[roomId];
        if (room.phase != MafiaTypes.GamePhase.REVEAL) revert LibGame.WrongPhase();
        if (recipients.length != encryptedKeys.length) revert LibGame.InvalidArrayLength();
        if (recipients.length > LibGame.MAX_ARRAY_SIZE) revert LibGame.ArrayTooLarge();
        if (LibGame.hasFlag(roomId, player, LibGame.FLAG_HAS_SHARED_KEYS)) revert LibGame.AlreadySharedKeys();

        for (uint256 i = 0; i < recipients.length; i++) {
            address to = recipients[i];
            if (!ds.isPlayerInRoom[roomId][to]) revert LibGame.NotParticipant();
            if (to == player) revert LibGame.InvalidSessionAddress();
            ds.playerDeckKeys[roomId][player][to] = encryptedKeys[i];
        }

        LibGame.setFlag(roomId, player, LibGame.FLAG_HAS_SHARED_KEYS);
        room.keysSharedCount++;
        emit LibGame.KeysSharedToAll(roomId, player);
        if (room.keysSharedCount == room.aliveCount) emit LibGame.AllKeysShared(roomId);
    }

    function commitAndConfirmRole(uint256 roomId, bytes32 roleHash) external nonReentrant {
        LibGame.requireNotPaused();
        address player = LibGame.requireActiveParticipant(roomId);
        LibGame.requireBeforeDeadline(roomId);

        LibStorage.Storage storage ds = LibStorage.s();
        MafiaTypes.GameRoom storage room = ds.rooms[roomId];
        if (room.phase != MafiaTypes.GamePhase.REVEAL) revert LibGame.WrongPhase();
        if (ds.roleCommits[roomId][player] != bytes32(0)) revert LibGame.RoleAlreadyCommitted();
        if (LibGame.hasFlag(roomId, player, LibGame.FLAG_CONFIRMED_ROLE)) revert LibGame.AlreadyRevealed();

        ds.roleCommits[roomId][player] = roleHash;
        emit LibGame.RoleCommitted(roomId, player, roleHash);

        LibGame.setFlag(roomId, player, LibGame.FLAG_CONFIRMED_ROLE);
        room.confirmedCount++;
        emit LibGame.RoleConfirmed(roomId, player);

        if (room.confirmedCount == room.aliveCount) {
            LibGame.transitionToDay(roomId);
            emit LibGame.AllRolesConfirmed(roomId);
        }
    }

    function commitRole(uint256 roomId, bytes32 roleHash) external nonReentrant {
        LibGame.requireNotPaused();
        address player = LibGame.requireActiveParticipant(roomId);

        LibStorage.Storage storage ds = LibStorage.s();
        if (ds.rooms[roomId].phase != MafiaTypes.GamePhase.REVEAL) revert LibGame.WrongPhase();
        if (ds.roleCommits[roomId][player] != bytes32(0)) revert LibGame.RoleAlreadyCommitted();
        ds.roleCommits[roomId][player] = roleHash;
        emit LibGame.RoleCommitted(roomId, player, roleHash);
    }

    function confirmRole(uint256 roomId) external nonReentrant {
        LibGame.requireNotPaused();
        address player = LibGame.requireActiveParticipant(roomId);
        LibGame.requireBeforeDeadline(roomId);

        LibStorage.Storage storage ds = LibStorage.s();
        MafiaTypes.GameRoom storage room = ds.rooms[roomId];
        if (room.phase != MafiaTypes.GamePhase.REVEAL) revert LibGame.WrongPhase();
        if (ds.roleCommits[roomId][player] == bytes32(0)) revert LibGame.RoleNotCommitted();
        if (LibGame.hasFlag(roomId, player, LibGame.FLAG_CONFIRMED_ROLE)) revert LibGame.AlreadyRevealed();

        LibGame.setFlag(roomId, player, LibGame.FLAG_CONFIRMED_ROLE);
        room.confirmedCount++;
        emit LibGame.RoleConfirmed(roomId, player);
        if (room.confirmedCount == room.aliveCount) {
            LibGame.transitionToDay(roomId);
            emit LibGame.AllRolesConfirmed(roomId);
        }
    }

    // ---- View ----
    function getRevealedDeck(uint256 roomId, uint256 index) external view returns (string memory) {
        return LibStorage.s().revealedDeck[roomId][index];
    }
}

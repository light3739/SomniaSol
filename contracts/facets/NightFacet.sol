// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "../libraries/LibStorage.sol";
import "../libraries/LibGame.sol";
import "../libraries/MafiaTypes.sol";

/// @title NightFacet — Mafia actions and night phase logic
contract NightFacet {

    modifier nonReentrant() {
        LibGame.nonReentrantBefore();
        _;
        LibGame.nonReentrantAfter();
    }

    function mafiaMessage(uint256 roomId, string calldata encryptedMessage) external nonReentrant {
        LibGame.requireNotPaused();
        address player = LibGame.requireActiveParticipant(roomId);
        LibStorage.Storage storage ds = LibStorage.s();
        
        if (ds.rooms[roomId].phase != MafiaTypes.GamePhase.NIGHT) revert LibGame.WrongPhase();
        if (ds.playerRoles[roomId][player] != MafiaTypes.Role.MAFIA) revert LibGame.NotAuthorized();

        // Obfuscated: No sender address in event
        emit LibGame.MafiaMessageSent(roomId, encryptedMessage);
    }

    function commitMafiaTarget(uint256 roomId, bytes32 targetHash) external nonReentrant {
        LibGame.requireNotPaused();
        address player = LibGame.requireActiveParticipant(roomId);
        LibGame.requireBeforeDeadline(roomId);

        LibStorage.Storage storage ds = LibStorage.s();
        MafiaTypes.GameRoom storage room = ds.rooms[roomId];
        if (room.phase != MafiaTypes.GamePhase.NIGHT) revert LibGame.WrongPhase();
        if (ds.playerRoles[roomId][player] != MafiaTypes.Role.MAFIA) revert LibGame.NotAuthorized();
        if (ds.mafiaTargetCommits[roomId][player] != bytes32(0)) revert LibGame.AlreadyCommitted();

        ds.mafiaTargetCommits[roomId][player] = targetHash;
        room.committedCount++;

        // Obfuscated: No player address in event
        emit LibGame.MafiaTargetCommitted(roomId, targetHash);

        if (room.committedCount == LibGame.countMafia(roomId)) {
            emit LibGame.AllMafiaTargetsCommitted(roomId);
        }
    }

    function revealMafiaTarget(uint256 roomId, address target, string calldata salt) external nonReentrant {
        LibGame.requireNotPaused();
        address player = LibGame.requireActiveParticipant(roomId);
        LibGame.requireBeforeDeadline(roomId);

        LibStorage.Storage storage ds = LibStorage.s();
        MafiaTypes.GameRoom storage room = ds.rooms[roomId];
        if (room.phase != MafiaTypes.GamePhase.NIGHT) revert LibGame.WrongPhase();
        if (ds.playerRoles[roomId][player] != MafiaTypes.Role.MAFIA) revert LibGame.NotAuthorized();

        bytes32 sharedTargetHash = keccak256(abi.encode(target, salt));
        if (sharedTargetHash != ds.mafiaTargetCommits[roomId][player]) revert LibGame.InvalidReveal();

        ds.mafiaRevealedTargets[roomId][player] = target;
        LibGame.setFlag(roomId, player, LibGame.FLAG_HAS_REVEALED);
        room.revealedCount++;

        // Obfuscated: No player address in event
        emit LibGame.MafiaTargetRevealed(roomId, target);

        if (room.revealedCount == LibGame.countMafia(roomId)) {
            LibGame.finalizeNight(roomId);
        }
    }
}

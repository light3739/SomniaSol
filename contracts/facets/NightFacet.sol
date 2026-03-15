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
        if (ds.playerRoles[roomId][player] != MafiaTypes.Role.MAFIA) revert LibGame.NotMafiaMember();

        // Obfuscated: No sender address in event
        emit LibGame.MafiaMessageSent(roomId, bytes(encryptedMessage));
    }

    function commitMafiaTarget(uint256 roomId, bytes32 targetHash) external nonReentrant {
        LibGame.requireNotPaused();
        address player = LibGame.requireActiveParticipant(roomId);
        LibGame.requireBeforeDeadline(roomId);

        LibStorage.Storage storage ds = LibStorage.s();
        MafiaTypes.GameRoom storage room = ds.rooms[roomId];
        if (room.phase != MafiaTypes.GamePhase.NIGHT) revert LibGame.WrongPhase();
        if (ds.playerRoles[roomId][player] != MafiaTypes.Role.MAFIA) revert LibGame.NotMafiaMember();
        if (ds.mafiaTargetCommits[roomId][player].commitHash != bytes32(0)) revert LibGame.AlreadyCommitted();

        ds.mafiaTargetCommits[roomId][player].commitHash = targetHash;
        ds.mafiaTargetCommits[roomId][player].revealed = false;
        ds.mafiaCommittedCount[roomId]++;

        // Obfuscated: No player address in event
        emit LibGame.MafiaTargetCommitted(roomId, targetHash);

        if (ds.mafiaCommittedCount[roomId] == LibGame.countMafia(roomId)) {
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
        if (ds.playerRoles[roomId][player] != MafiaTypes.Role.MAFIA) revert LibGame.NotMafiaMember();

        bytes32 sharedTargetHash = keccak256(abi.encode(target, salt));
        if (sharedTargetHash != ds.mafiaTargetCommits[roomId][player].commitHash) revert LibGame.InvalidReveal();

        ds.mafiaTargetCommits[roomId][player].target = target;
        ds.mafiaTargetCommits[roomId][player].revealed = true;
        LibGame.setFlag(roomId, player, LibGame.FLAG_HAS_REVEALED);
        ds.mafiaRevealedCount[roomId]++;

        // Obfuscated: No player address in event
        emit LibGame.MafiaTargetRevealed(roomId, target);

        if (ds.mafiaRevealedCount[roomId] == LibGame.countMafia(roomId)) {
            LibGame.finalizeNight(roomId);
        }
    }

    function getMafiaConsensus(uint256 roomId) external view returns (uint8 committed, uint8 revealed, address consensusTarget) {
        LibStorage.Storage storage ds = LibStorage.s();
        return (
            ds.mafiaCommittedCount[roomId],
            ds.mafiaRevealedCount[roomId],
            ds.mafiaConsensusTarget[roomId]
        );
    }

    /**
     * @notice Force resolve the night. Can be called if mafia members are idle.
     * @param victim The player to kill (if consensus exists on-chain or passed by GM)
     */
    function resolveNightAsGameMaster(uint256 roomId, address victim, address /*investigated*/) external {
        LibStorage.Storage storage ds = LibStorage.s();
        if (ds.rooms[roomId].phase != MafiaTypes.GamePhase.NIGHT) revert LibGame.WrongPhase();
        
        // Priority: If victim is passed by GM/caller, use it. Otherwise use on-chain consensus.
        if (victim != address(0)) {
            LibGame.killPlayer(roomId, victim);
            emit LibGame.NightFinalized(roomId, victim, address(0));
        } else {
            LibGame.finalizeNight(roomId);
        }
    }
}

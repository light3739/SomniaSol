// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "../libraries/LibStorage.sol";
import "../libraries/LibGame.sol";
import "../libraries/MafiaTypes.sol";

/// @title VotingFacet — Day voting, elimination, role reveal
contract VotingFacet {

    modifier nonReentrant() {
        LibGame.nonReentrantBefore();
        _;
        LibGame.nonReentrantAfter();
    }

    function startVoting(uint256 roomId) external nonReentrant {
        LibGame.requireNotPaused();
        LibGame.requireActiveParticipant(roomId);

        LibStorage.Storage storage ds = LibStorage.s();
        MafiaTypes.GameRoom storage room = ds.rooms[roomId];
        if (room.phase != MafiaTypes.GamePhase.DAY) revert LibGame.WrongPhase();

        room.phase = MafiaTypes.GamePhase.VOTING;
        room.votedCount = 0;
        room.lastActionTimestamp = uint32(block.timestamp);
        room.phaseDeadline = uint32(block.timestamp + LibGame.PHASE_TIMEOUT);

        MafiaTypes.Player[] storage players = ds.roomPlayers[roomId];
        for (uint8 i = 0; i < players.length; i++) {
            address p = players[i].wallet;
            LibGame.clearFlag(roomId, p, LibGame.FLAG_HAS_VOTED);
            if ((players[i].flags & LibGame.FLAG_ACTIVE) != 0) ds.voteCounts[roomId][p] = 0;
        }
        emit LibGame.VotingStarted(roomId);
    }

    function vote(uint256 roomId, address target) external nonReentrant {
        LibGame.requireNotPaused();
        address player = LibGame.requireActiveParticipant(roomId);
        LibGame.requireBeforeDeadline(roomId);

        LibStorage.Storage storage ds = LibStorage.s();
        MafiaTypes.GameRoom storage room = ds.rooms[roomId];
        if (room.phase != MafiaTypes.GamePhase.VOTING) revert LibGame.WrongPhase();
        if (LibGame.hasFlag(roomId, player, LibGame.FLAG_HAS_VOTED)) revert LibGame.AlreadyVoted();
        if (!ds.isPlayerInRoom[roomId][target]) revert LibGame.NotParticipant();
        if ((ds.roomPlayers[roomId][ds.playerIndex[roomId][target]].flags & LibGame.FLAG_ACTIVE) == 0) revert LibGame.NotActive();

        ds.voteCounts[roomId][target]++;
        LibGame.setFlag(roomId, player, LibGame.FLAG_HAS_VOTED);
        room.votedCount++;

        emit LibGame.PlayerVoted(roomId, player, target);

        if (room.votedCount == room.aliveCount) {
            LibGame.finalizeVotingInternal(roomId);
        }
    }

    function finalizeVoting(uint256 roomId) external nonReentrant {
        LibGame.requireNotPaused();
        LibStorage.Storage storage ds = LibStorage.s();
        if (ds.rooms[roomId].phase != MafiaTypes.GamePhase.VOTING) revert LibGame.WrongPhase();
        if (block.timestamp <= ds.rooms[roomId].phaseDeadline && ds.rooms[roomId].votedCount < ds.rooms[roomId].aliveCount) revert LibGame.TooEarly();
        LibGame.finalizeVotingInternal(roomId);
    }
}

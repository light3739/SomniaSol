// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "../libraries/LibStorage.sol";
import "../libraries/LibGame.sol";
import "../libraries/MafiaTypes.sol";

/// @title VotingFacet — Day voting, elimination, role reveal
contract VotingFacet {

    function startVoting(uint256 roomId) external {
        LibGame.nonReentrantBefore();
        LibGame.requireNotPaused();
        LibGame.requireActiveParticipant(roomId);

        LibStorage.Storage storage ds = LibStorage.s();
        MafiaTypes.GameRoom storage room = ds.rooms[roomId];
        if (room.phase != MafiaTypes.GamePhase.DAY) revert LibGame.WrongPhase();

        room.phase = MafiaTypes.GamePhase.VOTING;
        room.votedCount = 0;
        room.phaseDeadline = uint32(block.timestamp + LibGame.VOTING_TIMEOUT);

        MafiaTypes.Player[] storage players = ds.roomPlayers[roomId];
        for (uint8 i = 0; i < players.length; i++) {
            address p = players[i].wallet;
            players[i].flags &= ~LibGame.FLAG_HAS_VOTED;
            ds.votes[roomId][p] = address(0);
            if ((players[i].flags & LibGame.FLAG_ACTIVE) != 0) ds.voteCounts[roomId][p] = 0;
        }
        emit LibGame.VotingStarted(roomId);
        LibGame.nonReentrantAfter();
    }

    function vote(uint256 roomId, address target) external {
        LibGame.nonReentrantBefore();
        LibGame.requireNotPaused();
        address player = LibGame.requireActiveParticipant(roomId);
        LibGame.requireBeforeDeadline(roomId);

        LibStorage.Storage storage ds = LibStorage.s();
        MafiaTypes.GameRoom storage room = ds.rooms[roomId];
        if (room.phase != MafiaTypes.GamePhase.VOTING) revert LibGame.WrongPhase();
        if (!ds.isPlayerInRoom[roomId][target]) revert LibGame.NotParticipant();
        if (!LibGame.hasFlag(roomId, target, LibGame.FLAG_ACTIVE)) revert LibGame.PlayerInactive();

        bool alreadyVoted = LibGame.hasFlag(roomId, player, LibGame.FLAG_HAS_VOTED);
        address oldTarget = ds.votes[roomId][player];
        if (oldTarget != address(0) && ds.voteCounts[roomId][oldTarget] > 0)
            ds.voteCounts[roomId][oldTarget]--;

        ds.votes[roomId][player] = target;
        ds.voteCounts[roomId][target]++;

        if (!alreadyVoted) {
            LibGame.setFlag(roomId, player, LibGame.FLAG_HAS_VOTED);
            room.votedCount++;
        }
        emit LibGame.VoteCast(roomId, player, target);

        if (room.votedCount == room.aliveCount) _finalizeVoting(roomId);

        LibGame.nonReentrantAfter();
    }

    function revealRole(uint256 roomId, MafiaTypes.Role role, string calldata salt) external {
        LibGame.nonReentrantBefore();
        LibGame.requireNotPaused();
        address player = LibGame.requireActiveParticipant(roomId);

        LibStorage.Storage storage ds = LibStorage.s();
        if (ds.rooms[roomId].phase != MafiaTypes.GamePhase.ENDED) revert LibGame.WrongPhase();
        if (ds.playerRoles[roomId][player] != MafiaTypes.Role.NONE) revert LibGame.RoleAlreadyRevealed();
        if (ds.roleCommits[roomId][player] == bytes32(0)) revert LibGame.RoleNotCommitted();
        if (bytes(salt).length > 64) revert LibGame.SaltTooLong();

        bytes32 calculatedHash = keccak256(abi.encode(role, salt));
        if (calculatedHash != ds.roleCommits[roomId][player]) revert LibGame.InvalidRoleReveal();

        ds.playerRoles[roomId][player] = role;
        emit LibGame.RoleRevealed(roomId, player, role);

        // Punish cheaters
        if (LibGame.hasFlag(roomId, player, LibGame.FLAG_CLAIMED_MAFIA) && role != MafiaTypes.Role.MAFIA) {
            LibGame.killPlayer(roomId, player);
            LibGame.slashDeposit(roomId, player, "Used mafia functions with non-mafia role");
            emit LibGame.MafiaCheaterPunished(roomId, player, role);
            emit LibGame.PlayerEliminated(roomId, player, "Used mafia functions with non-mafia role");
        }

        if (LibGame.hasFlag(roomId, player, LibGame.FLAG_CLAIMED_DETECTIVE) && role != MafiaTypes.Role.DETECTIVE) {
            LibGame.killPlayer(roomId, player);
            LibGame.slashDeposit(roomId, player, "Used detective check with non-detective role");
            emit LibGame.PlayerEliminated(roomId, player, "Used detective check with non-detective role");
        }

        LibGame.nonReentrantAfter();
    }

    function endGameAutomatically(uint256 roomId) external {
        LibGame.nonReentrantBefore();
        LibGame.requireNotPaused();
        LibGame.requireActiveParticipant(roomId);

        LibStorage.Storage storage ds = LibStorage.s();
        MafiaTypes.GameRoom storage room = ds.rooms[roomId];
        if (room.phase == MafiaTypes.GamePhase.LOBBY || room.phase == MafiaTypes.GamePhase.ENDED)
            revert LibGame.WrongPhase();
        if (!LibGame.allRolesRevealed(roomId)) revert LibGame.NotAllRolesRevealed();

        (bool mafiaWins, bool townWins) = LibGame.calculateWinCondition(roomId);
        if (mafiaWins) LibGame.endGame(roomId, "Mafia wins");
        else if (townWins) LibGame.endGame(roomId, "Town wins");
        else revert LibGame.WinConditionNotMet();

        LibGame.nonReentrantAfter();
    }

    function forcePhaseTimeout(uint256 roomId) external {
        LibGame.nonReentrantBefore();
        LibGame.requireNotPaused();
        LibGame.requireActiveParticipant(roomId);

        LibStorage.Storage storage ds = LibStorage.s();
        MafiaTypes.GameRoom storage room = ds.rooms[roomId];
        if (room.phaseDeadline == 0 || block.timestamp <= room.phaseDeadline) revert LibGame.TimeNotExpired();

        emit LibGame.PhaseTimeout(roomId, room.phase);

        if (room.phase == MafiaTypes.GamePhase.SHUFFLING) {
            _kickCurrentShuffler(roomId);
        } else if (room.phase == MafiaTypes.GamePhase.REVEAL) {
            _kickUnconfirmedPlayers(roomId);
            if (room.aliveCount >= 2) LibGame.transitionToDay(roomId);
            else LibGame.endGame(roomId, "Too few players remaining");
        } else if (room.phase == MafiaTypes.GamePhase.VOTING) {
            _finalizeVoting(roomId);
        } else if (room.phase == MafiaTypes.GamePhase.NIGHT) {
            _finalizeNight(roomId);
        } else if (room.phase == MafiaTypes.GamePhase.DAY) {
            room.phase = MafiaTypes.GamePhase.VOTING;
            room.votedCount = 0;
            room.phaseDeadline = uint32(block.timestamp + LibGame.PHASE_TIMEOUT);
            emit LibGame.VotingStarted(roomId);
        }

        LibGame.nonReentrantAfter();
    }

    /// @notice Claim deposit refund after game ends (for non-slashed players)
    function claimRefund(uint256 roomId) external {
        LibGame.nonReentrantBefore();
        LibStorage.Storage storage ds = LibStorage.s();
        if (ds.rooms[roomId].phase != MafiaTypes.GamePhase.ENDED) revert LibGame.WrongPhase();
        LibGame.refundDeposit(roomId, msg.sender);
        LibGame.nonReentrantAfter();
    }

    // ---- Internal ----

    function _finalizeVoting(uint256 roomId) internal {
        LibStorage.Storage storage ds = LibStorage.s();
        MafiaTypes.GameRoom storage room = ds.rooms[roomId];

        // --- Phase 1: AFK Kill ---
        // If not everyone voted, this is a timeout — kick AFK players
        bool isTimeout = room.votedCount < room.aliveCount;

        MafiaTypes.Player[] storage players = ds.roomPlayers[roomId];
        if (isTimeout) {
            for (uint8 i = 0; i < players.length; i++) {
                if ((players[i].flags & LibGame.FLAG_ACTIVE) != 0 &&
                    (players[i].flags & LibGame.FLAG_HAS_VOTED) == 0) {
                    address afk = players[i].wallet;
                    LibGame.killPlayer(roomId, afk);
                    LibGame.slashDeposit(roomId, afk, "AFK: did not vote");
                    emit LibGame.PlayerKicked(roomId, afk, "Kicked for AFK (did not vote)");
                    emit LibGame.PlayerEliminated(roomId, afk, "Kicked for AFK (did not vote)");
                }
            }
            // Check if game should end after AFK kicks
            if (LibGame.checkWinCondition(roomId)) {
                _resetVotingState(roomId);
                return;
            }
        }

        // --- Phase 2: Count votes among remaining active players ---
        address victim = address(0);
        uint8 maxVotes = 0;
        bool isTie = false;

        for (uint8 i = 0; i < players.length; i++) {
            if ((players[i].flags & LibGame.FLAG_ACTIVE) != 0) {
                address p = players[i].wallet;
                uint8 v = ds.voteCounts[roomId][p];
                if (v > maxVotes) { maxVotes = v; victim = p; isTie = false; }
                else if (v == maxVotes && v > 0) { isTie = true; }
            }
        }

        // Majority = more than half of CURRENTLY alive players (after AFK kicks)
        if (!isTie && maxVotes > room.aliveCount / 2 && victim != address(0)) {
            LibGame.killPlayer(roomId, victim);
            emit LibGame.PlayerEliminated(roomId, victim, "Voted out");
            emit LibGame.VotingFinalized(roomId, victim, maxVotes);
        } else {
            emit LibGame.VotingFinalized(roomId, address(0), 0);
        }

        _resetVotingState(roomId);
        if (!LibGame.checkWinCondition(roomId)) LibGame.transitionToNight(roomId);
    }

    function _finalizeNight(uint256 roomId) internal {
        LibStorage.Storage storage ds = LibStorage.s();
        address mafiaTarget = ds.mafiaConsensusTarget[roomId];
        address healed = address(0);
        MafiaTypes.Player[] storage players = ds.roomPlayers[roomId];
        for (uint8 i = 0; i < players.length; i++) {
            address p = players[i].wallet;
            if (ds.revealedActions[roomId][p] == MafiaTypes.NightActionType.HEAL) {
                healed = ds.revealedTargets[roomId][p];
                break;
            }
        }

        emit LibGame.NightFinalized(roomId, mafiaTarget, healed);
        if (mafiaTarget != address(0) && mafiaTarget != healed) {
            LibGame.killPlayer(roomId, mafiaTarget);
            emit LibGame.PlayerEliminated(roomId, mafiaTarget, "Killed at night");
        }
        _resetNightState(roomId);
        if (!LibGame.checkWinCondition(roomId)) LibGame.transitionToDay(roomId);
    }

    function _resetVotingState(uint256 roomId) internal {
        LibStorage.Storage storage ds = LibStorage.s();
        MafiaTypes.Player[] storage players = ds.roomPlayers[roomId];
        for (uint8 i = 0; i < players.length; i++) {
            address p = players[i].wallet;
            ds.votes[roomId][p] = address(0);
            ds.voteCounts[roomId][p] = 0;
            players[i].flags &= ~LibGame.FLAG_HAS_VOTED;
        }
        ds.rooms[roomId].votedCount = 0;
    }

    function _resetNightState(uint256 roomId) internal {
        LibStorage.Storage storage ds = LibStorage.s();
        MafiaTypes.Player[] storage players = ds.roomPlayers[roomId];
        for (uint8 i = 0; i < players.length; i++) {
            address p = players[i].wallet;
            delete ds.nightCommits[roomId][p];
            delete ds.revealedActions[roomId][p];
            delete ds.revealedTargets[roomId][p];
            players[i].flags &= ~(LibGame.FLAG_HAS_COMMITTED | LibGame.FLAG_HAS_REVEALED);
        }
        ds.rooms[roomId].committedCount = 0;
        ds.rooms[roomId].revealedCount = 0;
    }

    function _kickCurrentShuffler(uint256 roomId) internal {
        LibStorage.Storage storage ds = LibStorage.s();
        MafiaTypes.GameRoom storage room = ds.rooms[roomId];
        if (room.currentShufflerIndex < ds.roomPlayers[roomId].length) {
            address stalledPlayer = ds.roomPlayers[roomId][room.currentShufflerIndex].wallet;
            LibGame.killPlayer(roomId, stalledPlayer);
            LibGame.slashDeposit(roomId, stalledPlayer, "Timeout during shuffle");
            emit LibGame.PlayerKicked(roomId, stalledPlayer, "Timeout during shuffle");
        }

        uint8 nextIndex = LibGame.findNextActive(roomId, room.currentShufflerIndex + 1);
        room.currentShufflerIndex = nextIndex;
        room.lastActionTimestamp = uint32(block.timestamp);
        room.phaseDeadline = uint32(block.timestamp + LibGame.PHASE_TIMEOUT);

        if (nextIndex >= ds.roomPlayers[roomId].length) {
            if (room.aliveCount >= 2) LibGame.transitionToReveal(roomId);
            else LibGame.endGame(roomId, "Too few players remaining");
        }
    }

    function _kickUnconfirmedPlayers(uint256 roomId) internal {
        LibStorage.Storage storage ds = LibStorage.s();
        MafiaTypes.Player[] storage players = ds.roomPlayers[roomId];
        for (uint8 i = 0; i < players.length; i++) {
            if ((players[i].flags & LibGame.FLAG_ACTIVE) != 0) {
                bool shared = (players[i].flags & LibGame.FLAG_HAS_SHARED_KEYS) != 0;
                bool confirmed = (players[i].flags & LibGame.FLAG_CONFIRMED_ROLE) != 0;
                if (!shared || !confirmed) {
                    LibGame.killPlayer(roomId, players[i].wallet);
                    LibGame.slashDeposit(roomId, players[i].wallet, "Timeout during reveal");
                    emit LibGame.PlayerKicked(roomId, players[i].wallet, "Timeout during reveal");
                }
            }
        }
    }

    // ---- Views ----

    function getAliveMafiaCount(uint256 roomId) external view returns (uint8) {
        LibStorage.Storage storage ds = LibStorage.s();
        uint8 count = 0;
        MafiaTypes.Player[] storage players = ds.roomPlayers[roomId];
        for (uint8 i = 0; i < players.length; i++) {
            if ((players[i].flags & LibGame.FLAG_ACTIVE) != 0 &&
                (players[i].flags & LibGame.FLAG_CLAIMED_MAFIA) != 0) count++;
        }
        return count;
    }

    function getRevealedMafiaCount(uint256 roomId) external view returns (uint8) {
        LibStorage.Storage storage ds = LibStorage.s();
        uint8 count = 0;
        for (uint8 i = 0; i < ds.roomPlayers[roomId].length; i++) {
            address p = ds.roomPlayers[roomId][i].wallet;
            if (ds.playerRoles[roomId][p] == MafiaTypes.Role.MAFIA &&
                (ds.roomPlayers[roomId][i].flags & LibGame.FLAG_ACTIVE) != 0) count++;
        }
        return count;
    }

    /// @notice Get how many votes a player has received
    function voteCounts(uint256 roomId, address player) external view returns (uint8) {
        return LibStorage.s().voteCounts[roomId][player];
    }

    /// @notice Get who a voter voted for
    function votes(uint256 roomId, address voter) external view returns (address) {
        return LibStorage.s().votes[roomId][voter];
    }

    /// @notice Get a player's revealed role
    function playerRoles(uint256 roomId, address player) external view returns (MafiaTypes.Role) {
        return LibStorage.s().playerRoles[roomId][player];
    }
}

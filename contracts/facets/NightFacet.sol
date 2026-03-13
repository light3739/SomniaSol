// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "../libraries/LibStorage.sol";
import "../libraries/LibGame.sol";
import "../libraries/MafiaTypes.sol";

/// @title NightFacet — Night actions, mafia consensus, Game Master privacy
/// @dev Supports TWO modes:
///   1. Decentralized (commit-reveal) — players commit/reveal individually on-chain
///   2. Game Master mode — trusted server submits all night results privately
///
/// In Game Master mode, players send their night actions (encrypted) to the GM server
/// off-chain. The GM processes them and submits only the result (kill target + heal target)
/// on-chain via resolveNightAsGameMaster(). This hides WHO did what.
contract NightFacet {

    // ===================== DECENTRALIZED MODE (commit-reveal) =====================

    function commitNightAction(uint256 roomId, bytes32 hash) external {
        LibGame.nonReentrantBefore();
        LibGame.requireNotPaused();
        address player = LibGame.requireActiveParticipant(roomId);
        LibGame.requireBeforeDeadline(roomId);

        LibStorage.Storage storage ds = LibStorage.s();
        if (ds.rooms[roomId].phase != MafiaTypes.GamePhase.NIGHT) revert LibGame.WrongPhase();
        if (LibGame.hasFlag(roomId, player, LibGame.FLAG_HAS_COMMITTED)) revert LibGame.AlreadyCommitted();

        ds.nightCommits[roomId][player] = MafiaTypes.NightCommit({
            commitHash: hash,
            revealed: false,
            commitTime: uint32(block.timestamp)
        });
        LibGame.setFlag(roomId, player, LibGame.FLAG_HAS_COMMITTED);
        ds.rooms[roomId].committedCount++;
        emit LibGame.NightActionCommitted(roomId, player, hash);

        LibGame.nonReentrantAfter();
    }

    function revealNightAction(
        uint256 roomId,
        MafiaTypes.NightActionType action,
        address target,
        string calldata salt
    ) external {
        LibGame.nonReentrantBefore();
        LibGame.requireNotPaused();
        address player = LibGame.requireActiveParticipant(roomId);
        LibGame.requireBeforeDeadline(roomId);

        LibStorage.Storage storage ds = LibStorage.s();
        if (ds.rooms[roomId].phase != MafiaTypes.GamePhase.NIGHT) revert LibGame.WrongPhase();
        if (LibGame.hasFlag(roomId, player, LibGame.FLAG_HAS_REVEALED)) revert LibGame.AlreadyRevealed();
        if (action == MafiaTypes.NightActionType.KILL) revert LibGame.Unauthorized();
        if (!LibGame.hasFlag(roomId, player, LibGame.FLAG_HAS_COMMITTED)) revert LibGame.NotCommitted();

        if (action != MafiaTypes.NightActionType.NONE && target != address(0)) {
            if (!ds.isPlayerInRoom[roomId][target]) revert LibGame.NotParticipant();
            if (!LibGame.hasFlag(roomId, target, LibGame.FLAG_ACTIVE)) revert LibGame.PlayerInactive();
        }

        bytes32 calculatedHash = keccak256(abi.encode(action, target, salt));
        if (calculatedHash != ds.nightCommits[roomId][player].commitHash) revert LibGame.InvalidReveal();

        ds.nightCommits[roomId][player].revealed = true;
        ds.revealedActions[roomId][player] = action;
        ds.revealedTargets[roomId][player] = target;
        LibGame.setFlag(roomId, player, LibGame.FLAG_HAS_REVEALED);
        ds.rooms[roomId].revealedCount++;

        if (action == MafiaTypes.NightActionType.CHECK) {
            LibGame.setFlag(roomId, player, LibGame.FLAG_CLAIMED_DETECTIVE);
        }

        emit LibGame.NightActionRevealed(roomId, player, action, target);
        LibGame.nonReentrantAfter();
    }

    function sendMafiaMessage(uint256 roomId, bytes calldata encryptedMessage) external {
        LibGame.nonReentrantBefore();
        LibGame.requireNotPaused();
        address player = LibGame.requireActiveParticipant(roomId);

        LibStorage.Storage storage ds = LibStorage.s();
        if (ds.rooms[roomId].phase != MafiaTypes.GamePhase.NIGHT) revert LibGame.WrongPhase();
        if (ds.roleCommits[roomId][player] == bytes32(0)) revert LibGame.RoleNotCommitted();
        if (encryptedMessage.length > 1024) revert LibGame.ArrayTooLarge();

        LibGame.setFlag(roomId, player, LibGame.FLAG_CLAIMED_MAFIA);
        ds.mafiaChat[roomId].push(MafiaTypes.MafiaMessage({
            encryptedMessage: encryptedMessage,
            timestamp: uint32(block.timestamp),
            sender: player
        }));
        emit LibGame.MafiaMessageSent(roomId, encryptedMessage);

        LibGame.nonReentrantAfter();
    }

    function commitMafiaTarget(uint256 roomId, bytes32 targetHash) external {
        LibGame.nonReentrantBefore();
        LibGame.requireNotPaused();
        address player = LibGame.requireActiveParticipant(roomId);
        LibGame.requireBeforeDeadline(roomId);

        LibStorage.Storage storage ds = LibStorage.s();
        if (ds.rooms[roomId].phase != MafiaTypes.GamePhase.NIGHT) revert LibGame.WrongPhase();
        if (ds.roleCommits[roomId][player] == bytes32(0)) revert LibGame.RoleNotCommitted();
        if (ds.mafiaTargetCommits[roomId][player].commitHash != bytes32(0)) revert LibGame.MafiaTargetAlreadyCommitted();

        LibGame.setFlag(roomId, player, LibGame.FLAG_CLAIMED_MAFIA);
        LibGame.setFlag(roomId, player, LibGame.FLAG_HAS_COMMITTED);
        ds.mafiaTargetCommits[roomId][player].commitHash = targetHash;
        ds.mafiaCommittedCount[roomId]++;
        emit LibGame.MafiaTargetCommitted(roomId, targetHash);

        LibGame.nonReentrantAfter();
    }

    function revealMafiaTarget(uint256 roomId, address target, string calldata salt) external {
        LibGame.nonReentrantBefore();
        LibGame.requireNotPaused();
        address player = LibGame.requireActiveParticipant(roomId);
        LibGame.requireBeforeDeadline(roomId);

        LibStorage.Storage storage ds = LibStorage.s();
        if (ds.rooms[roomId].phase != MafiaTypes.GamePhase.NIGHT) revert LibGame.WrongPhase();
        if (ds.roleCommits[roomId][player] == bytes32(0)) revert LibGame.RoleNotCommitted();
        if (ds.mafiaTargetCommits[roomId][player].revealed) revert LibGame.MafiaTargetAlreadyRevealed();

        LibGame.setFlag(roomId, player, LibGame.FLAG_CLAIMED_MAFIA);
        if (target != address(0)) {
            if (!ds.isPlayerInRoom[roomId][target]) revert LibGame.NotParticipant();
            if (!LibGame.hasFlag(roomId, target, LibGame.FLAG_ACTIVE)) revert LibGame.PlayerInactive();
        }

        bytes32 calculatedHash = keccak256(abi.encode(target, salt));
        if (calculatedHash != ds.mafiaTargetCommits[roomId][player].commitHash) revert LibGame.InvalidMafiaTargetReveal();

        ds.mafiaTargetCommits[roomId][player].target = target;
        ds.mafiaTargetCommits[roomId][player].revealed = true;
        LibGame.setFlag(roomId, player, LibGame.FLAG_HAS_REVEALED);
        ds.mafiaRevealedCount[roomId]++;
        emit LibGame.MafiaTargetRevealed(roomId, target);

        if (ds.mafiaRevealedCount[roomId] == ds.mafiaCommittedCount[roomId]) _checkMafiaConsensus(roomId);

        LibGame.nonReentrantAfter();
    }

    function endNight(uint256 roomId) external {
        LibGame.nonReentrantBefore();
        LibGame.requireNotPaused();
        LibGame.requireActiveParticipant(roomId);

        LibStorage.Storage storage ds = LibStorage.s();
        MafiaTypes.GameRoom storage room = ds.rooms[roomId];
        if (room.phase != MafiaTypes.GamePhase.NIGHT) revert LibGame.WrongPhase();

        bool allRevealed = (room.committedCount > 0 && room.revealedCount >= room.committedCount)
            || (ds.mafiaCommittedCount[roomId] > 0 && ds.mafiaRevealedCount[roomId] >= ds.mafiaCommittedCount[roomId]);
        if (!allRevealed) {
            if (room.phaseDeadline == 0 || block.timestamp <= room.phaseDeadline) revert LibGame.MafiaNotReady();
        }

        uint8 mafiaCommitted = ds.mafiaCommittedCount[roomId];
        if (mafiaCommitted > 0 && ds.mafiaRevealedCount[roomId] < mafiaCommitted) revert LibGame.MafiaNotReady();
        if (room.revealedCount < room.committedCount) revert LibGame.InvalidReveal();

        _finalizeNight(roomId);
        LibGame.nonReentrantAfter();
    }

    // ===================== GAME MASTER MODE =====================
    // The GM receives encrypted night actions off-chain, resolves them server-side,
    // then posts ONLY the result. Nobody on-chain sees individual night actions.

    /// @notice Game Master resolves the night — posts kill/heal result directly
    /// @param roomId The room
    /// @param killTarget Who the mafia chose to kill (address(0) = no kill)
    /// @param healTarget Who the doctor chose to heal (address(0) = no heal)
    function resolveNightAsGameMaster(
        uint256 roomId,
        address killTarget,
        address healTarget
    ) external {
        LibGame.nonReentrantBefore();
        LibGame.requireNotPaused();

        LibStorage.Storage storage ds = LibStorage.s();
        if (msg.sender != ds.gameMaster) revert LibGame.NotGameMaster();
        if (ds.rooms[roomId].phase != MafiaTypes.GamePhase.NIGHT) revert LibGame.WrongPhase();
        if (ds.nightSubmittedByGM[roomId]) revert LibGame.AlreadyRevealed();

        // Validate targets if non-zero
        if (killTarget != address(0)) {
            if (!ds.isPlayerInRoom[roomId][killTarget]) revert LibGame.NotParticipant();
            if (!LibGame.hasFlag(roomId, killTarget, LibGame.FLAG_ACTIVE)) revert LibGame.PlayerInactive();
        }
        if (healTarget != address(0)) {
            if (!ds.isPlayerInRoom[roomId][healTarget]) revert LibGame.NotParticipant();
        }

        ds.nightSubmittedByGM[roomId] = true;
        ds.mafiaConsensusTarget[roomId] = killTarget;

        // Apply kill (if not healed)
        emit LibGame.NightResolvedByGM(roomId, killTarget, healTarget);
        emit LibGame.NightFinalized(roomId, killTarget, healTarget);

        if (killTarget != address(0) && killTarget != healTarget) {
            LibGame.killPlayer(roomId, killTarget);
            emit LibGame.PlayerEliminated(roomId, killTarget, "Killed at night");
        }

        if (!LibGame.checkWinCondition(roomId)) LibGame.transitionToDay(roomId);

        LibGame.nonReentrantAfter();
    }

    // ===================== INTERNAL =====================

    function _checkMafiaConsensus(uint256 roomId) internal {
        LibStorage.Storage storage ds = LibStorage.s();
        if (ds.mafiaCommittedCount[roomId] == 0) return;

        address firstTarget = address(0);
        bool firstSet = false;
        bool consensus = true;

        MafiaTypes.Player[] storage players = ds.roomPlayers[roomId];
        for (uint8 i = 0; i < players.length; i++) {
            address p = players[i].wallet;
            if (ds.mafiaTargetCommits[roomId][p].revealed && (players[i].flags & LibGame.FLAG_ACTIVE) != 0) {
                address target = ds.mafiaTargetCommits[roomId][p].target;
                if (!firstSet) { firstTarget = target; firstSet = true; }
                else if (target != firstTarget) { consensus = false; break; }
            }
        }
        address consensusTarget = (consensus && firstTarget != address(0)) ? firstTarget : address(0);
        ds.mafiaConsensusTarget[roomId] = consensusTarget;
        emit LibGame.MafiaConsensusReached(roomId, consensusTarget, consensus && firstTarget != address(0));
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

    // ===================== VIEWS =====================

    function getMafiaChat(uint256 roomId) external view returns (MafiaTypes.MafiaMessage[] memory) {
        return LibStorage.s().mafiaChat[roomId];
    }

    function getMafiaConsensus(uint256 roomId) external view returns (uint8 committed, uint8 revealed, address consensusTarget) {
        LibStorage.Storage storage ds = LibStorage.s();
        return (ds.mafiaCommittedCount[roomId], ds.mafiaRevealedCount[roomId], ds.mafiaConsensusTarget[roomId]);
    }

    function gameMaster() external view returns (address) {
        return LibStorage.s().gameMaster;
    }

    /// @notice Get a player's revealed night action type
    function revealedActions(uint256 roomId, address player) external view returns (MafiaTypes.NightActionType) {
        return LibStorage.s().revealedActions[roomId][player];
    }

    /// @notice Get a player's revealed night target
    function revealedTargets(uint256 roomId, address player) external view returns (address) {
        return LibStorage.s().revealedTargets[roomId][player];
    }
}

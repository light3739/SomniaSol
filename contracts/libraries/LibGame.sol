// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "./MafiaTypes.sol";
import "./LibStorage.sol";

/// @title LibGame — Shared helpers used across multiple facets
library LibGame {
    // ---- Constants ----
    uint32 constant TURN_TIMEOUT = 2 minutes;
    uint32 constant PHASE_TIMEOUT = 3 minutes;
    uint32 constant NIGHT_TIMEOUT = 1 minutes;
    uint32 constant VOTING_TIMEOUT = 90 seconds;
    uint32 constant SESSION_DURATION = 4 hours;
    uint32 constant MAX_ARRAY_SIZE = 50;
    uint32 public constant CANCEL_GRACE_PERIOD = 2 hours; // 🆕 Grace period after which anyone can cancel tournament

    // ---- Player flags (bitfield) ----
    uint32 constant FLAG_CONFIRMED_ROLE    = 0x1;
    uint32 constant FLAG_ACTIVE            = 0x2;
    uint32 constant FLAG_HAS_VOTED         = 0x4;
    uint32 constant FLAG_HAS_COMMITTED     = 0x8;
    uint32 constant FLAG_HAS_REVEALED      = 0x10;
    uint32 constant FLAG_HAS_SHARED_KEYS   = 0x20;
    uint32 constant FLAG_DECK_COMMITTED    = 0x40;
    uint32 constant FLAG_CLAIMED_MAFIA     = 0x80;
    uint32 constant FLAG_CLAIMED_DETECTIVE = 0x100;

    // ---- Errors ----
    error NotParticipant();
    error NotYourTurn();
    error WrongPhase();
    error Unauthorized();
    error RoomFull();
    error AlreadyJoined();
    error InvalidDeckSize();
    error TimeNotExpired();
    error PlayerInactive();
    error InvalidReveal();
    error AlreadyRevealed();
    error AlreadyVoted();
    error AlreadyCommitted();
    error AlreadySharedKeys();
    error SessionExpired();
    error SessionNotForThisRoom();
    error InvalidSessionKey();
    error InvalidArrayLength();
    error PhaseDeadlinePassed();
    error SessionAlreadyRegistered();
    error InvalidSessionAddress();
    error ArrayTooLarge();
    error NicknameTooLong();
    error PublicKeyTooLong();
    error RoleAlreadyCommitted();
    error RoleAlreadyRevealed();
    error InvalidRoleReveal();
    error NotMafiaMember();
    error MafiaTargetAlreadyCommitted();
    error MafiaTargetAlreadyRevealed();
    error InvalidMafiaTargetReveal();
    error MafiaNotReady();
    error NotEnoughPlayers();
    error NotAllRolesRevealed();
    error WinConditionNotMet();
    error RoleNotCommitted();
    error NotCommitted();
    error InvalidPlayerCount();
    error SaltTooLong();
    error RoomNameTooLong();
    error ContractPaused();
    error Reentrancy();
    error InsufficientDeposit();
    error DepositAlreadyRefunded();
    error NotGameMaster();
    error NotOwner();

    // ---- Events ----
    event RoomCreated(uint256 indexed roomId, address host, string name, uint256 maxPlayers);
    event PlayerJoined(uint256 indexed roomId, address player, string nickname, address sessionKey);
    event GameStarted(uint256 indexed roomId);
    event DeckCommitted(uint256 indexed roomId, address player, bytes32 commitHash);
    event DeckRevealed(uint256 indexed roomId, address player, string[] deck);
    event PlayerKicked(uint256 indexed roomId, address player, string reason);
    event KeysSharedToAll(uint256 indexed roomId, address from);
    event AllKeysShared(uint256 indexed roomId);
    event RoleConfirmed(uint256 indexed roomId, address player);
    event AllRolesConfirmed(uint256 indexed roomId);
    event DayStarted(uint256 indexed roomId, uint256 dayNumber);
    event VotingStarted(uint256 indexed roomId);
    event VoteCast(uint256 indexed roomId, address voter, address target);
    event VotingFinalized(uint256 indexed roomId, address eliminated, uint256 voteCount);
    event NightStarted(uint256 indexed roomId);
    event NightActionCommitted(uint256 indexed roomId, address player, bytes32 commitHash);
    event NightActionRevealed(uint256 indexed roomId, address player, MafiaTypes.NightActionType action, address target);
    event NightFinalized(uint256 indexed roomId, address killed, address healed);
    event PhaseTimeout(uint256 indexed roomId, MafiaTypes.GamePhase phase);
    event PlayerEliminated(uint256 indexed roomId, address player, string reason);
    event GameEnded(uint256 indexed roomId, string winCondition);
    event SessionKeyRegistered(address indexed mainWallet, address indexed sessionKey, uint256 roomId, uint256 expiresAt);
    event SessionKeyRevoked(address indexed mainWallet, address indexed sessionKey);
    event EmergencyPause(address indexed admin);
    event EmergencyUnpause(address indexed admin);
    event RoleCommitted(uint256 indexed roomId, address player, bytes32 commitHash);
    event RoleRevealed(uint256 indexed roomId, address player, MafiaTypes.Role role);
    event MafiaMessageSent(uint256 indexed roomId, bytes encryptedMessage);
    event MafiaTargetCommitted(uint256 indexed roomId, bytes32 commitHash);
    event MafiaTargetRevealed(uint256 indexed roomId, address target);
    event MafiaConsensusReached(uint256 indexed roomId, address target, bool success);
    event MafiaCheaterPunished(uint256 indexed roomId, address cheater, MafiaTypes.Role actualRole);
    event ZkVerifierUpdated(address indexed newVerifier);
    event GameMasterUpdated(address indexed newGameMaster);
    event NightResolvedByGM(uint256 indexed roomId, address killed, address healed);
    event DepositCollected(uint256 indexed roomId, address player, uint128 amount);
    event DepositSlashed(uint256 indexed roomId, address player, uint128 amount, string reason);
    event DepositRefunded(uint256 indexed roomId, address player, uint128 amount);
    event FeeWithdrawalInitiated(address indexed owner, uint128 amount, uint256 readyAt);

    // ---- Reentrancy guard ----
    function nonReentrantBefore() internal {
        LibStorage.Storage storage ds = LibStorage.s();
        if (ds.reentrancyStatus == 2) revert Reentrancy();
        ds.reentrancyStatus = 2;
    }

    function nonReentrantAfter() internal {
        LibStorage.s().reentrancyStatus = 1;
    }

    // ---- Pause guard ----
    function requireNotPaused() internal view {
        if (LibStorage.s().paused) revert ContractPaused();
    }

    function requireOwner() internal view {
        if (msg.sender != LibStorage.s().owner) revert NotOwner();
    }

    // ---- Access helpers ----
    function resolvePlayer(uint256 roomId) internal view returns (address) {
        LibStorage.Storage storage ds = LibStorage.s();
        address potentialMain = ds.sessionToMain[msg.sender];
        if (potentialMain != address(0)) {
            MafiaTypes.SessionKey storage session = ds.sessionKeys[potentialMain];
            if (!session.isActive) revert InvalidSessionKey();
            if (block.timestamp > session.expiresAt) revert SessionExpired();
            if (session.roomId != uint64(roomId)) revert SessionNotForThisRoom();
            return potentialMain;
        }
        return msg.sender;
    }

    function requireActiveParticipant(uint256 roomId) internal view returns (address) {
        address player = resolvePlayer(roomId);
        LibStorage.Storage storage ds = LibStorage.s();
        if (!ds.isPlayerInRoom[roomId][player]) revert NotParticipant();
        if (!hasFlag(roomId, player, FLAG_ACTIVE)) revert PlayerInactive();
        return player;
    }

    function requireBeforeDeadline(uint256 roomId) internal view {
        uint32 deadline = LibStorage.s().rooms[roomId].phaseDeadline;
        if (deadline != 0 && block.timestamp > deadline) revert PhaseDeadlinePassed();
    }

    // ---- Flag helpers ----
    function hasFlag(uint256 roomId, address wallet, uint32 flag) internal view returns (bool) {
        LibStorage.Storage storage ds = LibStorage.s();
        uint8 idx = ds.playerIndex[roomId][wallet];
        return (ds.roomPlayers[roomId][idx].flags & flag) != 0;
    }

    function setFlag(uint256 roomId, address wallet, uint32 flag) internal {
        LibStorage.Storage storage ds = LibStorage.s();
        uint8 idx = ds.playerIndex[roomId][wallet];
        ds.roomPlayers[roomId][idx].flags |= flag;
    }

    function clearFlag(uint256 roomId, address wallet, uint32 flag) internal {
        LibStorage.Storage storage ds = LibStorage.s();
        uint8 idx = ds.playerIndex[roomId][wallet];
        ds.roomPlayers[roomId][idx].flags &= ~flag;
    }

    // ---- Player management ----
    function killPlayer(uint256 roomId, address victim) internal {
        if (!hasFlag(roomId, victim, FLAG_ACTIVE)) return;
        clearFlag(roomId, victim, FLAG_ACTIVE);
        LibStorage.s().rooms[roomId].aliveCount--;
    }

    function findNextActive(uint256 roomId, uint8 startIndex) internal view returns (uint8) {
        MafiaTypes.Player[] storage players = LibStorage.s().roomPlayers[roomId];
        for (uint8 i = startIndex; i < players.length; i++) {
            if ((players[i].flags & FLAG_ACTIVE) != 0) return i;
        }
        return uint8(players.length);
    }

    // ---- Phase transitions ----
    function transitionToDay(uint256 roomId) internal {
        MafiaTypes.GameRoom storage room = LibStorage.s().rooms[roomId];
        room.phase = MafiaTypes.GamePhase.DAY;
        room.dayCount++;
        room.lastActionTimestamp = uint32(block.timestamp);
        room.phaseDeadline = uint32(block.timestamp + PHASE_TIMEOUT);
        emit DayStarted(roomId, room.dayCount);
    }

    function transitionToNight(uint256 roomId) internal {
        LibStorage.Storage storage ds = LibStorage.s();
        MafiaTypes.GameRoom storage room = ds.rooms[roomId];
        room.phase = MafiaTypes.GamePhase.NIGHT;
        room.committedCount = 0;
        room.revealedCount = 0;
        room.phaseDeadline = uint32(block.timestamp + NIGHT_TIMEOUT);

        MafiaTypes.Player[] storage players = ds.roomPlayers[roomId];
        for (uint8 i = 0; i < players.length; i++) {
            address p = players[i].wallet;
            players[i].flags &= ~(FLAG_HAS_COMMITTED | FLAG_HAS_REVEALED | FLAG_CLAIMED_MAFIA | FLAG_CLAIMED_DETECTIVE);
            delete ds.nightCommits[roomId][p];
            delete ds.revealedActions[roomId][p];
            delete ds.revealedTargets[roomId][p];
            delete ds.mafiaTargetCommits[roomId][p];
        }

        delete ds.mafiaChat[roomId];
        ds.mafiaCommittedCount[roomId] = 0;
        ds.mafiaRevealedCount[roomId] = 0;
        ds.mafiaConsensusTarget[roomId] = address(0);
        ds.nightSubmittedByGM[roomId] = false;
        emit NightStarted(roomId);
    }

    function transitionToReveal(uint256 roomId) internal {
        LibStorage.Storage storage ds = LibStorage.s();
        MafiaTypes.GameRoom storage room = ds.rooms[roomId];
        room.phase = MafiaTypes.GamePhase.REVEAL;
        room.keysSharedCount = 0;
        room.confirmedCount = 0;
        room.phaseDeadline = uint32(block.timestamp + PHASE_TIMEOUT);

        MafiaTypes.Player[] storage players = ds.roomPlayers[roomId];
        for (uint8 i = 0; i < players.length; i++) {
            if ((players[i].flags & FLAG_ACTIVE) != 0) {
                players[i].flags &= ~(FLAG_HAS_SHARED_KEYS | FLAG_CONFIRMED_ROLE | FLAG_DECK_COMMITTED);
            }
        }
    }

    // ---- Win condition ----
    function checkWinCondition(uint256 roomId) internal returns (bool) {
        MafiaTypes.GameRoom storage room = LibStorage.s().rooms[roomId];
        if (room.aliveCount <= 1) {
            endGame(roomId, room.aliveCount == 0 ? "Draw" : "Last player standing");
            return true;
        }
        if (allRolesRevealed(roomId)) {
            (bool mafiaWins, bool townWins) = calculateWinCondition(roomId);
            if (mafiaWins) { endGame(roomId, "Mafia wins"); return true; }
            else if (townWins) { endGame(roomId, "Town wins"); return true; }
        }
        return false;
    }

    function allRolesRevealed(uint256 roomId) internal view returns (bool) {
        LibStorage.Storage storage ds = LibStorage.s();
        MafiaTypes.Player[] storage players = ds.roomPlayers[roomId];
        for (uint8 i = 0; i < players.length; i++) {
            if ((players[i].flags & FLAG_ACTIVE) != 0 &&
                ds.playerRoles[roomId][players[i].wallet] == MafiaTypes.Role.NONE) return false;
        }
        return true;
    }

    function calculateWinCondition(uint256 roomId) internal view returns (bool mafiaWins, bool townWins) {
        LibStorage.Storage storage ds = LibStorage.s();
        uint8 mafiaCount = 0;
        uint8 townCount = 0;
        MafiaTypes.Player[] storage players = ds.roomPlayers[roomId];
        for (uint8 i = 0; i < players.length; i++) {
            if ((players[i].flags & FLAG_ACTIVE) != 0) {
                MafiaTypes.Role role = ds.playerRoles[roomId][players[i].wallet];
                if (role == MafiaTypes.Role.MAFIA) mafiaCount++;
                else if (role != MafiaTypes.Role.NONE) townCount++;
            }
        }
        return (mafiaCount > 0 && mafiaCount >= townCount, mafiaCount == 0 && townCount > 0);
    }

    function endGame(uint256 roomId, string memory reason) internal {
        LibStorage.Storage storage ds = LibStorage.s();
        ds.rooms[roomId].phase = MafiaTypes.GamePhase.ENDED;
        ds.rooms[roomId].phaseDeadline = 0;
        emit GameEnded(roomId, reason);
    }

    // ---- Session keys ----
    function registerSessionKey(address mainWallet, address sessionAddress, uint256 roomId) internal {
        LibStorage.Storage storage ds = LibStorage.s();
        if (sessionAddress == address(0)) revert InvalidSessionAddress();
        if (ds.isRegisteredSession[sessionAddress]) revert SessionAlreadyRegistered();
        if (ds.sessionToMain[sessionAddress] != address(0)) revert SessionAlreadyRegistered();

        if (ds.sessionKeys[mainWallet].isActive) {
            address oldSession = ds.sessionKeys[mainWallet].sessionAddress;
            delete ds.sessionToMain[oldSession];
            ds.isRegisteredSession[oldSession] = false;
        }

        uint32 expiresAt = uint32(block.timestamp + SESSION_DURATION);
        ds.sessionKeys[mainWallet] = MafiaTypes.SessionKey({
            sessionAddress: sessionAddress,
            expiresAt: expiresAt,
            roomId: uint64(roomId),
            isActive: true
        });
        ds.sessionToMain[sessionAddress] = mainWallet;
        ds.isRegisteredSession[sessionAddress] = true;
        emit SessionKeyRegistered(mainWallet, sessionAddress, roomId, expiresAt);
    }

    // ---- Deposit helpers ----
    function collectDeposit(uint256 roomId, address player, uint128 required) internal {
        if (msg.value < required) revert InsufficientDeposit();
        LibStorage.Storage storage ds = LibStorage.s();
        uint128 amount = uint128(msg.value);
        ds.playerDeposits[roomId][player] += amount;
        ds.rooms[roomId].depositPool += amount;
        ds.totalLockedFunds += amount;
        emit DepositCollected(roomId, player, amount);
    }

    function slashDeposit(uint256 roomId, address player, string memory reason) internal {
        LibStorage.Storage storage ds = LibStorage.s();
        uint128 amount = ds.playerDeposits[roomId][player];
        if (amount > 0) {
            ds.playerDeposits[roomId][player] = 0;
            // If prizes already distributed, slashed funds go to platform fees to avoid hanging in contract
            if (ds.prizesClaimed[roomId]) {
                ds.platformFeeBalance += amount;
                ds.totalLockedFunds -= amount;
            } else {
                // Slashed funds stay in ds.rooms[roomId].depositPool to be claimed by winners
                // totalLockedFunds remains unchanged as the money is still in the system
            }
            emit DepositSlashed(roomId, player, amount, reason);
        }
    }

    function refundDeposit(uint256 roomId, address player) internal {
        LibStorage.Storage storage ds = LibStorage.s();
        if (ds.depositRefunded[roomId][player]) revert DepositAlreadyRefunded();
        uint128 amount = ds.playerDeposits[roomId][player];
        if (amount > 0) {
            // Checks-Effects-Interactions (CEI)
            ds.depositRefunded[roomId][player] = true;
            ds.playerDeposits[roomId][player] = 0;
            ds.rooms[roomId].depositPool -= amount;
            ds.totalLockedFunds -= amount;

            (bool sent, ) = payable(player).call{value: amount}("");
            if (!sent) revert("Refund failed");
            emit DepositRefunded(roomId, player, amount);
        }
    }

    // ---- Signature Verification ----
    function verifyGmSignature(uint256 roomId, address player, bytes calldata signature) internal view {
        LibStorage.Storage storage ds = LibStorage.s();
        if (signature.length != 65) revert Unauthorized();

        bytes32 messageHash = keccak256(abi.encodePacked(roomId, player));
        bytes32 ethHash = keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", messageHash));

        bytes32 r;
        bytes32 s;
        uint8 v;
        assembly {
            r := calldataload(signature.offset)
            s := calldataload(add(signature.offset, 32))
            v := byte(0, calldataload(add(signature.offset, 64)))
        }
        if (v < 27) v += 27;

        address signer = ecrecover(ethHash, v, r, s);
        if (signer != ds.gameMaster) revert Unauthorized();
    }
}

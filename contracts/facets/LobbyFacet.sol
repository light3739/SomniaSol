// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "../libraries/LibStorage.sol";
import "../libraries/LibGame.sol";
import "../libraries/MafiaTypes.sol";

/// @title LobbyFacet — Room creation, joining, game start, session keys, admin
contract LobbyFacet {

    modifier nonReentrant() {
        LibGame.nonReentrantBefore();
        _;
        LibGame.nonReentrantAfter();
    }

    // ===================== ADMIN =====================

    function setZkVerifier(address v) external {
        LibGame.requireOwner();
        LibStorage.s().zkVerifier = v;
        emit LibGame.ZkVerifierUpdated(v);
    }

    function setGameMaster(address gm) external {
        LibGame.requireOwner();
        LibStorage.s().gameMaster = gm;
        emit LibGame.GameMasterUpdated(gm);
    }

    function setDefaultDeposit(uint128 amount) external {
        LibGame.requireOwner();
        LibStorage.s().defaultDeposit = amount;
    }

    function pause() external {
        LibGame.requireOwner();
        LibStorage.s().paused = true;
        emit LibGame.EmergencyPause(msg.sender);
    }

    function unpause() external {
        LibGame.requireOwner();
        LibStorage.s().paused = false;
        emit LibGame.EmergencyUnpause(msg.sender);
    }

    function initiateFeeWithdrawal(address token) external {
        LibGame.requireOwner();
        LibStorage.Storage storage ds = LibStorage.s();
        uint256 amount = ds.platformFeeBalances[token];
        require(amount > 0, "No fees to withdraw");
        ds.feeWithdrawalReadyAt[token] = uint32(block.timestamp + 24 hours);
        emit LibGame.FeeWithdrawalInitiated(msg.sender, amount, ds.feeWithdrawalReadyAt[token]);
    }

    function withdrawFees(address token) external nonReentrant {
        LibGame.requireOwner();
        LibStorage.Storage storage ds = LibStorage.s();
        
        require(ds.feeWithdrawalReadyAt[token] != 0, "Withdrawal not initiated");
        require(block.timestamp >= ds.feeWithdrawalReadyAt[token], "Timelock not expired");
        require(block.timestamp <= ds.feeWithdrawalReadyAt[token] + 48 hours, "Timelock expired");

        uint256 amount = ds.platformFeeBalances[token];
        require(amount > 0, "No fees to withdraw");
        
        ds.platformFeeBalances[token] = 0;
        ds.feeWithdrawalReadyAt[token] = 0;

        LibGame.safeTransfer(token, msg.sender, amount);
    }

    // ===================== SESSION KEYS =====================

    function revokeSessionKey() external {
        LibStorage.Storage storage ds = LibStorage.s();
        MafiaTypes.SessionKey storage session = ds.sessionKeys[msg.sender];
        if (session.isActive) {
            emit LibGame.SessionKeyRevoked(msg.sender, session.sessionAddress);
            delete ds.sessionToMain[session.sessionAddress];
            ds.isRegisteredSession[session.sessionAddress] = false;
            session.isActive = false;
        }
    }

    // ===================== ROOM CREATION =====================

    function createAndJoin(
        string calldata roomName,
        uint8 maxPlayers,
        string calldata nickname,
        bytes calldata publicKey,
        address sessionAddress,
        bool isPrivate,
        uint256 tournamentId
    ) external payable nonReentrant returns (uint256) {
        LibGame.requireNotPaused();

        if (maxPlayers < 4 || maxPlayers > 20) revert LibGame.InvalidPlayerCount();
        if (bytes(roomName).length > 32) revert LibGame.RoomNameTooLong();
        if (bytes(nickname).length > 128) revert LibGame.NicknameTooLong();
        if (publicKey.length > 1024) revert LibGame.PublicKeyTooLong();

        LibStorage.Storage storage ds = LibStorage.s();
        uint256 roomId = ++ds.nextRoomId;
        uint128 depositRequired = ds.defaultDeposit;

        ds.rooms[roomId] = MafiaTypes.GameRoom({
            id: uint64(roomId),
            host: msg.sender,
            name: roomName,
            phase: MafiaTypes.GamePhase.LOBBY,
            maxPlayers: maxPlayers,
            playersCount: 0,
            aliveCount: 0,
            dayCount: 0,
            currentShufflerIndex: 0,
            lastActionTimestamp: uint32(block.timestamp),
            phaseDeadline: 0,
            confirmedCount: 0,
            votedCount: 0,
            committedCount: 0,
            revealedCount: 0,
            keysSharedCount: 0,
            depositPool: 0,
            depositPerPlayer: depositRequired,
            isPrivate: isPrivate,
            tournamentId: tournamentId
        });

        emit LibGame.RoomCreated(roomId, msg.sender, roomName, maxPlayers);

        ds.roomPlayers[roomId].push(MafiaTypes.Player({
            wallet: msg.sender,
            nickname: nickname,
            publicKey: publicKey,
            flags: LibGame.FLAG_ACTIVE
        }));

        ds.isPlayerInRoom[roomId][msg.sender] = true;
        ds.playerIndex[roomId][msg.sender] = 0;
        ds.rooms[roomId].playersCount = 1;
        ds.rooms[roomId].aliveCount = 1;

        // Collect deposit if required and not part of a tournament
        if (tournamentId == 0 && depositRequired > 0) {
            LibGame.collectDeposit(roomId, msg.sender, depositRequired);
        }

        if (sessionAddress != address(0)) {
            LibGame.registerSessionKey(msg.sender, sessionAddress, roomId);
            // Fund session key with remaining ETH after deposit
            uint256 sessionFunds = msg.value > depositRequired ? msg.value - depositRequired : 0;
            if (sessionFunds > 0) {
                (bool sent, ) = payable(sessionAddress).call{value: sessionFunds}("");
                require(sent, "Failed to fund session");
            }
        }

        emit LibGame.PlayerJoined(roomId, msg.sender, nickname, sessionAddress);

        return roomId;
    }

    function joinRoom(
        uint256 roomId,
        string calldata nickname,
        bytes calldata publicKey,
        address sessionAddress,
        bytes calldata gmSignature
    ) external payable nonReentrant {
        LibGame.requireNotPaused();

        LibStorage.Storage storage ds = LibStorage.s();
        MafiaTypes.GameRoom storage room = ds.rooms[roomId];
        if (room.phase != MafiaTypes.GamePhase.LOBBY) revert LibGame.WrongPhase();
        if (room.playersCount >= room.maxPlayers) revert LibGame.RoomFull();
        if (ds.isPlayerInRoom[roomId][msg.sender]) revert LibGame.AlreadyJoined();
        if (bytes(nickname).length > 128) revert LibGame.NicknameTooLong();
        if (publicKey.length > 1024) revert LibGame.PublicKeyTooLong();

        // Private room: verify GM signature (password checked off-chain by GM server)
        if (room.isPrivate) {
            LibGame.verifyGmSignature(roomId, msg.sender, gmSignature);
        }

        uint8 idx = uint8(ds.roomPlayers[roomId].length);
        ds.roomPlayers[roomId].push(MafiaTypes.Player({
            wallet: msg.sender,
            nickname: nickname,
            publicKey: publicKey,
            flags: LibGame.FLAG_ACTIVE
        }));

        ds.isPlayerInRoom[roomId][msg.sender] = true;
        ds.playerIndex[roomId][msg.sender] = idx;
        room.playersCount++;
        room.aliveCount++;

        // Collect deposit if required and not part of a tournament
        uint128 depositRequired = room.depositPerPlayer;
        if (room.tournamentId == 0 && depositRequired > 0) {
            LibGame.collectDeposit(roomId, msg.sender, depositRequired);
        }

        if (sessionAddress != address(0)) {
            LibGame.registerSessionKey(msg.sender, sessionAddress, roomId);
            uint256 sessionFunds = msg.value > depositRequired ? msg.value - depositRequired : 0;
            if (sessionFunds > 0) {
                (bool sent, ) = payable(sessionAddress).call{value: sessionFunds}("");
                require(sent, "Failed to fund session");
            }
        }

        emit LibGame.PlayerJoined(roomId, msg.sender, nickname, sessionAddress);
    }

    function startGame(uint256 roomId) external nonReentrant {
        LibGame.requireNotPaused();
        LibGame.requireActiveParticipant(roomId);

        LibStorage.Storage storage ds = LibStorage.s();
        MafiaTypes.GameRoom storage room = ds.rooms[roomId];
        if (room.phase != MafiaTypes.GamePhase.LOBBY) revert LibGame.WrongPhase();
        if (room.playersCount < 4) revert LibGame.NotEnoughPlayers();

        room.phase = MafiaTypes.GamePhase.SHUFFLING;
        room.currentShufflerIndex = LibGame.findNextActive(roomId, 0);
        room.lastActionTimestamp = uint32(block.timestamp);
        room.phaseDeadline = uint32(block.timestamp + LibGame.PHASE_TIMEOUT);

        emit LibGame.GameStarted(roomId);
    }

    // ===================== VIEW FUNCTIONS =====================

    function getPlayers(uint256 roomId) external view returns (MafiaTypes.Player[] memory) {
        return LibStorage.s().roomPlayers[roomId];
    }

    function getRoom(uint256 roomId) external view returns (MafiaTypes.GameRoom memory) {
        return LibStorage.s().rooms[roomId];
    }

    function getDeck(uint256 roomId) external view returns (string[] memory) {
        return LibStorage.s().revealedDeck[roomId];
    }

    function getPhaseDeadline(uint256 roomId) external view returns (uint32) {
        return LibStorage.s().rooms[roomId].phaseDeadline;
    }

    function sessionKeys(address wallet) external view returns (MafiaTypes.SessionKey memory) {
        return LibStorage.s().sessionKeys[wallet];
    }

    function nextRoomId() external view returns (uint256) {
        return LibStorage.s().nextRoomId;
    }

    function getKeyFromTo(uint256 roomId, address from, address to) external view returns (bytes memory) {
        return LibStorage.s().playerDeckKeys[roomId][from][to];
    }

    function getAllKeysForMe(uint256 roomId) external view returns (address[] memory senders, bytes[] memory keys) {
        LibStorage.Storage storage ds = LibStorage.s();
        address player = ds.sessionToMain[msg.sender] != address(0) ? ds.sessionToMain[msg.sender] : msg.sender;
        MafiaTypes.Player[] storage players = ds.roomPlayers[roomId];
        uint8 count = 0;
        for (uint8 i = 0; i < players.length; i++) {
            if (players[i].wallet != player && ds.playerDeckKeys[roomId][players[i].wallet][player].length > 0) count++;
        }
        senders = new address[](count);
        keys = new bytes[](count);
        uint8 idx = 0;
        for (uint8 i = 0; i < players.length; i++) {
            address sender = players[i].wallet;
            if (sender != player && ds.playerDeckKeys[roomId][sender][player].length > 0) {
                senders[idx] = sender;
                keys[idx] = ds.playerDeckKeys[roomId][sender][player];
                idx++;
            }
        }
    }

    function getPlayerFlags(uint256 roomId, address player) external view returns (
        bool isActive, bool hasConfirmedRole, bool hasVoted, bool hasCommitted,
        bool hasRevealed, bool hasSharedKeys, bool hasClaimedMafia
    ) {
        LibStorage.Storage storage ds = LibStorage.s();
        uint8 idx = ds.playerIndex[roomId][player];
        uint32 flags = ds.roomPlayers[roomId][idx].flags;
        return (
            (flags & LibGame.FLAG_ACTIVE) != 0,
            (flags & LibGame.FLAG_CONFIRMED_ROLE) != 0,
            (flags & LibGame.FLAG_HAS_VOTED) != 0,
            (flags & LibGame.FLAG_HAS_COMMITTED) != 0,
            (flags & LibGame.FLAG_HAS_REVEALED) != 0,
            (flags & LibGame.FLAG_HAS_SHARED_KEYS) != 0,
            (flags & LibGame.FLAG_CLAIMED_MAFIA) != 0
        );
    }

    function getPlayerDeposit(uint256 roomId, address player) external view returns (uint128) {
        return LibStorage.s().playerDeposits[roomId][player];
    }

    function getDefaultDeposit() external view returns (uint128) {
        return LibStorage.s().defaultDeposit;
    }
}

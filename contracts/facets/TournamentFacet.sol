// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "../libraries/LibStorage.sol";
import "../libraries/LibGame.sol";
import "../libraries/MafiaTypes.sol";

/// @title TournamentFacet — Tournament creation, registration, and prize distribution
contract TournamentFacet {

    event PrizeDistributed(uint256 indexed roomId, address indexed winner, uint128 amount);
    
    modifier nonReentrant() {
        LibGame.nonReentrantBefore();
        _;
        LibGame.nonReentrantAfter();
    }

    uint32 constant REGISTRATION_PERIOD = 24 hours;

    function createTournament(
        string calldata name,
        uint128 buyIn,
        uint8 maxPlayers,
        uint8 playersPerTable,
        bytes32 passwordHash
    ) external payable nonReentrant {
        LibGame.requireNotPaused();
        LibStorage.Storage storage ds = LibStorage.s();
        uint256 tId = ++ds.nextTournamentId;
        require(ds.activeTournaments[msg.sender] < 3, "Too many active tournaments");
        ds.activeTournaments[msg.sender]++;

        MafiaTypes.Tournament storage t = ds.tournaments[tId];
        t.id = tId;
        t.organizer = msg.sender;
        t.name = name;
        t.buyIn = buyIn;
        t.maxPlayers = maxPlayers;
        t.playersPerTable = playersPerTable;
        t.phase = MafiaTypes.TournamentPhase.REGISTRATION;
        t.registrationDeadline = uint32(block.timestamp + REGISTRATION_PERIOD);

        // If Freeroll (buyIn == 0), organizer must fund the prize pool
        if (buyIn == 0) {
            require(msg.value > 0, "Freeroll requires prize pool");
            t.prizePool = uint128(msg.value);
            ds.totalLockedFunds += uint128(msg.value);
        }

        t.passwordHash = passwordHash;

        emit LibGame.TournamentCreated(tId, msg.sender, name, buyIn);
    }

    function cancelTournament(uint256 tournamentId) external nonReentrant {
        LibGame.requireNotPaused();
        LibStorage.Storage storage ds = LibStorage.s();
        MafiaTypes.Tournament storage t = ds.tournaments[tournamentId];
        
        require(t.phase == MafiaTypes.TournamentPhase.REGISTRATION, "Wrong phase");
        
        // Anyone can cancel after registrationDeadline + CANCEL_GRACE_PERIOD
        // Organizer can cancel anytime during registration
        bool canCancel = (msg.sender == t.organizer) || 
                         (block.timestamp > t.registrationDeadline + LibGame.CANCEL_GRACE_PERIOD);
        require(canCancel, "Cannot cancel yet");
        
        t.phase = MafiaTypes.TournamentPhase.CANCELLED;
        if (ds.activeTournaments[t.organizer] > 0) ds.activeTournaments[t.organizer]--;
        
        // Effects before Interactions (CEI)
        address[] storage participants = t.participants;
        if (t.buyIn > 0 && participants.length > 0) {
            uint128 refundAmount = t.buyIn;
            uint128 totalRefunded = 0;
            
            // Pass 1: Local state (Effects)
            for (uint256 i = 0; i < participants.length; i++) {
                address p = participants[i];
                if (ds.isTournamentParticipant[tournamentId][p]) {
                    ds.isTournamentParticipant[tournamentId][p] = false;
                    totalRefunded += refundAmount;
                }
            }

            // Global effects
            ds.totalLockedFunds -= totalRefunded;
            t.prizePool = 0;

            // Pass 2: External calls (Interactions)
            for (uint256 i = 0; i < participants.length; i++) {
                address p = participants[i];
                // Note: p.call doesn't depend on isTournamentParticipant being true 
                // because we already reduced totalRefunded above for marked players.
                // However, for precision, we iterate again. 
                // To remember WHO to call without extra storage, we can't easily.
                // But in cancelTournament, usually everyone in the list gets refunded.
                // Let's use a simpler CEI: we already set flags to false.
                (bool sent, ) = payable(p).call{value: refundAmount}("");
                if (!sent) emit LibGame.RefundFailed(tournamentId, p, refundAmount);
            }
        }
        
        emit LibGame.TournamentCancelled(tournamentId);
    }

    function joinTournament(uint256 tournamentId, string calldata password) external payable nonReentrant {
        LibGame.requireNotPaused();
        LibStorage.Storage storage ds = LibStorage.s();
        MafiaTypes.Tournament storage t = ds.tournaments[tournamentId];
        require(t.phase == MafiaTypes.TournamentPhase.REGISTRATION, "Not in registration");
        require(block.timestamp <= t.registrationDeadline, "Registration closed");
        require(t.participants.length < t.maxPlayers, "Tournament full");
        require(!ds.isTournamentParticipant[tournamentId][msg.sender], "Already joined");

        // Whitelist check
        if (ds.tournamentWhitelistEnabled[tournamentId]) {
            require(ds.tournamentWhitelist[tournamentId][msg.sender], "Not whitelisted");
        }

        // Password check
        if (t.passwordHash != bytes32(0)) {
            require(keccak256(abi.encodePacked(password)) == t.passwordHash, "Invalid password");
        }

        if (t.buyIn > 0) {
            require(msg.value >= t.buyIn, "Insufficient buy-in");
            t.prizePool += uint128(msg.value);
            ds.totalLockedFunds += uint128(msg.value);
        }

        t.participants.push(msg.sender);
        ds.isTournamentParticipant[tournamentId][msg.sender] = true;

        emit LibGame.TournamentJoined(tournamentId, msg.sender);
    }

    /**
     * @notice Distribute prizes for a specific game room (Mafia style)
     * @dev Winners get weighted share: Alive x2, Dead x1
     */
    function distributeMafiaPrizes(uint256 roomId) external nonReentrant {
        LibGame.requireNotPaused();
        LibStorage.Storage storage ds = LibStorage.s();
        MafiaTypes.GameRoom storage room = ds.rooms[roomId];
        
        if (room.phase != MafiaTypes.GamePhase.ENDED) revert LibGame.WrongPhase();
        if (ds.prizesClaimed[roomId]) revert LibGame.AlreadyClaimed();

        bool mafiaWon = ds.gameResult[roomId];
        uint128 prizePool = room.depositPool;
        
        // Front-run protection: only GM or winners can trigger distribution
        bool isWinner = false;
        MafiaTypes.Role myRole = ds.playerRoles[roomId][msg.sender];
        if (mafiaWon) {
            isWinner = (myRole == MafiaTypes.Role.MAFIA);
        } else {
            isWinner = (myRole != MafiaTypes.Role.MAFIA && myRole != MafiaTypes.Role.NONE);
        }
        require(msg.sender == ds.gameMaster || isWinner, "Not authorized to distribute");

        ds.prizesClaimed[roomId] = true;
        ds.totalLockedFunds -= prizePool;

        MafiaTypes.Player[] storage players = ds.roomPlayers[roomId];
        uint256 totalShares = 0;
        uint8[] memory multipliers = new uint8[](players.length);

        for (uint8 i = 0; i < players.length; i++) {
            MafiaTypes.Role role = ds.playerRoles[roomId][players[i].wallet];
            bool winnerFound = false;
            
            if (mafiaWon) {
                winnerFound = (role == MafiaTypes.Role.MAFIA);
            } else {
                winnerFound = (role != MafiaTypes.Role.MAFIA && role != MafiaTypes.Role.NONE);
            }

            if (winnerFound) {
                uint8 m = ((players[i].flags & LibGame.FLAG_ACTIVE) != 0) ? 2 : 1;
                multipliers[i] = m;
                totalShares += m;
            }
        }

        require(totalShares > 0, "No winners found");

        uint128 totalDistributed = 0;
        address[] memory winnersAddresses = new address[](players.length);
        uint128[] memory payouts = new uint128[](players.length);

        for (uint8 i = 0; i < players.length; i++) {
            if (multipliers[i] > 0) {
                uint128 payout = uint128((uint256(prizePool) * multipliers[i]) / totalShares);
                totalDistributed += payout;
                winnersAddresses[i] = players[i].wallet;
                payouts[i] = payout;
            }
        }

        // Effects before Interactions
        if (prizePool > totalDistributed) {
            ds.platformFeeBalance += (prizePool - totalDistributed);
        }

        if (room.tournamentId > 0) {
            address organizer = ds.tournaments[room.tournamentId].organizer;
            if (ds.activeTournaments[organizer] > 0) ds.activeTournaments[organizer]--;
        }

        // Interactions
        for (uint8 i = 0; i < winnersAddresses.length; i++) {
            if (payouts[i] > 0) {
                (bool sent, ) = payable(winnersAddresses[i]).call{value: payouts[i]}("");
                if (sent) {
                    emit PrizeDistributed(roomId, winnersAddresses[i], payouts[i]);
                }
            }
        }
    }

    // ---- Whitelist Management ----

    function toggleTournamentWhitelist(uint256 tournamentId, bool enabled) external {
        LibStorage.Storage storage ds = LibStorage.s();
        require(ds.tournaments[tournamentId].organizer == msg.sender, "Not organizer");
        ds.tournamentWhitelistEnabled[tournamentId] = enabled;
    }

    function addToTournamentWhitelist(uint256 tournamentId, address[] calldata players) external {
        LibStorage.Storage storage ds = LibStorage.s();
        require(ds.tournaments[tournamentId].organizer == msg.sender, "Not organizer");
        for (uint256 i = 0; i < players.length; i++) {
            ds.tournamentWhitelist[tournamentId][players[i]] = true;
        }
    }

    function removeFromTournamentWhitelist(uint256 tournamentId, address[] calldata players) external {
        LibStorage.Storage storage ds = LibStorage.s();
        require(ds.tournaments[tournamentId].organizer == msg.sender, "Not organizer");
        for (uint256 i = 0; i < players.length; i++) {
            ds.tournamentWhitelist[tournamentId][players[i]] = false;
        }
    }
}

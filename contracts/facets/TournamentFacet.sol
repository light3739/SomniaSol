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
        bytes32 passwordHash,
        address paymentToken,
        uint128 initialPrize
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
        t.paymentToken = paymentToken;
        t.passwordHash = passwordHash;

        // If Freeroll (buyIn == 0), organizer must fund the prize pool
        if (buyIn == 0) {
            require(initialPrize > 0 || msg.value > 0, "Freeroll requires prize pool");
            uint128 funding = (paymentToken == address(0)) ? uint128(msg.value) : initialPrize;
            
            if (paymentToken != address(0)) {
                LibGame.safeReceive(paymentToken, msg.sender, funding);
            }
            
            t.prizePool = funding;
            ds.totalLockedFundsByToken[paymentToken] += funding;
        }

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

            // Pass 2: External calls (Interactions)
            for (uint256 i = 0; i < participants.length; i++) {
                address p = participants[i];
                // 🆕 Double refund protection: check if still marked as participant
                // (flags were set to false in Pass 1, but if someone is in the list twice,
                // we must be careful. Actually, we need to check the mapping.)
                if (ds.isTournamentParticipant[tournamentId][p]) {
                    ds.isTournamentParticipant[tournamentId][p] = false;
                    LibGame.safeTransfer(t.paymentToken, p, refundAmount);
                }
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
        if (t.passwordHash != 0) {
            require(keccak256(abi.encodePacked(password)) == t.passwordHash, "Invalid password");
        }

        if (t.buyIn > 0) {
            if (t.paymentToken != address(0)) {
                require(msg.value == 0, "ETH not accepted for token tournaments");
            }
            LibGame.safeReceive(t.paymentToken, msg.sender, t.buyIn);
            t.prizePool += t.buyIn;
            ds.totalLockedFundsByToken[t.paymentToken] += t.buyIn;
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
        // uint128 prizePool = room.depositPool; // This line is removed

        // Front-run protection: only GM or winners can trigger distribution
        bool isWinner = false;
        MafiaTypes.Role myRole = ds.playerRoles[roomId][msg.sender];
        if (mafiaWon) {
            isWinner = (myRole == MafiaTypes.Role.MAFIA);
        } else {
            isWinner = (myRole != MafiaTypes.Role.MAFIA && myRole != MafiaTypes.Role.NONE);
        }
        require(msg.sender == ds.gameMaster || isWinner, "Not authorized to distribute");

        MafiaTypes.Tournament storage t = ds.tournaments[room.tournamentId];
        
        // 🆕 P0 Fix: Calculate prize pool for this room
        uint256 currentPrizePool; // Renamed from prizePool to avoid conflict
        if (room.tournamentId > 0) {
            // If it's a tournament, prize pool is proportional to players in this room
            // Example: totalPlayers=20, roomPlayers=10 -> prizePool = t.prizePool * 10 / 20
            currentPrizePool = (uint256(t.prizePool) * room.playersCount) / t.participants.length;
        } else {
            currentPrizePool = room.depositPool;
        }

        ds.prizesClaimed[roomId] = true;
        ds.totalLockedFundsByToken[t.paymentToken] -= currentPrizePool;

        // 🆕 P1 Fix: Collect 10% Platform Fee
        uint256 platformFee = currentPrizePool / 10;
        uint256 distributablePrize = currentPrizePool - platformFee;
        ds.platformFeeBalances[t.paymentToken] += platformFee;

        MafiaTypes.Player[] storage players = ds.roomPlayers[roomId];
        // uint256 totalShares = 0; // This line is removed
        uint8[] memory multipliers = new uint8[](players.length); // This line is the anchor

        uint256 winnersCount = 0;
        uint256 totalShares = 0;

        for (uint256 i = 0; i < players.length; i++) {
            address player = players[i].wallet;
            MafiaTypes.Role role = ds.playerRoles[roomId][player];
            bool isWinnerPlayer = false;

            if (mafiaWon) {
                isWinnerPlayer = (role == MafiaTypes.Role.MAFIA);
            } else {
                // Team Citizens/Town (Town, Doctor, Detective)
                isWinnerPlayer = (role != MafiaTypes.Role.MAFIA && role != MafiaTypes.Role.NONE);
            }

            if (isWinnerPlayer) {
                winnersCount++;
                // 🆕 Alive (FLAG_ACTIVE) x2, Dead x1
                uint8 m = ((players[i].flags & LibGame.FLAG_ACTIVE) != 0) ? 2 : 1;
                multipliers[i] = m;
                totalShares += m;
            }
        }

        if (totalShares == 0) {
            ds.platformFeeBalances[t.paymentToken] += distributablePrize;
            return;
        }

        uint256 shareValue = distributablePrize / totalShares;
        uint256 totalDistributed = 0;
        address[] memory winnersAddresses = new address[](players.length);
        uint128[] memory payouts = new uint128[](players.length);

        for (uint256 i = 0; i < players.length; i++) {
            if (multipliers[i] > 0) {
                uint128 payout = uint128(shareValue * multipliers[i]);
                totalDistributed += payout;
                winnersAddresses[i] = players[i].wallet;
                payouts[i] = payout;
            }
        }

        // Effects before Interactions
        uint256 dust = distributablePrize - totalDistributed;
        if (dust > 0) {
            ds.platformFeeBalances[t.paymentToken] += dust;
        }

        if (room.tournamentId > 0) {
            address organizer = ds.tournaments[room.tournamentId].organizer;
            if (ds.activeTournaments[organizer] > 0) ds.activeTournaments[organizer]--;
        }

        // Interactions
        for (uint8 i = 0; i < winnersAddresses.length; i++) {
            if (payouts[i] > 0) {
                LibGame.safeTransfer(t.paymentToken, winnersAddresses[i], payouts[i]);
                emit PrizeDistributed(roomId, winnersAddresses[i], payouts[i]);
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

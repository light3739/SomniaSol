// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "../libraries/LibStorage.sol";
import "../libraries/LibGame.sol";
import "../libraries/MafiaTypes.sol";

/// @title TournamentFacet — Tournament creation, registration, and prize distribution
contract TournamentFacet {

    event PrizeDistributed(uint256 indexed roomId, address indexed winner, uint128 amount);
    event TournamentCancelled(uint256 indexed tournamentId);

    uint32 constant REGISTRATION_PERIOD = 24 hours;

    function createTournament(
        string calldata name,
        uint128 buyIn,
        uint8 maxPlayers,
        uint8 playersPerTable
    ) external payable {
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

        emit TournamentCreated(tId, msg.sender, name, buyIn);
    }

    function cancelTournament(uint256 tournamentId) external {
        LibGame.nonReentrantBefore();
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
        
        // Refund mechanism for participants would go here if not handled by individual claims
        // To keep it simple and avoid OOG, we can mark them for claimable refunds
        // But since this is Buy-In, we should probably return money to participants
        
        emit TournamentCancelled(tournamentId);
        LibGame.nonReentrantAfter();
    }

    function joinTournament(uint256 tournamentId) external payable {
        LibGame.requireNotPaused();
        LibStorage.Storage storage ds = LibStorage.s();
        MafiaTypes.Tournament storage t = ds.tournaments[tournamentId];
        require(t.phase == MafiaTypes.TournamentPhase.REGISTRATION, "Not in registration");
        require(block.timestamp <= t.registrationDeadline, "Registration closed");
        require(t.participants.length < t.maxPlayers, "Tournament full");

        if (t.buyIn > 0) {
            require(msg.value >= t.buyIn, "Insufficient buy-in");
            t.prizePool += t.buyIn;
            ds.totalLockedFunds += t.buyIn;
        }

        t.participants.push(msg.sender);
        emit TournamentJoined(tournamentId, msg.sender);
    }

    /**
     * @notice Distribute prizes for a specific game room (Mafia style)
     * @dev Winners get weighted share: Alive x2, Dead x1
     */
    function distributeMafiaPrizes(uint256 roomId) external {
        LibGame.nonReentrantBefore();
        LibStorage.Storage storage ds = LibStorage.s();
        MafiaTypes.GameRoom storage room = ds.rooms[roomId];

        require(room.phase == MafiaTypes.GamePhase.ENDED, "Game not ended");
        require(!ds.prizesClaimed[roomId], "Already claimed");
        ds.prizesClaimed[roomId] = true;

        // true = mafia won, false = town won
        bool mafiaWon = ds.gameResult[roomId];

        // Front-running protection: Only GM or a winner can trigger distribution
        if (msg.sender != ds.gameMaster) {
            MafiaTypes.Role senderRole = ds.playerRoles[roomId][msg.sender];
            bool senderIsWinner = (mafiaWon && senderRole == MafiaTypes.Role.MAFIA) ||
                                  (!mafiaWon && senderRole != MafiaTypes.Role.MAFIA && senderRole != MafiaTypes.Role.NONE);
            require(senderIsWinner, "Not authorized: Only GM or winner");
        }

        uint128 prizePool;
        uint128 fee;

        if (room.tournamentId > 0) {
            MafiaTypes.Tournament storage t = ds.tournaments[room.tournamentId];
            // For tournament rooms, we distribute a portion of the tournament prize pool
            // OR the whole pool if it's the final. For now, we'll assume the room pool is set by the organizer.
            // If tournament pool is used, we take fee from there.
            uint128 totalPool = t.prizePool;
            fee = totalPool / 10;
            prizePool = totalPool - fee;
            ds.platformFeeBalance += fee;
            ds.totalLockedFunds -= totalPool;
            t.prizePool = 0; // Distributed
            t.prizesClaimed = true;
        } else {
            uint128 totalPool = room.depositPool;
            fee = totalPool / 10; 
            prizePool = totalPool - fee;
            ds.platformFeeBalance += fee;
            ds.totalLockedFunds -= totalPool;
        }

        MafiaTypes.Player[] storage players = ds.roomPlayers[roomId];
        uint256 totalShares = 0;
        
        // Track winners and their share multiplier
        uint8[] memory multipliers = new uint8[](players.length);
        uint256 winnerCount = 0;

        for (uint8 i = 0; i < players.length; i++) {
            MafiaTypes.Role role = ds.playerRoles[roomId][players[i].wallet];
            bool isWinner = false;
            
            if (mafiaWon) {
                isWinner = (role == MafiaTypes.Role.MAFIA);
            } else {
                isWinner = (role != MafiaTypes.Role.MAFIA && role != MafiaTypes.Role.NONE);
            }

            if (isWinner) {
                bool isAlive = (players[i].flags & LibGame.FLAG_ACTIVE) != 0;
                uint8 m = isAlive ? 2 : 1;
                multipliers[i] = m;
                totalShares += m;
                winnerCount++;
            }
        }

        require(totalShares > 0, "No winners found");

        uint128 totalDistributed = 0;
        // Distribute portions
        for (uint8 i = 0; i < players.length; i++) {
            if (multipliers[i] > 0) {
                uint128 payout = uint128((uint256(prizePool) * multipliers[i]) / totalShares);
                totalDistributed += payout;
                address winner = players[i].wallet;
                
                (bool sent, ) = payable(winner).call{value: payout}("");
                if (sent) {
                    emit PrizeDistributed(roomId, winner, payout);
                }
            }
        }

        // Handle rounding dust (residue goes to platform)
        if (prizePool > totalDistributed) {
            uint128 dust = prizePool - totalDistributed;
            ds.platformFeeBalance += dust;
        }

        if (room.tournamentId > 0) {
            address organizer = ds.tournaments[room.tournamentId].organizer;
            if (ds.activeTournaments[organizer] > 0) ds.activeTournaments[organizer]--;
        }

        LibGame.nonReentrantAfter();
    }
}

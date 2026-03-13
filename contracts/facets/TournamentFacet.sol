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
        uint8 playersPerTable
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
        
        // Refund all participants
        address[] storage participants = t.participants;
        if (t.buyIn > 0 && participants.length > 0) {
            uint128 refundAmount = t.buyIn;
            for (uint256 i = 0; i < participants.length; i++) {
                address p = participants[i];
                // Prevent double refund if participants array somehow has duplicates
                if (!ds.isTournamentParticipant[tournamentId][p]) continue;
                ds.isTournamentParticipant[tournamentId][p] = false;

                (bool sent, ) = payable(p).call{value: refundAmount}("");
                if (sent) {
                    ds.totalLockedFunds -= refundAmount;
                }
            }
            t.prizePool = 0;
        }
        
        emit LibGame.TournamentCancelled(tournamentId);
    }

    function joinTournament(uint256 tournamentId) external payable nonReentrant {
        LibGame.requireNotPaused();
        LibStorage.Storage storage ds = LibStorage.s();
        MafiaTypes.Tournament storage t = ds.tournaments[tournamentId];
        require(t.phase == MafiaTypes.TournamentPhase.REGISTRATION, "Not in registration");
        require(block.timestamp <= t.registrationDeadline, "Registration closed");
        require(t.participants.length < t.maxPlayers, "Tournament full");
        require(!ds.isTournamentParticipant[tournamentId][msg.sender], "Already joined");

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
        LibStorage.Storage storage ds = LibStorage.s();
        MafiaTypes.GameRoom storage room = ds.rooms[roomId];

        require(room.phase == MafiaTypes.GamePhase.ENDED, "Game not ended");
        require(!ds.prizesClaimed[roomId], "Already claimed");
        ds.prizesClaimed[roomId] = true;

        bool mafiaWon = ds.gameResult[roomId];

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
            // Multi-room support: Distribute a fraction of the total pool based on players in this room
            // totalPool = (t.prizePool * room.maxPlayers) / t.maxPlayers
            uint128 totalPoolFraction;
            if (t.maxPlayers > 0) {
                totalPoolFraction = uint128((uint256(t.prizePool) * room.maxPlayers) / t.maxPlayers);
            } else {
                totalPoolFraction = t.prizePool;
            }
            
            fee = totalPoolFraction / 10;
            prizePool = totalPoolFraction - fee;
            ds.platformFeeBalance += fee;
            ds.totalLockedFunds -= totalPoolFraction;
            
            // Subtract the fractional pool from the total tournament prize pool
            if (t.prizePool >= totalPoolFraction) {
                t.prizePool -= totalPoolFraction;
            } else {
                t.prizePool = 0;
            }
            
            // If it was the last room or only room, mark claimed
            if (t.prizePool == 0) {
                t.prizesClaimed = true;
            }
        } else {
            uint128 totalPool = room.depositPool;
            fee = totalPool / 10; 
            prizePool = totalPool - fee;
            ds.platformFeeBalance += fee;
            ds.totalLockedFunds -= totalPool;
        }

        MafiaTypes.Player[] storage players = ds.roomPlayers[roomId];
        uint256 totalShares = 0;
        uint8[] memory multipliers = new uint8[](players.length);

        for (uint8 i = 0; i < players.length; i++) {
            MafiaTypes.Role role = ds.playerRoles[roomId][players[i].wallet];
            bool isWinner = false;
            
            if (mafiaWon) {
                isWinner = (role == MafiaTypes.Role.MAFIA);
            } else {
                isWinner = (role != MafiaTypes.Role.MAFIA && role != MafiaTypes.Role.NONE);
            }

            if (isWinner) {
                uint8 m = ((players[i].flags & LibGame.FLAG_ACTIVE) != 0) ? 2 : 1;
                multipliers[i] = m;
                totalShares += m;
            }
        }

        require(totalShares > 0, "No winners found");

        uint128 totalDistributed = 0;
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

        if (prizePool > totalDistributed) {
            ds.platformFeeBalance += (prizePool - totalDistributed);
        }

        if (room.tournamentId > 0) {
            address organizer = ds.tournaments[room.tournamentId].organizer;
            if (ds.activeTournaments[organizer] > 0) ds.activeTournaments[organizer]--;
        }
    }
}

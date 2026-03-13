// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "../libraries/LibStorage.sol";
import "../libraries/LibGame.sol";
import "../libraries/MafiaTypes.sol";

interface IGroth16Verifier {
    function verifyProof(
        uint[2] calldata a,
        uint[2][2] calldata b,
        uint[2] calldata c,
        uint[5] calldata input
    ) external view returns (bool);
}

contract GameEndFacet {

    function endGameZK(
        uint256 roomId,
        uint[2] calldata a,
        uint[2][2] calldata b,
        uint[2] calldata c,
        uint[5] calldata input
    ) external {
        LibGame.nonReentrantBefore();
        LibGame.requireNotPaused();

        LibStorage.Storage storage ds = LibStorage.s();
        MafiaTypes.GameRoom storage room = ds.rooms[roomId];

        if (room.phase == MafiaTypes.GamePhase.LOBBY || room.phase == MafiaTypes.GamePhase.ENDED)
            revert LibGame.WrongPhase();
        require(ds.zkVerifier != address(0), "Verifier not set");

        bool proofOk = IGroth16Verifier(ds.zkVerifier).verifyProof(a, b, c, input);
        require(proofOk, "Invalid ZK proof");

        // Prevent replay attacks
        bytes32 nullifier = keccak256(abi.encode(a, b, c, input));
        require(!ds.proofNullifiers[nullifier], "Proof already used");
        ds.proofNullifiers[nullifier] = true;

        uint256 townWin    = input[0];
        uint256 mafiaWin   = input[1];
        uint256 proofRoomId = input[2];
        uint256 mafiaCount = input[3];
        uint256 townCount  = input[4];

        require(proofRoomId == roomId, "RoomId mismatch");
        require(townCount > 0, "No town players");
        require(mafiaCount + townCount > 0, "Empty game");

        if (townWin == 1) {
            ds.gameResult[roomId] = false; // Town wins
            LibGame.endGame(roomId, "Town wins (ZK)");
        } else if (mafiaWin == 1) {
            ds.gameResult[roomId] = true; // Mafia wins
            LibGame.endGame(roomId, "Mafia wins (ZK)");
        } else {
            revert("ZK: no winner");
        }

        LibGame.nonReentrantAfter();
    }
}


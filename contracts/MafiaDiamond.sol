// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "./libraries/LibStorage.sol";

/// @title MafiaDiamond — Diamond proxy that delegates calls to facets
/// @dev Simplified Diamond (EIP-2535 inspired) with admin-managed facet routing.
///      All facets share the same storage via LibStorage.
contract MafiaDiamond {
    // ---- Diamond storage ----
    struct Facet {
        address facetAddress;
        bytes4[] selectors;
    }

    // Selector -> facet address
    mapping(bytes4 => address) public selectorToFacet;
    address public owner;

    event FacetAdded(address indexed facet, uint256 selectorCount);
    event FacetRemoved(address indexed facet);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    error FunctionNotFound(bytes4 selector);
    error NotOwner();
    error FacetCallFailed();

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    constructor(address _owner) {
        owner = _owner;
        // Sync owner to diamond storage so facets can check access
        LibStorage.s().owner = _owner;
        // Initialize reentrancy status
        LibStorage.s().reentrancyStatus = 1;
        // Initialize nextRoomId
        LibStorage.s().nextRoomId = 0;
    }

    /// @notice Register all selectors from a facet
    function addFacet(address facet, bytes4[] calldata selectors) external onlyOwner {
        for (uint256 i = 0; i < selectors.length; i++) {
            selectorToFacet[selectors[i]] = facet;
        }
        emit FacetAdded(facet, selectors.length);
    }

    /// @notice Remove specific selectors
    function removeSelectors(bytes4[] calldata selectors) external onlyOwner {
        for (uint256 i = 0; i < selectors.length; i++) {
            delete selectorToFacet[selectors[i]];
        }
    }

    /// @notice Replace facet for specific selectors (upgrade)
    function replaceFacet(address newFacet, bytes4[] calldata selectors) external onlyOwner {
        for (uint256 i = 0; i < selectors.length; i++) {
            selectorToFacet[selectors[i]] = newFacet;
        }
        emit FacetAdded(newFacet, selectors.length);
    }

    function transferOwnership(address newOwner) external onlyOwner {
        emit OwnershipTransferred(owner, newOwner);
        owner = newOwner;
        LibStorage.s().owner = newOwner;
    }

    // ---- Fallback: delegate to facet ----
    fallback() external payable {
        address facet = selectorToFacet[msg.sig];
        if (facet == address(0)) revert FunctionNotFound(msg.sig);

        assembly {
            calldatacopy(0, 0, calldatasize())
            let result := delegatecall(gas(), facet, 0, calldatasize(), 0, 0)
            returndatacopy(0, 0, returndatasize())
            switch result
            case 0 { revert(0, returndatasize()) }
            default { return(0, returndatasize()) }
        }
    }

    receive() external payable {}
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @title PNP Token (PNPT)
/// @notice Represents Pick n Pay reward points (Smart Shopper-style) as a
///         standard fungible ERC20 with 18 decimals. In the assignment narrative
///         1 PNPT ~ R0.01 in notional ZAR terms.
/// @dev Identical to the contract used in 01-order-book; copied here per the
///      assignment instructions so the Uniswap v4 pool can use the same tokens.
contract PNPToken is ERC20 {
    /// @param initialSupply Total supply (in 18-decimal wei units) minted to the
    ///        deployer at construction time. The deployer can then seed the LP
    ///        position and any test fixtures.
    constructor(uint256 initialSupply) ERC20("PNP Token", "PNPT") {
        _mint(msg.sender, initialSupply);
    }
}

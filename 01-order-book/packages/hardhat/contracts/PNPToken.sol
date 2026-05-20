// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

// PNPT is the Pick n Pay reward points token used in this assignment.
// The wiki treats 1 PNPT as roughly R0.01 in notional terms.
contract PNPToken is ERC20 {
    // Mint the whole initial supply to the deployer so the deployer can
    // hand tokens out to traders in the tests.
    constructor(uint256 initialSupply) ERC20("PNP Token", "PNPT") {
        _mint(msg.sender, initialSupply);
    }
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

// Same PNPT token as in the order book assignment. Copied across so
// the v4 pool in this folder can use the exact same currency.
contract PNPToken is ERC20 {
    constructor(uint256 initialSupply) ERC20("PNP Token", "PNPT") {
        _mint(msg.sender, initialSupply);
    }
}

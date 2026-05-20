// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

// FNBT represents FNB eBucks. The wiki says 10 FNBT is worth about R1
// (so 1 FNBT is about R0.10), which works out to 1 FNBT being worth
// about 10 PNPT at the assignment spot rate.
contract FNBToken is ERC20 {
    // Whole supply goes to the deployer so the tests can transfer it
    // around to the buyer and seller accounts.
    constructor(uint256 initialSupply) ERC20("FNB Token", "FNBT") {
        _mint(msg.sender, initialSupply);
    }
}

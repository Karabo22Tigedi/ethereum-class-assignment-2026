// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @title FNB Token (FNBT)
/// @notice Represents FNB eBucks rewards as a standard fungible ERC20 with 18
///         decimals. In the assignment narrative 1 FNBT ~ R0.10 in notional
///         ZAR terms (i.e. 10 FNBT ~ R1), so 1 FNBT ~ 10 PNPT at the spot
///         conversion rate.
/// @dev Minimal ERC20 inheriting OpenZeppelin's reference implementation. The
///      whole `initialSupply` is minted to the deployer at construction so the
///      deployer can seed traders and the order book in tests.
contract FNBToken is ERC20 {
    /// @param initialSupply The total supply (in wei units, 18 decimals) minted
    ///        to the deployer. Tests deploy with `parseUnits("1000000", 18)`.
    constructor(uint256 initialSupply) ERC20("FNB Token", "FNBT") {
        _mint(msg.sender, initialSupply);
    }
}

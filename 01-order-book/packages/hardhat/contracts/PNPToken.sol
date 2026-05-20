// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @title PNP Token (PNPT)
/// @notice Represents Pick n Pay reward points (Smart Shopper-style) as a
///         standard fungible ERC20 with 18 decimals. In the assignment narrative
///         1 PNPT ~ R0.01 in notional ZAR terms.
/// @dev Minimal ERC20 inheriting OpenZeppelin's reference implementation. The
///      whole `initialSupply` is minted to the deployer at construction so the
///      deployer can fund traders, the order book, and any test fixtures.
contract PNPToken is ERC20 {
    /// @param initialSupply The total supply (in wei units, 18 decimals) minted
    ///        to the deployer. Tests deploy with `parseUnits("1000000", 18)`.
    constructor(uint256 initialSupply) ERC20("PNP Token", "PNPT") {
        _mint(msg.sender, initialSupply);
    }
}

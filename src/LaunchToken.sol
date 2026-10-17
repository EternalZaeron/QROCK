// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Burnable} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";

/// @title LaunchToken
/// @notice Fixed-supply ERC-20 minted once to a single recipient (the Seeder). No owner, no mint,
///         no pause, no transfer tax: every launch rule lives in the pool hook. tokenURI exposes
///         metadata for explorers and launch platforms.
contract LaunchToken is ERC20, ERC20Burnable {
    string private _uri;

    constructor(string memory name_, string memory symbol_, uint256 supply_, address recipient, string memory uri_)
        ERC20(name_, symbol_)
    {
        _mint(recipient, supply_);
        _uri = uri_;
    }

    function tokenURI() external view returns (string memory) {
        return _uri;
    }
}

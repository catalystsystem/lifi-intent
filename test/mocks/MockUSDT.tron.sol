// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import { MockERC20 } from "OIF/test/mocks/MockERC20.sol";

/// @notice Mock ERC20 mimicking Tron USDT behavior: transfer() returns false on success.
/// @dev approve() and transferFrom() work normally and return true.
contract MockTronUSDT is MockERC20 {
    constructor(
        string memory name_,
        string memory symbol_,
        uint8 decimals_
    ) MockERC20(name_, symbol_, decimals_) { }

    function transfer(
        address to,
        uint256 amount
    ) public virtual override returns (bool) {
        super.transfer(to, amount);
        return false;
    }
}

// SPDX-License-Identifier: LGPL-3.0-only
pragma solidity ^0.8.25;

import { SafeTransferLib } from "solady/utils/SafeTransferLib.sol";

/// @notice Wrapper around Solady's SafeTransferLib for Tron-deployed contracts.
/// @dev Tron USDT's transfer() returns false on success, causing Solady's safeTransfer to revert.
/// This library replaces transfer() with an approve + transferFrom pattern since those functions
/// return true correctly on Tron USDT.
library SafeTransferLibTron {
    function safeTransfer(
        address token,
        address to,
        uint256 amount
    ) internal {
        if (_selfAllowance(token) < amount) {
            SafeTransferLib.safeApproveWithRetry(token, address(this), type(uint256).max);
        }
        SafeTransferLib.safeTransferFrom(token, address(this), to, amount);
    }

    function _selfAllowance(
        address token
    ) private view returns (uint256 result) {
        assembly ("memory-safe") {
            let m := mload(0x40)
            let self := address()
            mstore(0x34, self)
            mstore(0x14, self)
            mstore(0x00, 0xdd62ed3e000000000000000000000000) // allowance(address,address)
            result := mul(
                mload(0x00),
                and(gt(returndatasize(), 0x1f), staticcall(gas(), token, 0x10, 0x44, 0x00, 0x20))
            )
            mstore(0x40, m)
        }
    }
}

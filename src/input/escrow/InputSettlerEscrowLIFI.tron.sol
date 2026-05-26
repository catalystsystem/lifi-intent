// SPDX-License-Identifier: LGPL-3.0-only
pragma solidity ^0.8.25;

import { SafeTransferLibTron } from "../../libs/SafeTransferLib.tron.sol";
import { InputSettlerEscrowLIFI } from "./InputSettlerEscrowLIFI.sol";

/// @title LIFI Input Settler Escrow for Tron
/// @dev Overrides _transfer to use SafeTransferLibTron, which replaces broken transfer()
/// calls with an approve + transferFrom pattern for Tron USDT compatibility.
contract InputSettlerEscrowLIFITron is InputSettlerEscrowLIFI {
    constructor(
        address initialOwner
    ) InputSettlerEscrowLIFI(initialOwner) { }

    function _domainName() internal pure override returns (string memory) {
        return "OIFEscrowLIFITron";
    }

    function _transfer(address token, address to, uint256 amount) internal override {
        SafeTransferLibTron.safeTransfer(token, to, amount);
    }
}

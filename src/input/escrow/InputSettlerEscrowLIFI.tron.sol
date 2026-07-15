// SPDX-License-Identifier: LGPL-3.0-only
pragma solidity ^0.8.25;

import { ISignatureTransfer } from "permit2/src/interfaces/ISignatureTransfer.sol";

import { SafeTransferLibTron } from "../../libs/SafeTransferLib.tron.sol";
import { InputSettlerEscrowLIFI } from "./InputSettlerEscrowLIFI.sol";

/// @title LIFI Input Settler Escrow for Tron
/// @dev Overrides _transfer to use SafeTransferLibTron, which replaces broken transfer()
/// calls with an approve + transferFrom pattern for Tron USDT compatibility.
/// Overrides _PERMIT2 with the Tron Permit2 deployment (TTJxU3P8rHycAyFY4kVtGNfmnMH4ezcuM9),
/// since Tron's CREATE2 derivation places Permit2 at a different address than the canonical one.
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

    /// @dev Tron Permit2 deployment: TTJxU3P8rHycAyFY4kVtGNfmnMH4ezcuM9.
    function _PERMIT2() internal pure override returns (ISignatureTransfer) {
        return ISignatureTransfer(0xBE365314f2E77FD1257d60C346Bb32DbDa369403);
    }
}

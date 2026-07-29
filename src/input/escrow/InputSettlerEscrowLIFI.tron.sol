// SPDX-License-Identifier: LGPL-3.0-only
pragma solidity ^0.8.26;

// NOTE: SafeTRC20 is imported from OpenZeppelin's tron-contracts, pinned (as a git submodule) to the commit that
// introduces `safeTransferUSDT`: OpenZeppelin/tron-contracts@ae352da. Once that change is merged, the submodule
// should be repointed to tron-contracts `master`.
import { ITRC20 } from "tron-contracts/token/TRC20/ITRC20.sol";
import { SafeTRC20 } from "tron-contracts/token/TRC20/utils/SafeTRC20.sol";

import { ISignatureTransfer } from "permit2/src/interfaces/ISignatureTransfer.sol";

import { InputSettlerEscrowLIFI } from "./InputSettlerEscrowLIFI.sol";

/**
 * @title LIFI Input Settler (escrow variant) for TRON.
 * @notice TRON USDT (`TR7NHqjeKQxGTCi8q8ZY4pL8otSzgjLj6t`) returns `false` from `transfer` even on a *successful*
 * transfer (while reverting on real failure). OpenZeppelin's `SafeERC20.safeTransfer`, used by {InputSettlerEscrow}
 * to pay out escrowed inputs, reads that `false` as a failure and reverts — locking USDT in the escrow.
 *
 * This variant overrides the {InputSettlerEscrow-_transfer} payout hook to settle inputs with {SafeTRC20}, routing
 * the {USDT} token through {SafeTRC20-safeTransferUSDT} (which ignores the boolean and verifies the transfer by the
 * recipient's balance delta) and every other token through the regular {SafeTRC20-safeTransfer}.
 *
 * Only the outbound payout needs this treatment. The inbound `transferFrom` performed on `open` is unaffected,
 * because USDT's `transferFrom` correctly returns `true`. Native (token 0) payouts are handled upstream by
 * {InputSettlerEscrow-_sendInputAsset} and never reach this hook.
 *
 * It also overrides {InputSettlerEscrow-_PERMIT2} with the TRON Permit2 deployment
 * (`TTJxU3P8rHycAyFY4kVtGNfmnMH4ezcuM9`), since TRON's CREATE2 derivation places Permit2 at a different address than
 * the canonical EVM one.
 */
contract InputSettlerEscrowLIFITron is InputSettlerEscrowLIFI {
    /// @notice TRON USDT (`TR7NHqjeKQxGTCi8q8ZY4pL8otSzgjLj6t`), whose `transfer` returns `false` even on success.
    address public constant USDT = 0xa614f803B6FD780986A42c78Ec9c7f77e6DeD13C;

    constructor(
        address initialOwner
    ) InputSettlerEscrowLIFI(initialOwner) { }

    function _domainName() internal pure override returns (string memory) {
        return "OIFEscrowLIFITron";
    }

    /**
     * @dev Pays out an escrowed input with {SafeTRC20}, sending {USDT} via {SafeTRC20-safeTransferUSDT}.
     * @param token The input token to transfer.
     * @param to The recipient of the tokens.
     * @param amount The amount to transfer.
     */
    function _transfer(address token, address to, uint256 amount) internal override {
        if (token == USDT) SafeTRC20.safeTransferUSDT(ITRC20(token), to, amount);
        else SafeTRC20.safeTransfer(ITRC20(token), to, amount);
    }

    /// @dev TRON Permit2 deployment: TTJxU3P8rHycAyFY4kVtGNfmnMH4ezcuM9.
    function _PERMIT2() internal pure override returns (ISignatureTransfer) {
        return ISignatureTransfer(0xBE365314f2E77FD1257d60C346Bb32DbDa369403);
    }
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { MandateOutput } from "../../src/input/types/MandateOutputType.sol";

/**
 * @notice Test-only wire-format byte builder.
 * @dev Production (`MandateOutputEncodingLib`) hashes these packed encodings directly and no longer exposes byte
 * encoders. Tests that must construct raw payload bytes — simulating the off-chain relayer that feeds
 * `fill` / `submit` / `hasAttested` — use this independent reimplementation instead. It imports only the
 * `MandateOutput` struct type (no production encoding logic) and is never referenced by any `src` contract.
 *
 * The dynamic tail is packed via a nested `abi.encodePacked` to keep the header arity low enough to compile under
 * the legacy (no-via-IR) pipeline used by `forge coverage`.
 */
library RefEncodingLib {
    error ContextOutOfRange();
    error CallOutOfRange();

    bytes4 internal constant FILL_MAGIC = bytes4(keccak256("OIF.Fill"));
    bytes4 internal constant NOT_FILLED_MAGIC = bytes4(keccak256("OIF.NotFilled"));

    function _tail(bytes memory callbackData, bytes memory context) private pure returns (bytes memory) {
        if (callbackData.length > type(uint16).max) revert CallOutOfRange();
        if (context.length > type(uint16).max) revert ContextOutOfRange();
        return abi.encodePacked(uint16(callbackData.length), callbackData, uint16(context.length), context);
    }

    function encodeMandateOutput(
        MandateOutput memory o
    ) internal pure returns (bytes memory) {
        return abi.encodePacked(
            o.oracle, o.settler, o.chainId, o.token, o.amount, o.recipient, _tail(o.callbackData, o.context)
        );
    }

    function encodeFillDescription(
        bytes32 solver,
        bytes32 orderId,
        uint32 timestamp,
        bytes32 token,
        uint256 amount,
        bytes32 recipient,
        bytes memory callbackData,
        bytes memory context
    ) internal pure returns (bytes memory) {
        return abi.encodePacked(
            FILL_MAGIC, solver, orderId, timestamp, token, amount, recipient, _tail(callbackData, context)
        );
    }

    function encodeFillDescription(
        bytes32 solver,
        bytes32 orderId,
        uint32 timestamp,
        MandateOutput memory o
    ) internal pure returns (bytes memory) {
        return encodeFillDescription(
            solver, orderId, timestamp, o.token, o.amount, o.recipient, o.callbackData, o.context
        );
    }

    function encodeNotFilledDescription(
        bytes32 orderId,
        uint32 fillDeadline,
        bytes32 token,
        uint256 amount,
        bytes32 recipient,
        bytes memory callbackData,
        bytes memory context
    ) internal pure returns (bytes memory) {
        return abi.encodePacked(
            NOT_FILLED_MAGIC, orderId, fillDeadline, token, amount, recipient, _tail(callbackData, context)
        );
    }

    function encodeNotFilledDescription(
        bytes32 orderId,
        uint32 fillDeadline,
        MandateOutput memory o
    ) internal pure returns (bytes memory) {
        return encodeNotFilledDescription(
            orderId, fillDeadline, o.token, o.amount, o.recipient, o.callbackData, o.context
        );
    }

    // --- `*Memory` aliases mirroring the retired production API, so test call sites are a pure prefix swap ---

    function encodeMandateOutputMemory(
        MandateOutput memory o
    ) internal pure returns (bytes memory) {
        return encodeMandateOutput(o);
    }

    function encodeFillDescriptionMemory(
        bytes32 solver,
        bytes32 orderId,
        uint32 timestamp,
        bytes32 token,
        uint256 amount,
        bytes32 recipient,
        bytes memory callbackData,
        bytes memory context
    ) internal pure returns (bytes memory) {
        return encodeFillDescription(solver, orderId, timestamp, token, amount, recipient, callbackData, context);
    }

    function encodeFillDescriptionMemory(
        bytes32 solver,
        bytes32 orderId,
        uint32 timestamp,
        MandateOutput memory o
    ) internal pure returns (bytes memory) {
        return encodeFillDescription(solver, orderId, timestamp, o);
    }

    function encodeNotFilledDescriptionMemory(
        bytes32 orderId,
        uint32 fillDeadline,
        MandateOutput memory o
    ) internal pure returns (bytes memory) {
        return encodeNotFilledDescription(orderId, fillDeadline, o);
    }
}

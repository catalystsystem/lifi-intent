// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { MandateOutput } from "../input/types/MandateOutputType.sol";

/**
 * @notice Converts MandateOutputs to and from byte payloads.
 * @dev This library defines 3 payload encodings, one for internal usage and two for cross-chain communication.
 * - MandateOutput serialisation of the exact output on a output chain (encodes the entirety MandateOutput struct). This
 * encoding may be used to obtain a collision free hash to uniquely identify a MandateOutput.
 * - FillDescription serialisation to describe describe what has been filled on a output chain. Its purpose is to
 * provide a source of truth of a output action.
 * - NotFilledDescription serialisation to describe that an output was provably not filled before its fill deadline.
 * Its purpose is to provide a source of truth of the permanent absence of a fill, enabling early refunds.
 * The encoding scheme uses 2 bytes long length identifiers. As a result, neither callbackData nor context exceed 65'535
 * bytes.
 *
 * Both proof payloads (FillDescription and NotFilledDescription) lead with a distinct 4-byte domain magic so consumers
 * dispatch on the leading 4 bytes and the two proof domains can never be cross-consumed. The Serialised MandateOutput
 * stays untagged: it is a purely internal identity key and is never ferried cross-chain.
 *
 * Serialised MandateOutput
 *      OUTPUT_ORACLE           0               (32 bytes)
 *      + OUTPUT_SETTLER        32              (32 bytes)
 *      + CHAIN_ID              64              (32 bytes)
 *      + COMMON_PAYLOAD        96
 *
 * Serialised FillDescription
 *      FILL_MAGIC              0               (4 bytes)
 *      + SOLVER                4               (32 bytes)
 *      + ORDERID               36              (32 bytes)
 *      + TIMESTAMP             68              (4 bytes)
 *      + COMMON_PAYLOAD        72
 *
 * Serialised NotFilledDescription
 *      NOT_FILLED_MAGIC        0               (4 bytes)
 *      + ORDERID               4               (32 bytes)
 *      + FILL_DEADLINE         36              (4 bytes)
 *      + COMMON_PAYLOAD        40
 *
 * Common Payload. Is identical between all schemes
 *      + TOKEN                 Y               (32 bytes)
 *      + AMOUNT                Y+32            (32 bytes)
 *      + RECIPIENT             Y+64            (32 bytes)
 *      + CALL_LENGTH           Y+96            (2 bytes)
 *      + CALL                  Y+98            (LENGTH bytes)
 *      + CONTEXT_LENGTH        Y+98+RC_LENGTH  (2 bytes)
 *      + CONTEXT               Y+100+RC_LENGTH (LENGTH bytes)
 *
 * where Y is the offset from the specific encoding (40, 72 or 96)
 */
library MandateOutputEncodingLib {
    error ContextOutOfRange();
    error CallOutOfRange();

    /// @dev Domain magic leading every serialised FillDescription.
    bytes4 internal constant FILL_MAGIC = bytes4(keccak256("OIF.Fill"));
    /// @dev Domain magic leading every serialised NotFilledDescription.
    bytes4 internal constant NOT_FILLED_MAGIC = bytes4(keccak256("OIF.NotFilled"));

    /// @dev Offset at which the common payload begins in a serialised FillDescription:
    /// FILL_MAGIC(4) + SOLVER(32) + ORDERID(32) + TIMESTAMP(4).
    uint256 internal constant FILL_COMMON_PAYLOAD_OFFSET = 72;
    /// @dev Offset at which the common payload begins in a serialised NotFilledDescription:
    /// NOT_FILLED_MAGIC(4) + ORDERID(32) + FILL_DEADLINE(4).
    uint256 internal constant NOT_FILLED_COMMON_PAYLOAD_OFFSET = 40;
    /// @dev Minimum length of the common payload (TOKEN(32) + AMOUNT(32) + RECIPIENT(32) + CALL_LENGTH(2) +
    /// CONTEXT_LENGTH(2)) with empty call/context.
    uint256 internal constant COMMON_PAYLOAD_MIN_LENGTH = 100;

    /// @dev Minimum length of a serialised FillDescription (common payload with empty call/context).
    uint256 internal constant FILL_DESCRIPTION_MIN_LENGTH = FILL_COMMON_PAYLOAD_OFFSET + COMMON_PAYLOAD_MIN_LENGTH;
    /// @dev Minimum length of a serialised NotFilledDescription (common payload with empty call/context).
    uint256 internal constant NOT_FILLED_DESCRIPTION_MIN_LENGTH =
        NOT_FILLED_COMMON_PAYLOAD_OFFSET + COMMON_PAYLOAD_MIN_LENGTH;

    // --- MandateOutput --- //

    /**
     * @notice Hash of an MandateOutput intended for output identification.
     * @dev This identifier is purely intended for the output chain. It should never be ferried cross-chain.
     * Chains or VMs may hash data differently.
     * Hashes the Serialised MandateOutput preimage directly (no intermediate `bytes` allocation): the buffer is
     * packed into scratch memory at the free-memory pointer and hashed in a single `keccak256`. The preimage layout
     * is `oracle‖settler‖chainId‖token‖amount‖recipient‖uint16(cbLen)‖cb‖uint16(ctxLen)‖ctx`; it is pinned by the
     * golden-vector unit tests and the independent differential reference (`test/util/RefEncodingLib.sol`).
     */
    function getMandateOutputHash(
        MandateOutput calldata output
    ) internal pure returns (bytes32 outputHash) {
        bytes calldata callbackData = output.callbackData;
        bytes calldata context = output.context;
        if (callbackData.length > type(uint16).max) revert CallOutOfRange();
        if (context.length > type(uint16).max) revert ContextOutOfRange();
        bytes32 oracle = output.oracle;
        bytes32 settler = output.settler;
        uint256 chainId = output.chainId;
        bytes32 token = output.token;
        uint256 amount = output.amount;
        bytes32 recipient = output.recipient;
        assembly ("memory-safe") {
            // Fixed header written at constant offsets from the scratch base; oracle 0x00, settler 0x20, chainId
            // 0x40, token 0x60, amount 0x80, recipient 0xa0, callbackData length 0xc0, callbackData bytes 0xc2.
            let start := mload(0x40)
            mstore(start, oracle)
            mstore(add(start, 0x20), settler)
            mstore(add(start, 0x40), chainId)
            mstore(add(start, 0x60), token)
            mstore(add(start, 0x80), amount)
            mstore(add(start, 0xa0), recipient)
            mstore(add(start, 0xc0), shl(240, callbackData.length))
            calldatacopy(add(start, 0xc2), callbackData.offset, callbackData.length)
            // Context region begins after the variable-length callbackData: length then bytes.
            let ctxAt := add(add(start, 0xc2), callbackData.length)
            mstore(ctxAt, shl(240, context.length))
            calldatacopy(add(ctxAt, 2), context.offset, context.length)
            // 0xc4 = fixed size (6*32 header + 2 + 2 length prefixes).
            outputHash := keccak256(start, add(0xc4, add(callbackData.length, context.length)))
        }
    }

    /// @dev Memory variant of {getMandateOutputHash}. Assumes a canonical in-memory `MandateOutput`; a noncanonical
    /// or aliased struct is not supported.
    function getMandateOutputHashMemory(
        MandateOutput memory output
    ) internal pure returns (bytes32 outputHash) {
        bytes memory callbackData = output.callbackData;
        bytes memory context = output.context;
        if (callbackData.length > type(uint16).max) revert CallOutOfRange();
        if (context.length > type(uint16).max) revert ContextOutOfRange();
        bytes32 oracle = output.oracle;
        bytes32 settler = output.settler;
        uint256 chainId = output.chainId;
        bytes32 token = output.token;
        uint256 amount = output.amount;
        bytes32 recipient = output.recipient;
        assembly ("memory-safe") {
            let start := mload(0x40)
            mstore(start, oracle)
            mstore(add(start, 0x20), settler)
            mstore(add(start, 0x40), chainId)
            mstore(add(start, 0x60), token)
            mstore(add(start, 0x80), amount)
            mstore(add(start, 0xa0), recipient)
            let cbLen := mload(callbackData)
            mstore(add(start, 0xc0), shl(240, cbLen))
            mcopy(add(start, 0xc2), add(callbackData, 0x20), cbLen)
            let ctxAt := add(add(start, 0xc2), cbLen)
            let ctxLen := mload(context)
            mstore(ctxAt, shl(240, ctxLen))
            mcopy(add(ctxAt, 2), add(context, 0x20), ctxLen)
            outputHash := keccak256(start, add(0xc4, add(cbLen, ctxLen)))
        }
    }

    /**
     * @notice Hash of an MandateOutput computed based on a common payload.
     * @param oracle Address of the oracle of the output.
     * @param settler Address of the settler contract of the output.
     * @param chainId Identifier of the chain for the output.
     * @param commonPayload Common payload of the serialised outputs.
     * @return bytes32 OutputDescription hash.
     */
    function getMandateOutputHashFromCommonPayload(
        bytes32 oracle,
        bytes32 settler,
        uint256 chainId,
        bytes calldata commonPayload
    ) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(oracle, settler, chainId, commonPayload));
    }

    // --- FillDescription / NotFilledDescription Hashing --- //

    /**
     * @notice Hash of a FillDescription preimage, computed directly (no intermediate `bytes` allocation).
     * @dev Preimage `FILL_MAGIC‖solver‖orderId‖uint32(timestamp)‖token‖amount‖recipient‖uint16(cbLen)‖cb‖
     * uint16(ctxLen)‖ctx`, packed into scratch memory at the free-memory pointer and hashed in a single `keccak256`.
     * Pinned by the golden-vector unit tests and the independent differential reference (`test/util/RefEncodingLib`).
     */
    function hashFillDescription(
        bytes32 solver,
        bytes32 orderId,
        uint32 fillTimestamp,
        MandateOutput calldata output
    ) internal pure returns (bytes32 fillHash) {
        bytes calldata callbackData = output.callbackData;
        bytes calldata context = output.context;
        if (callbackData.length > type(uint16).max) revert CallOutOfRange();
        if (context.length > type(uint16).max) revert ContextOutOfRange();
        bytes32 token = output.token;
        uint256 amount = output.amount;
        bytes32 recipient = output.recipient;
        bytes4 magic = FILL_MAGIC;
        assembly ("memory-safe") {
            // Offsets from the scratch base: magic 0x00 (4b), solver 0x04, orderId 0x24, timestamp 0x44 (4b),
            // token 0x48, amount 0x68, recipient 0x88, callbackData length 0xa8 (2b), callbackData bytes 0xaa.
            let start := mload(0x40)
            mstore(start, magic)
            mstore(add(start, 0x04), solver)
            mstore(add(start, 0x24), orderId)
            mstore(add(start, 0x44), shl(224, fillTimestamp))
            mstore(add(start, 0x48), token)
            mstore(add(start, 0x68), amount)
            mstore(add(start, 0x88), recipient)
            mstore(add(start, 0xa8), shl(240, callbackData.length))
            calldatacopy(add(start, 0xaa), callbackData.offset, callbackData.length)
            let ctxAt := add(add(start, 0xaa), callbackData.length)
            mstore(ctxAt, shl(240, context.length))
            calldatacopy(add(ctxAt, 2), context.offset, context.length)
            // 0xac = fixed size (magic 4 + solver/orderId 64 + ts 4 + token/amount/recipient 96 + 2 + 2).
            fillHash := keccak256(start, add(0xac, add(callbackData.length, context.length)))
        }
    }

    /// @dev Memory variant of {hashFillDescription}. Assumes a canonical in-memory `MandateOutput`.
    function hashFillDescriptionMemory(
        bytes32 solver,
        bytes32 orderId,
        uint32 fillTimestamp,
        MandateOutput memory output
    ) internal pure returns (bytes32 fillHash) {
        bytes memory callbackData = output.callbackData;
        bytes memory context = output.context;
        if (callbackData.length > type(uint16).max) revert CallOutOfRange();
        if (context.length > type(uint16).max) revert ContextOutOfRange();
        bytes32 token = output.token;
        uint256 amount = output.amount;
        bytes32 recipient = output.recipient;
        bytes4 magic = FILL_MAGIC;
        assembly ("memory-safe") {
            let start := mload(0x40)
            mstore(start, magic)
            mstore(add(start, 0x04), solver)
            mstore(add(start, 0x24), orderId)
            mstore(add(start, 0x44), shl(224, fillTimestamp))
            mstore(add(start, 0x48), token)
            mstore(add(start, 0x68), amount)
            mstore(add(start, 0x88), recipient)
            let cbLen := mload(callbackData)
            mstore(add(start, 0xa8), shl(240, cbLen))
            mcopy(add(start, 0xaa), add(callbackData, 0x20), cbLen)
            let ctxAt := add(add(start, 0xaa), cbLen)
            let ctxLen := mload(context)
            mstore(ctxAt, shl(240, ctxLen))
            mcopy(add(ctxAt, 2), add(context, 0x20), ctxLen)
            fillHash := keccak256(start, add(0xac, add(cbLen, ctxLen)))
        }
    }

    /**
     * @notice Hash of a NotFilledDescription preimage, computed directly (no intermediate `bytes` allocation).
     * @dev Preimage `NOT_FILLED_MAGIC‖orderId‖uint32(fillDeadline)‖token‖amount‖recipient‖uint16(cbLen)‖cb‖
     * uint16(ctxLen)‖ctx`. Pinned by the golden-vector unit tests and the independent differential reference.
     */
    function hashNotFilledDescription(
        bytes32 orderId,
        uint32 fillDeadline,
        MandateOutput calldata output
    ) internal pure returns (bytes32 notFilledHash) {
        bytes calldata callbackData = output.callbackData;
        bytes calldata context = output.context;
        if (callbackData.length > type(uint16).max) revert CallOutOfRange();
        if (context.length > type(uint16).max) revert ContextOutOfRange();
        bytes32 token = output.token;
        uint256 amount = output.amount;
        bytes32 recipient = output.recipient;
        bytes4 magic = NOT_FILLED_MAGIC;
        assembly ("memory-safe") {
            // Offsets from the scratch base: magic 0x00 (4b), orderId 0x04, fillDeadline 0x24 (4b), token 0x28,
            // amount 0x48, recipient 0x68, callbackData length 0x88 (2b), callbackData bytes 0x8a.
            let start := mload(0x40)
            mstore(start, magic)
            mstore(add(start, 0x04), orderId)
            mstore(add(start, 0x24), shl(224, fillDeadline))
            mstore(add(start, 0x28), token)
            mstore(add(start, 0x48), amount)
            mstore(add(start, 0x68), recipient)
            mstore(add(start, 0x88), shl(240, callbackData.length))
            calldatacopy(add(start, 0x8a), callbackData.offset, callbackData.length)
            let ctxAt := add(add(start, 0x8a), callbackData.length)
            mstore(ctxAt, shl(240, context.length))
            calldatacopy(add(ctxAt, 2), context.offset, context.length)
            // 0x8c = fixed size (magic 4 + orderId 32 + deadline 4 + token/amount/recipient 96 + 2 + 2).
            notFilledHash := keccak256(start, add(0x8c, add(callbackData.length, context.length)))
        }
    }

    /// @dev Memory variant of {hashNotFilledDescription}. Assumes a canonical in-memory `MandateOutput`.
    function hashNotFilledDescriptionMemory(
        bytes32 orderId,
        uint32 fillDeadline,
        MandateOutput memory output
    ) internal pure returns (bytes32 notFilledHash) {
        bytes memory callbackData = output.callbackData;
        bytes memory context = output.context;
        if (callbackData.length > type(uint16).max) revert CallOutOfRange();
        if (context.length > type(uint16).max) revert ContextOutOfRange();
        bytes32 token = output.token;
        uint256 amount = output.amount;
        bytes32 recipient = output.recipient;
        bytes4 magic = NOT_FILLED_MAGIC;
        assembly ("memory-safe") {
            let start := mload(0x40)
            mstore(start, magic)
            mstore(add(start, 0x04), orderId)
            mstore(add(start, 0x24), shl(224, fillDeadline))
            mstore(add(start, 0x28), token)
            mstore(add(start, 0x48), amount)
            mstore(add(start, 0x68), recipient)
            let cbLen := mload(callbackData)
            mstore(add(start, 0x88), shl(240, cbLen))
            mcopy(add(start, 0x8a), add(callbackData, 0x20), cbLen)
            let ctxAt := add(add(start, 0x8a), cbLen)
            let ctxLen := mload(context)
            mstore(ctxAt, shl(240, ctxLen))
            mcopy(add(ctxAt, 2), add(context, 0x20), ctxLen)
            notFilledHash := keccak256(start, add(0x8c, add(cbLen, ctxLen)))
        }
    }

    // --- FillDescription Decoding --- //

    /**
     * @notice Loads the solver of the output from a serialised fill description.
     * @param fillDescription Serialised fill description.
     * @return solver Solver of the output.
     */
    function loadSolverFromFillDescription(
        bytes calldata fillDescription
    ) internal pure returns (bytes32 solver) {
        assembly ("memory-safe") {
            solver := calldataload(add(fillDescription.offset, 0x04))
        }
    }

    /**
     * @notice Loads the orderId from a serialised fill description.
     * @param fillDescription Serialised fill description.
     * @return orderId associated with the output.
     */
    function loadOrderIdFromFillDescription(
        bytes calldata fillDescription
    ) internal pure returns (bytes32 orderId) {
        assembly ("memory-safe") {
            orderId := calldataload(add(fillDescription.offset, 0x24))
        }
    }

    /**
     * @notice Loads the timestamp when the fill was made from a serialised fill description.
     * @param fillDescription Serialised fill description.
     * @return ts Timestamp associated with the output.
     */
    function loadTimestampFromFillDescription(
        bytes calldata fillDescription
    ) internal pure returns (uint32 ts) {
        assembly ("memory-safe") {
            // Clean the leftmost bytes: (32-4)*8 = 224
            ts := shr(224, shl(224, calldataload(add(fillDescription.offset, 0x28))))
        }
    }

    // --- NotFilledDescription Decoding --- //

    /**
     * @notice Loads the orderId from a serialised not-filled description.
     * @param notFilledDescription Serialised not-filled description.
     * @return orderId associated with the output.
     */
    function loadOrderIdFromNotFilledDescription(
        bytes calldata notFilledDescription
    ) internal pure returns (bytes32 orderId) {
        assembly ("memory-safe") {
            orderId := calldataload(add(notFilledDescription.offset, 0x04))
        }
    }

    /**
     * @notice Loads the fill deadline from a serialised not-filled description.
     * @param notFilledDescription Serialised not-filled description.
     * @return fillDeadline The fill deadline the non-fill was attested against.
     */
    function loadFillDeadlineFromNotFilledDescription(
        bytes calldata notFilledDescription
    ) internal pure returns (uint32 fillDeadline) {
        assembly ("memory-safe") {
            // Clean the leftmost bytes: (32-4)*8 = 224
            fillDeadline := shr(224, shl(224, calldataload(add(notFilledDescription.offset, 0x08))))
        }
    }
}

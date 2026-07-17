// SPDX-License-Identifier: MIT
pragma solidity >=0.8.0;

import { MandateOutput } from "../input/types/MandateOutputType.sol";
import { OrderPurchase } from "../input/types/OrderPurchaseType.sol";
import { StandardOrder } from "../input/types/StandardOrderType.sol";

import { InputSettlerBase } from "../input/InputSettlerBase.sol";

interface IInputSettlerEscrow {
    function openFor(
        StandardOrder calldata order,
        address sponsor,
        bytes calldata signature
    ) external payable;

    function open(
        StandardOrder calldata order
    ) external payable;

    function finalise(
        StandardOrder calldata order,
        InputSettlerBase.SolveParams[] calldata solveParams,
        bytes32 destination,
        bytes calldata call
    ) external;

    function finaliseWithSignature(
        StandardOrder calldata order,
        InputSettlerBase.SolveParams[] calldata solveParams,
        bytes32 destination,
        bytes calldata call,
        bytes calldata orderOwnerSignature
    ) external;

    /**
     * @notice Refunds an order that has not been finalised before it expired. This order may have been filled but
     * finalise has not been called yet.
     * @param order StandardOrder description of the intent.
     */
    function refund(
        StandardOrder calldata order
    ) external;

    /**
     * @notice Refunds an order as soon as any one of its outputs is proven not filled before the order's fill
     * deadline — without waiting for `order.expires`. The time-based `refund` remains available as the backstop.
     * @param order StandardOrder description of the intent.
     * @param outputIndex Index of the output proven not filled.
     */
    function refundOnNonFill(
        StandardOrder calldata order,
        uint256 outputIndex
    ) external;

    function orderIdentifier(
        StandardOrder memory order
    ) external view returns (bytes32);

    function purchaseOrder(
        OrderPurchase memory orderPurchase,
        StandardOrder memory order,
        bytes32 orderSolvedByIdentifier,
        bytes32 purchaser,
        uint256 expiryTimestamp,
        bytes memory solverSignature
    ) external;
}

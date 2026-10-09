// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

import { IERC165 } from "openzeppelin/utils/introspection/IERC165.sol";

import { Client } from "./Client.sol";
import { IAny2EVMMessageReceiver } from "./interfaces/IAny2EVMMessageReceiver.sol";

/**
 * @title CCIPReceiver - Base contract for CCIP applications that can receive messages.
 * @dev Copied from Chainlink CCIP contracts-ccip-v2.0.0 (commit c2c125c27f056db2e98d21501922b6eff5750f36) on
 * 2026-10-09:
 * https://github.com/smartcontractkit/chainlink-ccip/blob/c2c125c27f056db2e98d21501922b6eff5750f36/chains/evm/contracts/applications/CCIPReceiver.sol
 * Modifications:
 * - Removed IAny2EVMMessageReceiverV2 and getCCVsAndFinalityConfig. A v2.0 OffRamp applies the default CCV and
 *   requires source finality for receivers without that interface, which is what the upstream default returns.
 * - `_ccipReceive` takes the message as calldata instead of memory.
 */
abstract contract CCIPReceiver is IAny2EVMMessageReceiver, IERC165 {
    address internal immutable i_ccipRouter;

    constructor(
        address router
    ) {
        if (router == address(0)) revert InvalidRouter(address(0));
        i_ccipRouter = router;
    }

    /// @notice IERC165 supports an interfaceId.
    /// @param interfaceId The interfaceId to check.
    /// @return true if the interfaceId is supported.
    /// @dev Should indicate whether the contract implements IAny2EVMMessageReceiver.
    /// This allows CCIP to check if ccipReceive is available before calling it.
    /// - If this returns false or reverts, only tokens are transferred to the receiver.
    /// - If this returns true, tokens are transferred and ccipReceive is called atomically.
    /// Additionally, if the receiver address does not have code associated with it at the time of
    /// execution (EXTCODESIZE returns 0), only tokens will be transferred.
    function supportsInterface(
        bytes4 interfaceId
    ) public pure virtual override returns (bool) {
        return interfaceId == type(IAny2EVMMessageReceiver).interfaceId || interfaceId == type(IERC165).interfaceId;
    }

    /// @inheritdoc IAny2EVMMessageReceiver
    function ccipReceive(
        Client.Any2EVMMessage calldata message
    ) external virtual override onlyRouter {
        _ccipReceive(message);
    }

    /// @notice Override this function in your implementation.
    /// @param message Any2EVMMessage.
    function _ccipReceive(
        Client.Any2EVMMessage calldata message
    ) internal virtual;

    /// @notice Return the current router
    /// @return CCIP router address
    function getRouter() public view virtual returns (address) {
        return address(i_ccipRouter);
    }

    error InvalidRouter(address router);

    /// @dev only calls from the set router are accepted.
    modifier onlyRouter() {
        if (msg.sender != getRouter()) revert InvalidRouter(msg.sender);
        _;
    }
}

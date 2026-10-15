// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { IAttester } from "../../../interfaces/IAttester.sol";
import { LibAddress } from "../../../libs/LibAddress.sol";
import { MessageEncodingLib } from "../../../libs/MessageEncodingLib.sol";
import { BaseInputOracle } from "../../../oracles/BaseInputOracle.sol";
import { ChainMap } from "../../../oracles/ChainMap.sol";
import { AxelarStrings } from "./AxelarStrings.sol";
import { SolanaEnvelope } from "./SolanaEnvelope.sol";

interface IAxelarMessageGateway {
    function callContract(
        string calldata chain,
        string calldata destination,
        bytes calldata payload
    ) external;
    function validateContractCall(
        bytes32 commandId,
        string calldata chain,
        string calldata sender,
        bytes32 hash
    ) external returns (bool);
}

interface IAxelarNativeGasService {
    function payNativeGasForContractCall(
        address sender,
        string calldata chain,
        string calldata destination,
        bytes calldata payload,
        address refund
    ) external payable;
}

/// @title AxelarOracle
/// @notice Transparent Axelar GMP oracle with owner-set, immutable chain maps.
/// @dev The owner maps an Axelar chain to an OIF chain through `ChainMap.setChainMap(key, chainId)`, where `key` is
/// the ASCII-lowercased Axelar name packed left-aligned and zero-padded: `uint256(bytes32(bytes(name)))`. Names are
/// 1–32 bytes without NUL; no other character set is imposed, so `reverseChainIdMap(chainId)` returns the packed
/// name, which `submit` unpacks into the outbound chain name. Axelar currently caps names at 20 bytes.
/// Inbound sender formats (EVM hex, Stellar StrKey, Solana base58) are inferred from the
/// sender string. No Stellar message limits are enforced here; Stellar and Solana destinations enforce their own,
/// so clients split batches to fit.
contract AxelarOracle is BaseInputOracle, ChainMap {
    using LibAddress for address;

    enum DeliveryMode {
        Relayed,
        SelfRelay
    }

    IAxelarMessageGateway public immutable gateway;
    IAxelarNativeGasService public immutable gasService;

    error InvalidConfiguration();
    error NotAllPayloadsValid();
    error NotApproved();
    error InvalidFee();

    constructor(
        address owner_,
        address gateway_,
        address gasService_
    ) ChainMap(owner_) {
        if (gateway_.code.length == 0 || gasService_.code.length == 0) revert InvalidConfiguration();
        gateway = IAxelarMessageGateway(gateway_);
        gasService = IAxelarNativeGasService(gasService_);
    }

    /// @notice Sets an immutable map from a packed lowercase Axelar name to an OIF chain ID.
    /// @dev `protocolChainIdentifier` must be `uint256(bytes32(bytes(name)))` for a 1–32-byte name with no NUL and no
    /// ASCII uppercase; anything else (zero, right-aligned, bytes after a NUL, uppercase) reverts
    /// `AxelarStrings.InvalidChainName`.
    function setChainMap(
        uint256 protocolChainIdentifier,
        uint256 chainId
    ) public override onlyOwner {
        if (AxelarStrings.chainKey(AxelarStrings.chainName(protocolChainIdentifier)) != protocolChainIdentifier) {
            revert AxelarStrings.InvalidChainName();
        }
        super.setChainMap(protocolChainIdentifier, chainId);
    }

    /// @notice Sends attested payloads to the Axelar chain mapped to `destinationChainId`.
    /// @dev `recipientOracle` is passed to Axelar unchecked. A wrong recipient or config loses only that delivery:
    /// export does not consume anything, so anyone can submit again.
    /// @param destinationChainId OIF chain ID of the destination; must be mapped.
    /// @param recipientOracle Destination oracle as an Axelar address string (`0x…`, `C…` StrKey, or base58).
    /// @param source Attester whose payloads are sent.
    /// @param payloads Payloads `source` has attested.
    /// @param destinationConfig Nonzero selects the Solana Borsh envelope with this config; zero sends the raw message.
    /// @param deliveryMode `Relayed` pays `msg.value` to the gas service; `SelfRelay` requires no value.
    function submit(
        uint256 destinationChainId,
        string calldata recipientOracle,
        address source,
        bytes[] calldata payloads,
        bytes32 destinationConfig,
        DeliveryMode deliveryMode
    ) external payable {
        uint256 key = reverseChainIdMap[destinationChainId];
        if (key == 0) revert ZeroValue();
        string memory chain = AxelarStrings.chainName(key);
        if (!IAttester(source).hasAttested(payloads)) revert NotAllPayloadsValid();
        bytes memory message = MessageEncodingLib.encodeMessage(source.toIdentifier(), payloads);
        if (destinationConfig != 0) message = SolanaEnvelope.encode(message, destinationConfig);
        if (deliveryMode == DeliveryMode.Relayed) {
            if (msg.value == 0) revert InvalidFee();
            gasService.payNativeGasForContractCall{ value: msg.value }(
                address(this), chain, recipientOracle, message, msg.sender
            );
        } else if (msg.value != 0) {
            revert InvalidFee();
        }
        gateway.callContract(chain, recipientOracle, message);
    }

    /// @notice Records the payload hashes of a gateway-approved message.
    /// @dev Anyone may execute, but only the gateway can approve the exact destination-bound message. The original
    /// `sourceChain` and `sourceAddress` strings are validated, since Axelar binds the approved spelling.
    function execute(
        bytes32 commandId,
        string calldata sourceChain,
        string calldata sourceAddress,
        bytes calldata payload
    ) external {
        uint256 chainId = _getMappedChainId(AxelarStrings.chainKey(sourceChain));
        bytes32 sender = AxelarStrings.decodeAddress(sourceAddress);
        if (!gateway.validateContractCall(commandId, sourceChain, sourceAddress, keccak256(payload))) {
            revert NotApproved();
        }
        (bytes32 application, bytes32[] memory hashes) = MessageEncodingLib.getHashesOfEncodedPayloads(payload);
        for (uint256 i; i < hashes.length; ++i) {
            _attestations[chainId][sender][application][hashes[i]] = true;
            emit OutputProven(chainId, sender, application, hashes[i]);
        }
    }
}

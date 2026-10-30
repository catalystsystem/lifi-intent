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
/// the ASCII-lowercased Axelar name packed left-aligned and zero-padded: `uint256(bytes32(bytes(name)))`. The setter
/// accepts only names Axelar can route (1–20 ASCII bytes without NUL or `_`). Lowercase names are used only for
/// internal mapping lookup; `submit` forwards the caller's outbound spelling unchanged to Axelar.
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

    /// @dev Axelar `ChainNameRaw::MAX_LEN`: the longest chain name Axelar routes.
    uint256 private constant MAX_CHAIN_NAME = 20;

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
    /// @dev `protocolChainIdentifier` must be `uint256(bytes32(bytes(name)))` for a name Axelar's `ChainNameRaw`
    /// accepts (1–20 bytes, ASCII only, no `_`), with no NUL and no ASCII uppercase. Anything else (zero,
    /// right-aligned, bytes after a NUL, uppercase, too long, non-ASCII, `_`) reverts `AxelarStrings.InvalidChainName`:
    /// the map is set-once, so a name Axelar cannot route would permanently consume `chainId`.
    function setChainMap(
        uint256 protocolChainIdentifier,
        uint256 chainId
    ) public override onlyOwner {
        bytes memory name = bytes(AxelarStrings.chainName(protocolChainIdentifier));
        if (AxelarStrings.chainKey(string(name)) != protocolChainIdentifier) revert AxelarStrings.InvalidChainName();
        if (name.length > MAX_CHAIN_NAME) revert AxelarStrings.InvalidChainName();
        for (uint256 i; i < name.length; ++i) {
            if (name[i] >= 0x80 || name[i] == "_") revert AxelarStrings.InvalidChainName();
        }
        super.setChainMap(protocolChainIdentifier, chainId);
    }

    /// @notice Sends attested payloads to a configured Axelar destination chain.
    /// @dev The destination is ASCII-lowercased only for mapping lookup. The caller must supply the exact Axelar
    /// chain name: its original spelling is sent unchanged to both the gas service and gateway.
    /// `recipientOracle` is passed to Axelar unchecked. A wrong chain spelling, recipient or config loses only that
    /// delivery: export does not consume anything, so anyone can submit again.
    /// @param destinationChain Exact Axelar destination name; its lowercase key must be mapped.
    /// @param recipientOracle Destination oracle as an Axelar address string (`0x…`, `C…` StrKey, or base58).
    /// @param source Attester whose payloads are sent.
    /// @param payloads Payloads `source` has attested.
    /// @param destinationConfig Nonzero selects the Solana Borsh envelope with this config; zero sends the raw message.
    /// @param deliveryMode `Relayed` pays `msg.value` to the gas service; `SelfRelay` requires no value.
    function submit(
        string calldata destinationChain,
        string calldata recipientOracle,
        address source,
        bytes[] calldata payloads,
        bytes32 destinationConfig,
        DeliveryMode deliveryMode
    ) external payable {
        _getMappedChainId(AxelarStrings.chainKey(destinationChain));
        if (!IAttester(source).hasAttested(payloads)) revert NotAllPayloadsValid();
        bytes memory message = MessageEncodingLib.encodeMessage(source.toIdentifier(), payloads);
        if (destinationConfig != 0) message = SolanaEnvelope.encode(message, destinationConfig);
        if (deliveryMode == DeliveryMode.Relayed) {
            if (msg.value == 0) revert InvalidFee();
            gasService.payNativeGasForContractCall{ value: msg.value }(
                address(this), destinationChain, recipientOracle, message, msg.sender
            );
        } else if (msg.value != 0) {
            revert InvalidFee();
        }
        gateway.callContract(destinationChain, recipientOracle, message);
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

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { BoundedOracle } from "../common/BoundedOracle.sol";
import { OracleAddress } from "../common/OracleAddress.sol";
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

/// Transparent, immutable Axelar GMP oracle. Based on OIF PR #137; supports Stellar sender identities.
contract AxelarOracle is BoundedOracle {
    enum DeliveryMode {
        Relayed,
        SelfRelay
    }

    struct Chain {
        string name;
        uint256 chainId;
        OracleAddress.Kind kind;
    }

    struct Route {
        uint256 chainId;
        OracleAddress.Kind kind;
    }
    IAxelarMessageGateway public immutable gateway;
    IAxelarNativeGasService public immutable gasService;
    mapping(bytes32 => Route) private routes;
    /// Permissionless memo of canonical Solana base58 decodings: keccak256(address string) => raw ID.
    mapping(bytes32 => bytes32) public solanaAddresses;
    error NotApproved();
    error InvalidFee();
    event SolanaAddressCached(bytes32 indexed id, string value);

    constructor(
        address gateway_,
        address gasService_,
        Chain[] memory chains
    ) {
        if (gateway_.code.length == 0 || gasService_.code.length == 0 || chains.length == 0 || chains.length > 16) {
            revert InvalidConfiguration();
        }
        gateway = IAxelarMessageGateway(gateway_);
        gasService = IAxelarNativeGasService(gasService_);
        for (uint256 i; i < chains.length; ++i) {
            Chain memory c = chains[i];
            bytes32 key = keccak256(bytes(c.name));
            if (bytes(c.name).length == 0 || bytes(c.name).length > 64 || c.chainId == 0 || routes[key].chainId != 0) {
                revert InvalidConfiguration();
            }
            for (uint256 j; j < i; ++j) {
                if (chains[j].chainId == c.chainId) revert InvalidConfiguration();
            }
            routes[key] = Route(c.chainId, c.kind);
        }
    }

    function route(
        string calldata name
    ) public view returns (Route memory r) {
        r = routes[keccak256(bytes(name))];
        if (r.chainId == 0) revert UnknownChain();
    }

    function submit(
        string calldata destinationChain,
        bytes32 recipientOracle,
        address source,
        bytes[] calldata payloads,
        bytes32 destinationConfig,
        DeliveryMode deliveryMode
    ) external payable {
        Route memory r = route(destinationChain);
        string memory recipient = OracleAddress.encode(recipientOracle, r.kind);
        bytes memory message = _export(source, payloads);
        if (r.kind == OracleAddress.Kind.Solana) message = SolanaEnvelope.encode(message, destinationConfig);
        else if (destinationConfig != 0) revert InvalidConfiguration();
        if (deliveryMode == DeliveryMode.Relayed) {
            if (msg.value == 0) revert InvalidFee();
            gasService.payNativeGasForContractCall{ value: msg.value }(
                address(this), destinationChain, recipient, message, msg.sender
            );
        } else if (msg.value != 0) {
            revert InvalidFee();
        }
        gateway.callContract(destinationChain, recipient, message);
    }

    /// Decode a canonical Solana base58 address once (~0.7M gas) and memoize it, so every later
    /// `execute` from that sender reads one slot instead of decoding. Anyone may pay for this:
    /// the entry is exactly what `OracleAddress.decode` returns, so caching never changes results.
    function cacheSolanaAddress(
        string calldata value
    ) external returns (bytes32 id) {
        id = OracleAddress.decode(value, OracleAddress.Kind.Solana);
        solanaAddresses[keccak256(bytes(value))] = id;
        emit SolanaAddressCached(id, value);
    }

    /// Anyone may execute, but only the gateway can approve the exact destination-bound message.
    function execute(
        bytes32 commandId,
        string calldata sourceChain,
        string calldata sourceAddress,
        bytes calldata payload
    ) external {
        Route memory r = route(sourceChain);
        bytes32 sender = r.kind == OracleAddress.Kind.Solana
            ? _solanaSender(sourceAddress)
            : OracleAddress.decode(sourceAddress, r.kind);
        if (!gateway.validateContractCall(commandId, sourceChain, sourceAddress, keccak256(payload))) {
            revert NotApproved();
        }
        _record(r.chainId, sender, payload);
    }

    /// Cached decoding when present; the all-zero ID is never distinguishable from absent, so it
    /// always takes the full decode.
    function _solanaSender(
        string calldata value
    ) private view returns (bytes32 id) {
        id = solanaAddresses[keccak256(bytes(value))];
        if (id == 0) id = OracleAddress.decode(value, OracleAddress.Kind.Solana);
    }
}

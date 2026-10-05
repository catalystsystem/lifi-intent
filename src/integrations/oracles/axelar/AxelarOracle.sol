// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { MappedOracle } from "../common/MappedOracle.sol";
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

/// Transparent Axelar GMP oracle with owner-set immutable chain maps (ChainMap conventions keyed by lowercase
/// Axelar name); supports Stellar and Solana sender identities.
contract AxelarOracle is MappedOracle {
    enum DeliveryMode { Relayed, SelfRelay }

    struct Route {
        uint256 chainId;
        OracleAddress.Kind kind;
    }

    /// Axelar ChainNameRaw::MAX_LEN.
    uint256 public constant MAX_CHAIN_NAME = 20;
    IAxelarMessageGateway public immutable gateway;
    IAxelarNativeGasService public immutable gasService;
    mapping(bytes32 nameKey => OracleAddress.Kind) private kinds;

    error NotApproved();
    error InvalidFee();

    event ChainMapConfigured(string name, uint256 chainId, OracleAddress.Kind kind);

    constructor(
        address owner_,
        address gateway_,
        address gasService_
    ) MappedOracle(owner_) {
        if (gateway_.code.length == 0 || gasService_.code.length == 0) revert InvalidConfiguration();
        gateway = IAxelarMessageGateway(gateway_);
        gasService = IAxelarNativeGasService(gasService_);
    }

    /// Set an immutable map from a lowercase Axelar name to an OIF chain. Each name and chain ID is set once.
    function setChainMap(
        string calldata name,
        uint256 chainId,
        OracleAddress.Kind kind
    ) external onlyOwner {
        bytes calldata b = bytes(name);
        if (b.length == 0 || b.length > MAX_CHAIN_NAME) revert InvalidConfiguration();
        for (uint256 i; i < b.length; ++i) {
            bytes1 c = b[i];
            if (!((c >= "a" && c <= "z") || (c >= "0" && c <= "9") || c == "-")) revert InvalidConfiguration();
        }
        bytes32 key = keccak256(b);
        _setRoute(key, chainId);
        kinds[key] = kind;
        emit ChainMapConfigured(name, chainId, kind);
    }

    function route(
        string calldata name
    ) public view returns (Route memory r) {
        (, r) = _route(name);
    }

    /// Lowercased canonical name and its map; Axelar names are unique after ASCII lowercasing.
    function _route(
        string calldata name
    ) internal view returns (string memory canonical, Route memory r) {
        bytes memory b = bytes(name);
        if (b.length == 0 || b.length > MAX_CHAIN_NAME) revert UnknownChain();
        for (uint256 i; i < b.length; ++i) {
            if (b[i] >= 0x41 && b[i] <= 0x5a) b[i] = bytes1(uint8(b[i]) + 32);
        }
        bytes32 key = keccak256(b);
        r = Route(_chainId(key), kinds[key]);
        canonical = string(b);
    }

    function submit(
        string calldata destinationChain,
        bytes32 recipientOracle,
        address source,
        bytes[] calldata payloads,
        bytes32 destinationConfig,
        DeliveryMode deliveryMode
    ) external payable {
        (string memory chain, Route memory r) = _route(destinationChain);
        string memory recipient = OracleAddress.encode(recipientOracle, r.kind);
        bytes memory message = _export(source, payloads);
        if (r.kind == OracleAddress.Kind.Solana) {
            message = SolanaEnvelope.encode(message, destinationConfig);
        } else if (destinationConfig != 0) revert InvalidConfiguration();
        if (deliveryMode == DeliveryMode.Relayed) {
            if (msg.value == 0) revert InvalidFee();
            gasService.payNativeGasForContractCall{ value: msg.value }(
                address(this), chain, recipient, message, msg.sender
            );
        } else if (msg.value != 0) revert InvalidFee();
        gateway.callContract(chain, recipient, message);
    }

    /// Anyone may execute, but only the gateway can approve the exact destination-bound message.
    function execute(
        bytes32 commandId,
        string calldata sourceChain,
        string calldata sourceAddress,
        bytes calldata payload
    ) external {
        (, Route memory r) = _route(sourceChain);
        bytes32 sender = OracleAddress.decode(sourceAddress, r.kind);
        if (!gateway.validateContractCall(commandId, sourceChain, sourceAddress, keccak256(payload))) {
            revert NotApproved();
        }
        _record(r.chainId, sender, payload);
    }
}

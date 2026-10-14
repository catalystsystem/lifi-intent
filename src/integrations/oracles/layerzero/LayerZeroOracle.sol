// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { IAttester } from "../../../interfaces/IAttester.sol";
import { LibAddress } from "../../../libs/LibAddress.sol";
import { MessageEncodingLib } from "../../../libs/MessageEncodingLib.sol";
import { BaseInputOracle } from "../../../oracles/BaseInputOracle.sol";
import { ChainMap } from "../../../oracles/ChainMap.sol";

struct Origin {
    uint32 srcEid;
    bytes32 sender;
    uint64 nonce;
}

struct MessagingFee {
    uint256 nativeFee;
    uint256 lzTokenFee;
}

struct MessagingReceipt {
    bytes32 guid;
    uint64 nonce;
    MessagingFee fee;
}

struct MessagingParams {
    uint32 dstEid;
    bytes32 receiver;
    bytes message;
    bytes options;
    bool payInLzToken;
}

struct SetConfigParam {
    uint32 eid;
    uint32 configType;
    bytes config;
}

interface IOracleEndpointV2 {
    function quote(
        MessagingParams calldata params,
        address sender
    ) external view returns (MessagingFee memory);
    function send(
        MessagingParams calldata params,
        address refundAddress
    ) external payable returns (MessagingReceipt memory);
    function setSendLibrary(
        address oapp,
        uint32 eid,
        address lib
    ) external;
    function setReceiveLibrary(
        address oapp,
        uint32 eid,
        address lib,
        uint256 gracePeriod
    ) external;
    function setConfig(
        address oapp,
        address lib,
        SetConfigParam[] calldata params
    ) external;
}

/// @title LayerZeroOracle
/// @notice Transparent LayerZero V2 OApp: the authenticated `Origin.sender` is recorded as the proving oracle, never
/// replaced by a configured peer.
/// @dev The owner maps a LayerZero endpoint ID to an OIF chain through `setChainMap(eid, chainId, security)`, with
/// `ChainMap` key `uint256(eid)`. Each map is set once and pins that route's libraries, executor and DVN configuration
/// in the same call, so a path never runs on the endpoint's mutable defaults. The plain `ChainMap.setChainMap` is
/// disabled. Paths open (`allowInitializePath`) only for mapped endpoint IDs, and only mapped destinations can be sent
/// to. No Stellar message limits are enforced here beyond each route's executor `maxMessageSize`; destinations enforce
/// their own, so clients split batches to fit.
contract LayerZeroOracle is BaseInputOracle, ChainMap {
    using LibAddress for address;

    struct UlnConfig {
        uint64 confirmations;
        uint8 requiredDVNCount;
        uint8 optionalDVNCount;
        uint8 optionalDVNThreshold;
        address[] requiredDVNs;
        address[] optionalDVNs;
    }

    struct ExecutorConfig {
        uint32 maxMessageSize;
        address executor;
    }

    /// @param sendLibrary Send message library pinned for the route.
    /// @param receiveLibrary Receive message library pinned for the route (no grace period).
    /// @param executor Executor pinned for the route.
    /// @param maxMessageSize Largest message the route sends; nonzero, so the library default is never inherited.
    /// @param sendConfirmations Block confirmations required on send; not 0 or NIL (`type(uint64).max`).
    /// @param receiveConfirmations Block confirmations required on receive; not 0 or NIL.
    /// @param sendDvns Required send DVNs, strictly ascending, 1–127. Optional DVNs are disabled.
    /// @param receiveDvns Required receive DVNs, strictly ascending, 1–127. Optional DVNs are disabled.
    struct Security {
        address sendLibrary;
        address receiveLibrary;
        address executor;
        uint32 maxMessageSize;
        uint64 sendConfirmations;
        uint64 receiveConfirmations;
        address[] sendDvns;
        address[] receiveDvns;
    }

    IOracleEndpointV2 public immutable endpoint;

    error InvalidConfiguration();
    error SecurityRequired();
    error NotAllPayloadsValid();
    error OnlyEndpoint();
    error UnexpectedValue();
    error InvalidOptions();

    constructor(
        address owner_,
        address endpoint_
    ) ChainMap(owner_) {
        if (endpoint_.code.length == 0) revert InvalidConfiguration();
        endpoint = IOracleEndpointV2(endpoint_);
    }

    /// @notice Disabled: a route must pin its security configuration when it is mapped.
    /// @dev Use `setChainMap(eid, chainId, security)`.
    function setChainMap(
        uint256,
        uint256
    ) public pure override {
        revert SecurityRequired();
    }

    /// @notice Sets an immutable map from a LayerZero endpoint ID to an OIF chain ID and pins the route's security
    /// configuration on the endpoint. Paths to and from `eid` open only after this call.
    /// @dev Each endpoint ID and chain ID is set once (`ChainMap.AlreadySet`); zero values revert `ChainMap.ZeroValue`.
    /// @param eid LayerZero endpoint ID; must fit `uint32`.
    /// @param chainId OIF chain ID.
    /// @param s Route security configuration.
    function setChainMap(
        uint256 eid,
        uint256 chainId,
        Security calldata s
    ) external onlyOwner {
        if (eid > type(uint32).max) revert InvalidConfiguration();
        if (
            s.executor == address(0) || s.sendLibrary == address(0) || s.receiveLibrary == address(0)
                || s.maxMessageSize == 0
        ) revert InvalidConfiguration();
        super.setChainMap(eid, chainId);
        // forge-lint: disable-next-line(unsafe-typecast)
        uint32 id = uint32(eid); // Checked above.
        endpoint.setSendLibrary(address(this), id, s.sendLibrary);
        endpoint.setReceiveLibrary(address(this), id, s.receiveLibrary, 0);
        SetConfigParam[] memory sendConfig = new SetConfigParam[](2);
        sendConfig[0] = SetConfigParam(id, 1, abi.encode(ExecutorConfig(s.maxMessageSize, s.executor)));
        sendConfig[1] = SetConfigParam(id, 2, _uln(s.sendConfirmations, s.sendDvns));
        endpoint.setConfig(address(this), s.sendLibrary, sendConfig);
        SetConfigParam[] memory receiveConfig = new SetConfigParam[](1);
        receiveConfig[0] = SetConfigParam(id, 2, _uln(s.receiveConfirmations, s.receiveDvns));
        endpoint.setConfig(address(this), s.receiveLibrary, receiveConfig);
    }

    function _uln(
        uint64 confirmations,
        address[] memory dvns
    ) private pure returns (bytes memory) {
        // UlnBase reads type(uint64).max (NIL_CONFIRMATIONS) in an OApp config as literal zero confirmations.
        if (confirmations == 0 || confirmations == type(uint64).max || dvns.length == 0 || dvns.length > 127) {
            revert InvalidConfiguration();
        }
        address previous;
        for (uint256 i; i < dvns.length; ++i) {
            if (dvns[i] <= previous) revert InvalidConfiguration();
            previous = dvns[i];
        }
        // NIL_DVN_COUNT explicitly disables optional DVNs rather than inheriting a mutable default.
        return abi.encode(UlnConfig(confirmations, uint8(dvns.length), 255, 0, dvns, new address[](0)));
    }

    /// @notice Quotes `submit` for the same arguments. Does not check that `source` attested the payloads.
    function quote(
        uint32 dstEid,
        bytes32 recipientOracle,
        address source,
        bytes[] calldata payloads,
        bytes calldata options
    ) external view returns (MessagingFee memory) {
        _checkDestination(dstEid, options);
        bytes memory message = MessageEncodingLib.encodeMessage(source.toIdentifier(), payloads);
        return endpoint.quote(MessagingParams(dstEid, recipientOracle, message, options, false), address(this));
    }

    /// @notice Sends attested payloads to the oracle `recipientOracle` on the mapped endpoint `dstEid`.
    /// @dev Unmapped destinations revert `ChainMap.ZeroValue`. Excess `msg.value` is refunded to the caller by the
    /// endpoint.
    function submit(
        uint32 dstEid,
        bytes32 recipientOracle,
        address source,
        bytes[] calldata payloads,
        bytes calldata options
    ) external payable returns (MessagingReceipt memory) {
        _checkDestination(dstEid, options);
        if (!IAttester(source).hasAttested(payloads)) revert NotAllPayloadsValid();
        bytes memory message = MessageEncodingLib.encodeMessage(source.toIdentifier(), payloads);
        return endpoint.send{ value: msg.value }(
            MessagingParams(dstEid, recipientOracle, message, options, false), msg.sender
        );
    }

    function _checkDestination(
        uint32 eid,
        bytes calldata options
    ) private view {
        _getMappedChainId(eid);
        _checkOptions(options);
    }

    /// A single Type-3 lzReceive option, positive gas, zero receiver value. No compose/drop/ordered options.
    function _checkOptions(
        bytes calldata options
    ) private pure {
        if (options.length != 22 || bytes6(options[:6]) != hex"000301001101" || uint128(bytes16(options[6:22])) == 0) {
            revert InvalidOptions();
        }
    }

    function allowInitializePath(
        Origin calldata origin
    ) external view returns (bool) {
        return chainIdMap[origin.srcEid] != 0;
    }

    function nextNonce(
        uint32,
        bytes32
    ) external pure returns (uint64) {
        return 0;
    }

    function oAppVersion() external pure returns (uint64, uint64) {
        return (1, 1);
    }

    /// @notice Records the payload hashes of an endpoint-verified message under its authenticated origin.
    function lzReceive(
        Origin calldata origin,
        bytes32,
        bytes calldata message,
        address,
        bytes calldata
    ) external payable {
        if (msg.sender != address(endpoint)) revert OnlyEndpoint();
        if (msg.value != 0) revert UnexpectedValue();
        uint256 chainId = _getMappedChainId(origin.srcEid);
        (bytes32 application, bytes32[] memory hashes) = MessageEncodingLib.getHashesOfEncodedPayloads(message);
        for (uint256 i; i < hashes.length; ++i) {
            _attestations[chainId][origin.sender][application][hashes[i]] = true;
            emit OutputProven(chainId, origin.sender, application, hashes[i]);
        }
    }
}

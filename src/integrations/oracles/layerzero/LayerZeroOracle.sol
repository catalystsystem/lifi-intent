// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { MappedOracle } from "../common/MappedOracle.sol";

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

/// Transparent OApp: authenticated Origin.sender is preserved, never replaced by a configured peer. The owner adds
/// set-once routes; each route pins its own libraries, executor and DVN configuration when it is added.
contract LayerZeroOracle is MappedOracle {
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

    struct Security {
        address sendLibrary;
        address receiveLibrary;
        address executor;
        uint64 sendConfirmations;
        uint64 receiveConfirmations;
        address[] sendDvns;
        address[] receiveDvns;
    }

    IOracleEndpointV2 public immutable endpoint;

    error OnlyEndpoint();
    error UnexpectedValue();
    error InvalidOptions();

    event ChainMapConfigured(uint32 eid, uint256 chainId);

    constructor(
        address owner_,
        address endpoint_
    ) MappedOracle(owner_) {
        if (endpoint_.code.length == 0) revert InvalidConfiguration();
        endpoint = IOracleEndpointV2(endpoint_);
    }

    /// Set an immutable map from a LayerZero endpoint ID to an OIF chain and pin the route's security configuration.
    /// Each endpoint ID and chain ID is set once; paths open only after this call.
    function setChainMap(
        uint32 eid,
        uint256 chainId,
        Security calldata s
    ) external onlyOwner {
        if (eid == 0) revert ZeroValue();
        if (s.executor == address(0) || s.sendLibrary == address(0) || s.receiveLibrary == address(0)) {
            revert InvalidConfiguration();
        }
        _setRoute(_key(eid), chainId);
        endpoint.setSendLibrary(address(this), eid, s.sendLibrary);
        endpoint.setReceiveLibrary(address(this), eid, s.receiveLibrary, 0);
        SetConfigParam[] memory sendConfig = new SetConfigParam[](2);
        sendConfig[0] = SetConfigParam(eid, 1, abi.encode(ExecutorConfig(uint32(MAX_MESSAGE), s.executor)));
        sendConfig[1] = SetConfigParam(eid, 2, _uln(s.sendConfirmations, s.sendDvns));
        endpoint.setConfig(address(this), s.sendLibrary, sendConfig);
        SetConfigParam[] memory receiveConfig = new SetConfigParam[](1);
        receiveConfig[0] = SetConfigParam(eid, 2, _uln(s.receiveConfirmations, s.receiveDvns));
        endpoint.setConfig(address(this), s.receiveLibrary, receiveConfig);
        emit ChainMapConfigured(eid, chainId);
    }

    function route(
        uint32 eid
    ) external view returns (uint256) {
        return _chainId(_key(eid));
    }

    function _key(
        uint32 eid
    ) private pure returns (bytes32) {
        return bytes32(uint256(eid));
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

    function quote(
        uint32 dstEid,
        bytes32 recipientOracle,
        address source,
        bytes[] calldata payloads,
        bytes calldata options
    ) external view returns (MessagingFee memory) {
        _checkDestination(dstEid, options);
        return endpoint.quote(
            MessagingParams(dstEid, recipientOracle, _encode(source, payloads), options, false), address(this)
        );
    }

    function submit(
        uint32 dstEid,
        bytes32 recipientOracle,
        address source,
        bytes[] calldata payloads,
        bytes calldata options
    ) external payable returns (MessagingReceipt memory) {
        _checkDestination(dstEid, options);
        return endpoint.send{ value: msg.value }(
            MessagingParams(dstEid, recipientOracle, _export(source, payloads), options, false), msg.sender
        );
    }

    function _checkDestination(
        uint32 eid,
        bytes calldata options
    ) private view {
        _chainId(_key(eid));
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
        return _chainIds[_key(origin.srcEid)] != 0;
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

    function lzReceive(
        Origin calldata origin,
        bytes32,
        bytes calldata message,
        address,
        bytes calldata
    ) external payable {
        if (msg.sender != address(endpoint)) revert OnlyEndpoint();
        if (msg.value != 0) revert UnexpectedValue();
        uint256 chain = _chainId(_key(origin.srcEid));
        _record(chain, origin.sender, message);
    }
}

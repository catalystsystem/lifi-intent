// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { BoundedOracle } from "../common/BoundedOracle.sol";

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

/// Transparent OApp: authenticated Origin.sender is preserved, never replaced by a configured peer.
contract LayerZeroOracle is BoundedOracle {
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

    struct Chain {
        uint32 eid;
        uint256 chainId;
        address sendLibrary;
        address receiveLibrary;
        address executor;
        uint64 sendConfirmations;
        uint64 receiveConfirmations;
        address[] sendDvns;
        address[] receiveDvns;
    }
    IOracleEndpointV2 public immutable endpoint;
    mapping(uint32 => uint256) public chainIds;
    error OnlyEndpoint();
    error UnexpectedValue();

    constructor(
        address endpoint_,
        Chain[] memory chains
    ) {
        if (endpoint_.code.length == 0 || chains.length == 0 || chains.length > 16) revert InvalidConfiguration();
        endpoint = IOracleEndpointV2(endpoint_);
        for (uint256 i; i < chains.length; ++i) {
            Chain memory c = chains[i];
            if (
                c.eid == 0 || c.chainId == 0 || chainIds[c.eid] != 0 || c.executor == address(0)
                    || c.sendLibrary == address(0) || c.receiveLibrary == address(0)
            ) revert InvalidConfiguration();
            for (uint256 j; j < i; ++j) {
                if (chains[j].chainId == c.chainId) revert InvalidConfiguration();
            }
            chainIds[c.eid] = c.chainId;
            endpoint.setSendLibrary(address(this), c.eid, c.sendLibrary);
            endpoint.setReceiveLibrary(address(this), c.eid, c.receiveLibrary, 0);
            SetConfigParam[] memory sendConfig = new SetConfigParam[](2);
            sendConfig[0] = SetConfigParam(c.eid, 1, abi.encode(ExecutorConfig(uint32(MAX_MESSAGE), c.executor)));
            sendConfig[1] = SetConfigParam(c.eid, 2, _uln(c.sendConfirmations, c.sendDvns));
            endpoint.setConfig(address(this), c.sendLibrary, sendConfig);
            SetConfigParam[] memory receiveConfig = new SetConfigParam[](1);
            receiveConfig[0] = SetConfigParam(c.eid, 2, _uln(c.receiveConfirmations, c.receiveDvns));
            endpoint.setConfig(address(this), c.receiveLibrary, receiveConfig);
        }
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
        if (chainIds[eid] == 0) revert UnknownChain();
        _checkOptions(options);
    }

    function allowInitializePath(
        Origin calldata origin
    ) external view returns (bool) {
        return chainIds[origin.srcEid] != 0;
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
        uint256 chain = chainIds[origin.srcEid];
        if (chain == 0) revert UnknownChain();
        _record(chain, origin.sender, message);
    }
}

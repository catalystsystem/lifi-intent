// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { Test, Vm } from "forge-std/Test.sol";

import { MandateOutput } from "../../../src/input/types/MandateOutputType.sol";
import { LibAddress } from "../../../src/libs/LibAddress.sol";
import { MessageEncodingLib } from "../../../src/libs/MessageEncodingLib.sol";
import { BaseInputOracle } from "../../../src/oracles/BaseInputOracle.sol";
import { ChainMap } from "../../../src/oracles/ChainMap.sol";
import { OutputSettlerSimple } from "../../../src/output/simple/OutputSettlerSimple.sol";
import { MockERC20 } from "../../mocks/MockERC20.sol";
import { RefEncodingLib } from "test/util/RefEncodingLib.sol";

import { ChainlinkCCIPOracle } from "../../../src/integrations/oracles/chainlink/ChainlinkCCIPOracle.sol";
import { CCIPReceiver } from "../../../src/integrations/oracles/chainlink/external/CCIPReceiver.sol";
import { Client } from "../../../src/integrations/oracles/chainlink/external/Client.sol";
import {
    IAny2EVMMessageReceiver
} from "../../../src/integrations/oracles/chainlink/external/interfaces/IAny2EVMMessageReceiver.sol";
import { IRouterClient } from "../../../src/integrations/oracles/chainlink/external/interfaces/IRouterClient.sol";

/// @dev Charges fees like the CCIP router: native fees keep all of msg.value, token fees pull exactly the quoted fee.
contract RouterMock is IRouterClient {
    event MessageSent(uint64 destinationChainSelector, Client.EVM2AnyMessage message);

    uint256 public immutable fee;

    constructor(
        uint256 fee_
    ) {
        fee = fee_;
    }

    function getFee(
        uint64,
        Client.EVM2AnyMessage memory
    ) external view returns (uint256) {
        return fee;
    }

    function ccipSend(
        uint64 destinationChainSelector,
        Client.EVM2AnyMessage calldata message
    ) external payable returns (bytes32) {
        if (message.feeToken == address(0)) {
            if (msg.value < fee) revert InsufficientFeeTokenAmount();
        } else {
            if (msg.value > 0) revert InvalidMsgValue();
            MockERC20(message.feeToken).transferFrom(msg.sender, address(this), fee);
        }
        emit MessageSent(destinationChainSelector, message);
        return keccak256(abi.encode(destinationChainSelector, message));
    }
}

contract ChainlinkCCIPOracleTest is Test {
    using LibAddress for address;

    uint64 constant DESTINATION_SELECTOR = 15971525489660198786; // Base
    uint64 constant SOURCE_SELECTOR = 5009297550715157269; // Ethereum
    uint256 constant SOURCE_CHAIN_ID = 1;
    uint256 constant FEE = 0.01 ether;
    /// @dev GenericExtraArgsV2 { gasLimit: 300_000, allowOutOfOrderExecution: true }.
    bytes constant EXTRA_ARGS = hex"181dcf10" hex"00000000000000000000000000000000000000000000000000000000000493e0"
        hex"0000000000000000000000000000000000000000000000000000000000000001";

    RouterMock internal _router;
    ChainlinkCCIPOracle internal _oracle;
    OutputSettlerSimple internal _outputSettler;
    MockERC20 internal _token;
    MockERC20 internal _feeToken;

    address internal _sender = makeAddr("sender");
    bytes32 internal _recipientOracle = makeAddr("recipientOracle").toIdentifier();

    function setUp() public {
        _router = new RouterMock(FEE);
        _oracle = new ChainlinkCCIPOracle(address(this), address(_router));
        _oracle.setChainMap(SOURCE_SELECTOR, SOURCE_CHAIN_ID);

        _outputSettler = new OutputSettlerSimple();
        _token = new MockERC20("TEST", "TEST", 18);
        _feeToken = new MockERC20("LINK", "LINK", 18);
    }

    /// @dev Fills an output on the output settler and returns its attested fill description.
    function _fill() internal returns (bytes[] memory payloads) {
        return _fillDescription(true);
    }

    /// @dev Returns a fill description, filling the output on the output settler if `filled`.
    function _fillDescription(
        bool filled
    ) internal returns (bytes[] memory payloads) {
        uint256 amount = 1e18;
        address recipient = makeAddr("recipient");
        bytes32 orderId = keccak256("orderId");
        bytes32 solver = keccak256("solver");

        _token.mint(_sender, amount);
        vm.prank(_sender);
        _token.approve(address(_outputSettler), amount);

        MandateOutput memory output = MandateOutput({
            oracle: address(_oracle).toIdentifier(),
            settler: address(_outputSettler).toIdentifier(),
            chainId: block.chainid,
            token: address(_token).toIdentifier(),
            amount: amount,
            recipient: recipient.toIdentifier(),
            callbackData: bytes(""),
            context: bytes("")
        });
        if (filled) {
            vm.prank(_sender);
            _outputSettler.fill(orderId, output, type(uint48).max, abi.encodePacked(solver));
        }

        payloads = new bytes[](1);
        payloads[0] = RefEncodingLib.encodeFillDescriptionMemory(
            solver, orderId, uint32(block.timestamp), output.token, amount, output.recipient, bytes(""), bytes("")
        );
    }

    function encodeMessage(
        bytes32 application,
        bytes[] calldata payloads
    ) external pure returns (bytes memory) {
        return MessageEncodingLib.encodeMessage(application, payloads);
    }

    function _deliver(
        uint64 sourceChainSelector,
        bytes memory sender,
        bytes memory data
    ) internal {
        vm.prank(address(_router));
        _oracle.ccipReceive(
            Client.Any2EVMMessage({
                messageId: keccak256(data),
                sourceChainSelector: sourceChainSelector,
                sender: sender,
                data: data,
                destTokenAmounts: new Client.EVMTokenAmount[](0)
            })
        );
    }

    // --- Submit --- //

    function test_submit_native_refunds_excess() external {
        bytes[] memory payloads = _fill();
        uint256 excess = 1 ether;
        vm.deal(_sender, FEE + excess);

        Client.EVM2AnyMessage memory expected = Client.EVM2AnyMessage({
            receiver: abi.encode(_recipientOracle),
            data: this.encodeMessage(address(_outputSettler).toIdentifier(), payloads),
            tokenAmounts: new Client.EVMTokenAmount[](0),
            feeToken: address(0),
            extraArgs: EXTRA_ARGS
        });
        vm.expectCall(address(_router), FEE, abi.encodeCall(IRouterClient.ccipSend, (DESTINATION_SELECTOR, expected)));

        vm.prank(_sender);
        uint256 refund = _oracle.submit{ value: FEE + excess }(
            DESTINATION_SELECTOR, _recipientOracle, EXTRA_ARGS, address(0), address(_outputSettler), payloads
        );
        vm.snapshotGasLastCall("oracle", "chainlinkCCIPOracleSubmit");

        assertEq(refund, excess);
        assertEq(_sender.balance, excess);
        assertEq(address(_router).balance, FEE);
        assertEq(address(_oracle).balance, 0);
    }

    function test_submit_fee_token_refunds_value() external {
        bytes[] memory payloads = _fill();
        _feeToken.mint(_sender, FEE);
        vm.deal(_sender, 1 ether);
        vm.prank(_sender);
        _feeToken.approve(address(_oracle), FEE);

        Client.EVM2AnyMessage memory expected = Client.EVM2AnyMessage({
            receiver: abi.encode(_recipientOracle),
            data: this.encodeMessage(address(_outputSettler).toIdentifier(), payloads),
            tokenAmounts: new Client.EVMTokenAmount[](0),
            feeToken: address(_feeToken),
            extraArgs: EXTRA_ARGS
        });
        vm.expectCall(address(_router), 0, abi.encodeCall(IRouterClient.ccipSend, (DESTINATION_SELECTOR, expected)));

        vm.prank(_sender);
        uint256 refund = _oracle.submit{ value: 1 ether }(
            DESTINATION_SELECTOR, _recipientOracle, EXTRA_ARGS, address(_feeToken), address(_outputSettler), payloads
        );
        vm.snapshotGasLastCall("oracle", "chainlinkCCIPOracleSubmitFeeToken");

        assertEq(refund, 1 ether);
        assertEq(_sender.balance, 1 ether);
        assertEq(_feeToken.balanceOf(_sender), 0);
        assertEq(_feeToken.balanceOf(address(_router)), FEE);
        assertEq(_feeToken.balanceOf(address(_oracle)), 0);
        assertEq(_feeToken.allowance(address(_oracle), address(_router)), 0);
    }

    function test_submit_reverts_insufficient_fee() external {
        bytes[] memory payloads = _fill();
        vm.deal(_sender, FEE);

        vm.prank(_sender);
        vm.expectRevert(abi.encodeWithSelector(ChainlinkCCIPOracle.InsufficientFee.selector, FEE - 1, FEE));
        _oracle.submit{ value: FEE - 1 }(
            DESTINATION_SELECTOR, _recipientOracle, EXTRA_ARGS, address(0), address(_outputSettler), payloads
        );
    }

    function test_submit_reverts_unattested_payload() external {
        bytes[] memory payloads = _fillDescription(false);

        vm.expectRevert(ChainlinkCCIPOracle.NotAllPayloadsValid.selector);
        _oracle.submit{ value: FEE }(
            DESTINATION_SELECTOR, _recipientOracle, EXTRA_ARGS, address(0), address(_outputSettler), payloads
        );
    }

    function test_submit_reverts_when_refund_fails() external {
        bytes[] memory payloads = _fill();

        // This test contract cannot receive native value.
        vm.expectRevert(ChainlinkCCIPOracle.RefundFailed.selector);
        _oracle.submit{ value: FEE + 1 }(
            DESTINATION_SELECTOR, _recipientOracle, EXTRA_ARGS, address(0), address(_outputSettler), payloads
        );
    }

    // --- Receive --- //

    function test_supports_ccip_receiver_interface() external view {
        assertTrue(_oracle.supportsInterface(type(IAny2EVMMessageReceiver).interfaceId));
    }

    function test_submitted_message_is_proven_on_receive() external {
        bytes[] memory payloads = _fill();
        vm.deal(_sender, FEE);
        vm.recordLogs();
        vm.prank(_sender);
        _oracle.submit{ value: FEE }(
            DESTINATION_SELECTOR, _recipientOracle, EXTRA_ARGS, address(0), address(_outputSettler), payloads
        );
        Vm.Log[] memory logs = vm.getRecordedLogs();
        (, Client.EVM2AnyMessage memory sent) = abi.decode(logs[logs.length - 1].data, (uint64, Client.EVM2AnyMessage));

        // The CCIP sender on an EVM source chain is abi.encode(address).
        bytes memory remoteOracle = abi.encode(makeAddr("remoteOracle"));
        bytes32 application = address(_outputSettler).toIdentifier();
        bytes32 payloadHash = keccak256(payloads[0]);
        assertFalse(_oracle.isProven(SOURCE_CHAIN_ID, bytes32(remoteOracle), application, payloadHash));

        vm.expectEmit(address(_oracle));
        emit BaseInputOracle.OutputProven(SOURCE_CHAIN_ID, bytes32(remoteOracle), application, payloadHash);
        _deliver(SOURCE_SELECTOR, remoteOracle, sent.data);
        vm.snapshotGasLastCall("oracle", "chainlinkCCIPOracleReceive");

        assertTrue(_oracle.isProven(SOURCE_CHAIN_ID, bytes32(remoteOracle), application, payloadHash));
        assertFalse(_oracle.isProven(uint256(SOURCE_SELECTOR), bytes32(remoteOracle), application, payloadHash));
    }

    function test_ccipReceive_reverts_not_router(
        address caller
    ) external {
        vm.assume(caller != address(_router));
        Client.Any2EVMMessage memory message;
        message.sourceChainSelector = SOURCE_SELECTOR;
        message.sender = abi.encode(caller);

        vm.prank(caller);
        vm.expectRevert(abi.encodeWithSelector(CCIPReceiver.InvalidRouter.selector, caller));
        _oracle.ccipReceive(message);
    }

    function test_ccipReceive_reverts_unmapped_selector() external {
        bytes[] memory payloads = new bytes[](1);
        payloads[0] = hex"deadbeef";
        bytes memory data = this.encodeMessage(bytes32(uint256(1)), payloads);

        vm.expectRevert(ChainMap.ZeroValue.selector);
        _deliver(DESTINATION_SELECTOR, abi.encode(address(1)), data);
    }

    function test_ccipReceive_reverts_sender_not_32_bytes(
        bytes calldata sender
    ) external {
        vm.assume(sender.length != 32);
        bytes[] memory payloads = new bytes[](1);
        payloads[0] = hex"deadbeef";
        bytes memory data = this.encodeMessage(bytes32(uint256(1)), payloads);

        vm.expectRevert(abi.encodeWithSelector(ChainlinkCCIPOracle.InvalidSender.selector, sender));
        _deliver(SOURCE_SELECTOR, sender, data);
    }
}

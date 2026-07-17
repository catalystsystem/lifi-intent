// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

// Inline helpers satisfy strict file ownership; sending ETH is the behavior under test.
// forge-lint: disable-start(multi-contract-file, arbitrary-send-eth)

import { InputSettlerBase } from "../../../src/input/InputSettlerBase.sol";
import { InputSettlerEscrow } from "../../../src/input/escrow/InputSettlerEscrow.sol";
import { MandateOutput } from "../../../src/input/types/MandateOutputType.sol";
import { OrderPurchase } from "../../../src/input/types/OrderPurchaseType.sol";
import { StandardOrder } from "../../../src/input/types/StandardOrderType.sol";
import { IInputSettlerEscrow } from "../../../src/interfaces/IInputSettlerEscrow.sol";
import { LibAddress } from "../../../src/libs/LibAddress.sol";

import { InputSettlerEscrowTestBase } from "./InputSettlerEscrow.base.t.sol";

contract RejectsNative {
    function openNative(
        IInputSettlerEscrow settler,
        StandardOrder calldata order
    ) external payable {
        settler.open{ value: msg.value }(order);
    }

    receive() external payable {
        revert("reject ETH");
    }
}

contract NoNativeReceiver { }

contract InputSettlerEscrowNativeTest is InputSettlerEscrowTestBase {
    using LibAddress for address;

    uint256 internal constant NATIVE_AMOUNT = 1 ether;

    function _order(
        address user,
        uint256[2][] memory inputs,
        uint256 nonce
    ) internal view returns (StandardOrder memory order) {
        MandateOutput[] memory outputs = new MandateOutput[](1);
        outputs[0] = MandateOutput({
            settler: address(outputSettlerCoin).toIdentifier(),
            oracle: alwaysYesOracle.toIdentifier(),
            chainId: block.chainid,
            token: address(anotherToken).toIdentifier(),
            amount: 1,
            recipient: swapper.toIdentifier(),
            callbackData: hex"",
            context: hex""
        });
        order = StandardOrder({
            user: user,
            nonce: nonce,
            originChainId: block.chainid,
            expires: type(uint32).max,
            fillDeadline: type(uint32).max - 1,
            inputOracle: alwaysYesOracle,
            inputs: inputs,
            outputs: outputs
        });
    }

    function _nativeOrder(
        address user,
        uint256 amount,
        uint256 nonce
    ) internal view returns (StandardOrder memory order) {
        uint256[2][] memory inputs = new uint256[2][](1);
        // Token id 0 is the source-derived native-input sentinel.
        inputs[0] = [uint256(0), amount];
        return _order(user, inputs, nonce);
    }

    function _solveParams() internal view returns (InputSettlerBase.SolveParams[] memory solveParams) {
        solveParams = new InputSettlerBase.SolveParams[](1);
        solveParams[0] = InputSettlerBase.SolveParams({ solver: solver.toIdentifier(), timestamp: 1 });
    }

    function _openNative(
        StandardOrder memory order,
        uint256 amount
    ) internal {
        vm.deal(swapper, amount);
        vm.prank(swapper);
        IInputSettlerEscrow(inputSettlerEscrow).open{ value: amount }(order);
    }

    function test_open_single_native_input() public {
        StandardOrder memory order = _nativeOrder(swapper, NATIVE_AMOUNT, 1);
        uint256 balanceBefore = inputSettlerEscrow.balance;

        _openNative(order, NATIVE_AMOUNT);

        bytes32 orderId = IInputSettlerEscrow(inputSettlerEscrow).orderIdentifier(order);
        // Deposited is source-derived from InputSettlerEscrow.OrderStatus.
        assertEq(
            uint8(InputSettlerEscrow(inputSettlerEscrow).orderStatus(orderId)),
            uint8(InputSettlerEscrow.OrderStatus.Deposited)
        );
        assertEq(inputSettlerEscrow.balance, balanceBefore + NATIVE_AMOUNT);
    }

    function test_open_native_reverts_when_value_too_little() public {
        StandardOrder memory order = _nativeOrder(swapper, NATIVE_AMOUNT, 2);
        uint256 actual = NATIVE_AMOUNT - 1;
        vm.deal(swapper, actual);

        vm.prank(swapper);
        vm.expectRevert(abi.encodeWithSelector(InputSettlerEscrow.InvalidNativeValue.selector, NATIVE_AMOUNT, actual));
        IInputSettlerEscrow(inputSettlerEscrow).open{ value: actual }(order);
    }

    function test_open_native_reverts_when_value_too_much() public {
        StandardOrder memory order = _nativeOrder(swapper, NATIVE_AMOUNT, 3);
        uint256 actual = NATIVE_AMOUNT + 1;
        vm.deal(swapper, actual);

        vm.prank(swapper);
        vm.expectRevert(abi.encodeWithSelector(InputSettlerEscrow.InvalidNativeValue.selector, NATIVE_AMOUNT, actual));
        IInputSettlerEscrow(inputSettlerEscrow).open{ value: actual }(order);
    }

    function test_open_erc20_only_reverts_on_stray_value() public {
        uint256[2][] memory inputs = new uint256[2][](1);
        inputs[0] = [uint256(uint160(address(token))), NATIVE_AMOUNT];
        StandardOrder memory order = _order(swapper, inputs, 4);
        vm.deal(swapper, 1);

        vm.prank(swapper);
        vm.expectRevert(abi.encodeWithSelector(InputSettlerEscrow.InvalidNativeValue.selector, 0, 1));
        IInputSettlerEscrow(inputSettlerEscrow).open{ value: 1 }(order);
    }

    function test_open_mixed_native_and_erc20_inputs() public {
        uint256 erc20Amount = 0.4 ether;
        uint256 nativeAmount = 0.6 ether;
        uint256[2][] memory inputs = new uint256[2][](3);
        // Token id 0 is the source-derived native-input sentinel.
        inputs[0] = [uint256(0), nativeAmount / 2];
        inputs[1] = [uint256(uint160(address(token))), erc20Amount];
        // Token id 0 is the source-derived native-input sentinel.
        inputs[2] = [uint256(0), nativeAmount / 2];
        StandardOrder memory order = _order(swapper, inputs, 5);

        vm.prank(swapper);
        assertTrue(token.approve(inputSettlerEscrow, erc20Amount));
        vm.deal(swapper, nativeAmount);
        vm.prank(swapper);
        IInputSettlerEscrow(inputSettlerEscrow).open{ value: nativeAmount }(order);

        assertEq(inputSettlerEscrow.balance, nativeAmount);
        assertEq(token.balanceOf(inputSettlerEscrow), erc20Amount);
        assertEq(token.balanceOf(swapper), 1 ether - erc20Amount);
    }

    function test_open_for_self_native_input() public {
        StandardOrder memory order = _nativeOrder(swapper, NATIVE_AMOUNT, 6);
        vm.deal(swapper, NATIVE_AMOUNT);

        vm.prank(swapper);
        IInputSettlerEscrow(inputSettlerEscrow).openFor{ value: NATIVE_AMOUNT }(order, swapper, hex"");

        bytes32 orderId = IInputSettlerEscrow(inputSettlerEscrow).orderIdentifier(order);
        assertEq(
            uint8(InputSettlerEscrow(inputSettlerEscrow).orderStatus(orderId)),
            uint8(InputSettlerEscrow.OrderStatus.Deposited)
        );
        assertEq(inputSettlerEscrow.balance, NATIVE_AMOUNT);
    }

    function test_open_for_permit2_rejects_native_input() public {
        StandardOrder memory order = _nativeOrder(swapper, NATIVE_AMOUNT, 7);

        vm.prank(solver);
        vm.expectRevert(InputSettlerEscrow.NativeTokenNotSupported.selector);
        // 0x00 is source-derived SIGNATURE_TYPE_PERMIT2.
        IInputSettlerEscrow(inputSettlerEscrow).openFor(order, swapper, hex"00");
    }

    function test_open_for_erc3009_rejects_native_input() public {
        StandardOrder memory order = _nativeOrder(swapper, NATIVE_AMOUNT, 8);

        vm.prank(solver);
        vm.expectRevert(InputSettlerEscrow.NativeTokenNotSupported.selector);
        // 0x01 is source-derived SIGNATURE_TYPE_3009.
        IInputSettlerEscrow(inputSettlerEscrow).openFor(order, swapper, hex"01");
    }

    function test_open_for_non_self_reverts_on_any_value() public {
        StandardOrder memory order = _nativeOrder(swapper, NATIVE_AMOUNT, 9);
        vm.deal(solver, 1);

        vm.prank(solver);
        vm.expectRevert(abi.encodeWithSelector(InputSettlerEscrow.InvalidNativeValue.selector, 0, 1));
        // 0x00 is source-derived SIGNATURE_TYPE_PERMIT2.
        IInputSettlerEscrow(inputSettlerEscrow).openFor{ value: 1 }(order, swapper, hex"00");
    }

    function test_finalise_pays_native_to_destination() public {
        StandardOrder memory order = _nativeOrder(swapper, NATIVE_AMOUNT, 10);
        _openNative(order, NATIVE_AMOUNT);
        address destination = makeAddr("native destination");
        uint256 balanceBefore = destination.balance;

        vm.prank(solver);
        IInputSettlerEscrow(inputSettlerEscrow).finalise(order, _solveParams(), destination.toIdentifier(), hex"");

        assertEq(destination.balance - balanceBefore, NATIVE_AMOUNT);
    }

    function test_refund_returns_native_to_user() public {
        StandardOrder memory order = _nativeOrder(swapper, NATIVE_AMOUNT, 11);
        _openNative(order, NATIVE_AMOUNT);
        uint256 balanceBefore = swapper.balance;
        vm.warp(uint256(order.expires) + 1);

        IInputSettlerEscrow(inputSettlerEscrow).refund(order);

        assertEq(swapper.balance - balanceBefore, NATIVE_AMOUNT);
    }

    function test_refund_on_non_fill_returns_native_to_user() public {
        StandardOrder memory order = _nativeOrder(swapper, NATIVE_AMOUNT, 12);
        _openNative(order, NATIVE_AMOUNT);
        uint256 balanceBefore = swapper.balance;
        vm.warp(order.fillDeadline + 1);

        IInputSettlerEscrow(inputSettlerEscrow).refundOnNonFill(order, 0);

        assertEq(swapper.balance - balanceBefore, NATIVE_AMOUNT);
    }

    function test_refund_native_reverting_user_blocks_refund() public {
        RejectsNative rejectingUser = new RejectsNative();
        StandardOrder memory order = _nativeOrder(address(rejectingUser), NATIVE_AMOUNT, 13);
        vm.deal(address(this), NATIVE_AMOUNT);
        rejectingUser.openNative{ value: NATIVE_AMOUNT }(IInputSettlerEscrow(inputSettlerEscrow), order);
        bytes32 orderId = IInputSettlerEscrow(inputSettlerEscrow).orderIdentifier(order);
        vm.warp(uint256(order.expires) + 1);

        // spec-adjudication: FINDINGS #5.
        vm.expectRevert();
        IInputSettlerEscrow(inputSettlerEscrow).refund(order);

        // spec-adjudication: FINDINGS #5.
        assertEq(inputSettlerEscrow.balance, NATIVE_AMOUNT);
        // spec-adjudication: FINDINGS #5.
        assertEq(
            uint8(InputSettlerEscrow(inputSettlerEscrow).orderStatus(orderId)),
            uint8(InputSettlerEscrow.OrderStatus.Deposited)
        );
    }

    function test_open_native_reverts_when_user_is_zero() public {
        StandardOrder memory order = _nativeOrder(address(0), NATIVE_AMOUNT, 14);
        vm.deal(address(this), NATIVE_AMOUNT);

        // spec-adjudication: FINDINGS #5.
        vm.expectRevert(InputSettlerEscrow.UserIsZero.selector);
        IInputSettlerEscrow(inputSettlerEscrow).open{ value: NATIVE_AMOUNT }(order);
    }

    function test_open_erc20_reverts_when_user_is_zero() public {
        uint256[2][] memory inputs = new uint256[2][](1);
        inputs[0] = [uint256(uint160(address(token))), 1];
        StandardOrder memory order = _order(address(0), inputs, 15);

        // spec-adjudication: FINDINGS #5.
        vm.expectRevert(InputSettlerEscrow.UserIsZero.selector);
        IInputSettlerEscrow(inputSettlerEscrow).open(order);
    }

    function test_native_input_order_is_not_purchasable() public {
        StandardOrder memory order = _nativeOrder(swapper, NATIVE_AMOUNT, 16);
        _openNative(order, NATIVE_AMOUNT);
        bytes32 orderId = IInputSettlerEscrow(inputSettlerEscrow).orderIdentifier(order);
        OrderPurchase memory purchase =
            OrderPurchase({ orderId: orderId, destination: solver, callData: hex"", discount: 0, timeToBuy: 1000 });
        bytes memory signature = this.getOrderPurchaseSignature(solverPrivateKey, purchase);

        // spec-adjudication: FINDINGS #5.
        vm.prank(purchaser);
        vm.expectRevert(InputSettlerEscrow.NativeTokenNotSupported.selector);
        InputSettlerEscrow(inputSettlerEscrow)
            .purchaseOrder(
                purchase, order, solver.toIdentifier(), purchaser.toIdentifier(), type(uint256).max, signature
            );
    }

    function test_zero_amount_native_input_send_is_skipped() public {
        StandardOrder memory order = _nativeOrder(swapper, 0, 17);
        IInputSettlerEscrow(inputSettlerEscrow).open(order);
        NoNativeReceiver destination = new NoNativeReceiver();

        vm.prank(solver);
        IInputSettlerEscrow(inputSettlerEscrow)
            .finalise(order, _solveParams(), address(destination).toIdentifier(), hex"");

        bytes32 orderId = IInputSettlerEscrow(inputSettlerEscrow).orderIdentifier(order);
        assertEq(
            uint8(InputSettlerEscrow(inputSettlerEscrow).orderStatus(orderId)),
            uint8(InputSettlerEscrow.OrderStatus.Claimed)
        );
    }
}

// forge-lint: disable-end(multi-contract-file, arbitrary-send-eth)

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

// Native value transfers are the behavior under test.
// forge-lint: disable-start(multi-contract-file, arbitrary-send-eth)

import { InputSettlerBase } from "../../../src/input/InputSettlerBase.sol";
import { InputSettlerPurchase } from "../../../src/input/InputSettlerPurchase.sol";
import { InputSettlerEscrow } from "../../../src/input/escrow/InputSettlerEscrow.sol";
import { InputSettlerEscrowTron } from "../../../src/input/escrow/InputSettlerEscrowTron.sol";
import { MandateOutput } from "../../../src/input/types/MandateOutputType.sol";
import { OrderPurchase, OrderPurchaseType } from "../../../src/input/types/OrderPurchaseType.sol";
import { StandardOrder } from "../../../src/input/types/StandardOrderType.sol";
import { IInputSettlerEscrow } from "../../../src/interfaces/IInputSettlerEscrow.sol";
import { LibAddress } from "../../../src/libs/LibAddress.sol";

import { EIP712, InputSettlerEscrowTestBase } from "./InputSettlerEscrow.base.t.sol";

contract InputSettlerEscrowPurchaseNativeTest is InputSettlerEscrowTestBase {
    using LibAddress for address;

    uint256 internal constant DISCOUNT_DENOM = 1e18;
    uint256 internal constant NATIVE_AMOUNT = 1 ether;

    function _order(
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
            user: swapper,
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
        uint256 amount,
        uint256 nonce
    ) internal view returns (StandardOrder memory order) {
        uint256[2][] memory inputs = new uint256[2][](1);
        inputs[0] = [uint256(0), amount];
        return _order(inputs, nonce);
    }

    function _open(
        StandardOrder memory order,
        uint256 nativeValue
    ) internal {
        vm.deal(swapper, nativeValue);
        vm.prank(swapper);
        IInputSettlerEscrow(inputSettlerEscrow).open{ value: nativeValue }(order);
    }

    function _purchase(
        StandardOrder memory order,
        uint64 discount,
        uint256 nativeValue
    ) internal {
        (OrderPurchase memory purchase, bytes memory signature) = _purchaseData(order, discount);

        vm.prank(purchaser);
        IInputSettlerEscrow(inputSettlerEscrow).purchaseOrder{ value: nativeValue }(
            purchase, order, solver.toIdentifier(), purchaser.toIdentifier(), type(uint256).max, signature
        );
    }

    function _expectPurchaseRevert(
        StandardOrder memory order,
        uint64 discount,
        uint256 nativeValue,
        bytes memory revertData
    ) internal {
        (OrderPurchase memory purchase, bytes memory signature) = _purchaseData(order, discount);

        vm.expectRevert(revertData);
        vm.prank(purchaser);
        IInputSettlerEscrow(inputSettlerEscrow).purchaseOrder{ value: nativeValue }(
            purchase, order, solver.toIdentifier(), purchaser.toIdentifier(), type(uint256).max, signature
        );
    }

    function _purchaseData(
        StandardOrder memory order,
        uint64 discount
    ) internal view returns (OrderPurchase memory purchase, bytes memory signature) {
        bytes32 orderId = IInputSettlerEscrow(inputSettlerEscrow).orderIdentifier(order);
        purchase = OrderPurchase({
            orderId: orderId, destination: solver, callData: hex"", discount: discount, timeToBuy: 1000
        });
        signature = this.getOrderPurchaseSignature(solverPrivateKey, purchase);
    }

    function getOrderPurchaseSignatureFor(
        uint256 privateKey,
        address settler,
        OrderPurchase calldata purchase
    ) external view returns (bytes memory signature) {
        bytes32 digest = keccak256(
            abi.encodePacked(
                "\x19\x01", EIP712(settler).DOMAIN_SEPARATOR(), OrderPurchaseType.hashOrderPurchase(purchase)
            )
        );
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(privateKey, digest);
        signature = bytes.concat(r, s, bytes1(v));
    }

    function _solveParams() internal view returns (InputSettlerBase.SolveParams[] memory solveParams) {
        solveParams = new InputSettlerBase.SolveParams[](1);
        solveParams[0] = InputSettlerBase.SolveParams({ solver: solver.toIdentifier(), timestamp: 1 });
    }

    function test_purchase_native_succeeds_and_finalise_pays_full_escrow_to_purchaser() public {
        StandardOrder memory order = _nativeOrder(NATIVE_AMOUNT, 1);
        _open(order, NATIVE_AMOUNT);
        vm.deal(purchaser, NATIVE_AMOUNT);

        uint256 solverBalanceBefore = solver.balance;
        _purchase(order, 0, NATIVE_AMOUNT);

        assertEq(solver.balance - solverBalanceBefore, NATIVE_AMOUNT);
        (uint32 lastOrderTimestamp, bytes32 storedPurchaser) = InputSettlerPurchase(inputSettlerEscrow)
            .purchasedOrders(solver.toIdentifier(), IInputSettlerEscrow(inputSettlerEscrow).orderIdentifier(order));
        assertEq(lastOrderTimestamp, 0);
        assertEq(storedPurchaser, purchaser.toIdentifier());

        vm.prank(purchaser);
        IInputSettlerEscrow(inputSettlerEscrow).finalise(order, _solveParams(), purchaser.toIdentifier(), hex"");

        assertEq(purchaser.balance, NATIVE_AMOUNT);
        assertEq(inputSettlerEscrow.balance, 0);
    }

    function test_purchase_native_reverts_when_value_too_little() public {
        StandardOrder memory order = _nativeOrder(NATIVE_AMOUNT, 2);
        _open(order, NATIVE_AMOUNT);
        uint256 actual = NATIVE_AMOUNT - 1;
        vm.deal(purchaser, actual);

        _expectPurchaseRevert(
            order,
            0,
            actual,
            abi.encodeWithSelector(InputSettlerEscrow.InvalidNativeValue.selector, NATIVE_AMOUNT, actual)
        );
    }

    function test_purchase_native_reverts_when_value_too_much() public {
        StandardOrder memory order = _nativeOrder(NATIVE_AMOUNT, 3);
        _open(order, NATIVE_AMOUNT);
        uint256 actual = NATIVE_AMOUNT + 1;
        vm.deal(purchaser, actual);

        _expectPurchaseRevert(
            order,
            0,
            actual,
            abi.encodeWithSelector(InputSettlerEscrow.InvalidNativeValue.selector, NATIVE_AMOUNT, actual)
        );
    }

    function test_purchase_erc20_only_reverts_on_stray_value() public {
        uint256[2][] memory inputs = new uint256[2][](1);
        inputs[0] = [uint256(uint160(address(token))), NATIVE_AMOUNT];
        StandardOrder memory order = _order(inputs, 4);
        vm.prank(swapper);
        assertTrue(token.approve(inputSettlerEscrow, NATIVE_AMOUNT));
        _open(order, 0);
        vm.deal(purchaser, 1);

        _expectPurchaseRevert(order, 0, 1, abi.encodeWithSelector(InputSettlerEscrow.InvalidNativeValue.selector, 0, 1));
    }

    function test_purchase_underpayment_cannot_drain_pooled_native_escrow() public {
        StandardOrder memory orderToPurchase = _nativeOrder(NATIVE_AMOUNT, 5);
        StandardOrder memory pooledOrder = _nativeOrder(2 ether, 6);
        _open(orderToPurchase, NATIVE_AMOUNT);
        _open(pooledOrder, 2 ether);
        uint256 pooledBalanceBefore = inputSettlerEscrow.balance;

        _expectPurchaseRevert(
            orderToPurchase,
            0,
            0,
            abi.encodeWithSelector(InputSettlerEscrow.InvalidNativeValue.selector, NATIVE_AMOUNT, 0)
        );

        assertEq(inputSettlerEscrow.balance, pooledBalanceBefore);
        bytes32 pooledOrderId = IInputSettlerEscrow(inputSettlerEscrow).orderIdentifier(pooledOrder);
        assertEq(
            uint8(InputSettlerEscrow(inputSettlerEscrow).orderStatus(pooledOrderId)),
            uint8(InputSettlerEscrow.OrderStatus.Deposited)
        );
    }

    function test_purchase_mixed_native_and_erc20_uses_value_and_transferFrom() public {
        uint256 nativeAmount = 0.6 ether;
        uint256 tokenAmount = 0.4 ether;
        uint256[2][] memory inputs = new uint256[2][](3);
        inputs[0] = [uint256(0), nativeAmount / 2];
        inputs[1] = [uint256(uint160(address(token))), tokenAmount];
        inputs[2] = [uint256(0), nativeAmount / 2];
        StandardOrder memory order = _order(inputs, 7);
        vm.prank(swapper);
        assertTrue(token.approve(inputSettlerEscrow, tokenAmount));
        _open(order, nativeAmount);

        token.mint(purchaser, tokenAmount);
        vm.prank(purchaser);
        assertTrue(token.approve(inputSettlerEscrow, tokenAmount));
        vm.deal(purchaser, nativeAmount);
        uint256 solverNativeBefore = solver.balance;
        uint256 solverTokenBefore = token.balanceOf(solver);

        _purchase(order, 0, nativeAmount);

        assertEq(solver.balance - solverNativeBefore, nativeAmount);
        assertEq(token.balanceOf(solver) - solverTokenBefore, tokenAmount);
        assertEq(token.balanceOf(purchaser), 0);
        assertEq(inputSettlerEscrow.balance, nativeAmount);
        assertEq(token.balanceOf(inputSettlerEscrow), tokenAmount);
    }

    function test_purchase_native_discount_requires_exact_discounted_value() public {
        uint64 discount = 0.25e18;
        uint256 discountedAmount = (NATIVE_AMOUNT * (DISCOUNT_DENOM - discount)) / DISCOUNT_DENOM;
        StandardOrder memory order = _nativeOrder(NATIVE_AMOUNT, 8);
        _open(order, NATIVE_AMOUNT);
        vm.deal(purchaser, discountedAmount);
        uint256 solverBalanceBefore = solver.balance;

        _purchase(order, discount, discountedAmount);

        assertEq(solver.balance - solverBalanceBefore, discountedAmount);
        assertEq(inputSettlerEscrow.balance, NATIVE_AMOUNT);
    }

    function test_tron_native_open_and_purchase_succeeds() public {
        InputSettlerEscrowTron tronSettler = new InputSettlerEscrowTron(address(0));
        StandardOrder memory order = _nativeOrder(NATIVE_AMOUNT, 9);
        vm.deal(swapper, NATIVE_AMOUNT);
        vm.prank(swapper);
        tronSettler.open{ value: NATIVE_AMOUNT }(order);

        bytes32 orderId = tronSettler.orderIdentifier(order);
        OrderPurchase memory purchase =
            OrderPurchase({ orderId: orderId, destination: solver, callData: hex"", discount: 0, timeToBuy: 1000 });
        bytes memory signature = this.getOrderPurchaseSignatureFor(solverPrivateKey, address(tronSettler), purchase);
        vm.deal(purchaser, NATIVE_AMOUNT);
        uint256 solverBalanceBefore = solver.balance;

        vm.prank(purchaser);
        tronSettler.purchaseOrder{ value: NATIVE_AMOUNT }(
            purchase, order, solver.toIdentifier(), purchaser.toIdentifier(), type(uint256).max, signature
        );

        assertEq(solver.balance - solverBalanceBefore, NATIVE_AMOUNT);
        assertEq(address(tronSettler).balance, NATIVE_AMOUNT);
        (uint32 lastOrderTimestamp, bytes32 storedPurchaser) =
            tronSettler.purchasedOrders(solver.toIdentifier(), orderId);
        assertEq(lastOrderTimestamp, 0);
        assertEq(storedPurchaser, purchaser.toIdentifier());
    }
}

// forge-lint: disable-end(multi-contract-file, arbitrary-send-eth)

// SPDX-License-Identifier: LGPL-3.0-only
pragma solidity ^0.8.26;

// The inline rejecting owner is required by strict file ownership, and sending ETH is the behavior under test.
// forge-lint: disable-start(multi-contract-file, arbitrary-send-eth)

import { InputSettlerBase } from "../../../src/input/InputSettlerBase.sol";
import { InputSettlerEscrow } from "../../../src/input/escrow/InputSettlerEscrow.sol";
import { InputSettlerEscrowLIFI } from "../../../src/input/escrow/InputSettlerEscrowLIFI.sol";
import { MandateOutput } from "../../../src/input/types/MandateOutputType.sol";
import { StandardOrder } from "../../../src/input/types/StandardOrderType.sol";
import { IInputSettlerEscrow } from "../../../src/interfaces/IInputSettlerEscrow.sol";
import { LibAddress } from "../../../src/libs/LibAddress.sol";

import { InputSettlerEscrowTestBase } from "./InputSettlerEscrow.base.t.sol";

contract RejectingFeeOwner {
    function setGovernanceFee(
        InputSettlerEscrowLIFI settler,
        uint64 fee
    ) external {
        settler.setGovernanceFee(fee);
    }

    function transferSettlerOwnership(
        InputSettlerEscrowLIFI settler,
        address newOwner
    ) external {
        settler.transferOwnership(newOwner);
    }

    receive() external payable {
        revert("reject ETH");
    }
}

contract InputSettlerEscrowLIFINativeTest is InputSettlerEscrowTestBase {
    using LibAddress for address;

    // 0.05e18 is the source-derived MAX_GOVERNANCE_FEE.
    uint64 internal constant TEST_FEE = 0.05 ether;
    uint256 internal constant NATIVE_AMOUNT = 1 ether;

    function setUp() public override {
        super.setUp();
        owner = makeAddr("native fee owner");
        inputSettlerEscrow = address(new InputSettlerEscrowLIFI(owner));
    }

    function _nativeOrder(
        uint256 nonce
    ) internal view returns (StandardOrder memory order) {
        uint256[2][] memory inputs = new uint256[2][](1);
        // Token id 0 is the source-derived native-input sentinel.
        inputs[0] = [uint256(0), NATIVE_AMOUNT];
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

    function _setFee(
        uint64 fee
    ) internal {
        vm.prank(owner);
        InputSettlerEscrowLIFI(inputSettlerEscrow).setGovernanceFee(fee);
        // 7 days is source-derived GOVERNANCE_FEE_CHANGE_DELAY.
        vm.warp(block.timestamp + 7 days + 1);
        InputSettlerEscrowLIFI(inputSettlerEscrow).applyGovernanceFee();
    }

    function _openNative(
        StandardOrder memory order
    ) internal {
        vm.deal(swapper, NATIVE_AMOUNT);
        vm.prank(swapper);
        IInputSettlerEscrow(inputSettlerEscrow).open{ value: NATIVE_AMOUNT }(order);
    }

    function _solveParams() internal view returns (InputSettlerBase.SolveParams[] memory solveParams) {
        solveParams = new InputSettlerBase.SolveParams[](1);
        solveParams[0] = InputSettlerBase.SolveParams({ solver: solver.toIdentifier(), timestamp: 1 });
    }

    function test_finalise_native_with_governance_fee() public {
        _setFee(TEST_FEE);
        StandardOrder memory order = _nativeOrder(1);
        _openNative(order);
        address destination = makeAddr("native LIFI destination");
        uint256 ownerBefore = owner.balance;
        uint256 destinationBefore = destination.balance;
        // 1e18 is source-derived GOVERNANCE_FEE_DENOM used by _calcFee.
        uint256 expectedFee = (NATIVE_AMOUNT * TEST_FEE) / 1e18;

        vm.prank(solver);
        IInputSettlerEscrow(inputSettlerEscrow).finalise(order, _solveParams(), destination.toIdentifier(), hex"");

        assertEq(owner.balance - ownerBefore, expectedFee);
        assertEq(destination.balance - destinationBefore, NATIVE_AMOUNT - expectedFee);
    }

    function test_refund_native_waives_governance_fee() public {
        _setFee(TEST_FEE);
        StandardOrder memory order = _nativeOrder(2);
        _openNative(order);
        uint256 userBefore = swapper.balance;
        uint256 ownerBefore = owner.balance;
        vm.warp(uint256(order.expires) + 1);

        IInputSettlerEscrow(inputSettlerEscrow).refund(order);

        assertEq(swapper.balance - userBefore, NATIVE_AMOUNT);
        assertEq(owner.balance, ownerBefore);
    }

    function test_finalise_native_rejecting_fee_owner_blocks() public {
        RejectingFeeOwner rejectingOwner = new RejectingFeeOwner();
        inputSettlerEscrow = address(new InputSettlerEscrowLIFI(address(rejectingOwner)));
        rejectingOwner.setGovernanceFee(InputSettlerEscrowLIFI(inputSettlerEscrow), TEST_FEE);
        // 7 days is source-derived GOVERNANCE_FEE_CHANGE_DELAY.
        vm.warp(block.timestamp + 7 days + 1);
        InputSettlerEscrowLIFI(inputSettlerEscrow).applyGovernanceFee();
        StandardOrder memory order = _nativeOrder(3);
        _openNative(order);
        bytes32 orderId = IInputSettlerEscrow(inputSettlerEscrow).orderIdentifier(order);
        address destination = makeAddr("unbricked destination");

        // spec-adjudication: FINDINGS #5.
        vm.prank(solver);
        vm.expectRevert();
        IInputSettlerEscrow(inputSettlerEscrow).finalise(order, _solveParams(), destination.toIdentifier(), hex"");
        // spec-adjudication: FINDINGS #5.
        assertEq(inputSettlerEscrow.balance, NATIVE_AMOUNT);
        // spec-adjudication: FINDINGS #5.
        assertEq(
            uint8(InputSettlerEscrow(inputSettlerEscrow).orderStatus(orderId)),
            uint8(InputSettlerEscrow.OrderStatus.Deposited)
        );

        address receivingOwner = makeAddr("receiving fee owner");
        // spec-adjudication: FINDINGS #5.
        rejectingOwner.transferSettlerOwnership(InputSettlerEscrowLIFI(inputSettlerEscrow), receivingOwner);
        uint256 ownerBefore = receivingOwner.balance;
        uint256 destinationBefore = destination.balance;
        // 1e18 is source-derived GOVERNANCE_FEE_DENOM used by _calcFee.
        uint256 expectedFee = (NATIVE_AMOUNT * TEST_FEE) / 1e18;

        vm.prank(solver);
        IInputSettlerEscrow(inputSettlerEscrow).finalise(order, _solveParams(), destination.toIdentifier(), hex"");

        // spec-adjudication: FINDINGS #5.
        assertEq(receivingOwner.balance - ownerBefore, expectedFee);
        // spec-adjudication: FINDINGS #5.
        assertEq(destination.balance - destinationBefore, NATIVE_AMOUNT - expectedFee);
        // spec-adjudication: FINDINGS #5.
        assertEq(
            uint8(InputSettlerEscrow(inputSettlerEscrow).orderStatus(orderId)),
            uint8(InputSettlerEscrow.OrderStatus.Claimed)
        );
    }
}

// forge-lint: disable-end(multi-contract-file, arbitrary-send-eth)

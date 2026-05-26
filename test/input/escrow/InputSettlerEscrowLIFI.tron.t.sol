// SPDX-License-Identifier: LGPL-3.0-only
pragma solidity ^0.8.25;

import { InputSettlerEscrowLIFI } from "../../../src/input/escrow/InputSettlerEscrowLIFI.sol";
import { InputSettlerEscrowLIFITron } from "../../../src/input/escrow/InputSettlerEscrowLIFI.tron.sol";
import { InputSettlerBase } from "OIF/src/input/InputSettlerBase.sol";

import { StandardOrder } from "OIF/src/input/types/StandardOrderType.sol";
import { MandateOutput, MandateOutputEncodingLib } from "OIF/src/libs/MandateOutputEncodingLib.sol";

import { InputSettlerEscrowTest } from "OIF/test/input/escrow/InputSettlerEscrow.t.sol";

import { MockTronUSDT } from "../../mocks/MockUSDT.tron.sol";

contract InputSettlerEscrowLIFITronHarness is InputSettlerEscrowLIFITron {
    constructor(
        address initialOwner
    ) InputSettlerEscrowLIFITron(initialOwner) { }

    function validateFillsNow(
        address inputOracle,
        MandateOutput[] calldata outputs,
        bytes32 orderId
    ) external view {
        _validateFillsNow(inputOracle, outputs, orderId);
    }
}

contract InputSettlerEscrowLIFITronTest is InputSettlerEscrowTest {
    function setUp() public virtual override {
        super.setUp();

        owner = makeAddr("owner");
        inputSettlerEscrow = address(new InputSettlerEscrowLIFITronHarness(owner));

        // Replace tokens with MockTronUSDT to simulate Tron USDT behavior
        token = new MockTronUSDT("Tron USDT", "USDT", 6);
        anotherToken = new MockTronUSDT("Tron USDT2", "USDT2", 6);

        token.mint(swapper, 1e18);
        anotherToken.mint(solver, 1e18);

        vm.prank(swapper);
        token.approve(address(permit2), type(uint256).max);
        vm.prank(solver);
        anotherToken.approve(address(outputSettlerCoin), type(uint256).max);
    }

    /// forge-config: default.isolate = true
    function test_finalise_self_with_fee_gas() public {
        test_finalise_self_with_fee(MAX_GOVERNANCE_FEE / 3);
    }

    function test_finalise_self_with_fee(
        uint64 fee
    ) public {
        vm.assume(fee <= MAX_GOVERNANCE_FEE);
        vm.prank(owner);
        InputSettlerEscrowLIFI(inputSettlerEscrow).setGovernanceFee(fee);
        vm.warp(uint32(block.timestamp) + GOVERNANCE_FEE_CHANGE_DELAY + 1);
        InputSettlerEscrowLIFI(inputSettlerEscrow).applyGovernanceFee();

        uint256 amount = 1e18 / 10;
        address inputOracle = address(alwaysYesOracle);

        MandateOutput[] memory outputs = new MandateOutput[](1);
        outputs[0] = MandateOutput({
            settler: bytes32(uint256(uint160(address(outputSettlerCoin)))),
            oracle: bytes32(uint256(uint160(inputOracle))),
            chainId: block.chainid,
            token: bytes32(uint256(uint160(address(anotherToken)))),
            amount: amount,
            recipient: bytes32(uint256(uint160(swapper))),
            callbackData: hex"",
            context: hex""
        });
        uint256[2][] memory inputs = new uint256[2][](1);
        inputs[0] = [uint256(uint160(address(token))), amount];

        StandardOrder memory order = StandardOrder({
            user: swapper,
            nonce: 0,
            originChainId: block.chainid,
            expires: type(uint32).max,
            fillDeadline: type(uint32).max,
            inputOracle: inputOracle,
            inputs: inputs,
            outputs: outputs
        });

        vm.prank(swapper);
        token.approve(inputSettlerEscrow, amount);
        vm.prank(swapper);
        InputSettlerEscrowLIFI(inputSettlerEscrow).open(order);

        bytes32 orderId = InputSettlerEscrowLIFI(inputSettlerEscrow).orderIdentifier(order);
        bytes memory payload = MandateOutputEncodingLib.encodeFillDescriptionMemory(
            bytes32(uint256(uint160((solver)))), orderId, uint32(block.timestamp), outputs[0]
        );
        bytes32 payloadHash = keccak256(payload);

        vm.expectCall(
            address(alwaysYesOracle),
            abi.encodeWithSignature(
                "efficientRequireProven(bytes)",
                abi.encodePacked(
                    order.outputs[0].chainId, order.outputs[0].oracle, order.outputs[0].settler, payloadHash
                )
            )
        );

        InputSettlerBase.SolveParams[] memory solveParams = new InputSettlerBase.SolveParams[](1);
        solveParams[0] = InputSettlerBase.SolveParams({
            timestamp: uint32(block.timestamp), solver: bytes32(uint256(uint160((solver))))
        });

        vm.prank(solver);
        InputSettlerEscrowLIFI(inputSettlerEscrow)
            .finalise(order, solveParams, bytes32(uint256(uint160((solver)))), hex"");
        vm.snapshotGasLastCall("inputSettler", "tronEscrowFinaliseSelfWithFee");

        uint256 govFeeAmount = (amount * fee) / 10 ** 18;
        uint256 amountPostFee = amount - govFeeAmount;

        assertEq(token.balanceOf(solver), amountPostFee);
        assertEq(token.balanceOf(InputSettlerEscrowLIFI(inputSettlerEscrow).owner()), govFeeAmount);
    }

    function test_finalise_self_no_fee() public {
        uint256 amount = 1e18 / 10;
        address inputOracle = address(alwaysYesOracle);

        MandateOutput[] memory outputs = new MandateOutput[](1);
        outputs[0] = MandateOutput({
            settler: bytes32(uint256(uint160(address(outputSettlerCoin)))),
            oracle: bytes32(uint256(uint160(inputOracle))),
            chainId: block.chainid,
            token: bytes32(uint256(uint160(address(anotherToken)))),
            amount: amount,
            recipient: bytes32(uint256(uint160(swapper))),
            callbackData: hex"",
            context: hex""
        });
        uint256[2][] memory inputs = new uint256[2][](1);
        inputs[0] = [uint256(uint160(address(token))), amount];

        StandardOrder memory order = StandardOrder({
            user: swapper,
            nonce: 0,
            originChainId: block.chainid,
            expires: type(uint32).max,
            fillDeadline: type(uint32).max,
            inputOracle: inputOracle,
            inputs: inputs,
            outputs: outputs
        });

        vm.prank(swapper);
        token.approve(inputSettlerEscrow, amount);
        vm.prank(swapper);
        InputSettlerEscrowLIFI(inputSettlerEscrow).open(order);

        bytes32 orderId = InputSettlerEscrowLIFI(inputSettlerEscrow).orderIdentifier(order);
        bytes memory payload = MandateOutputEncodingLib.encodeFillDescriptionMemory(
            bytes32(uint256(uint160((solver)))), orderId, uint32(block.timestamp), outputs[0]
        );
        bytes32 payloadHash = keccak256(payload);

        vm.expectCall(
            address(alwaysYesOracle),
            abi.encodeWithSignature(
                "efficientRequireProven(bytes)",
                abi.encodePacked(
                    order.outputs[0].chainId, order.outputs[0].oracle, order.outputs[0].settler, payloadHash
                )
            )
        );

        InputSettlerBase.SolveParams[] memory solveParams = new InputSettlerBase.SolveParams[](1);
        solveParams[0] = InputSettlerBase.SolveParams({
            timestamp: uint32(block.timestamp), solver: bytes32(uint256(uint160((solver))))
        });

        vm.prank(solver);
        InputSettlerEscrowLIFI(inputSettlerEscrow)
            .finalise(order, solveParams, bytes32(uint256(uint160((solver)))), hex"");

        assertEq(token.balanceOf(solver), amount);
    }
}

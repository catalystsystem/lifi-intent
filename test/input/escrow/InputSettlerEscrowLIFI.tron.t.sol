// SPDX-License-Identifier: LGPL-3.0-only
pragma solidity ^0.8.25;

import { InputSettlerEscrowLIFI } from "../../../src/input/escrow/InputSettlerEscrowLIFI.sol";
import { InputSettlerEscrowLIFITron } from "../../../src/input/escrow/InputSettlerEscrowLIFI.tron.sol";
import { InputSettlerBase } from "OIF/src/input/InputSettlerBase.sol";

import { StandardOrder } from "OIF/src/input/types/StandardOrderType.sol";
import { MandateOutput, MandateOutputEncodingLib } from "OIF/src/libs/MandateOutputEncodingLib.sol";
import { RefEncodingLib } from "test/util/RefEncodingLib.sol";

import { InputSettlerEscrowTest } from "OIF/test/input/escrow/InputSettlerEscrow.t.sol";

import { MockERC20 } from "OIF/test/mocks/MockERC20.sol";
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

    /// @dev Exposes the internal `_resolveLock` payout, putting the order in `Deposited` first (the state `open`
    /// leaves it in), so the outbound-transfer behaviour can be tested in isolation.
    function payOut(
        bytes32 orderId,
        uint256[2][] calldata inputs,
        address destination
    ) external {
        orderStatus[orderId] = OrderStatus.Deposited;
        _resolveLock(orderId, inputs, destination, OrderStatus.Claimed);
    }
}

contract InputSettlerEscrowLIFITronTest is InputSettlerEscrowTest {
    /// @dev Tron Permit2 deployment: TTJxU3P8rHycAyFY4kVtGNfmnMH4ezcuM9.
    address constant TRON_PERMIT2 = 0xBE365314f2E77FD1257d60C346Bb32DbDa369403;

    function setUp() public virtual override {
        super.setUp();

        // Host a Permit2 instance at the Tron address by copying the canonical runtime code,
        // and point the base test helpers at it.
        vm.etch(TRON_PERMIT2, permit2.code);
        permit2 = TRON_PERMIT2;

        owner = makeAddr("owner");
        inputSettlerEscrow = address(new InputSettlerEscrowLIFITronHarness(owner));

        // `token` is TRON USDT: deploy the false-returning mock at the settler's hardcoded USDT address so payouts
        // exercise the SafeTRC20.safeTransferUSDT path. `anotherToken` is a well-behaved TRC20 that settles through
        // the regular SafeTRC20.safeTransfer path.
        address usdt = InputSettlerEscrowLIFITron(inputSettlerEscrow).USDT();
        deployCodeTo("MockUSDT.tron.sol:MockTronUSDT", abi.encode("Tron USDT", "USDT", uint8(6)), usdt);
        token = MockTronUSDT(usdt);
        anotherToken = new MockERC20("Mock2 ERC20", "MOCK2", 18);

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
        // Warp target computed before the warp and reused everywhere; reading block.timestamp after vm.warp is
        // unsafe under via-IR (see InputSettlerEscrowLIFI.t.sol).
        uint32 fillTimestamp = uint32(block.timestamp + GOVERNANCE_FEE_CHANGE_DELAY + 1);
        vm.warp(fillTimestamp);
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
        bytes memory payload = RefEncodingLib.encodeFillDescriptionMemory(
            bytes32(uint256(uint160((solver)))), orderId, fillTimestamp, outputs[0]
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
            timestamp: fillTimestamp, solver: bytes32(uint256(uint160((solver))))
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
        bytes memory payload = RefEncodingLib.encodeFillDescriptionMemory(
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

    //--- Outbound transfer (USDT vs. regular token) ---//

    function _payOutInputs(
        address t,
        uint256 amount
    ) internal pure returns (uint256[2][] memory inputs) {
        inputs = new uint256[2][](1);
        inputs[0][0] = uint256(uint160(t));
        inputs[0][1] = amount;
    }

    /// @dev The Tron variant pays out USDT despite its `false` return, via SafeTRC20.safeTransferUSDT.
    function test_tronEscrow_pays_out_usdt() public {
        uint256 amount = 1000;
        token.mint(inputSettlerEscrow, amount);
        uint256 balanceBefore = token.balanceOf(solver);
        InputSettlerEscrowLIFITronHarness(inputSettlerEscrow)
            .payOut(bytes32(uint256(1)), _payOutInputs(address(token), amount), solver);
        assertEq(token.balanceOf(solver) - balanceBefore, amount);
    }

    /// @dev Non-USDT tokens still settle through the regular SafeTRC20.safeTransfer path.
    function test_tronEscrow_pays_out_regular_token() public {
        uint256 amount = 1000;
        anotherToken.mint(inputSettlerEscrow, amount);
        uint256 balanceBefore = anotherToken.balanceOf(solver);
        InputSettlerEscrowLIFITronHarness(inputSettlerEscrow)
            .payOut(bytes32(uint256(2)), _payOutInputs(address(anotherToken), amount), solver);
        assertEq(anotherToken.balanceOf(solver) - balanceBefore, amount);
    }
}

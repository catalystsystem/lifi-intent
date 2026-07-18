// SPDX-License-Identifier: LGPL-3.0-only
pragma solidity ^0.8.22;

import { InputSettlerCompactLIFI } from "../../../src/input/compact/InputSettlerCompactLIFI.sol";

import { InputSettlerBase } from "OIF/src/input/InputSettlerBase.sol";
import { InputSettlerCompactTest } from "OIF/test/input/compact/InputSettlerCompact.t.sol";

import { StandardOrder } from "OIF/src/input/types/StandardOrderType.sol";
import { MandateOutput } from "OIF/src/libs/MandateOutputEncodingLib.sol";

contract InputSettlerCompactLIFITest is InputSettlerCompactTest {
    // uint64 constant GOVERNANCE_FEE_CHANGE_DELAY = 7 days;
    // uint64 constant MAX_GOVERNANCE_FEE = 10 ** 18 * 0.05; // 10%

    function setUp() public override {
        super.setUp();

        owner = makeAddr("owner");
        inputSettlerCompact = address(new InputSettlerCompactLIFI(address(theCompact), owner));
    }

    // --- Fee tests --- //

    function test_invalid_governance_fee() public {
        vm.prank(owner);
        InputSettlerCompactLIFI(inputSettlerCompact).setGovernanceFee(MAX_GOVERNANCE_FEE);

        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSignature("GovernanceFeeTooHigh()"));
        InputSettlerCompactLIFI(inputSettlerCompact).setGovernanceFee(MAX_GOVERNANCE_FEE + 1);

        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSignature("GovernanceFeeTooHigh()"));
        InputSettlerCompactLIFI(inputSettlerCompact).setGovernanceFee(MAX_GOVERNANCE_FEE + 123123123);

        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSignature("GovernanceFeeTooHigh()"));
        InputSettlerCompactLIFI(inputSettlerCompact).setGovernanceFee(type(uint64).max);
    }

    function test_governance_fee_change_not_ready(
        uint64 fee,
        uint256 timeDelay
    ) public {
        vm.assume(fee <= MAX_GOVERNANCE_FEE);
        vm.assume(timeDelay < uint32(block.timestamp) + GOVERNANCE_FEE_CHANGE_DELAY);

        vm.prank(owner);
        vm.expectEmit();
        emit NextGovernanceFee(fee, uint32(block.timestamp) + GOVERNANCE_FEE_CHANGE_DELAY);
        InputSettlerCompactLIFI(inputSettlerCompact).setGovernanceFee(fee);

        vm.warp(timeDelay);
        vm.expectRevert(abi.encodeWithSignature("GovernanceFeeChangeNotReady()"));
        InputSettlerCompactLIFI(inputSettlerCompact).applyGovernanceFee();

        vm.warp(uint32(block.timestamp) + GOVERNANCE_FEE_CHANGE_DELAY + 1);

        assertEq(InputSettlerCompactLIFI(inputSettlerCompact).governanceFee(), 0);

        vm.expectEmit();
        emit GovernanceFeeChanged(0, fee);
        InputSettlerCompactLIFI(inputSettlerCompact).applyGovernanceFee();

        assertEq(InputSettlerCompactLIFI(inputSettlerCompact).governanceFee(), fee);
    }

    /// forge-config: default.isolate = true
    function test_finalise_self_with_fee_gas() external {
        test_finalise_self_with_fee(MAX_GOVERNANCE_FEE / 3);
    }

    function test_finalise_self_with_fee(
        uint64 fee
    ) public {
        vm.assume(fee <= MAX_GOVERNANCE_FEE);
        vm.prank(owner);
        InputSettlerCompactLIFI(inputSettlerCompact).setGovernanceFee(fee);
        // Warp target computed before the warp and reused for solve params; reading block.timestamp after vm.warp
        // is unsafe under via-IR (see InputSettlerEscrowLIFI.t.sol).
        uint32 fillTimestamp = uint32(block.timestamp + GOVERNANCE_FEE_CHANGE_DELAY + 1);
        vm.warp(fillTimestamp);
        InputSettlerCompactLIFI(inputSettlerCompact).applyGovernanceFee();

        uint256 amount = 1e18 / 10;

        token.mint(swapper, amount);
        vm.prank(swapper);
        token.approve(address(theCompact), type(uint256).max);

        vm.prank(swapper);
        uint256 tokenId = theCompact.depositERC20(address(token), alwaysOkAllocatorLockTag, amount, swapper);

        uint256[2][] memory inputs = new uint256[2][](1);
        inputs[0] = [tokenId, amount];
        MandateOutput[] memory outputs = new MandateOutput[](1);
        outputs[0] = MandateOutput({
            settler: bytes32(uint256(uint160(address(outputSettlerCoin)))),
            oracle: bytes32(uint256(uint160(address(alwaysYesOracle)))),
            chainId: block.chainid,
            token: bytes32(uint256(uint160(address(anotherToken)))),
            amount: amount,
            recipient: bytes32(uint256(uint160(swapper))),
            callbackData: hex"",
            context: hex""
        });
        StandardOrder memory order = StandardOrder({
            user: address(swapper),
            nonce: 0,
            originChainId: block.chainid,
            fillDeadline: type(uint32).max,
            expires: type(uint32).max,
            inputOracle: alwaysYesOracle,
            inputs: inputs,
            outputs: outputs
        });

        // Make Compact
        uint256[2][] memory idsAndAmounts = new uint256[2][](1);
        idsAndAmounts[0] = [tokenId, amount];

        bytes memory sponsorSig = getCompactBatchWitnessSignature(
            swapperPrivateKey, inputSettlerCompact, swapper, 0, type(uint32).max, idsAndAmounts, witnessHash(order)
        );

        bytes memory signature = abi.encode(sponsorSig, hex"");

        uint256 govFeeAmount = (amount * fee) / 10 ** 18;
        uint256 amountPostFee = amount - govFeeAmount;

        InputSettlerBase.SolveParams[] memory solveParams = new InputSettlerBase.SolveParams[](1);
        solveParams[0] = InputSettlerBase.SolveParams({
            solver: bytes32(uint256(uint160((solver)))), timestamp: fillTimestamp
        });

        vm.prank(solver);
        InputSettlerCompactLIFI(inputSettlerCompact)
            .finalise(order, signature, solveParams, bytes32(uint256(uint160((solver)))), hex"");
        vm.snapshotGasLastCall("inputSettler", "compactFinaliseSelfWithFee");

        assertEq(token.balanceOf(solver), amountPostFee);
        assertEq(theCompact.balanceOf(owner, tokenId), govFeeAmount);
    }
}

// SPDX-License-Identifier: LGPL-3.0-only
pragma solidity ^0.8.26;

import { Ownable } from "solady/auth/Ownable.sol";

/**
 * @notice Governance fee timelock
 * Allows for safely setting and changing a governance fee through a built in time-lock. Also provides a generic
 * function to compute the the impact of the governance fee on an amount.
 */
abstract contract GovernanceFee is Ownable {
    error GovernanceFeeTooHigh();
    error GovernanceFeeChangeNotReady();

    /**
     * @notice Governance fee will be changed shortly.
     */
    event NextGovernanceFee(uint64 nextGovernanceFee, uint64 nextGovernanceFeeTime);

    /**
     * @notice Governance fee changed. This fee is taken of the inputs.
     */
    event GovernanceFeeChanged(uint64 oldGovernanceFee, uint64 newGovernanceFee);

    /**
     * @notice When a new governance fee is set, when will it be applicable.
     * @dev Is used to prevent changing governance from changing the fee mid-flight.
     */
    uint64 constant GOVERNANCE_FEE_CHANGE_DELAY = 7 days;
    /**
     * @dev Resolution of the governance fee. Need to fit in uint64.
     */
    uint256 constant GOVERNANCE_FEE_DENOM = 10 ** 18;
    /**
     * @dev Max possible fee.
     */
    uint64 constant MAX_GOVERNANCE_FEE = 10 ** 18 * 0.05; // 5%

    /**
     * @notice Current applied governance fee.
     */
    uint64 public governanceFee = 0;
    /**
     * @notice Next governance fee. Will be applied: nextGovernanceFeeTime < block.timestamp
     */
    uint64 public nextGovernanceFee = 0;
    /**
     * @notice When the next governance fee will be applied. Is type(uint64).max when no change is scheduled.
     */
    uint64 public nextGovernanceFeeTime = type(uint64).max;

    /**
     * @notice Sets a new governanceFee. Is applied after a call to applyGovernanceFee
     * @param _nextGovernanceFee New governance fee. Is bounded by MAX_GOVERNANCE_FEE.
     */
    function setGovernanceFee(
        uint64 _nextGovernanceFee
    ) external onlyOwner {
        if (_nextGovernanceFee > MAX_GOVERNANCE_FEE) revert GovernanceFeeTooHigh();
        nextGovernanceFee = _nextGovernanceFee;
        nextGovernanceFeeTime = uint64(block.timestamp) + GOVERNANCE_FEE_CHANGE_DELAY;

        emit NextGovernanceFee(nextGovernanceFee, nextGovernanceFeeTime);
    }

    /**
     * @notice Applies a scheduled governace fee change.
     */
    function applyGovernanceFee() external {
        if (block.timestamp < nextGovernanceFeeTime) revert GovernanceFeeChangeNotReady();
        // Load the previous governance fee.
        uint64 oldGovernanceFee = governanceFee;
        // Set the next governanceFee.
        governanceFee = nextGovernanceFee;
        // Ensure this function can't be called again.
        nextGovernanceFeeTime = type(uint64).max;

        // Emit associated event.
        emit GovernanceFeeChanged(oldGovernanceFee, nextGovernanceFee);
    }

    /**
     * @notice Helper function to compute the fee.
     * @param amount To compute fee of.
     * @param fee Fee to subtract from amount. Is percentage and GOVERNANCE_FEE_DENOM based.
     * @return amountFee Fee
     */
    function _calcFee(
        uint256 amount,
        uint256 fee
    ) internal pure returns (uint256 amountFee) {
        unchecked {
            // Check if amount * fee overflows. If it does, don't take the fee.
            if (fee == 0 || amount >= type(uint256).max / fee) return amountFee = 0;
            // The above check ensures that amount * fee < type(uint256).max.
            // amount >= amount * fee / GOVERNANCE_FEE_DENOM since fee < GOVERNANCE_FEE_DENOM
            return amountFee = (amount * fee) / GOVERNANCE_FEE_DENOM;
        }
    }

    /**
     * @notice Returns a copy of `inputs` with the governance fee deducted from each amount, matching exactly what the
     * settler's `_resolveLock` delivers to the destination on a finalise/claim.
     * @dev Used to give input callbacks the net (delivered) amounts rather than the gross order inputs. Applies the
     * same
     * fee gate as the claim paths: the fee is taken only when an owner is set. Callbacks never run on the refund path,
     * so the refund waiver does not apply here.
     * @param inputs The gross order inputs.
     * @return netInputs A fresh array with the same token ids and fee-adjusted amounts.
     */
    function _netInputs(
        uint256[2][] calldata inputs
    ) internal view returns (uint256[2][] memory netInputs) {
        address _owner = owner();
        uint64 fee = _owner != address(0) ? governanceFee : 0;
        uint256 numInputs = inputs.length;
        netInputs = new uint256[2][](numInputs);
        for (uint256 i; i < numInputs; ++i) {
            uint256 amount = inputs[i][1];
            netInputs[i] = [inputs[i][0], amount - _calcFee(amount, fee)];
        }
    }
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import { Test } from "forge-std/Test.sol";

import { SafeTransferLib } from "solady/utils/SafeTransferLib.sol";

import { SafeTransferLibTron } from "../../src/libs/SafeTransferLib.tron.sol";
import { MockTronUSDT } from "../mocks/MockUSDT.tron.sol";
import { MockERC20 } from "OIF/test/mocks/MockERC20.sol";

contract SafeTransferLibTronHarness {
    function safeTransfer(
        address token,
        address to,
        uint256 amount
    ) external {
        SafeTransferLibTron.safeTransfer(token, to, amount);
    }
}

contract SoladySafeTransferLibHarness {
    function safeTransfer(
        address token,
        address to,
        uint256 amount
    ) external {
        SafeTransferLib.safeTransfer(token, to, amount);
    }
}

contract SafeTransferLibTronTest is Test {
    SafeTransferLibTronHarness harness;
    SoladySafeTransferLibHarness soladyHarness;
    MockTronUSDT tronToken;
    MockERC20 normalToken;
    address recipient;

    function setUp() public {
        harness = new SafeTransferLibTronHarness();
        soladyHarness = new SoladySafeTransferLibHarness();
        tronToken = new MockTronUSDT("Tron USDT", "USDT", 6);
        normalToken = new MockERC20("Normal Token", "NORM", 18);
        recipient = makeAddr("recipient");
    }

    function test_safeTransfer_normalToken() public {
        uint256 amount = 1e18;
        normalToken.mint(address(harness), amount);

        harness.safeTransfer(address(normalToken), recipient, amount);

        assertEq(normalToken.balanceOf(recipient), amount);
        assertEq(normalToken.balanceOf(address(harness)), 0);
    }

    function test_safeTransfer_tronToken() public {
        uint256 amount = 1e6;
        tronToken.mint(address(harness), amount);

        harness.safeTransfer(address(tronToken), recipient, amount);

        assertEq(tronToken.balanceOf(recipient), amount);
        assertEq(tronToken.balanceOf(address(harness)), 0);
    }

    function test_safeTransfer_tronToken_fuzz(
        uint256 amount
    ) public {
        vm.assume(amount > 0 && amount < type(uint128).max);
        tronToken.mint(address(harness), amount);

        harness.safeTransfer(address(tronToken), recipient, amount);

        assertEq(tronToken.balanceOf(recipient), amount);
        assertEq(tronToken.balanceOf(address(harness)), 0);
    }

    function test_safeTransfer_zeroAmount() public {
        tronToken.mint(address(harness), 1e6);

        harness.safeTransfer(address(tronToken), recipient, 0);

        assertEq(tronToken.balanceOf(recipient), 0);
        assertEq(tronToken.balanceOf(address(harness)), 1e6);
    }

    function test_safeTransfer_reverts_insufficientBalance() public {
        vm.expectRevert();
        harness.safeTransfer(address(tronToken), recipient, 1e6);
    }

    function test_safeTransfer_maxApprovalReused() public {
        uint256 amount = 1e6;
        tronToken.mint(address(harness), amount * 3);

        harness.safeTransfer(address(tronToken), recipient, amount);
        // OZ ERC20 doesn't decrease infinite approval
        uint256 allowanceAfterFirst = tronToken.allowance(address(harness), address(harness));
        assertEq(allowanceAfterFirst, type(uint256).max);

        harness.safeTransfer(address(tronToken), recipient, amount);
        harness.safeTransfer(address(tronToken), recipient, amount);

        assertEq(tronToken.balanceOf(recipient), amount * 3);
        assertEq(tronToken.balanceOf(address(harness)), 0);
    }

    function test_safeTransfer_normalToken_directTransferUsedFirst() public {
        uint256 amount = 1e18;
        normalToken.mint(address(harness), amount);

        harness.safeTransfer(address(normalToken), recipient, amount);

        assertEq(normalToken.balanceOf(recipient), amount);
    }

    function test_soladySafeTransfer_reverts_tronToken() public {
        uint256 amount = 1e6;
        tronToken.mint(address(soladyHarness), amount);

        vm.expectRevert(SafeTransferLib.TransferFailed.selector);
        soladyHarness.safeTransfer(address(tronToken), recipient, amount);
    }

    function test_safeTransfer_tronToken_multipleRecipients() public {
        address recipient2 = makeAddr("recipient2");
        uint256 amount = 1e6;
        tronToken.mint(address(harness), amount * 2);

        harness.safeTransfer(address(tronToken), recipient, amount);
        harness.safeTransfer(address(tronToken), recipient2, amount);

        assertEq(tronToken.balanceOf(recipient), amount);
        assertEq(tronToken.balanceOf(recipient2), amount);
    }
}

// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { Sweeper } from "../../src/Sweeper.sol";
import { ISweeper } from "../../src/interface/ISweeper.sol";
import { MockUsdc } from "../mock/mERC20.sol";
import { BaseSetUp } from "../utils/BaseSetUp.sol";
import { SafeTransferLib } from "solady/utils/SafeTransferLib.sol";

contract SweeperTest is BaseSetUp {
    Sweeper sweeper;
    MockUsdc token;

    address internal treasury = address(0x7ea5);
    address internal holderOne = address(0x1);
    address internal holderTwo = address(0x2);
    address internal holderThree = address(0x3);

    function setUp() public {
        (address storageAddress,) = initialize();

        token = new MockUsdc("Mock Usdc", "mUsdc");
        sweeper = new Sweeper(storageAddress);

        address[3] memory holders = [holderOne, holderTwo, holderThree];
        for (uint256 i; i < holders.length; i++) {
            token.mint(holders[i], 1_000e6);
            vm.prank(holders[i]);
            token.approve(address(sweeper), type(uint256).max);
        }
    }

    function test_initialState() public view {
        assertEq(address(sweeper.ppStorage()), address(ppStorage));
        assertEq(ppStorage.owner(), admin, "sweeper is gated on the storage owner");
    }

    function test_constructorRejectsTheZeroStorage() public {
        vm.expectRevert(ISweeper.InvalidAddress.selector);
        new Sweeper(address(0));
    }

    function test_sweepFollowsTheStorageOwner() public {
        address newOwner = address(0xc0ffee);
        (address[] memory from, uint256[] memory amounts) = _batch(1e6, 1e6, 1e6);

        vm.prank(admin);
        ppStorage.transferOwnership(newOwner);

        vm.prank(admin);
        vm.expectRevert(ISweeper.NotAuthorized.selector);
        sweeper.sweep(address(token), from, amounts, treasury);

        vm.prank(newOwner);
        sweeper.sweep(address(token), from, amounts, treasury);

        assertEq(token.balanceOf(treasury), 3e6);
    }

    function test_sweepCollectsFromEveryHolder() public {
        (address[] memory from, uint256[] memory amounts) = _batch(100e6, 250e6, 400e6);

        vm.expectEmit(address(sweeper));
        emit ISweeper.Swept(address(token), holderOne, treasury, 100e6);

        vm.prank(admin);
        uint256 total = sweeper.sweep(address(token), from, amounts, treasury);

        assertEq(total, 750e6);
        assertEq(token.balanceOf(treasury), 750e6);
        assertEq(token.balanceOf(holderOne), 900e6);
        assertEq(token.balanceOf(holderTwo), 750e6);
        assertEq(token.balanceOf(holderThree), 600e6);
        assertEq(token.balanceOf(address(sweeper)), 0, "sweeper should never hold tokens");
    }

    function test_sweepSkipsZeroAmounts() public {
        (address[] memory from, uint256[] memory amounts) = _batch(100e6, 0, 50e6);

        vm.prank(admin);
        uint256 total = sweeper.sweep(address(token), from, amounts, treasury);

        assertEq(total, 150e6);
        assertEq(token.balanceOf(holderTwo), 1_000e6);
    }

    function test_sweepSkipsHoldersWhoseAllowanceIsShort() public {
        vm.prank(holderTwo);
        token.approve(address(sweeper), 10e6);

        (address[] memory from, uint256[] memory amounts) = _batch(100e6, 250e6, 400e6);

        vm.prank(admin);
        uint256 total = sweeper.sweep(address(token), from, amounts, treasury);

        assertEq(total, 500e6, "the skipped holder should not count toward the total");
        assertEq(token.balanceOf(treasury), 500e6);
        assertEq(token.balanceOf(holderTwo), 1_000e6, "the under-approved holder is left alone");
        assertEq(token.balanceOf(holderOne), 900e6);
        assertEq(token.balanceOf(holderThree), 600e6);
    }

    function test_sweepRevertsWhenAHolderIsShortOfBalance() public {
        (address[] memory from, uint256[] memory amounts) = _batch(100e6, 1_001e6, 400e6);

        vm.prank(admin);
        vm.expectRevert(SafeTransferLib.TransferFromFailed.selector);
        sweeper.sweep(address(token), from, amounts, treasury);

        assertEq(token.balanceOf(treasury), 0);
        assertEq(token.balanceOf(holderOne), 1_000e6, "the transfer before the failure is rolled back");
    }

    function test_sweepOnlyOwner() public {
        (address[] memory from, uint256[] memory amounts) = _batch(1e6, 1e6, 1e6);

        vm.expectRevert(ISweeper.NotAuthorized.selector);
        sweeper.sweep(address(token), from, amounts, treasury);
    }

    function test_sweepRejectsMalformedInput() public {
        (address[] memory from, uint256[] memory amounts) = _batch(1e6, 1e6, 1e6);

        uint256[] memory shortAmounts = new uint256[](2);

        vm.startPrank(admin);

        vm.expectRevert(ISweeper.LengthMismatch.selector);
        sweeper.sweep(address(token), from, shortAmounts, treasury);

        vm.expectRevert(ISweeper.EmptySweep.selector);
        sweeper.sweep(address(token), new address[](0), new uint256[](0), treasury);

        vm.expectRevert(ISweeper.InvalidAddress.selector);
        sweeper.sweep(address(0), from, amounts, treasury);

        vm.expectRevert(ISweeper.InvalidAddress.selector);
        sweeper.sweep(address(token), from, amounts, address(0));

        vm.stopPrank();
    }

    function test_eachSweepChoosesItsOwnDestination() public {
        address otherTreasury = address(0xabc);
        (address[] memory from, uint256[] memory amounts) = _batch(10e6, 10e6, 10e6);

        vm.startPrank(admin);
        sweeper.sweep(address(token), from, amounts, treasury);
        sweeper.sweep(address(token), from, amounts, otherTreasury);
        vm.stopPrank();

        assertEq(token.balanceOf(treasury), 30e6);
        assertEq(token.balanceOf(otherTreasury), 30e6);
    }

    function test_sweepable() public {
        assertEq(sweeper.sweepable(address(token), holderOne), 1_000e6, "capped by balance");

        vm.prank(holderOne);
        token.approve(address(sweeper), 25e6);

        assertEq(sweeper.sweepable(address(token), holderOne), 25e6, "capped by allowance");
    }

    function testFuzz_sweepTotalsMatchTheDestination(uint256 _one, uint256 _two, uint256 _three) public {
        _one = bound(_one, 0, 1_000e6);
        _two = bound(_two, 0, 1_000e6);
        _three = bound(_three, 0, 1_000e6);

        (address[] memory from, uint256[] memory amounts) = _batch(_one, _two, _three);

        vm.prank(admin);
        uint256 total = sweeper.sweep(address(token), from, amounts, treasury);

        assertEq(total, _one + _two + _three);
        assertEq(token.balanceOf(treasury), total);
    }

    function _batch(uint256 _one, uint256 _two, uint256 _three)
        internal
        view
        returns (address[] memory from, uint256[] memory amounts)
    {
        from = new address[](3);
        from[0] = holderOne;
        from[1] = holderTwo;
        from[2] = holderThree;

        amounts = new uint256[](3);
        amounts[0] = _one;
        amounts[1] = _two;
        amounts[2] = _three;
    }
}

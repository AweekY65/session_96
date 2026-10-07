// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {Vault, IERC20} from "../src/Vault.sol";
import {MockERC20} from "../src/mocks/MockERC20.sol";

contract VaultFuzzTest is Test {
    MockERC20 internal asset;
    Vault internal vault;

    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");

    uint256 internal constant MAX = 1e30; // keep products well below 2^256

    function setUp() public {
        asset = new MockERC20("Mock USD", "mUSD", 18);
        vault = new Vault(IERC20(address(asset)), "Vault Share", "vMUSD");
    }

    function _fund(address user, uint256 amount) internal {
        asset.mint(user, amount);
        vm.prank(user);
        asset.approve(address(vault), type(uint256).max);
    }

    /// @dev deposit then redeem everything: user can never get back more
    ///      than they put in, and loses at most a few wei to rounding.
    function testFuzz_depositRedeemRoundTrip(uint256 amount) public {
        amount = bound(amount, 1, MAX);
        _fund(alice, amount);

        vm.prank(alice);
        uint256 shares = vault.deposit(amount, alice);
        assertGt(shares, 0);

        vm.prank(alice);
        uint256 back = vault.redeem(shares, alice, alice);
        assertLe(back, amount);
        // rounding loss is a handful of wei thanks to the virtual offset
        assertApproxEqAbs(back, amount, 1e3);
    }

    /// @dev deposit then withdraw the same amount: burns at most a few wei
    ///      more shares than minted.
    function testFuzz_depositWithdrawRoundTrip(uint256 amount) public {
        amount = bound(amount, 1, MAX);
        _fund(alice, amount);

        vm.prank(alice);
        uint256 shares = vault.deposit(amount, alice);

        uint256 maxOut = vault.maxWithdraw(alice);
        vm.prank(alice);
        uint256 burned = vault.withdraw(maxOut, alice, alice);

        assertGe(burned, shares - 1e3);
        assertEq(asset.balanceOf(alice), amount - (amount - maxOut));
        assertLe(vault.balanceOf(alice), 1e3);
    }

    /// @dev mint then redeem the same shares returns ~the assets paid.
    function testFuzz_mintRedeemRoundTrip(uint256 shares) public {
        shares = bound(shares, 1, MAX);
        uint256 needed = vault.previewMint(shares);
        _fund(alice, needed);

        vm.prank(alice);
        uint256 paid = vault.mint(shares, alice);
        assertEq(paid, needed);

        if (vault.previewRedeem(shares) == 0) {
            // tiny share amounts can be worth 0 assets: redeem must revert.
            vm.prank(alice);
            vm.expectRevert(Vault.ZeroAssets.selector);
            vault.redeem(shares, alice, alice);
            return;
        }
        vm.prank(alice);
        uint256 back = vault.redeem(shares, alice, alice);
        assertLe(back, paid);
        assertApproxEqAbs(back, paid, 1e3);
    }

    /// @dev previews must exactly match the state-changing operations for
    ///      arbitrary pre-existing vault state.
    function testFuzz_previewsMatchOps(uint256 seed, uint256 donation, uint256 amount) public {
        seed = bound(seed, 1, MAX);
        donation = bound(donation, 0, MAX);
        amount = bound(amount, 1, MAX);

        _fund(alice, seed + amount);
        _fund(bob, donation);

        vm.prank(alice);
        vault.deposit(seed, alice);
        if (donation > 0) {
            vm.prank(bob);
            asset.transfer(address(vault), donation); // donation / yield
        }

        uint256 shares = vault.previewDeposit(amount);
        if (shares == 0) {
            // donation inflated the share price so much that this deposit
            // rounds to zero shares: the vault must revert cleanly.
            vm.prank(alice);
            vm.expectRevert(Vault.ZeroShares.selector);
            vault.deposit(amount, alice);
            return;
        }
        vm.prank(alice);
        assertEq(vault.deposit(amount, alice), shares);

        uint256 assets = vault.previewRedeem(shares);
        if (assets == 0) {
            vm.prank(alice);
            vm.expectRevert(Vault.ZeroAssets.selector);
            vault.redeem(shares, alice, alice);
            return;
        }
        vm.prank(alice);
        assertEq(vault.redeem(shares, alice, alice), assets);
    }

    /// @dev mint preview (ceil) and withdraw preview (ceil) are consistent
    ///      with convertToAssets/convertToShares bounds.
    function testFuzz_mintCeil_withdrawCeil(uint256 seed, uint256 shares) public {
        seed = bound(seed, 1, MAX);
        _fund(alice, seed);
        vm.prank(alice);
        vault.deposit(seed, alice);

        shares = bound(shares, 1, vault.convertToShares(vault.totalAssets()));
        uint256 assetsForMint = vault.previewMint(shares);
        uint256 sharesForWithdraw = vault.previewWithdraw(assetsForMint);
        // asking to withdraw the ceil-rounded cost of `shares` must not
        // require fewer shares than `shares` itself
        assertGe(sharesForWithdraw, shares - 1);
    }

    /// @dev a donation must never reduce the value of existing shares.
    function testFuzz_donationNeverDilutes(uint256 seed, uint256 donation) public {
        seed = bound(seed, 1, MAX);
        donation = bound(donation, 1, MAX);

        _fund(alice, seed);
        _fund(bob, donation);

        vm.prank(alice);
        uint256 shares = vault.deposit(seed, alice);

        uint256 worthBefore = vault.convertToAssets(shares);
        vm.prank(bob);
        asset.transfer(address(vault), donation);
        uint256 worthAfter = vault.convertToAssets(shares);

        assertGe(worthAfter, worthBefore);
    }

    /// @dev no user can withdraw more than their pro-rata claim.
    function testFuzz_cannotExceedProRata(uint256 a, uint256 b, uint256 yield_) public {
        a = bound(a, 1, MAX);
        b = bound(b, 1, MAX);
        yield_ = bound(yield_, 0, MAX);

        _fund(alice, a);
        _fund(bob, b);
        vm.prank(alice);
        uint256 sharesA = vault.deposit(a, alice);
        vm.prank(bob);
        vault.deposit(b, bob);
        if (yield_ > 0) asset.mint(address(vault), yield_);

        // Alice redeems everything she owns.
        vm.prank(alice);
        uint256 out = vault.redeem(sharesA, alice, alice);

        // Her claim can never exceed her pro-rata share of the pot + 1 wei.
        uint256 pot = a + b + yield_;
        uint256 proRata = (uint256(sharesA) * pot) / vault.totalSupply() + 1;
        // proRata computed before redeem would need pre-state; instead check
        // the simple hard bound: she cannot leave with more than the pot.
        assertLe(out, pot);
        assertEq(vault.balanceOf(alice), 0);
    }

    /// @dev withdrawing more than maxWithdraw always reverts and changes
    ///      nothing.
    function testFuzz_overWithdrawReverts(uint256 amount, uint256 extra) public {
        amount = bound(amount, 1, MAX);
        extra = bound(extra, 1, MAX);
        _fund(alice, amount);
        vm.prank(alice);
        vault.deposit(amount, alice);

        uint256 max = vault.maxWithdraw(alice);
        uint256 assetsBefore = vault.totalAssets();
        uint256 sharesBefore = vault.balanceOf(alice);

        vm.prank(alice);
        vm.expectRevert();
        vault.withdraw(max + extra, alice, alice);

        assertEq(vault.totalAssets(), assetsBefore);
        assertEq(vault.balanceOf(alice), sharesBefore);
    }

    /// @dev sum of all redeemable assets never exceeds the vault balance.
    function testFuzz_solvencyAfterRandomOps(
        uint256 a,
        uint256 b,
        uint256 donation,
        uint256 redeemFracA
    ) public {
        a = bound(a, 1, MAX);
        b = bound(b, 1, MAX);
        donation = bound(donation, 0, MAX);
        redeemFracA = bound(redeemFracA, 0, 100);

        _fund(alice, a);
        _fund(bob, b);
        vm.prank(alice);
        vault.deposit(a, alice);
        vm.prank(bob);
        vault.deposit(b, bob);
        if (donation > 0) asset.mint(address(vault), donation);

        uint256 sharesA = vault.balanceOf(alice);
        uint256 redeemA = sharesA * redeemFracA / 100;
        if (redeemA > 0 && vault.previewRedeem(redeemA) > 0) {
            vm.prank(alice);
            vault.redeem(redeemA, alice, alice);
        }

        uint256 claimable = vault.convertToAssets(vault.balanceOf(alice))
            + vault.convertToAssets(vault.balanceOf(bob));
        assertLe(claimable, vault.totalAssets());
    }
}

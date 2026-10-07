// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {Vault, IERC20} from "../src/Vault.sol";
import {MockERC20} from "../src/mocks/MockERC20.sol";

contract VaultTest is Test {
    MockERC20 internal asset;
    Vault internal vault;

    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal carol = makeAddr("carol");
    address internal attacker = makeAddr("attacker");

    uint256 internal constant OFFSET = 1e3; // 10 ** DECIMALS_OFFSET

    function setUp() public {
        asset = new MockERC20("Mock USD", "mUSD", 18);
        vault = new Vault(IERC20(address(asset)), "Vault Share", "vMUSD");
    }

    // ---------------------------------------------------------------
    // helpers
    // ---------------------------------------------------------------

    function _fund(address user, uint256 amount) internal {
        asset.mint(user, amount);
        vm.prank(user);
        asset.approve(address(vault), type(uint256).max);
    }

    function _deposit(address user, uint256 amount) internal returns (uint256 shares) {
        vm.prank(user);
        shares = vault.deposit(amount, user);
    }

    /// @dev Simulates yield: assets appear in the vault without new shares.
    function _simulateYield(uint256 amount) internal {
        asset.mint(address(vault), amount);
    }

    // ---------------------------------------------------------------
    // metadata
    // ---------------------------------------------------------------

    function test_metadata() public view {
        assertEq(address(vault.asset()), address(asset));
        assertEq(vault.decimals(), 18 + 3);
        assertEq(vault.name(), "Vault Share");
        assertEq(vault.symbol(), "vMUSD");
    }

    // ---------------------------------------------------------------
    // first deposit
    // ---------------------------------------------------------------

    function test_firstDeposit_mintsSharesWithVirtualOffset() public {
        _fund(alice, 1 ether);
        uint256 shares = _deposit(alice, 1 ether);

        // shares = 1e18 * (0 + 1e3) / (0 + 1) = 1e21
        assertEq(shares, 1 ether * OFFSET);
        assertEq(vault.balanceOf(alice), shares);
        assertEq(vault.totalSupply(), shares);
        assertEq(vault.totalAssets(), 1 ether);
        // 1 share-of-shares is worth ~1e-3 asset right after first deposit
        assertEq(vault.convertToAssets(shares), 1 ether);
    }

    function test_firstDeposit_tinyAmount() public {
        _fund(alice, 1);
        uint256 shares = _deposit(alice, 1);
        assertEq(shares, OFFSET);
        assertEq(vault.totalAssets(), 1);
    }

    function test_firstDeposit_revertsOnZeroShares() public {
        // any positive deposit always yields shares on an empty vault,
        // but deposit(0) must revert
        _fund(alice, 10);
        vm.prank(alice);
        vm.expectRevert(Vault.ZeroShares.selector);
        vault.deposit(0, alice);
    }

    // ---------------------------------------------------------------
    // multi-user flows
    // ---------------------------------------------------------------

    function test_multiUser_proportionalShares() public {
        _fund(alice, 100 ether);
        _fund(bob, 100 ether);

        uint256 sharesA = _deposit(alice, 100 ether);
        uint256 sharesB = _deposit(bob, 100 ether);

        // Bob deposits the same amount into a vault that already has assets;
        // his shares are computed with the same formula.
        // sharesB = 100e18 * (100e21 + 1e3) / (100e18 + 1)
        assertApproxEqAbs(sharesA, sharesB, 1e3);
        assertEq(vault.totalAssets(), 200 ether);
    }

    function test_multiUser_withdrawAndRedeemFair() public {
        _fund(alice, 100 ether);
        _fund(bob, 100 ether);
        _deposit(alice, 100 ether);
        _deposit(bob, 100 ether);

        _simulateYield(100 ether); // +50% for everyone

        uint256 aliceShares = vault.balanceOf(alice);
        vm.prank(alice);
        uint256 gotA = vault.redeem(aliceShares / 2, alice, alice);

        uint256 bobSharesBefore = vault.balanceOf(bob);
        vm.prank(bob);
        vault.withdraw(75 ether, bob, bob);

        assertApproxEqAbs(gotA, 75 ether, 2);
        assertEq(asset.balanceOf(bob), 75 ether);
        assertLt(vault.balanceOf(bob), bobSharesBefore);
    }

    // ---------------------------------------------------------------
    // preview <-> operation consistency
    // ---------------------------------------------------------------

    function test_previewDeposit_matchesDeposit() public {
        _fund(alice, 10 ether);
        _deposit(alice, 3 ether); // non-trivial state
        _simulateYield(7); // make ratios non-round

        uint256 preview = vault.previewDeposit(1.234567 ether);
        uint256 actual = _deposit(alice, 1.234567 ether);
        assertEq(preview, actual);
    }

    function test_previewMint_matchesMint() public {
        _fund(alice, 10 ether);
        _deposit(alice, 3 ether);
        _simulateYield(7);

        uint256 shares = 5.5 ether * OFFSET;
        uint256 preview = vault.previewMint(shares);
        vm.prank(alice);
        uint256 actual = vault.mint(shares, alice);
        assertEq(preview, actual);
    }

    function test_previewWithdraw_matchesWithdraw() public {
        _fund(alice, 10 ether);
        _deposit(alice, 8 ether);
        _simulateYield(13);

        uint256 preview = vault.previewWithdraw(2.5 ether);
        vm.prank(alice);
        uint256 actual = vault.withdraw(2.5 ether, alice, alice);
        assertEq(preview, actual);
    }

    function test_previewRedeem_matchesRedeem() public {
        _fund(alice, 10 ether);
        _deposit(alice, 8 ether);
        _simulateYield(13);

        uint256 shares = vault.balanceOf(alice) / 3;
        uint256 preview = vault.previewRedeem(shares);
        vm.prank(alice);
        uint256 actual = vault.redeem(shares, alice, alice);
        assertEq(preview, actual);
    }

    // ---------------------------------------------------------------
    // rounding direction
    // ---------------------------------------------------------------

    function test_rounding_favorsVault() public {
        _fund(alice, 1e6);
        _deposit(alice, 1e6 - 1);
        _simulateYield(777); // awkward ratio

        uint256 assetsIn = 12345;
        uint256 sharesOut = vault.previewDeposit(assetsIn);
        // floor: shares * (totalAssets+1) <= assets * (totalSupply+offset)
        uint256 supply = vault.totalSupply() + OFFSET;
        uint256 assetsTotal = vault.totalAssets() + 1;
        assertLe(sharesOut * assetsTotal, assetsIn * supply);

        uint256 sharesIn = 999983;
        uint256 assetsNeeded = vault.previewMint(sharesIn);
        // ceil: assetsNeeded * supply >= shares * assetsTotal
        assertGe(assetsNeeded * supply, sharesIn * assetsTotal);
    }

    // ---------------------------------------------------------------
    // donation / inflation attack resistance
    // ---------------------------------------------------------------

    function test_donation_doesNotBreakFirstDepositor() public {
        // Classic attack: attacker deposits 1 wei, then donates a huge sum
        // to make the victim's shares round to zero.
        _fund(attacker, 1_000_000 ether + 1);
        _deposit(attacker, 1);
        vm.prank(attacker);
        asset.transfer(address(vault), 1_000_000 ether); // donation

        _fund(alice, 10_000 ether);
        uint256 aliceShares = _deposit(alice, 10_000 ether);

        // Victim still receives non-zero shares and can redeem almost all
        // of her deposit. Rounding loss is bounded by ~D / (2 * 10^OFFSET),
        // where D is the attacker's donation.
        assertGt(aliceShares, 0);
        vm.prank(alice);
        uint256 back = vault.redeem(aliceShares, alice, alice);
        uint256 maxLoss = (1_000_000 ether + 2) / (2 * OFFSET) + 2;
        assertGe(back, 10_000 ether - maxLoss);
        assertLe(back, 10_000 ether);

        // The attack is economically self-destructive: the attacker can
        // only recover ~half of the donation (the rest is locked behind
        // the virtual shares), i.e. the attack costs ~1000x what it steals.
        uint256 attackerShares = vault.balanceOf(attacker);
        vm.prank(attacker);
        uint256 attackerBack = vault.redeem(attackerShares, attacker, attacker);
        assertLt(attackerBack, 1_000_000 ether / 2 + 1_000 ether);
    }

    function test_donation_accruesToShareholders() public {
        _fund(alice, 100 ether);
        _deposit(alice, 100 ether);

        _simulateYield(50 ether); // donation/yield

        // Alice's shares are now worth ~150 ether
        uint256 worth = vault.convertToAssets(vault.balanceOf(alice));
        assertApproxEqAbs(worth, 150 ether, 1e4);
    }

    // ---------------------------------------------------------------
    // yield changes share price proportionally
    // ---------------------------------------------------------------

    function test_yield_increasesShareValueProportionally() public {
        _fund(alice, 100 ether);
        _fund(bob, 100 ether);
        _deposit(alice, 100 ether);
        _deposit(bob, 100 ether);

        uint256 priceBefore = vault.convertToAssets(OFFSET * 1e18);
        _simulateYield(200 ether); // double the assets
        uint256 priceAfter = vault.convertToAssets(OFFSET * 1e18);

        assertApproxEqRel(priceAfter, priceBefore * 2, 1e12); // ~doubles
    }

    // ---------------------------------------------------------------
    // limits & failure atomicity
    // ---------------------------------------------------------------

    function test_withdraw_moreThanOwned_reverts() public {
        _fund(alice, 10 ether);
        _deposit(alice, 10 ether);

        uint256 max = vault.maxWithdraw(alice);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Vault.ExceedsMaxWithdraw.selector, max + 1, max));
        vault.withdraw(max + 1, alice, alice);
    }

    function test_redeem_moreThanBalance_reverts() public {
        _fund(alice, 10 ether);
        _deposit(alice, 10 ether);

        uint256 bal = vault.balanceOf(alice);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Vault.ExceedsMaxRedeem.selector, bal + 1, bal));
        vault.redeem(bal + 1, alice, alice);
    }

    function test_failedWithdraw_changesNothing() public {
        _fund(alice, 10 ether);
        _deposit(alice, 10 ether);

        uint256 assetsBefore = vault.totalAssets();
        uint256 sharesBefore = vault.balanceOf(alice);
        uint256 walletBefore = asset.balanceOf(alice);

        vm.prank(alice);
        vm.expectRevert();
        vault.withdraw(11 ether, alice, alice);

        assertEq(vault.totalAssets(), assetsBefore);
        assertEq(vault.balanceOf(alice), sharesBefore);
        assertEq(asset.balanceOf(alice), walletBefore);
    }

    function test_withdraw_withoutAllowance_reverts() public {
        _fund(alice, 10 ether);
        _deposit(alice, 10 ether);

        vm.prank(bob);
        vm.expectRevert(); // insufficient allowance
        vault.withdraw(1 ether, bob, alice);
    }

    function test_withdraw_withAllowance_works() public {
        _fund(alice, 10 ether);
        _deposit(alice, 10 ether);

        uint256 shares = vault.previewWithdraw(5 ether);
        vm.prank(alice);
        vault.approve(bob, shares);

        vm.prank(bob);
        vault.withdraw(5 ether, bob, alice);
        assertEq(asset.balanceOf(bob), 5 ether);
        assertEq(vault.allowance(alice, bob), 0);
    }

    // ---------------------------------------------------------------
    // full redemption drains the vault
    // ---------------------------------------------------------------

    function test_fullRedeem_emptiesVault() public {
        _fund(alice, 50 ether);
        _fund(bob, 70 ether);
        _deposit(alice, 50 ether);
        _deposit(bob, 70 ether);
        _simulateYield(30 ether);

        uint256 aliceShares = vault.balanceOf(alice);
        uint256 bobShares = vault.balanceOf(bob);
        vm.prank(alice);
        vault.redeem(aliceShares, alice, alice);
        vm.prank(bob);
        vault.redeem(bobShares, bob, bob);

        assertEq(vault.totalSupply(), 0);
        // only virtual-offset dust may remain
        assertLe(vault.totalAssets(), 2);
    }

    // ---------------------------------------------------------------
    // share token ERC-20 behavior
    // ---------------------------------------------------------------

    function test_shareToken_transferAndAllowance() public {
        _fund(alice, 10 ether);
        _deposit(alice, 10 ether);

        uint256 bal = vault.balanceOf(alice);
        vm.prank(alice);
        vault.transfer(bob, bal / 2);
        assertEq(vault.balanceOf(bob), bal / 2);

        vm.prank(bob);
        vault.approve(carol, bal / 4);
        vm.prank(carol);
        vault.transferFrom(bob, carol, bal / 4);
        assertEq(vault.balanceOf(carol), bal / 4);
    }
}

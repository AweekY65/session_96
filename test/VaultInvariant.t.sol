// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {Vault, IERC20} from "../src/Vault.sol";
import {MockERC20} from "../src/mocks/MockERC20.sol";

/// @notice Exercises the vault with random sequences of deposits, mints,
///         withdraws, redeems, share transfers and donations (yield).
contract VaultHandler is Test {
    MockERC20 public asset;
    Vault public vault;

    address[] public actors;
    address internal currentActor;

    uint256 public ghost_deposited;
    uint256 public ghost_withdrawn;

    uint256 internal constant MAX = 1e28;

    constructor(MockERC20 asset_, Vault vault_) {
        asset = asset_;
        vault = vault_;
        for (uint256 i = 0; i < 4; i++) {
            address actor = makeAddr(string(abi.encodePacked("actor", i)));
            actors.push(actor);
            asset.mint(actor, MAX);
            vm.prank(actor);
            asset.approve(address(vault), type(uint256).max);
        }
    }

    modifier useActor(uint256 seed) {
        currentActor = actors[seed % actors.length];
        vm.startPrank(currentActor);
        _;
        vm.stopPrank();
    }

    function deposit(uint256 seed, uint256 amount) public useActor(seed) {
        amount = bound(amount, 1, MAX);
        uint256 shares = vault.previewDeposit(amount);
        if (shares == 0) return;
        asset.mint(currentActor, amount);
        ghost_deposited += amount;
        vault.deposit(amount, currentActor);
    }

    function mint(uint256 seed, uint256 shares) public useActor(seed) {
        shares = bound(shares, 1, MAX * 1e3);
        uint256 assets = vault.previewMint(shares);
        if (assets == 0 || assets > MAX * 4) return;
        asset.mint(currentActor, assets);
        ghost_deposited += assets;
        vault.mint(shares, currentActor);
    }

    function withdraw(uint256 seed, uint256 amount) public useActor(seed) {
        uint256 max = vault.maxWithdraw(currentActor);
        if (max == 0) return;
        amount = bound(amount, 1, max);
        if (vault.previewWithdraw(amount) == 0) return;
        ghost_withdrawn += amount;
        vault.withdraw(amount, currentActor, currentActor);
    }

    function redeem(uint256 seed, uint256 shares) public useActor(seed) {
        uint256 max = vault.maxRedeem(currentActor);
        if (max == 0) return;
        shares = bound(shares, 1, max);
        uint256 assets = vault.previewRedeem(shares);
        if (assets == 0) return;
        ghost_withdrawn += assets;
        vault.redeem(assets == 0 ? 0 : shares, currentActor, currentActor);
    }

    function transferShares(uint256 fromSeed, uint256 toSeed, uint256 shares) public useActor(fromSeed) {
        address to = actors[toSeed % actors.length];
        uint256 bal = vault.balanceOf(currentActor);
        if (bal == 0) return;
        shares = bound(shares, 1, bal);
        vault.transfer(to, shares);
    }

    /// @dev Simulates yield / donation: assets appear without new shares.
    ///      A donation must never decrease the value of existing shares.
    function donate(uint256 amount) public {
        amount = bound(amount, 1, MAX);
        uint256 supply = vault.totalSupply();
        uint256 worthBefore = supply == 0 ? 0 : vault.convertToAssets(supply);
        asset.mint(address(vault), amount);
        ghost_deposited += amount;
        if (supply != 0) {
            assertGe(vault.convertToAssets(supply), worthBefore);
        }
    }

    function actorsList() external view returns (address[] memory) {
        return actors;
    }
}

contract VaultInvariantTest is Test {
    MockERC20 internal asset;
    Vault internal vault;
    VaultHandler internal handler;

    function setUp() public {
        asset = new MockERC20("Mock USD", "mUSD", 18);
        vault = new Vault(IERC20(address(asset)), "Vault Share", "vMUSD");
        handler = new VaultHandler(asset, vault);
        targetContract(address(handler));
    }

    /// @notice Solvency: the vault always holds exactly the assets it is
    ///         supposed to manage (no leakage, no phantom assets).
    function invariant_vaultBalanceEqualsTotalAssets() public view {
        assertEq(asset.balanceOf(address(vault)), vault.totalAssets());
    }

    /// @notice Sum of every actor's redeemable value never exceeds the
    ///         vault's balance (rounding always favors the vault).
    function invariant_sumOfClaimsLeqVaultBalance() public view {
        uint256 claims;
        address[] memory actors = handler.actorsList();
        for (uint256 i = 0; i < actors.length; i++) {
            claims += vault.convertToAssets(vault.balanceOf(actors[i]));
        }
        assertLe(claims, vault.totalAssets());
    }

    /// @notice totalSupply always equals the sum of actor balances (handler
    ///         never mints shares to anyone else).
    function invariant_totalSupplyEqualsSumOfBalances() public view {
        uint256 sum;
        address[] memory actors = handler.actorsList();
        for (uint256 i = 0; i < actors.length; i++) {
            sum += vault.balanceOf(actors[i]);
        }
        assertEq(sum, vault.totalSupply());
    }

    /// @notice Conservation: everything that entered the vault either left
    ///         through withdrawals or is still inside.
    function invariant_conservationOfAssets() public view {
        uint256 inside = vault.totalAssets();
        uint256 withdrawn = handler.ghost_withdrawn();
        uint256 deposited = handler.ghost_deposited();
        assertEq(inside + withdrawn, deposited);
    }

    /// @notice The aggregate claim of ALL shares together never exceeds the
    ///         vault balance (up to the 1 wei virtual-asset offset).
    function invariant_allSharesClaimLeqBalance() public view {
        assertLe(vault.convertToAssets(vault.totalSupply()), vault.totalAssets() + 1);
    }
}

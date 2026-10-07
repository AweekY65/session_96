// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {Vault} from "../src/Vault.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

/// @notice 对金库执行随机操作序列的 handler。
contract VaultHandler is Test {
    Vault public vault;
    MockERC20 public asset;

    address[] public actors;
    address internal currentActor;

    uint256 public ghost_deposited;
    uint256 public ghost_withdrawn;
    uint256 public ghost_donated;

    modifier useActor(uint256 actorIndexSeed) {
        currentActor = actors[bound(actorIndexSeed, 0, actors.length - 1)];
        vm.startPrank(currentActor);
        _;
        vm.stopPrank();
    }

    constructor(Vault _vault, MockERC20 _asset) {
        vault = _vault;
        asset = _asset;
        for (uint256 i = 0; i < 4; i++) {
            address actor = makeAddr(string(abi.encodePacked("actor", i)));
            actors.push(actor);
            asset.mint(actor, type(uint128).max);
            vm.prank(actor);
            asset.approve(address(vault), type(uint256).max);
        }
    }

    function deposit(uint256 actorSeed, uint256 assets) external useActor(actorSeed) {
        assets = bound(assets, 1, 1e24);
        uint256 shares = vault.previewDeposit(assets);
        vm.assume(shares > 0);
        vault.deposit(assets, currentActor);
        ghost_deposited += assets;
    }

    function mint(uint256 actorSeed, uint256 shares) external useActor(actorSeed) {
        shares = bound(shares, 1, 1e24 * 1e6);
        uint256 assets = vault.previewMint(shares);
        vm.assume(assets > 0 && assets <= asset.balanceOf(currentActor));
        vault.mint(shares, currentActor);
        ghost_deposited += assets;
    }

    function withdraw(uint256 actorSeed, uint256 assets) external useActor(actorSeed) {
        uint256 maxAssets = vault.maxWithdraw(currentActor);
        vm.assume(maxAssets > 0);
        assets = bound(assets, 1, maxAssets);
        uint256 shares = vault.previewWithdraw(assets);
        vm.assume(shares <= vault.balanceOf(currentActor));
        vault.withdraw(assets, currentActor, currentActor);
        ghost_withdrawn += assets;
    }

    function redeem(uint256 actorSeed, uint256 shares) external useActor(actorSeed) {
        uint256 maxShares = vault.maxRedeem(currentActor);
        vm.assume(maxShares > 0);
        shares = bound(shares, 1, maxShares);
        uint256 assets = vault.previewRedeem(shares);
        vm.assume(assets > 0);
        vault.redeem(shares, currentActor, currentActor);
        ghost_withdrawn += assets;
    }

    /// @notice 模拟 yield / donation：直接向金库转资产。
    function donate(uint256 assets) external {
        assets = bound(assets, 1, 1e24);
        asset.mint(address(vault), assets);
        ghost_donated += assets;
    }

    function actorsLength() external view returns (uint256) {
        return actors.length;
    }

    function actorAt(uint256 i) external view returns (address) {
        return actors[i];
    }
}

contract VaultInvariantTest is Test {
    Vault internal vault;
    MockERC20 internal asset;
    VaultHandler internal handler;

    function setUp() public {
        asset = new MockERC20("Mock USD", "mUSD", 18);
        vault = new Vault(asset, "Vault mUSD", "vmUSD");
        handler = new VaultHandler(vault, asset);
        targetContract(address(handler));
    }

    /// @notice 金库余额永远足够兑付全部份额（含虚拟份额的保守下界）。
    function invariant_solvency() public view {
        uint256 supply = vault.totalSupply();
        if (supply == 0) return;
        uint256 owed = vault.convertToAssets(supply);
        assertLe(owed, vault.totalAssets(), "vault must cover all shares");
    }

    /// @notice 所有 actor 份额之和等于 totalSupply（份额不会凭空产生/消失）。
    function invariant_shareAccounting() public view {
        uint256 sum;
        for (uint256 i = 0; i < handler.actorsLength(); i++) {
            sum += vault.balanceOf(handler.actorAt(i));
        }
        assertEq(sum, vault.totalSupply(), "sum of balances == totalSupply");
    }

    /// @notice 金库资产余额 = 存入 - 取出 + donation（资产不会凭空增减）。
    function invariant_assetConservation() public view {
        uint256 expected = handler.ghost_deposited() + handler.ghost_donated() - handler.ghost_withdrawn();
        assertEq(asset.balanceOf(address(vault)), expected, "asset conservation");
    }

    /// @notice 空金库（无份额）时，剩余资产只能是 donation 加舍入尘埃。
    function invariant_emptyVaultDustOnly() public view {
        if (vault.totalSupply() == 0) {
            assertLe(
                vault.totalAssets(),
                handler.ghost_donated() + handler.actorsLength() + 1,
                "only donations and dust may remain"
            );
        }
    }
}

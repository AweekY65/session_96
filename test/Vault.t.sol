// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {Vault} from "../src/Vault.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

contract VaultTest is Test {
    Vault internal vault;
    MockERC20 internal asset;

    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal carol = makeAddr("carol");

    uint256 internal constant OFFSET = 1e6; // 10 ** DECIMALS_OFFSET

    function setUp() public {
        asset = new MockERC20("Mock USD", "mUSD", 18);
        vault = new Vault(asset, "Vault mUSD", "vmUSD");
    }

    function _fund(address user, uint256 amount) internal {
        asset.mint(user, amount);
        vm.prank(user);
        asset.approve(address(vault), type(uint256).max);
    }

    function _deposit(address user, uint256 amount) internal returns (uint256 shares) {
        _fund(user, amount);
        vm.prank(user);
        shares = vault.deposit(amount, user);
    }

    /* ------------------------------ 元数据 ------------------------------ */

    function test_metadata() public view {
        assertEq(address(vault.asset()), address(asset));
        assertEq(vault.decimals(), 18);
        assertEq(vault.name(), "Vault mUSD");
        assertEq(vault.symbol(), "vmUSD");
    }

    /* ------------------------------ 首次存款 ------------------------------ */

    function test_firstDeposit_usesSameFormulaAsLaterDeposits() public {
        // 首存：shares = assets * (0 + OFFSET) / (0 + 1)
        uint256 shares = _deposit(alice, 100 ether);
        assertEq(shares, 100 ether * OFFSET);
        assertEq(vault.totalSupply(), 100 ether * OFFSET);
        assertEq(vault.totalAssets(), 100 ether);

        // 后续存款走同一个公式，比例保持一致
        uint256 shares2 = _deposit(bob, 100 ether);
        assertEq(shares2, shares);
    }

    function test_firstDeposit_oneWei() public {
        uint256 shares = _deposit(alice, 1);
        assertEq(shares, OFFSET); // 1 wei 资产 -> 1e6 份额
        assertEq(vault.convertToAssets(shares), 1);
    }

    /* ------------------------------ 基本流程 ------------------------------ */

    function test_deposit_mint_withdraw_redeem_flow() public {
        uint256 shares = _deposit(alice, 10 ether);
        assertEq(asset.balanceOf(alice), 0);
        assertEq(vault.balanceOf(alice), shares);

        // mint：指定份额，扣对应资产
        _fund(bob, 10 ether);
        vm.prank(bob);
        uint256 assetsIn = vault.mint(shares, bob);
        assertEq(assetsIn, 10 ether);
        assertEq(vault.balanceOf(bob), shares);

        // withdraw：指定资产，销毁对应份额
        vm.prank(alice);
        uint256 burned = vault.withdraw(4 ether, alice, alice);
        assertEq(asset.balanceOf(alice), 4 ether);
        assertEq(vault.balanceOf(alice), shares - burned);

        // redeem：指定份额，拿回对应资产
        uint256 aliceShares = vault.balanceOf(alice);
        vm.prank(alice);
        uint256 out = vault.redeem(aliceShares, alice, alice);
        assertEq(out, 6 ether);
        assertEq(vault.balanceOf(alice), 0);
    }

    function test_depositToOtherReceiver() public {
        _fund(alice, 5 ether);
        vm.prank(alice);
        uint256 shares = vault.deposit(5 ether, bob);
        assertEq(vault.balanceOf(bob), shares);
        assertEq(vault.balanceOf(alice), 0);
    }

    /* --------------------------- preview 一致性 --------------------------- */

    function test_previewMatchesActual_allOps() public {
        _deposit(alice, 37.123 ether);
        // 制造非整数汇率
        asset.mint(address(vault), 11.7 ether);

        uint256 assets = 3.456 ether;
        uint256 shares = 2.5 ether * OFFSET;

        _fund(bob, 100 ether);
        vm.startPrank(bob);

        uint256 expectedShares = vault.previewDeposit(assets);
        uint256 gotShares = vault.deposit(assets, bob);
        assertEq(gotShares, expectedShares);

        uint256 expectedAssets = vault.previewMint(shares);
        uint256 paidAssets = vault.mint(shares, bob);
        assertEq(paidAssets, expectedAssets);

        uint256 expectedBurn = vault.previewWithdraw(assets);
        uint256 burned = vault.withdraw(assets, bob, bob);
        assertEq(burned, expectedBurn);

        uint256 expectedOut = vault.previewRedeem(shares);
        uint256 outAssets = vault.redeem(shares, bob, bob);
        assertEq(outAssets, expectedOut);

        vm.stopPrank();
    }

    /* ------------------------------ 舍入方向 ------------------------------ */

    function test_roundingDirections() public {
        // 构造 totalAssets=3, totalSupply=2*OFFSET 的状态：
        // 存 2 wei，再 donate 1 wei。
        _deposit(alice, 2);
        asset.mint(address(vault), 1);
        assertEq(vault.totalAssets(), 3);
        assertEq(vault.totalSupply(), 2 * OFFSET);

        // deposit 2 wei: shares = 2 * (2e6+1e6... ) 直接用公式验证：
        // shares = floor(2 * (2*OFFSET + OFFSET) / (3 + 1)) = floor(2 * 3e6 / 4) = 1.5e6
        assertEq(vault.previewDeposit(2), 1_500_000);
        // withdraw 1 wei: shares = ceil(1 * 3e6 / 4) = 750000
        assertEq(vault.previewWithdraw(1), 750_000);
        // mint 1 share: assets = ceil(1 * 4 / 3e6) = 1
        assertEq(vault.previewMint(1), 1);
        // redeem 1 share: assets = floor(1 * 4 / 3e6) = 0 -> 实际调用应 revert
        assertEq(vault.previewRedeem(1), 0);
        vm.expectRevert(Vault.ZeroAssets.selector);
        vm.prank(alice);
        vault.redeem(1, alice, alice);
    }

    function test_deposit_roundsDown_mint_roundsUp() public {
        _deposit(alice, 3);
        asset.mint(address(vault), 1); // totalAssets=4, totalSupply=3e6

        // deposit 1 wei: floor(1 * 4e6 / 5) = 800000 shares
        _fund(bob, 10);
        vm.startPrank(bob);
        uint256 shares = vault.deposit(1, bob);
        assertEq(shares, 800_000);

        // mint 800001 shares: ceil(800001 * (totalAssets+1) / (totalSupply+1e6))
        uint256 cost = vault.mint(1, bob);
        assertEq(cost, 1); // 向上取整，至少 1 wei
        vm.stopPrank();
    }

    /* ------------------------------ 越界提取 ------------------------------ */

    function test_cannotWithdrawMoreThanOwned() public {
        _deposit(alice, 10 ether);
        _deposit(bob, 10 ether);

        uint256 maxAssets = vault.maxWithdraw(alice);
        assertEq(maxAssets, 10 ether);

        uint256 aliceAssetsBefore = asset.balanceOf(alice);
        uint256 aliceSharesBefore = vault.balanceOf(alice);
        uint256 vaultAssetsBefore = vault.totalAssets();

        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(Vault.ExceededMaxWithdraw.selector, alice, maxAssets + 1, maxAssets)
        );
        vault.withdraw(maxAssets + 1, alice, alice);

        // 失败操作不改变任何余额
        assertEq(asset.balanceOf(alice), aliceAssetsBefore);
        assertEq(vault.balanceOf(alice), aliceSharesBefore);
        assertEq(vault.totalAssets(), vaultAssetsBefore);
    }

    function test_cannotRedeemMoreThanBalance() public {
        _deposit(alice, 10 ether);
        uint256 shares = vault.balanceOf(alice);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Vault.ExceededMaxRedeem.selector, alice, shares + 1, shares));
        vault.redeem(shares + 1, alice, alice);

        assertEq(vault.balanceOf(alice), shares);
        assertEq(vault.totalAssets(), 10 ether);
    }

    function test_cannotWithdrawOthersShares() public {
        _deposit(alice, 10 ether);
        // bob 试图以 alice 为 owner 提取，未授权 -> revert
        vm.prank(bob);
        vm.expectRevert(); // InsufficientAllowance
        vault.withdraw(1 ether, bob, alice);
        assertEq(vault.totalAssets(), 10 ether);
    }

    function test_approvedSpenderCanWithdrawAndRedeem() public {
        _deposit(alice, 10 ether);
        uint256 shares = vault.balanceOf(alice);

        vm.prank(alice);
        vault.approve(bob, shares);

        vm.prank(bob);
        uint256 burned = vault.withdraw(4 ether, bob, alice);
        assertEq(asset.balanceOf(bob), 4 ether);

        vm.prank(bob);
        vault.redeem(shares - burned, bob, alice);
        assertEq(vault.balanceOf(alice), 0);
        assertEq(asset.balanceOf(bob), 10 ether);
    }

    /* ------------------------------ 零值输入 ------------------------------ */

    function test_zeroAmountsRevert() public {
        _deposit(alice, 1 ether);
        vm.startPrank(alice);
        vm.expectRevert(Vault.ZeroShares.selector);
        vault.deposit(0, alice);
        vm.expectRevert(Vault.ZeroAssets.selector);
        vault.mint(0, alice);
        vm.expectRevert(Vault.ZeroShares.selector);
        vault.withdraw(0, alice, alice);
        vm.expectRevert(Vault.ZeroAssets.selector);
        vault.redeem(0, alice, alice);
        vm.stopPrank();
    }

    /* --------------------------- donation 防护 --------------------------- */

    function test_donationAttack_victimLossIsBounded() public {
        // 攻击者：首存 1 wei，然后直接转账大额资产试图 inflate 每份价格
        _deposit(alice, 1);
        asset.mint(alice, 1000 ether);
        vm.prank(alice);
        asset.transfer(address(vault), 1000 ether);

        // 受害者存入 2000 ether
        uint256 victimShares = _deposit(bob, 2000 ether);
        assertGt(victimShares, 0, "victim must receive shares");

        // 受害者赎回：损失仅为份额舍入尘埃（远小于本金，且与本金相比可忽略）
        vm.prank(bob);
        uint256 out = vault.redeem(victimShares, bob, bob);
        assertLe(out, 2000 ether, "victim cannot gain");
        assertGe(out, 2000 ether - 0.001 ether, "victim loss bounded to rounding dust");

        // 攻击者无法从中获利：拿回的不会超过其投入（1 wei + 1000 ether donation）多少
        uint256 attackerShares = vault.balanceOf(alice);
        vm.prank(alice);
        uint256 attackerOut = vault.redeem(attackerShares, alice, alice);
        assertLe(attackerOut, 1000 ether + 0.001 ether, "attacker cannot profit meaningfully");
    }

    function test_donationDoesNotBreakShareMathForLaterUsers() public {
        _deposit(alice, 50 ether);
        asset.mint(address(vault), 13.37 ether); // 直接 donation

        uint256 preview = vault.previewDeposit(50 ether);
        uint256 sharesBob = _deposit(bob, 50 ether);
        assertEq(sharesBob, preview, "preview must match actual after donation");
        vm.prank(bob);
        uint256 out = vault.redeem(sharesBob, bob, bob);
        // bob 应拿回 >= 50 ether（donation 按份额比例增值），亏损不超过 1 wei 舍入
        assertGe(out + 1, 50 ether);
    }

    /* ------------------------------ yield 模拟 ------------------------------ */

    function test_yieldIncreasesShareValueProportionally() public {
        _deposit(alice, 100 ether);
        _deposit(bob, 100 ether);
        uint256 sharesAlice = vault.balanceOf(alice);

        uint256 valueBefore = vault.convertToAssets(sharesAlice);
        assertEq(valueBefore, 100 ether);

        // 模拟 yield：直接向金库转入 100 ether（总资产 +50%）
        asset.mint(address(vault), 100 ether);

        uint256 valueAfter = vault.convertToAssets(sharesAlice);
        // alice 占一半份额，总资产 300 ether -> 她的份额值 150 ether（允许 1 wei 舍入）
        assertApproxEqAbs(valueAfter, 150 ether, 1);
        assertGt(valueAfter, valueBefore);
    }

    /* ------------------------------ 全部赎回 ------------------------------ */

    function test_fullRedeemEmptiesVault() public {
        _deposit(alice, 70 ether);
        _deposit(bob, 30 ether);
        asset.mint(address(vault), 5 ether); // yield

        uint256 sharesA = vault.balanceOf(alice);
        uint256 sharesB = vault.balanceOf(bob);
        vm.prank(alice);
        vault.redeem(sharesA, alice, alice);
        vm.prank(bob);
        vault.redeem(sharesB, bob, bob);

        assertEq(vault.totalSupply(), 0);
        // 剩余资产仅为虚拟偏移导致的舍入尘埃（<= 用户数量级 wei）
        assertLe(vault.totalAssets(), 2);
        assertEq(asset.balanceOf(alice) + asset.balanceOf(bob) + vault.totalAssets(), 105 ether);
    }

    /* ------------------------------ fuzz ------------------------------ */

    function testFuzz_previewDepositMatchesActual(uint112 amount) public {
        vm.assume(amount > 0);
        _deposit(alice, 1 ether); // 非空金库
        uint256 preview = vault.previewDeposit(amount);
        uint256 actual = _deposit(bob, amount);
        assertEq(actual, preview);
    }

    function testFuzz_previewMintMatchesActual(uint112 shares) public {
        vm.assume(shares > 0);
        _deposit(alice, 1 ether);
        uint256 preview = vault.previewMint(shares);
        _fund(bob, preview);
        vm.prank(bob);
        uint256 actual = vault.mint(shares, bob);
        assertEq(actual, preview);
    }

    function testFuzz_previewWithdrawMatchesActual(uint112 assets) public {
        _deposit(alice, 1 ether);
        uint256 maxAssets = vault.maxWithdraw(alice);
        vm.assume(assets > 0 && assets <= maxAssets);
        uint256 preview = vault.previewWithdraw(assets);
        vm.prank(alice);
        uint256 actual = vault.withdraw(assets, alice, alice);
        assertEq(actual, preview);
    }

    function testFuzz_previewRedeemMatchesActual(uint112 shares) public {
        _deposit(alice, 1 ether);
        uint256 maxShares = vault.maxRedeem(alice);
        vm.assume(shares > 0 && shares <= maxShares);
        vm.assume(vault.previewRedeem(shares) > 0);
        uint256 preview = vault.previewRedeem(shares);
        vm.prank(alice);
        uint256 actual = vault.redeem(shares, alice, alice);
        assertEq(actual, preview);
    }

    function testFuzz_depositWithdrawRoundTrip(uint112 amount) public {
        vm.assume(amount > 0);
        uint256 shares = _deposit(alice, amount);
        vm.prank(alice);
        uint256 out = vault.redeem(shares, alice, alice);
        // 赎回所得不超过存入，亏损最多 1 wei 舍入
        assertLe(out, amount);
        assertGe(out + 1, amount);
    }

    function testFuzz_donationNeverDecreasesShareValue(uint112 depositAmt, uint112 donation) public {
        vm.assume(depositAmt > 0);
        uint256 shares = _deposit(alice, depositAmt);
        uint256 valueBefore = vault.convertToAssets(shares);
        if (donation > 0) asset.mint(address(vault), donation);
        uint256 valueAfter = vault.convertToAssets(shares);
        assertGe(valueAfter, valueBefore);
    }

    function testFuzz_multiUserDepositAndFullRedeem(uint112 a, uint112 b, uint112 yield) public {
        vm.assume(a > 0 && b > 0);
        uint256 sharesA = _deposit(alice, a);
        uint256 sharesB = _deposit(bob, b);
        if (yield > 0) asset.mint(address(vault), yield);

        vm.prank(alice);
        uint256 outA = vault.redeem(sharesA, alice, alice);
        vm.prank(bob);
        uint256 outB = vault.redeem(sharesB, bob, bob);

        // 两人合计取出不超过金库总资产；金库不会被掏空到负数
        assertLe(outA + outB, uint256(a) + uint256(b) + uint256(yield));
        assertEq(vault.totalSupply(), 0);
    }

    function testFuzz_userCannotExceedOwnShare(uint112 a, uint112 b) public {
        vm.assume(a > 0 && b > 0);
        _deposit(alice, a);
        _deposit(bob, b);

        uint256 maxAssets = vault.maxWithdraw(alice);
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(Vault.ExceededMaxWithdraw.selector, alice, maxAssets + 1, maxAssets)
        );
        vault.withdraw(maxAssets + 1, alice, alice);
    }
}

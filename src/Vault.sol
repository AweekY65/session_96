// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ERC20} from "./ERC20.sol";
import {Math} from "./Math.sol";

/// @title Vault —— ERC-4626 风格的单资产金库（纯本地实现，无预言机/外部依赖）
/// @notice 采用 OpenZeppelin 式“虚拟份额/虚拟资产”偏移抵御 donation（通胀）攻击：
///         换算时把 totalSupply 视为 totalSupply + 10**DECIMALS_OFFSET，
///         把 totalAssets 视为 totalAssets + 1。
///         首存与后续存款使用完全相同的公式，不存在特殊分支。
contract Vault is ERC20 {
    using Math for uint256;

    /// @notice 虚拟份额偏移：totalSupply 端虚拟增加 10**DECIMALS_OFFSET 份。
    uint8 public constant DECIMALS_OFFSET = 6;

    ERC20 public immutable asset;

    event Deposit(address indexed sender, address indexed owner, uint256 assets, uint256 shares);
    event Withdraw(
        address indexed sender, address indexed receiver, address indexed owner, uint256 assets, uint256 shares
    );

    error ZeroAssets();
    error ZeroShares();
    error ExceededMaxWithdraw(address owner, uint256 assets, uint256 maxAssets);
    error ExceededMaxRedeem(address owner, uint256 shares, uint256 maxShares);

    constructor(ERC20 _asset, string memory _name, string memory _symbol)
        ERC20(_name, _symbol, _asset.decimals())
    {
        asset = _asset;
    }

    /* ------------------------------ 总量视图 ------------------------------ */

    /// @notice 金库实际持有的 asset 余额（含直接转账进来的 donation / yield）。
    function totalAssets() public view returns (uint256) {
        return asset.balanceOf(address(this));
    }

    /* ------------------------------ 换算逻辑 ------------------------------ */

    /// @dev shares = assets * (totalSupply + 10**offset) / (totalAssets + 1)
    function _convertToShares(uint256 assets, Math.Rounding rounding) internal view returns (uint256) {
        return assets.mulDiv(totalSupply + 10 ** DECIMALS_OFFSET, totalAssets() + 1, rounding);
    }

    /// @dev assets = shares * (totalAssets + 1) / (totalSupply + 10**offset)
    function _convertToAssets(uint256 shares, Math.Rounding rounding) internal view returns (uint256) {
        return shares.mulDiv(totalAssets() + 1, totalSupply + 10 ** DECIMALS_OFFSET, rounding);
    }

    /// @notice 每份 share 对应的资产，向下取整（用户视角的保守值）。
    function convertToAssets(uint256 shares) public view returns (uint256) {
        return _convertToAssets(shares, Math.Rounding.Down);
    }

    /// @notice 每份资产对应的 share，向下取整。
    function convertToShares(uint256 assets) public view returns (uint256) {
        return _convertToShares(assets, Math.Rounding.Down);
    }

    /* ------------------------------ preview ------------------------------ */
    /* preview 与实际操作使用同一函数、同一舍入方向，保证逐 wei 一致。        */

    function previewDeposit(uint256 assets) public view returns (uint256) {
        return _convertToShares(assets, Math.Rounding.Down);
    }

    function previewMint(uint256 shares) public view returns (uint256) {
        return _convertToAssets(shares, Math.Rounding.Up);
    }

    function previewWithdraw(uint256 assets) public view returns (uint256) {
        return _convertToShares(assets, Math.Rounding.Up);
    }

    function previewRedeem(uint256 shares) public view returns (uint256) {
        return _convertToAssets(shares, Math.Rounding.Down);
    }

    /* ------------------------------ 上限视图 ------------------------------ */

    function maxDeposit(address) public pure returns (uint256) {
        return type(uint256).max;
    }

    function maxMint(address) public pure returns (uint256) {
        return type(uint256).max;
    }

    function maxWithdraw(address owner) public view returns (uint256) {
        return _convertToAssets(balanceOf[owner], Math.Rounding.Down);
    }

    function maxRedeem(address owner) public view returns (uint256) {
        return balanceOf[owner];
    }

    /* ------------------------------ 核心操作 ------------------------------ */

    function deposit(uint256 assets, address receiver) public returns (uint256 shares) {
        shares = previewDeposit(assets);
        if (shares == 0) revert ZeroShares();

        asset.transferFrom(msg.sender, address(this), assets);
        _mint(receiver, shares);
        emit Deposit(msg.sender, receiver, assets, shares);
    }

    function mint(uint256 shares, address receiver) public returns (uint256 assets) {
        assets = previewMint(shares);
        if (assets == 0) revert ZeroAssets();

        asset.transferFrom(msg.sender, address(this), assets);
        _mint(receiver, shares);
        emit Deposit(msg.sender, receiver, assets, shares);
    }

    function withdraw(uint256 assets, address receiver, address owner) public returns (uint256 shares) {
        uint256 maxAssets = maxWithdraw(owner);
        if (assets > maxAssets) revert ExceededMaxWithdraw(owner, assets, maxAssets);

        shares = previewWithdraw(assets);
        if (shares == 0) revert ZeroShares();

        if (msg.sender != owner) _spendAllowance(owner, msg.sender, shares);

        _burn(owner, shares);
        asset.transfer(receiver, assets);
        emit Withdraw(msg.sender, receiver, owner, assets, shares);
    }

    function redeem(uint256 shares, address receiver, address owner) public returns (uint256 assets) {
        uint256 maxShares = maxRedeem(owner);
        if (shares > maxShares) revert ExceededMaxRedeem(owner, shares, maxShares);

        assets = previewRedeem(shares);
        if (assets == 0) revert ZeroAssets();

        if (msg.sender != owner) _spendAllowance(owner, msg.sender, shares);

        _burn(owner, shares);
        asset.transfer(receiver, assets);
        emit Withdraw(msg.sender, receiver, owner, assets, shares);
    }

    function _spendAllowance(address owner, address spender, uint256 shares) internal {
        uint256 allowed = allowance[owner][spender];
        if (allowed != type(uint256).max) {
            if (allowed < shares) revert InsufficientAllowance();
            allowance[owner][spender] = allowed - shares;
        }
    }
}

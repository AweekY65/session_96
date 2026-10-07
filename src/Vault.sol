// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Math, Rounding} from "./libraries/Math.sol";

interface IERC20 {
    function totalSupply() external view returns (uint256);
    function balanceOf(address account) external view returns (uint256);
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function decimals() external view returns (uint8);
}

/// @title Vault
/// @notice Minimal ERC-4626 style asset vault. Fully self-contained: no
///         oracles, no external calls besides the underlying ERC-20 asset.
///
/// Share math (OpenZeppelin-style virtual offset):
///   shares = assets * (totalSupply + 10^OFFSET) / (totalAssets + 1)
///   assets = shares * (totalAssets + 1) / (totalSupply + 10^OFFSET)
///
/// The virtual "+1 asset / +10^OFFSET shares" makes the classic first-deposit
/// inflation ("donation") attack economically infeasible and keeps the first
/// and later deposits on the exact same conversion formula.
///
/// Rounding always favors the vault (ERC-4626 convention):
///   deposit  -> shares minted rounded DOWN
///   mint     -> assets pulled rounded UP
///   withdraw -> shares burned rounded UP
///   redeem   -> assets sent rounded DOWN
/// preview* functions use the identical rounding as the state-changing call.
contract Vault {
    using Math for uint256;

    // ----- ERC-4626 events -----
    event Deposit(address indexed sender, address indexed owner, uint256 assets, uint256 shares);
    event Withdraw(
        address indexed sender, address indexed receiver, address indexed owner, uint256 assets, uint256 shares
    );

    // ----- ERC-20 (share token) events -----
    event Transfer(address indexed from, address indexed to, uint256 amount);
    event Approval(address indexed owner, address indexed spender, uint256 amount);

    error ZeroAssets();
    error ZeroShares();
    error TransferFailed();
    error InsufficientBalance(uint256 available, uint256 required);
    error InsufficientAllowance(uint256 allowed, uint256 required);
    error ExceedsMaxDeposit(uint256 assets, uint256 maxAssets);
    error ExceedsMaxMint(uint256 shares, uint256 maxShares);
    error ExceedsMaxWithdraw(uint256 assets, uint256 maxAssets);
    error ExceedsMaxRedeem(uint256 shares, uint256 maxShares);

    /// @notice Decimals offset used for the virtual share/asset offset.
    uint8 public constant DECIMALS_OFFSET = 3;

    IERC20 public immutable asset;
    uint8 private immutable _assetDecimals;

    // ----- share token (ERC-20) state -----
    string public name;
    string public symbol;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    constructor(IERC20 asset_, string memory name_, string memory symbol_) {
        asset = asset_;
        _assetDecimals = asset_.decimals();
        name = name_;
        symbol = symbol_;
    }

    // ============================================================
    //                        ERC-20 (shares)
    // ============================================================

    function decimals() public view returns (uint8) {
        return _assetDecimals + DECIMALS_OFFSET;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        _transfer(msg.sender, to, amount);
        return true;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 allowed = allowance[from][msg.sender];
        if (allowed != type(uint256).max) {
            if (allowed < amount) revert InsufficientAllowance(allowed, amount);
            allowance[from][msg.sender] = allowed - amount;
            emit Approval(from, msg.sender, allowed - amount);
        }
        _transfer(from, to, amount);
        return true;
    }

    function _transfer(address from, address to, uint256 amount) internal {
        uint256 bal = balanceOf[from];
        if (bal < amount) revert InsufficientBalance(bal, amount);
        unchecked {
            balanceOf[from] = bal - amount;
            balanceOf[to] += amount;
        }
        emit Transfer(from, to, amount);
    }

    // ============================================================
    //                     ERC-4626 accounting
    // ============================================================

    /// @notice Total assets managed by the vault. Donations sent directly to
    ///         the vault are included (they accrue to all shareholders).
    function totalAssets() public view returns (uint256) {
        return asset.balanceOf(address(this));
    }

    function convertToShares(uint256 assets) public view returns (uint256) {
        return _convertToShares(assets, Rounding.Floor);
    }

    function convertToAssets(uint256 shares) public view returns (uint256) {
        return _convertToAssets(shares, Rounding.Floor);
    }

    function _convertToShares(uint256 assets, Rounding rounding) internal view returns (uint256) {
        uint256 supply = totalSupply;
        uint256 virtualShares = 10 ** DECIMALS_OFFSET;
        return assets.mulDiv(supply + virtualShares, totalAssets() + 1, rounding);
    }

    function _convertToAssets(uint256 shares, Rounding rounding) internal view returns (uint256) {
        uint256 supply = totalSupply;
        uint256 virtualShares = 10 ** DECIMALS_OFFSET;
        return shares.mulDiv(totalAssets() + 1, supply + virtualShares, rounding);
    }

    // ============================================================
    //                     ERC-4626 previews
    // ============================================================

    function previewDeposit(uint256 assets) public view returns (uint256) {
        return _convertToShares(assets, Rounding.Floor);
    }

    function previewMint(uint256 shares) public view returns (uint256) {
        return _convertToAssets(shares, Rounding.Ceil);
    }

    function previewWithdraw(uint256 assets) public view returns (uint256) {
        return _convertToShares(assets, Rounding.Ceil);
    }

    function previewRedeem(uint256 shares) public view returns (uint256) {
        return _convertToAssets(shares, Rounding.Floor);
    }

    // ============================================================
    //                     ERC-4626 limits
    // ============================================================

    function maxDeposit(address) public pure returns (uint256) {
        return type(uint256).max;
    }

    function maxMint(address) public pure returns (uint256) {
        return type(uint256).max;
    }

    function maxWithdraw(address owner) public view returns (uint256) {
        return _convertToAssets(balanceOf[owner], Rounding.Floor);
    }

    function maxRedeem(address owner) public view returns (uint256) {
        return balanceOf[owner];
    }

    // ============================================================
    //                  ERC-4626 state changes
    // ============================================================

    function deposit(uint256 assets, address receiver) external returns (uint256 shares) {
        if (assets > maxDeposit(receiver)) revert ExceedsMaxDeposit(assets, maxDeposit(receiver));
        shares = previewDeposit(assets);
        if (shares == 0) revert ZeroShares();
        _pullAssets(assets);
        _mint(receiver, shares);
        emit Deposit(msg.sender, receiver, assets, shares);
    }

    function mint(uint256 shares, address receiver) external returns (uint256 assets) {
        if (shares > maxMint(receiver)) revert ExceedsMaxMint(shares, maxMint(receiver));
        if (shares == 0) revert ZeroShares();
        assets = previewMint(shares);
        if (assets == 0) revert ZeroAssets();
        _pullAssets(assets);
        _mint(receiver, shares);
        emit Deposit(msg.sender, receiver, assets, shares);
    }

    function withdraw(uint256 assets, address receiver, address owner) external returns (uint256 shares) {
        if (assets > maxWithdraw(owner)) revert ExceedsMaxWithdraw(assets, maxWithdraw(owner));
        shares = previewWithdraw(assets);
        if (shares == 0) revert ZeroShares();
        _spendShares(owner, shares);
        _pushAssets(receiver, assets);
        emit Withdraw(msg.sender, receiver, owner, assets, shares);
    }

    function redeem(uint256 shares, address receiver, address owner) external returns (uint256 assets) {
        if (shares > maxRedeem(owner)) revert ExceedsMaxRedeem(shares, maxRedeem(owner));
        if (shares == 0) revert ZeroShares();
        assets = previewRedeem(shares);
        if (assets == 0) revert ZeroAssets();
        _spendShares(owner, shares);
        _pushAssets(receiver, assets);
        emit Withdraw(msg.sender, receiver, owner, assets, shares);
    }

    // ============================================================
    //                        internals
    // ============================================================

    function _pullAssets(uint256 assets) internal {
        if (!asset.transferFrom(msg.sender, address(this), assets)) revert TransferFailed();
    }

    function _pushAssets(address receiver, uint256 assets) internal {
        if (!asset.transfer(receiver, assets)) revert TransferFailed();
    }

    function _spendShares(address owner, uint256 shares) internal {
        if (msg.sender != owner) {
            uint256 allowed = allowance[owner][msg.sender];
            if (allowed != type(uint256).max) {
                if (allowed < shares) revert InsufficientAllowance(allowed, shares);
                allowance[owner][msg.sender] = allowed - shares;
                emit Approval(owner, msg.sender, allowed - shares);
            }
        }
        _burn(owner, shares);
    }

    function _mint(address to, uint256 shares) internal {
        totalSupply += shares;
        unchecked {
            balanceOf[to] += shares;
        }
        emit Transfer(address(0), to, shares);
    }

    function _burn(address from, uint256 shares) internal {
        uint256 bal = balanceOf[from];
        if (bal < shares) revert InsufficientBalance(bal, shares);
        unchecked {
            balanceOf[from] = bal - shares;
            totalSupply -= shares;
        }
        emit Transfer(from, address(0), shares);
    }
}

# Local ERC-4626 Style Vault

一个完全本地运行的 ERC-4626 风格资产金库，使用 Foundry 在本地 EVM 中开发、测试与验证。
**不依赖**主网 / 测试网 / RPC 节点 / 价格预言机 / 数据库或任何外部服务 —— 唯一的链上交互对象是作为底层资产的 ERC-20 合约（测试中由 `MockERC20` 提供）。

## 结构

- `src/Vault.sol` — 金库合约（自带 ERC-20 share 代币实现，无外部依赖）
- `src/libraries/Math.sol` — 512-bit 全精度 `mulDiv`（支持 Floor / Ceil 舍入方向）
- `src/mocks/MockERC20.sol` — 仅用于本地测试的可铸造 ERC-20 资产
- `test/Vault.t.sol` — 单元测试（21 个）
- `test/VaultFuzz.t.sol` — fuzz 测试（9 个）
- `test/VaultInvariant.t.sol` — invariant 测试（5 个，基于 handler 的随机操作序列）

## Share 数学

金库采用 OpenZeppelin 风格的 **virtual offset（虚拟份额/资产偏移）**，`DECIMALS_OFFSET = 3`：

```
convertToShares(assets) = assets * (totalSupply + 10^3) / (totalAssets + 1)
convertToAssets(shares) = shares * (totalAssets + 1) / (totalSupply + 10^3)
```

- `totalAssets()` 直接读取金库持有的 asset 余额，因此直接转账进来的 donation / yield 会立即计入并按比例提升所有 share 的价值。
- 首次存款与后续存款使用**完全相同**的公式：空金库时 `1 wei asset → 10^3 wei shares`，不存在特殊的"首存分支"。
- share 代币精度 = asset 精度 + 3（`decimals() = assetDecimals + DECIMALS_OFFSET`）。

## 舍入方向

所有换算通过 512-bit 全精度 `mulDiv` 完成，舍入永远**有利于金库**（ERC-4626 惯例），保证任何用户都无法通过舍入误差占其他用户的便宜：

| 操作       | 预览函数           | 舍入方向 | 含义                       |
|------------|--------------------|----------|----------------------------|
| `deposit`  | `previewDeposit`   | Floor    | 铸造的 shares 向下取整     |
| `mint`     | `previewMint`      | Ceil     | 拉取的 assets 向上取整     |
| `withdraw` | `previewWithdraw`  | Ceil     | 销毁的 shares 向上取整     |
| `redeem`   | `previewRedeem`    | Floor    | 返还的 assets 向下取整     |

`preview*` 与对应的状态变更函数调用**同一个内部换算函数、同一个舍入方向**，因此预览结果与实际执行结果严格一致（由 `test_preview*_matches*` 与 fuzz 测试验证）。

## Donation（通货膨胀攻击）防护策略

经典攻击：攻击者抢先存入 1 wei 获得 1 share，再直接向金库捐赠巨额资产，使后续存款者的 share 计算舍入为 0，从而吞掉其本金。

本合约的对策是 **virtual offset**：换算时分子加上 `10^3` 虚拟 shares、分母加上 `1` 虚拟 asset。效果：

1. 攻击者空金库存 1 wei 得到 `10^3` shares，但金库中同时存在 `10^3` 虚拟 shares —— 攻击者最多只拥有金库的 50%，其捐赠的一半永久锁定给虚拟份额（即后续存款者），攻击在经济上必然亏损（测试中验证：捐赠 1,000,000 ether 最多造成受害者约 500 ether 的舍入损失，而攻击者自身损失约 500,000 ether，成本约为收益的 1000 倍）。
2. 受害者的损失被限制在"1 wei share 的价值"量级，即 `donation / (2 * 10^OFFSET)`，而不是未防护时的"全部本金"。
3. 正常路径下（无恶意巨额捐赠），用户 deposit→redeem 往返的舍入损耗只有几个 wei。

相关测试：`test_donation_doesNotBreakFirstDepositor`、`test_donation_accruesToShareholders`、`testFuzz_donationNeverDilutes`。

## 安全边界

- **余额隔离**：用户只能提取自己 share 对应的资产。`withdraw`/`redeem` 超过 `maxWithdraw`/`maxRedeem` 时以自定义错误 revert；代他人提取需要 share 代币的 allowance。
- **失败原子性**：所有检查（限额、零值、allowance、余额）都发生在任何转账与状态变更之前；Solidity 0.8 的 revert 语义保证失败操作不改变任何余额（`test_failedWithdraw_changesNothing`、`testFuzz_overWithdrawReverts`）。
- **零值保护**：会产生 0 shares 的 `deposit`、需要 0 assets 的 `mint`、价值为 0 的 `redeem` 等均 revert（`ZeroShares`/`ZeroAssets`），避免无意义的状态变更与灰尘份额。
- **算术安全**：所有乘除使用 512-bit 全精度 `mulDiv`，中间结果不会溢出；加减法依赖 Solidity 0.8 内置溢出检查。
- **偿付能力不变量**：所有用户 share 的可赎回价值之和永远 ≤ 金库实际余额（invariant 测试持续验证）。
- **信任假设**：金库不管理任何策略，资产静态存放于合约内；`totalAssets` 依赖 `asset.balanceOf(this)`，因此假设底层 ERC-20 是正常实现（无 rebasing、无转账手续费）。对 fee-on-transfer 或 rebasing 代币**不适用**。

## Yield 模拟

测试中通过 `MockERC20.mint(address(vault), amount)` 直接向金库增加资产来模拟收益。由于 `totalAssets()` 实时读取余额，share 价格立即按比例上升（`test_yield_increasesShareValueProportionally`：资产翻倍时 share 价值约翻倍）。

## 运行测试

需要 [Foundry](https://book.getfoundry.sh/getting-started/installation)。所有测试均在本地 EVM 执行，不访问任何网络：

```bash
# 全部测试（unit + fuzz + invariant）
forge test

# 分类运行
forge test --match-contract VaultTest            # 单元测试
forge test --match-contract VaultFuzzTest        # fuzz 测试
forge test --match-contract VaultInvariantTest   # invariant 测试

# 详细输出 / gas 报告
forge test -vvv
forge test --gas-report
```

fuzz / invariant 的运行参数（runs、depth 等）配置在 `foundry.toml` 中。

## 测试覆盖

- **单元测试**：首次存款（含 1 wei 小额）、多用户按比例分配、deposit/mint/withdraw/redeem 四种 preview 与实际操作一致性、舍入方向、donation 攻击、yield 后按比例赎回、超限 withdraw/redeem revert、失败操作零副作用、allowance 代取、全部赎回清空金库、share 代币 ERC-20 行为。
- **Fuzz 测试**：deposit↔redeem、deposit↔withdraw、mint↔redeem 往返损耗上界；随机初始状态 + 随机 donation 下 preview 与操作一致；mint/withdraw 的 Ceil 一致性；donation 永不稀释既有份额；用户无法超出按比例份额；超额 withdraw 必 revert 且无副作用；随机操作序列后的偿付能力。
- **Invariant 测试**（handler 随机调用 deposit/mint/withdraw/redeem/transferShares/donate）：金库余额与 `totalAssets` 恒等；全体用户可赎回价值 ≤ 金库余额；`totalSupply` 恒等于各持有者余额之和；资产守恒（进入 = 提出 + 留存）；全部 share 的总债权 ≤ 余额 + 1 wei；donation 后既有份额价值单调不减。

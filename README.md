# LocalVault —— 纯本地 ERC-4626 风格资产金库

一个完全运行在 Foundry 本地 EVM 中的 ERC-4626 风格金库实现。**不依赖**主网/测试网、
RPC、价格预言机、数据库或任何外部服务：所有合约（金库、份额代币、测试资产）都在本地
编译部署，所有测试通过 `forge test` 在本地 EVM 中执行。

## 结构

```
src/Vault.sol   金库（份额即 ERC20，asset 为任意 ERC20）
src/ERC20.sol   最小化 ERC20 实现（份额与测试资产共用）
src/Math.sol    全精度 mulDiv（512 位中间结果，支持向上/向下取整）
test/Vault.t.sol            unit + fuzz 测试
test/VaultInvariant.t.sol   invariant 测试（随机操作序列 handler）
test/mocks/MockERC20.sol    测试用资产（可 mint/burn）
```

## Share 数学

金库采用 OpenZeppelin 风格的**虚拟份额/虚拟资产偏移**（`DECIMALS_OFFSET = 6`）：

```
totalShares_virtual = totalSupply  + 10**6   （虚拟份额）
totalAssets_virtual = totalAssets() + 1      （虚拟资产，1 wei）

shares = assets * totalShares_virtual / totalAssets_virtual
assets = shares * totalAssets_virtual / totalShares_virtual
```

- `totalAssets()` 直接读取金库合约的 asset 余额，因此**直接转账（donation / yield）
  会自动反映到每份份额的价格中**。
- 首次存款与后续存款使用**完全相同的公式**，没有任何特殊分支：首存 1 wei 资产得到
  `10**6` 份额，首存 `X` 资产得到 `X * 10**6` 份额。
- 所有乘除使用 512 位全精度 `mulDiv`，中间结果不会溢出。

## 舍入方向（rounding）

遵循 ERC-4626 惯例——**永远向有利于金库（即有利于现有份额持有者）的方向舍入**：

| 操作             | 舍入方向 | 含义                               |
|------------------|----------|------------------------------------|
| `previewDeposit` | 向下     | 用户存入资产，少铸份额             |
| `previewMint`    | 向上     | 用户铸造份额，多收资产             |
| `previewWithdraw`| 向上     | 用户提取资产，多烧份额             |
| `previewRedeem`  | 向下     | 用户赎回份额，少付资产             |

`preview*` 与实际操作调用**同一个内部换算函数、同一个舍入方向**，因此 preview 的结果
与实际执行逐 wei 一致（有 unit 与 fuzz 测试保证）。

## Donation（通胀攻击）防护策略

经典的首存通胀攻击：攻击者存入 1 wei 获得份额，再直接向金库转账大额资产，使后续
受害者的存款因舍入被"抹零"，攻击者独占受害者本金。

本实现的处理策略：

1. **虚拟偏移**：换算时分子加 `10**6` 虚拟份额、分母加 1 wei 虚拟资产。攻击者要稀释
   受害者，必须让捐赠额相对 `10**6` 虚拟份额也有意义，攻击成本被放大到无利可图。
2. **实测验证**（`test_donationAttack_victimLossIsBounded`）：攻击者存 1 wei 并捐赠
   1000 ether 后，受害者存入 2000 ether 的损失被限制在**份额舍入尘埃**级别
   （< 0.001 ether，相对本金可忽略），且攻击者无法从中获利。
3. 剩余风险（已接受的边界）：受害者损失上界约为"1~2 份份额的价值"。当金库被大额
   捐赠推高份额价格时，该尘埃的绝对值会变大，但相对受害者本金的比例不变。

## 安全边界与假设

- **适用资产**：标准的、无手续费、无回调 hook 的 ERC20（如本仓库的 `MockERC20`）。
  不适用于通缩/转账收税代币、ERC777 类带 hook 的代币、余额会变基的 rebasing 代币。
- **越界保护**：`withdraw`/`redeem` 先检查 `maxWithdraw`/`maxRedeem`，用户无法提取
  超过自身份额对应的资产；替他人提取需要份额授权（allowance）。
- **失败原子性**：所有失败操作通过 `revert` 回滚，Solidity 保证状态（余额、授权、
  份额）全部不变（有测试验证）。
- **零值输入**：会产生 0 份额/0 资产的操作直接 revert（`ZeroShares`/`ZeroAssets`），
  避免无意义的状态变更与事件。
- **重入**：遵循 checks-effects-interactions（先烧份额再转资产）；对无 hook 的标准
  ERC20 资产不存在重入面。
- **份额价格只增不减**（除每步 ≤1 wei 的舍入外）：金库没有亏损路径，donation 只会
  提高每份份额价值（fuzz 测试覆盖）。

## 测试

全部在本地 EVM 执行，不访问任何网络（`foundry.toml` 已固定本地 solc 并开启
`offline = true`）：

```bash
forge test                # 全部 unit + fuzz + invariant 测试
forge test -vvv           # 查看调用轨迹
forge test --mt testFuzz_ # 只跑 fuzz
forge test --mc VaultInvariantTest  # 只跑 invariant
```

覆盖场景：

- **unit**：首存（含 1 wei）、多用户、deposit/mint/withdraw/redeem 全流程、
  preview 与实际一致、四种舍入方向、越界提取/赎回 revert 且状态不变、授权提取、
  零值 revert、donation 攻击、donation 后换算一致、yield 按比例增值、全部赎回后
  金库清空（仅剩尘埃）。
- **fuzz**：preview 四种操作与实际一致、存取往返损耗 ≤1 wei、donation 永不降低
  份额价值、多用户+yield 后全额赎回的资产守恒、越界提取 revert。
- **invariant**（随机序列：deposit/mint/withdraw/redeem/donate）：
  偿付能力（金库余额 ≥ 全部份额可兑资产）、份额守恒（用户份额之和 == totalSupply）、
  资产守恒（余额 == 存入 - 取出 + 捐赠）、空金库仅剩 donation 与尘埃。

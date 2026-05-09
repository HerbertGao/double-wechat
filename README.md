# macOS 微信多开工具 (WeChat Multi-Instance Tool)

一个用于在 macOS 上创建和管理多个微信实例的工具，让您可以同时登录多个微信账号。**所有写操作不需要 sudo**，并且可以作为 Skill 接入 Claude Code / Codex CLI，让 AI 通过自然语言为你管理多开。

## 🚀 功能特性

- ✅ **创建微信实例** - 快速创建新的微信应用副本
- ✅ **启动管理** - 启动已创建的微信实例
- ✅ **实例列表** - 查看所有已安装的微信实例及版本状态
- ✅ **删除管理** - 清理不需要的微信实例
- ✅ **版本检测** - 自动检测实例与原始微信的版本差异
- ✅ **一键更新** - 批量更新版本不一致的实例
- ✅ **交互式菜单** - 友好的命令行界面（人类入口）
- ✅ **子命令 + JSON 输出** - 脚本/AI 友好（`list --json`、`doctor --json`、`create --yes` 等）
- ✅ **零特权** - 全程无需 sudo（前提：admin 用户 + `/Applications` 可写）

## 📋 系统要求

- **操作系统**: macOS 12 Monterey 或更高版本
- **微信版本**: 已安装的微信 4.0 应用 (`/Applications/WeChat.app`)
- **用户**: 当前用户在 `admin` 组、`/Applications` 可写（绝大多数 macOS 默认满足；用 `double-wechat doctor` 自检）
- **磁盘空间**: 每个实例约需要 150–200MB 空间

> 不再需要 sudo。脚本使用 `cp -R`（不带 `-p`），副本归当前用户所有，后续 PlistBuddy / codesign / rm 都无需特权。

## 🛠️ 安装方法

```bash
git clone https://github.com/HerbertGao/double-wechat.git
cd double-wechat
chmod +x double-wechat.sh

# 可选：放进 PATH（让 'double-wechat' 命令直接可用）
ln -s "$PWD/double-wechat.sh" /usr/local/bin/double-wechat
```

## 📖 使用方法

### 人类用户：交互菜单（无参运行）

```bash
./double-wechat.sh
```

```
=== 微信多开管理工具 ===
1. 创建新的微信实例
2. 启动现有微信实例
3. 列出所有微信实例
4. 删除微信实例
5. 一键更新所有过期实例
0. 退出
```

启动时会自动检测版本差异，发现实例版本与原始微信不一致时提示一键更新。

### 脚本/AI：子命令模式

```bash
double-wechat doctor [--json]                       # 自检环境
double-wechat list [--json]                         # 列出原始 + 所有副本
double-wechat create <0-9> [--no-launch] [--yes]    # 创建（默认创建后启动）
double-wechat start  <0-9>                          # 启动已有副本
double-wechat delete <0-9> [--yes]                  # 删除副本
double-wechat update [--all | <n>...] [--yes]       # 同步副本到原始版本
double-wechat help
double-wechat version
```

**约定**：

- 数据输出（含 JSON）走 stdout；日志（INFO/WARN/STEP/ERROR）走 stderr，可安全管道给解析器
- 写操作（create/delete/update）默认会要 stdin 确认；脚本/AI 调用必须加 `--yes`
- 退出码：`0` 成功 / `1` 业务失败 / `2` 参数错误

**示例**：

```bash
# 自检环境，机器可读
double-wechat doctor --json | jq

# 列出所有实例并筛选需要更新的
double-wechat list --json | jq '.instances[] | select(.needs_update)'

# 非交互式创建编号为 2 的副本，不立即启动
double-wechat create 2 --no-launch --yes

# 一键更新所有过期实例
double-wechat update --all --yes
```

## 🤖 作为 AI Skill / Plugin 使用

仓库提供 host-agnostic 的 [SKILL.md](packaging/skill/double-wechat/SKILL.md)，并打包成 Claude Code / Codex CLI 的 plugin，让 AI 通过自然语言或 slash command 调用本工具：

> "再开一个微信" / "我现在有几个微信？" / "把所有副本同步到最新版"

### 前置：装 binary

Plugin **不打包** binary——它假设 `double-wechat` 命令在 `PATH` 里。最简单：

```bash
# 用户级（无需 sudo，要求 ~/.local/bin 在 PATH 中）
ln -s "$PWD/double-wechat.sh" ~/.local/bin/double-wechat

# 或全局（需 sudo 或 /usr/local/bin 可写）
ln -s "$PWD/double-wechat.sh" /usr/local/bin/double-wechat
```

### 一行装：Claude Code

```bash
claude plugin marketplace add https://github.com/HerbertGao/double-wechat \
  && claude plugin install double-wechat@double-wechat
```

> marketplace 清单在仓库根 `.claude-plugin/marketplace.json`；plugin 内含 6 个 slash command + Skill 描述。

### 一行装：Codex CLI

```bash
codex plugin marketplace add https://github.com/HerbertGao/double-wechat
```

之后编辑 `~/.codex/config.toml` 启用 plugin：

```toml
[plugins."double-wechat@double-wechat"]
enabled = true
```

> marketplace 清单在仓库根 `.agents/plugins/marketplace.json`；Codex 没有 slash command 机制，纯靠 SKILL.md 自然语言路由。

### 装完后可用的 slash command（Claude Code）

| 命令 | 行为 |
|---|---|
| `/double-wechat:list` | 列出原始 + 所有副本及版本 |
| `/double-wechat:create [n]` | 创建副本；不指定编号时 AI 自动选空号 |
| `/double-wechat:start <n>` | 启动指定副本 |
| `/double-wechat:delete <n>` | **先确认再删** |
| `/double-wechat:update [--all\|<n>...]` | 列出差异、确认后批量更新 |
| `/double-wechat:doctor` | 自检环境（含 `sudo_required` / `legacy_migration_required` 判定） |

### 卸载

```bash
# Claude Code
claude plugin uninstall double-wechat
claude plugin marketplace remove https://github.com/HerbertGao/double-wechat

# Codex
codex plugin marketplace remove https://github.com/HerbertGao/double-wechat
```

### 手动安装（不走 marketplace）

如果你不想用 plugin marketplace，也可以手动软链 Skill：

```bash
ln -s "$PWD/packaging/skill/double-wechat" ~/.claude/skills/double-wechat
```

> Skill 与 Slash Command 互补：日常对话场景用 Skill（"再开一个微信"自动触发），需要确定性快捷入口时用 Slash Command。两者都依赖 `double-wechat` 二进制在 `PATH` 里。

## 🔧 技术原理

### 应用隔离机制

1. **文件系统隔离**：每个实例都有独立的 `.app` 文件
2. **标识符隔离**：不同的 Bundle Identifier 让系统识别为不同应用
3. **进程/沙箱隔离**：每个实例运行在独立进程，且 macOS 按 Bundle ID 给每个实例独立沙箱（`~/Library/Containers/com.tencent.xinWeChat<n>/`）

### 核心步骤（无 sudo 版）

1. **复制应用**: `cp -R /Applications/WeChat.app /Applications/WeChat<n>.app`（副本归当前用户）
2. **修改标识符**: `PlistBuddy -c "Set :CFBundleIdentifier com.tencent.xinWeChat<n>" .../Info.plist`
3. **重新签名**: `codesign --force --deep --sign - /Applications/WeChat<n>.app`（adhoc 签名）
4. **启动实例**: `nohup .../Contents/MacOS/WeChat &`

### 为什么不需要 sudo

- `/Applications/` 默认 `drwxrwxr-x root:admin`，admin 组成员可写
- macOS 上的微信通常以当前用户身份安装（可用 `ls -ld /Applications/WeChat.app` 验证），副本天然归当前用户
- 副本归用户后，PlistBuddy / codesign / rm 都不需要特权

如果你的环境出现 `/Applications` 不可写或原始 WeChat 归 root 所有，`double-wechat doctor` 会明确告诉你（`sudo_required: true`），此时建议先把当前用户加进 `admin` 组而不是绕过。

### 从旧版升级（一次性迁移）

如果你之前用过本工具的 v1.x（基于 sudo），你机器上的 `WeChat<n>.app` 副本归 `root:admin` 所有。新版无 sudo 的写操作（覆盖 create / delete / update）对这些副本会失败。

`double-wechat doctor` 会自动检测并给出迁移命令。**这是从旧版升级到新版唯一需要 sudo 的一步**：

```bash
# doctor 会列出具体路径，你也可以直接把所有副本一次性迁移到自己名下：
sudo chown -R "$(id -un):staff" /Applications/WeChat[0-9].app
```

迁移之后 `doctor` 的 `legacy_migration_required` 字段会变 `false`，所有写操作都能无 sudo 跑。

> **不要给子命令加 sudo**。`double-wechat create / delete / update / start` 会主动拒绝 `EUID == 0` 退出。原因：root 创建的副本归 root 所有，后续无 sudo 操作（包括日常的覆盖更新）会失败——这正是上面"一次性迁移"想消除的痛点。子命令设计为完全无需特权，正常调用即可。

## ⚠️ 注意事项

### 安全提醒

- 副本使用 adhoc 签名，仅本机有效，无法分发
- 不要删除原始的 `WeChat.app`（本工具子命令物理上不允许，编号必须是 0–9）
- update / delete / 覆盖 create 都会让对应实例的登录态丢失，需要重新扫码登录

### 限制说明

- 最多可创建 10 个实例（编号 0–9）
- 每个实例约占用 150–200MB 磁盘空间

## 🐛 故障排除

### 常见问题

**Q: 提示"未找到原始微信应用"**
A: 请确保微信已正确安装在 `/Applications/WeChat.app`。

**Q: doctor 报告 `sudo_required: true` 怎么办？**
A: 通常是因为当前用户不在 `admin` 组。打开 macOS"系统设置 → 用户与群组"把账户改为管理员，重新登录后再试。**不建议**用 sudo 绕过——这只会污染副本所有权，后续操作仍会出问题。

**Q: 启动实例失败**
A: 检查磁盘空间；或运行 `double-wechat update <n> --yes` 重建该实例。

**Q: 实例无法正常登录**
A: 每个实例都是独立的，需要重新扫码登录；这是正常现象。

### 退出码

- `0` 成功
- `1` 业务失败（实例不存在、签名失败、磁盘满等）
- `2` 参数错误（未知子命令、编号非法等）
- `130` 用户中断（Ctrl+C）

---

**免责声明**：本工具仅供学习和个人使用，请遵守相关法律法规和微信用户协议。使用本工具产生的任何后果由用户自行承担。

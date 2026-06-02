# macOS 微信多开工具 (WeChat Multi-Instance Tool)

在 macOS 上创建和管理多个微信实例，同时登录多个账号。**全程无需 sudo**（前提：admin 用户 + `/Applications` 可写），并且可以作为 **Skill / Plugin 接入 Claude Code / Codex CLI**，让 AI 用自然语言帮你管理多开。

> "再开一个微信" / "我现在有几个微信？" / "把所有副本同步到最新版"

## 能做什么

| 操作 | 说明 |
|---|---|
| 创建 / 启动 / 删除 | 复制、运行、清理微信实例（编号 0–9，最多 10 个） |
| 列表 + 版本检测 | 查看所有实例及与原版的版本差异 |
| 一键更新 | 批量把过期副本同步到原版 |
| 收编 (adopt) | 副本自更新后版本反超原版时，把它提升为新原版，避免被降级 |
| 环境自检 (doctor) | 检查是否能无 sudo 运行 |

每个实例约占 150–200MB 磁盘。需要 macOS 12+ 与已安装的 `/Applications/WeChat.app`。

---

## 作为 AI Skill / Plugin 使用（推荐）

仓库提供 host-agnostic 的 [SKILL.md](packaging/skill/double-wechat/SKILL.md)，并打包成 Claude Code / Codex CLI 的 plugin。装好后直接用自然语言或 slash command 调用。

### 前置：让 `double-wechat` 命令在 PATH 里

Plugin **不打包** binary，假设 `double-wechat` 命令可用：

```bash
git clone https://github.com/HerbertGao/double-wechat.git && cd double-wechat
chmod +x double-wechat.sh

# 免 sudo（推荐）：软链到用户目录
mkdir -p ~/.local/bin
ln -s "$PWD/double-wechat.sh" ~/.local/bin/double-wechat
# 确认 ~/.local/bin 在 PATH 中（默认 macOS 不在，按需加一次）：
#   echo 'export PATH="$HOME/.local/bin:$PATH"' >> ~/.zshrc && source ~/.zshrc
```

> 若 `/usr/local/bin` 在你的机器上可写（Intel + Homebrew 常见），也可 `ln -s "$PWD/double-wechat.sh" /usr/local/bin/double-wechat`；Apple Silicon 默认它归 `root:wheel`、需 sudo，故不作首选。

### Claude Code

**在终端（shell）里安装 / 卸载：**

```bash
# 安装
claude plugin marketplace add HerbertGao/double-wechat
claude plugin install double-wechat@double-wechat

# 卸载
claude plugin uninstall double-wechat@double-wechat
claude plugin marketplace remove double-wechat
```

**已经在 Claude Code 会话内时**，用同名 `/plugin` slash 命令完成同样操作：

```
/plugin marketplace add HerbertGao/double-wechat
/plugin install double-wechat@double-wechat
/plugin uninstall double-wechat@double-wechat
/plugin marketplace remove double-wechat
```

> 三个标识符别混：`marketplace add` 传**仓库** `HerbertGao/double-wechat`；`plugin install <plugin>@<marketplace>` 两段都是 `double-wechat`（清单里 plugin 名与 marketplace 名同名）；`marketplace remove` 传 **marketplace 名** `double-wechat`。
> marketplace 清单在仓库根 `.claude-plugin/marketplace.json`；plugin 内含 7 个 slash command + Skill 描述。

装好后，在会话里直接用自然语言（"再开一个微信"自动触发 Skill），或用下面的 slash command：

| 命令 | 行为 |
|---|---|
| `/double-wechat:list` | 列出原版 + 所有副本及版本 |
| `/double-wechat:create [n]` | 创建副本；不指定编号时 AI 自动选空号 |
| `/double-wechat:start <n>` | 启动指定副本 |
| `/double-wechat:delete <n>` | **先确认再删** |
| `/double-wechat:update [--all\|<n>...]` | 列出差异、确认后批量更新 |
| `/double-wechat:adopt [n]` | 把版本反超原版的副本提升为新原版 |
| `/double-wechat:doctor` | 自检环境 |

### Codex CLI

**在终端（shell）里安装 / 卸载**（先加 marketplace，再装 plugin）：

```bash
# 安装
codex plugin marketplace add HerbertGao/double-wechat
codex plugin add double-wechat@double-wechat

# 卸载
codex plugin remove double-wechat@double-wechat
codex plugin marketplace remove double-wechat
```

**已经在 Codex 会话内时**：Codex 无插件管理 slash 命令，安装走上面的终端命令；装好后在会话里直接用自然语言（"再开一个微信"），由 SKILL.md 路由到 `double-wechat` 命令。

> marketplace 清单在仓库根 `.agents/plugins/marketplace.json`。

### 手动安装（不走 marketplace）

```bash
ln -s "$PWD/packaging/skill/double-wechat" ~/.claude/skills/double-wechat
```

> Skill 与 Slash Command 互补：日常对话用 Skill（"再开一个微信"自动触发），需要确定性入口时用 Slash Command。两者都依赖 `double-wechat` 在 PATH 里。

---

## 直接用 CLI

### 人类：交互菜单（无参运行）

```bash
./double-wechat.sh
```

启动时自动检测版本差异，发现不一致会提示一键同步（较新副本走 adopt、较旧走 update）。

### 脚本 / AI：子命令模式

```bash
double-wechat doctor [--json]                       # 自检环境
double-wechat list [--json]                         # 列出原版 + 所有副本
double-wechat create <0-9> [--no-launch] [--yes]    # 创建（默认创建后启动）
double-wechat start  <0-9>                          # 启动已有副本
double-wechat delete <0-9> [--yes]                  # 删除副本
double-wechat update [--all | <n>...] [--yes]       # 同步副本到原版
double-wechat adopt  [<0-9>] [--yes]                # 收编版本反超原版的副本
double-wechat help | version
```

**约定**：

- 数据输出（含 JSON）走 stdout；日志（INFO/WARN/STEP/ERROR）走 stderr，可安全管道给解析器
- 写操作（create/delete/update/adopt）默认要 stdin 确认；脚本/AI 调用必须加 `--yes`
- 退出码：`0` 成功 / `1` 业务失败 / `2` 参数错误 / `130` 用户中断

```bash
double-wechat doctor --json | jq                                   # 机器可读自检
double-wechat list --json | jq '.instances[] | select(.needs_update)'  # 筛出待更新
double-wechat create 2 --no-launch --yes                           # 非交互创建编号 2
double-wechat update --all --yes                                   # 更新所有过期实例
```

---

## 技术原理

### 隔离机制

- **文件系统**：每个实例独立的 `.app`
- **标识符**：不同 Bundle Identifier（`com.tencent.xinWeChat<n>`）让系统识别为不同应用
- **进程 / 沙箱**：独立进程 + 按 Bundle ID 的独立沙箱（`~/Library/Containers/com.tencent.xinWeChat<n>/`）

### 核心步骤（无 sudo）

1. `cp -R /Applications/WeChat.app /Applications/WeChat<n>.app`（副本归当前用户）
2. `PlistBuddy -c "Set :CFBundleIdentifier com.tencent.xinWeChat<n>" .../Info.plist`
3. `codesign --force --deep --sign - /Applications/WeChat<n>.app`（adhoc 签名）
4. `nohup .../Contents/MacOS/WeChat &` 启动

### 为什么不需要 sudo

`/Applications/` 默认 `drwxrwxr-x root:admin`，admin 成员可写；微信通常以当前用户身份安装，副本天然归用户，PlistBuddy / codesign / rm 都不需特权。

若你的环境 `/Applications` 不可写或原版归 root，`doctor` 会报 `sudo_required: true`——此时应把用户加进 `admin` 组，而不是用 sudo 绕过（那只会污染副本所有权）。

> **不要给子命令加 sudo**。`create / delete / update / start / adopt` 会主动拒绝 `EUID == 0` 退出：root 创建的副本归 root，后续无 sudo 操作会失败。

### 副本自更新与 `adopt`

副本运行后，微信自带更新器可能就地替换整个 `.app`——升高 build、把 `CFBundleIdentifier` 改回原版、换回腾讯签名。结果这个副本版本反超原版、且丢了多开身份。

此时不能用 `update`（它会拿较旧原版覆盖、把副本**降级**）。`adopt` 反向处理：

1. 校验该副本确实比原版新、且是带正规腾讯签名的干净官方包
2. 用该副本覆盖原版 `WeChat.app`（升级，不降级）
3. 从新原版重新打包该副本，恢复 `com.tencent.xinWeChat<n>` 标识符与 adhoc 签名

`adopt` 是唯一会写原版 `WeChat.app` 的命令；交互菜单「一键同步」与启动自检会在需要时自动先 adopt 再 update。

### 从旧版 (v1.x, 基于 sudo) 升级

旧版副本归 `root:admin`，新版无 sudo 写操作会对它们失败。`doctor` 会检测并给出迁移命令——**这是升级唯一需要 sudo 的一步**：

```bash
sudo chown -R "$(id -un):staff" /Applications/WeChat[0-9].app
```

迁移后 `doctor` 的 `legacy_migration_required` 变 `false`，所有写操作恢复无 sudo。

---

## 注意事项

- 副本用 adhoc 签名，仅本机有效，无法分发
- 不要删原版 `WeChat.app`（子命令物理上不允许，编号必须 0–9）
- update / delete / 覆盖 create / adopt 都会让对应实例登录态丢失，需重新扫码
- 每个实例独立，需各自扫码登录（正常现象）

**常见问题**

- **未找到原始微信应用** → 确认装在 `/Applications/WeChat.app`
- **doctor 报 `sudo_required: true`** → 把账户改为管理员重新登录，别用 sudo 绕过
- **启动失败** → 检查磁盘空间，或 `double-wechat update <n> --yes` 重建

---

**免责声明**：本工具仅供学习和个人使用，请遵守相关法律法规和微信用户协议。使用产生的任何后果由用户自行承担。

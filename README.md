# macOS 微信多开工具

在 macOS 上同时登录多个微信账号。全程无需 sudo，支持接入 AI 编程工具用自然语言管理多开。

> "再开一个微信" / "我现在有几个微信？" / "把所有副本同步到最新版"

## ⚡ 快速开始

```bash
git clone https://github.com/HerbertGao/double-wechat.git && cd double-wechat
chmod +x double-wechat.sh

# 放进 PATH
mkdir -p ~/.local/bin
ln -s "$PWD/double-wechat.sh" ~/.local/bin/double-wechat
# 若 ~/.local/bin 不在 PATH 中：
#   echo 'export PATH="$HOME/.local/bin:$PATH"' >> ~/.zshrc && source ~/.zshrc
```

**环境要求**：macOS 12+、`/Applications/WeChat.app`、Xcode 命令行工具（`xcode-select --install`）。

## ✨ 功能概览

- **创建 / 启动 / 删除**：微信副本编号 0–9，最多 10 个，每个约 150–200 MB
- **版本检测 + 一键更新**：查看所有副本版本，批量同步过期副本
- **收编 (adopt)**：副本自更新后版本反超原版时，提升为新原版避免降级
- **环境自检 (doctor)**：检查运行环境是否就绪

## 🖥️ 使用

### 交互菜单

```bash
./double-wechat.sh
```

启动时自动检测版本差异并提示同步。

### 子命令

```bash
double-wechat list [--json]                         # 列出原版 + 所有副本
double-wechat create <0-9> [--no-launch] [--yes]    # 创建副本（默认创建后启动）
double-wechat start  <0-9>                          # 启动已有副本
double-wechat delete <0-9> [--yes]                  # 删除副本
double-wechat update [--all | <n>...] [--yes]       # 同步副本到原版
double-wechat adopt  [<0-9>] [--yes]                # 收编版本反超原版的副本
double-wechat doctor [--json]                       # 自检环境
```

写操作默认要确认，脚本 / AI 调用加 `--yes` 跳过。`--json` 输出走 stdout，日志走 stderr。

## 🤖 AI Skill

Skill 定义在 [.agents/skills/double-wechat/SKILL.md](.agents/skills/double-wechat/SKILL.md)，兼容 Claude Code、Codex CLI 等支持 `.agents/` 约定的 AI 编程工具。克隆仓库并将 `double-wechat` 放进 PATH 后即可用自然语言管理多开。

```bash
npx skills install HerbertGao/double-wechat
```

## ⚠️ 注意事项

- 副本用 adhoc 签名，仅本机有效
- 不要删原版 `WeChat.app`
- update / delete / adopt 会让对应实例登录态丢失，需重新扫码
- `doctor` 报 `sudo_required: true` → 把账户改为管理员，别用 sudo 绕过

技术原理（隔离机制、Team ID 补丁、v1.x 迁移等）见 [docs/HOW_IT_WORKS.md](docs/HOW_IT_WORKS.md)。

---

**免责声明**：本工具仅供学习和个人使用，请遵守相关法律法规和微信用户协议。使用产生的任何后果由用户自行承担。

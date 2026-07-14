---
name: double-wechat
description: Manage multiple WeChat instances on macOS via natural language — list / create / start / delete / update / adopt copies of WeChat.app. All operations run as the current user (no sudo required when the user is in the admin group). Backed by a local `double-wechat` shell binary.
min_binary_version: 2.1.3
---

# double-wechat Skill

让 AI Agent 通过自然语言在 macOS 上管理多个微信实例——列出、创建、启动、删除、版本同步。底层是本地的 `double-wechat` shell 脚本，全程以当前用户身份运行，**不需要 sudo**。

**适用场景**：

- "帮我再开一个微信"
- "我现在有几个微信？"
- "WeChat3 不要了，删掉"
- "原始微信升级了，把所有副本同步到最新版"
- "WeChat0 自己升级了、比原版还新，帮我理顺"
- "我的环境能不能跑这个工具？"

**不适用**：

- 跨机器/远程管理
- 随意改写原始 `/Applications/WeChat.app`（仅 `adopt` 会在受控条件下用更新的副本提升原版）
- 需要 sudo 的环境（自动检测，doctor 会报告）

---

## 前置依赖

- macOS 12 (Monterey) 或更高
- `/Applications/WeChat.app` 已正确安装
- 当前用户必须在 `admin` 组、且 `/Applications` 可写（绝大多数 macOS 用户默认满足；不满足时 `doctor` 会明确报告）
- `double-wechat` 可执行文件 **≥ 2.1.3** 且在 `PATH` 中
  - 仓库根目录的 `double-wechat.sh` 可直接软链：`ln -s "$PWD/double-wechat.sh" /usr/local/bin/double-wechat`

> Skill 发行物按 host 注册（Claude Code skill / Codex CLI plugin）；具体注册路径与命令见仓库 README。本文件保持 host-agnostic。

---

## Agent 工具表

Skill 通过 **shell 子命令** 暴露能力。Agent 通过 host 提供的 shell 执行工具（如 Claude Code 的 Bash 工具）调用以下命令；**所有数据输出走 stdout，所有日志走 stderr**，因此可以直接用 `--json` 形式管道给 JSON 解析器。

### 1. `double-wechat doctor [--json]`

**用途**：自检环境是否能让 Agent 无 sudo 跑写操作。**Agent 应在每段会话起始**调用一次（带 `--json`），缓存结果用于本会话——没必要重复调。

**参数**：

| 参数 | 说明 |
|---|---|
| `--json` | 机器可读输出（推荐 Agent 使用） |

**返回 JSON**：

```jsonc
{
  "version": "2.1.3",
  "in_admin_group": true,
  "applications_writable": true,
  "original_wechat_present": true,
  "original_wechat_owner": "herbertgao:staff",
  "original_short_version": "4.1.9",
  "original_build_version": "268575",
  "sudo_required": false,                   // /Applications 不可写时为 true
  "can_run_unprivileged": true,             // false 时 Agent 不应继续调用写操作
  "target_dir": "/Applications",
  "legacy_owned_instances": [               // 旧版 sudo 创建的 root-owned 副本路径
    "/Applications/WeChat0.app"
  ],
  "legacy_migration_required": false,       // legacy_owned_instances 非空时为 true
  "migration_hint": "",                     // 非空时是一次性 chown 命令
  "brand_mismatched_instances": [           // bundle id 被自更新回退、与编号不符的副本
    "/Applications/WeChat1.app"
  ],
  "brand_mismatch_required": false          // brand_mismatched_instances 非空时为 true
}
```

**Agent 行为约定**：

- `can_run_unprivileged: false` → **停止调用**任何写操作（create/delete/update），向用户报告环境问题，提示用户参考 doctor 文本输出
- `original_wechat_present: false` → 提示用户先安装 WeChat
- `sudo_required: true` → 不要尝试 sudo，建议用户从 macOS"系统设置 → 用户与群组"把当前用户加入 admin 组
- `legacy_migration_required: true` → **不要替用户执行 sudo**。把 `migration_hint` 字段中的命令原样展示给用户，告诉用户这是从旧版升级时的一次性迁移，让用户在他自己的终端里手动跑。跑完之后再调任何写操作
- `brand_mismatch_required: true` → 该副本的 Bundle ID 被自更新写回官方包时抹掉了（退回原版 id，与原版撞车、多开失效）。**与版本无关，`needs_update` 可能为 false**。修复要按版本关系选择，**不能一律 create**（自更新常把副本升到比原版更新的版本，用 create 会从较旧原版重建导致降级）：
    - 副本版本 **高于** 原版（`list` 里该副本 `short_version`/`build_version` 大于 `original`）→ `double-wechat adopt <编号>`（收编为新原版）
    - 副本版本 **等于/低于** 原版，**或原版版本读不出**（此时 adopt 会拒绝执行）→ `double-wechat create <编号>`（从原版重建）
    - 两者都保留登录态与聊天记录（存于独立沙盒容器，不受影响）；`create` / `adopt` 会自动强制退出相关正在运行的实例（按可执行文件路径精确退出，不会误杀撞车的原版），无需手动先退

---

### 2. `double-wechat list [--json]`

**用途**：列出所有微信实例（原始 + 已创建的副本）及版本信息。**只读、随时可调**。

**参数**：

| 参数 | 说明 |
|---|---|
| `--json` | 机器可读输出 |

**返回 JSON**：

```jsonc
{
  "original": {
    "path": "/Applications/WeChat.app",
    "short_version": "4.1.9",
    "build_version": "268575"
  },
  "instances": [
    {
      "number": "0",
      "path": "/Applications/WeChat0.app",
      "bundle_id": "com.tencent.xinWeChat0",
      "short_version": "4.1.9",
      "build_version": "268575",
      "needs_update": false           // true 表示版本与 original 不一致
    }
  ]
}
```

**典型使用**：

- 用户问"我有几个微信" → 调一次 list，从 `instances.length` 回答
- 用户要 create/delete 但没指定编号 → 先 list 拿到当前已用编号（`instances[].number`），再选一个未用的（0–9 范围内）

---

### 3. `double-wechat create <0-9> [--no-launch] [--yes]`

**用途**：创建编号为 `<n>` 的微信副本（cp + 改 Bundle ID + adhoc 签名），**默认创建后立即启动**。

**参数**：

| 位置参 | 类型 | 说明 |
|---|---|---|
| `<n>` | `0-9` 单个数字 | 实例编号 |

| 选项 | 说明 |
|---|---|
| `--no-launch` | 仅创建，不启动 |
| `--yes` / `-y` | **Agent 必加**：覆盖已有同号实例时跳过交互确认；非交互环境下未传此参数会失败 |

**Agent 行为约定**：

- 调用前 **必须** 先 `list --json` 确认编号未被占用；如果用户没指定编号，Agent 应自动从 0 开始挑第一个未用编号
- 如果用户明确要求覆盖某个已有实例，**必须先向用户确认**，再加 `--yes`
- 这是一个写操作，**永远不要在 doctor 显示 `can_run_unprivileged: false` 时调用**

**退出码**：`0` 成功；`1` 操作失败；`2` 参数错误

---

### 4. `double-wechat start <0-9>`

**用途**：启动已创建的副本。

**参数**：编号 `0-9`。

**Agent 行为约定**：

- 启动用 `nohup` 后台 fork，立即返回。Agent 不应等待界面就绪
- 启动前可选地 `list` 确认实例存在；不存在时本命令会报错并退出 1

---

### 5. `double-wechat delete <0-9> [--yes]`

**用途**：删除指定副本（先尝试 `osascript` 优雅退出运行中的实例，再 `rm -rf`）。

**参数**：

| 选项 | 说明 |
|---|---|
| `--yes` / `-y` | **Agent 必加**：跳过交互确认；非交互环境下未传此参数会失败 |

**Agent 行为约定（重要）**：

- 删除是不可恢复操作。Agent **必须先向用户口头确认**目标实例编号，得到肯定回复后才能加 `--yes` 调用
- **绝对不要**用 `delete` 删除原始 `WeChat.app`——本工具的 `<0-9>` 入参语义就是"副本编号"，无法误删原始（参数校验拒绝非数字）

---

### 6. `double-wechat update [--all | <n>...] [--yes]`

**用途**：把版本与原始 WeChat 不一致的副本重建为最新版本（保留账号编号，不保留旧 app 内文件）。

**参数**：

| 形式 | 说明 |
|---|---|
| `--all` | 更新所有 `needs_update: true` 的实例 |
| `<n>...` | 显式指定编号列表，如 `update 0 2 3` |
| `--yes` / `-y` | **Agent 必加**：跳过交互确认 |

**Agent 行为约定**：

- **先判断版本方向**：`update` 只适合版本**低于**原版的副本。若 `list --json` 里某副本版本**高于** `original`（被微信自更新所致），它要用 `adopt` 收编，**不能** `update`——否则会被降级
- 调用前先 `list --json`，把 `instances[].needs_update == true` 的列表回报给用户，确认后再 `update --all --yes`
- 实现细节：update 内部对每个目标先 `osascript ... to quit` 优雅退出，然后 `rm -rf` + 重新 cp/sign。**用户登录态会丢失**——Agent 应当在确认时提醒这一点
- 如果 update 失败并报"实例归非当前用户所有"，说明这些实例是旧版 sudo 创建的。**不要重试**，把命令输出里的 `sudo chown -R ...` 行原样展示给用户，让用户先做一次性迁移

---

### 7. `double-wechat adopt [<0-9>] [--yes]`

**用途**：当某个副本因微信自带的应用内更新而版本**高于**原始 `WeChat.app` 时，把该副本「收编」为新的原版（拷贝覆盖 `WeChat.app`），再从新原版重新打包该副本。全程不降级、不触碰用户数据容器。

**背景**：副本被启动后，微信自更新器会就地替换整个 `.app`——build 升高、`CFBundleIdentifier` 改回原版 id、签名换回腾讯签名。结果该副本版本超过原版且丢失多开身份。直接 `update` 会把它**降级**回旧原版；`adopt` 则反向：让更新的副本成为原版。

**参数**：

| 形式 | 说明 |
|---|---|
| `<n>` | 显式指定要收编的副本编号 `0-9` |
| 无编号 | 自动挑选版本最高、且比原版新的副本；无此类副本时输出提示并退出 0 |
| `--yes` / `-y` | **Agent 必加**：跳过交互确认；非交互环境下未传此参数会失败 |

**前置校验（任一不满足则拒绝并退出 1）**：

- 候选副本版本确实高于原版（否则提示改用 `update`）
- 候选副本是干净的官方包（带正规腾讯签名、签名校验通过、bundle id 为原版 id）——否则提升为原版会让原版失去正规签名
- 原版与候选副本均归当前用户所有

**Agent 行为约定**：

- 检测时机：`list --json` 后，若某副本版本数值**高于** `original`（比较 `short_version`，相等再比 `build_version`）→ 该副本走 `adopt`，**不要**走 `update`（update 会降级它）
- adopt 会**覆盖** `/Applications/WeChat.app`——这是工具中唯一写原始的命令。调用前**必须向用户确认**
- adopt 完成后原版升级为新版本，其余副本可能变为落后状态；按需再 `update --all --yes`

**退出码**：`0` 成功（含"无副本比原版新"）；`1` 操作失败（含校验未通过）；`2` 参数错误

---

## 不暴露给 Agent 的能力

以下用法**不在** Agent 工具表内，请勿调用：

- 无参 `double-wechat`（交互菜单，仅给人类用户）
- `interactive_start` / `interactive_delete`（菜单内部分支，期望从 stdin 读编号）

如果不小心调用了无参形式，命令会进入交互菜单等待 stdin 输入并卡住。Agent 应总是带子命令调用。

---

## 调用约定总览

| 项 | 约定 |
|---|---|
| 协议 | 纯 shell 子命令（无 MCP / 无 socket） |
| 数据输出 | stdout，`--json` 模式下为单行 JSON |
| 日志输出 | stderr，可被 Agent 安全忽略 |
| 退出码 | `0` 成功 / `1` 业务失败 / `2` 参数错误 |
| 交互确认 | 写操作（create/delete/update/adopt）默认要 stdin 确认；Agent 必加 `--yes` |
| sudo | 不需要；如果 `doctor` 报告 `sudo_required: true`，**不要**绕过 |
| root 调用 | 写子命令（create/delete/update/start/adopt）会主动拒绝 `EUID == 0`。**不要**用 `sudo` 跑这些命令——root 创建的副本归 root 所有，会破坏后续无 sudo 操作 |
| 并发 | 不要并行调用写操作（同时改 `/Applications` 不安全）；只读命令（list/doctor）可并行 |

---

## 安全与边界

- **写路径限定**：list/create/start/delete/update 只写 `/Applications/WeChat<0-9>.app`，编号校验严格匹配 `^[0-9]$`，无法逃逸目录
- **adopt 是唯一会写原始 `WeChat.app` 的命令**：它把自更新后版本更高的副本提升为新原版，仅在该副本为带正规腾讯签名的干净官方包时才执行（否则拒绝）；此操作有意覆盖原版，Agent 调用前必须向用户确认
- **凭据/数据隔离**：每个微信副本有独立的 `~/Library/Containers/com.tencent.xinWeChat<n>/`（macOS 沙箱按 Bundle ID 隔离），Agent 工具不读写这些路径
- **签名**：副本使用 adhoc 签名（`codesign --sign -`），仅本机有效，无法分发
- **腾讯 ToS 边界**：多开微信可能违反腾讯用户协议，由用户承担合规边界
- **不发起网络请求**：本 Skill 完全本地操作，不向任何远程服务发数据

---

## 与人类 CLI 接口的关系

无参 `double-wechat` 仍是人类用户的交互菜单入口；启动时会自动检测版本差异并提示一键同步（较新的副本走 adopt、较旧的走 update）。子命令模式与菜单模式共享同一份核心实现（`do_create_instance` / `do_start_instance` / `do_delete_instance`），任何修复同时受益。

> Agent 调用形态**仅限**子命令；遇到只用菜单完成的旧文档示例时，请翻译为对应子命令再执行。

---

## 典型对话样例

**例 1：用户问"我现在有几个微信"**

```
1. Agent: double-wechat list --json
2. Agent → user: "你目前有 2 个微信副本（编号 0、1），都和原始 WeChat 4.1.9 (Build 268575) 同版本。"
```

**例 2：用户说"再开一个"**

```
1. Agent: double-wechat list --json
   → 发现已用编号 [0, 1]
2. Agent → user: "我准备创建 WeChat2 并启动，OK 吗？"
3. user: ok
4. Agent: double-wechat create 2 --yes
5. Agent → user: "WeChat2 已创建并启动 (PID: 12345)。"
```

**例 3：用户说"原始微信升级了，副本都同步一下"**

```
1. Agent: double-wechat list --json
   → 找到 needs_update=true 的实例 [0, 1]
2. Agent → user: "WeChat0 / WeChat1 都需要更新。重建会丢失这些副本里的登录态，需要重新扫码。继续吗？"
3. user: 继续
4. Agent: double-wechat update --all --yes
5. Agent → user: "已更新 2 个实例，全部成功。"
```

**例 4：用户说"删掉 WeChat3"**

```
1. Agent: double-wechat list --json
   → 确认 WeChat3 存在
2. Agent → user: "确认删除 WeChat3.app？这会丢失该实例里的登录态和聊天记录。"
3. user: 是
4. Agent: double-wechat delete 3 --yes
5. Agent → user: "WeChat3.app 已删除。"
```

**例 5：用户说"WeChat0 自己升级了，比原始微信还新"**

```
1. Agent: double-wechat list --json
   → 发现 WeChat0 版本高于 original（自更新所致）
2. Agent → user: "WeChat0 已自更新到比原始微信更新的版本。我可以把它『收编』为新的原始 WeChat.app，再重新打包 WeChat0——这样不降级。这一步会覆盖 /Applications/WeChat.app，确认吗？"
3. user: 确认
4. Agent: double-wechat adopt 0 --yes
5. Agent → user: "已把 WeChat0 收编为新原版，两者均为最新版本。"
```

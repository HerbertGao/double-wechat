---
description: 创建新的微信实例（不指定编号时自动选空号）
argument-hint: "[number 0-9]"
allowed-tools: Bash(double-wechat:*)
---

参数：`$ARGUMENTS`

行为：

1. **如果 `$ARGUMENTS` 为空**：先跑 `double-wechat list --json` 看已用编号，从 `0..9` 里选第一个未用的；告诉用户你选了哪个编号，再跑 `double-wechat create <n> --yes`
2. **如果 `$ARGUMENTS` 是 0–9 单个数字**：先跑 `double-wechat list --json` 检查该编号是否已存在
   - 已存在 → 向用户确认是否覆盖（**会丢失该实例的登录态和聊天记录**），用户同意后跑 `double-wechat create <n> --yes`
   - 不存在 → 直接跑 `double-wechat create <n> --yes`
3. **如果 `$ARGUMENTS` 是非法编号（不是 0–9 单个数字）**：直接告诉用户参数错误，不要调用底层命令

成功后告诉用户：新实例编号 + 启动状态（PID）。create 默认会启动；如果用户明确说"先别启动"，加 `--no-launch`。

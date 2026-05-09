---
description: 把所有版本不一致的副本同步到原始 WeChat 版本
argument-hint: "[--all | <number...>]"
allowed-tools: Bash(double-wechat:*)
---

参数：`$ARGUMENTS`（可能为空、可能是 `--all`、可能是若干 0–9 编号）

流程：

1. 跑 `double-wechat list --json` 拿到当前清单
2. 计算需要更新的实例：
   - `$ARGUMENTS` 为空或是 `--all` → 取所有 `needs_update: true` 的实例
   - `$ARGUMENTS` 是若干编号 → 取这些编号对应的实例
3. **如果没有任何实例需要更新**：告诉用户"所有实例都已是最新版本"并停止
4. 把将要更新的实例（编号 + 当前版本 → 目标版本）列给用户，**口头确认**：
   "更新会重建副本，会丢失这些实例的登录态。继续吗？" 等待用户回复
5. 用户同意后，跑 `double-wechat update --all --yes`（或显式 `update <n1> <n2> ... --yes`）
6. 报告成功/失败汇总

**绝对不要**未经确认就跑带 `--yes` 的 update。

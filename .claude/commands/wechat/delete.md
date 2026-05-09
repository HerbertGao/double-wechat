---
description: 删除指定编号的微信实例（先确认后删）
argument-hint: "<number 0-9>"
allowed-tools: Bash(double-wechat:*)
---

参数：`$ARGUMENTS`

**这是不可恢复操作。必须遵循以下流程：**

1. 校验 `$ARGUMENTS` 是 0–9 单个数字；不是则告诉用户参数错误并停止
2. 跑 `double-wechat list --json` 确认该编号实例存在；不存在则告诉用户并停止
3. **向用户口头确认**："确定要删除 WeChat$ARGUMENTS.app 吗？这会丢失该实例的登录态和聊天记录。" 等待用户回复
4. 用户明确同意后，跑 `double-wechat delete $ARGUMENTS --yes`
5. 报告结果

**绝对不要**在用户没明确同意的情况下加 `--yes` 调用 delete。

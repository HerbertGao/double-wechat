---
description: 把因自更新而版本高于原版的副本「收编」为新的原始 WeChat
argument-hint: "[<number>]"
allowed-tools: Bash(double-wechat:*)
---

参数：`$ARGUMENTS`（可能为空，或一个 0–9 编号）

背景：副本被启动后微信会自更新，把整个 `.app` 替换成更高版本并改回原版 bundle id / 腾讯签名。这种副本版本高于原版且丢失多开身份；直接 `update` 会把它**降级**。`adopt` 反向处理：让更新的副本成为新原版。

流程：

1. 跑 `double-wechat list --json` 拿到当前清单
2. 找出版本高于 `original` 的副本（比较 `short_version`，相等再比 `build_version`）：
   - `$ARGUMENTS` 给了编号 → 收编该副本
   - `$ARGUMENTS` 为空 → 收编版本最高的那个；若无副本比原版新，告诉用户"没有需要收编的副本"并停止
3. 把方案列给用户，**口头确认**：
   "这会用 WeChat<n> 覆盖原始 /Applications/WeChat.app，再重新打包 WeChat<n>。原版与该副本都不会降级。继续吗？" 等待用户回复
4. 用户同意后，跑 `double-wechat adopt <n> --yes`（或无编号 `double-wechat adopt --yes`）
5. 报告结果；若命令提示其它副本落后于新原版，建议用户接着跑 update 同步

**绝对不要**未经确认就跑带 `--yes` 的 adopt——它会覆盖原始 `WeChat.app`。

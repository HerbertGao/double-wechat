---
description: 列出所有微信实例及版本状态
argument-hint: ""
allowed-tools: Bash(double-wechat:*)
---

跑 `double-wechat list --json` 获取实例清单（stdout 是 JSON，stderr 可忽略）。

把结果用一段简洁的中文总结给用户：

- 原始 WeChat 的版本（`original.short_version (Build original.build_version)`）
- 副本数量
- 每个副本的编号 + 版本（如版本与原始不一致，明确标注 `[需要更新]`）

如果有 `needs_update: true` 的实例，最后提示用户可以用 `/wechat:update` 一键更新。

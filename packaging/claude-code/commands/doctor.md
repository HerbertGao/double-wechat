---
description: 自检环境是否能无 sudo 跑多开操作
argument-hint: ""
allowed-tools: Bash(double-wechat:*)
---

跑 `double-wechat doctor --json` 拿到 JSON 报告。

用一段简洁中文向用户汇报关键字段：

- `can_run_unprivileged` —— **核心结论**。true 表示可以无 sudo 直接跑；false 表示环境有问题
- `in_admin_group` / `applications_writable` —— 何处不满足
- `original_wechat_present` + `original_short_version` + `original_build_version` —— 原始微信版本
- `sudo_required` —— 如果 true，**不要建议用户用 sudo 绕过**，建议把当前账户加入 admin 组
- `legacy_migration_required` —— 如果 true，告诉用户这是从旧版（v1.x）升级时一次性的所有权迁移；**把 `migration_hint` 字段中的命令原样展示给用户**，让用户在他自己的终端里手动跑（这是从旧版升级到新版唯一需要 sudo 的步骤）

如果 `can_run_unprivileged: false`，最后一句明确告诉用户："建议先解决环境问题再继续，不要用 sudo 绕过。"

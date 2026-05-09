---
description: 启动指定编号的微信实例
argument-hint: "<number 0-9>"
allowed-tools: Bash(double-wechat:*)
---

参数：`$ARGUMENTS`

如果 `$ARGUMENTS` 不是 0–9 单个数字，告诉用户参数错误，不要调用底层命令。

否则跑 `double-wechat start $ARGUMENTS`，把启动结果（PID 或失败原因）告诉用户。

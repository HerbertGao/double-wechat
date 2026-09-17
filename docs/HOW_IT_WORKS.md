# 技术原理

## 隔离机制

- **文件系统**：每个实例独立的 `.app`
- **标识符**：不同 Bundle Identifier（`com.tencent.xinWeChat<n>`）让系统识别为不同应用
- **进程 / 沙箱**：独立进程 + 按 Bundle ID 的独立沙箱（`~/Library/Containers/com.tencent.xinWeChat<n>/`）

## 核心步骤（无 sudo）

1. `cp -R /Applications/WeChat.app /Applications/WeChat<n>.app`（副本归当前用户）
2. `PlistBuddy -c "Set :CFBundleIdentifier com.tencent.xinWeChat<n>" .../Info.plist`
3. 编译 Team ID 补丁放进 `Contents/Frameworks/`，并写入 `Info.plist` 的 `LSEnvironment`（见下）
4. `codesign --force --deep --sign - /Applications/WeChat<n>.app`（adhoc 签名）
5. 启动（`DYLD_INSERT_LIBRARIES` 带上补丁；Dock / Finder 启动由 `LSEnvironment` 带上）

## Team ID 补丁（微信 4.1.15+）

4.1.15 起，微信加载器会读取自身签名的 Team ID，不是腾讯的 `5A4RE8SF68` 就不加载 `Resources/` 里的真实框架，副本启动即崩溃（`EXC_BAD_ACCESS`，`pc=0`）。adhoc 签名没有 Team ID，而 macOS 会直接杀掉任何冒用他人 Team ID 的签名，所以只能在进程内补：一个 interpose `SecCodeCopySigningInformation` 的十几行 dylib，只给本副本 bundle 内、且缺 Team ID 的代码补上。源码内嵌在 `double-wechat.sh` 的 `build_teamfix` 中。

修复前创建的 4.1.15+ 副本会被 `list` 标为需要更新，`update --all`（或菜单启动时的自检）会自动重建；`start` 会拒绝启动它们。

## 为什么不需要 sudo

`/Applications/` 默认 `drwxrwxr-x root:admin`，admin 成员可写；微信通常以当前用户身份安装，副本天然归用户，PlistBuddy / codesign / rm 都不需特权。

若你的环境 `/Applications` 不可写或原版归 root，`doctor` 会报 `sudo_required: true`——此时应把用户加进 `admin` 组，而不是用 sudo 绕过（那只会污染副本所有权）。

> **不要给子命令加 sudo**。`create / delete / update / start / adopt` 会主动拒绝 `EUID == 0` 退出：root 创建的副本归 root，后续无 sudo 操作会失败。

## 副本自更新与 `adopt`

副本运行后，微信自带更新器可能就地替换整个 `.app`——升高 build、把 `CFBundleIdentifier` 改回原版、换回腾讯签名。结果这个副本版本反超原版、且丢了多开身份。

此时不能用 `update`（它会拿较旧原版覆盖、把副本**降级**）。`adopt` 反向处理：

1. 校验该副本确实比原版新、且是带正规腾讯签名的干净官方包
2. 用该副本覆盖原版 `WeChat.app`（升级，不降级）
3. 从新原版重新打包该副本，恢复 `com.tencent.xinWeChat<n>` 标识符与 adhoc 签名

`adopt` 是唯一会写原版 `WeChat.app` 的命令；交互菜单「一键同步」与启动自检会在需要时自动先 adopt 再 update。

## 从旧版 (v1.x, 基于 sudo) 升级

旧版副本归 `root:admin`，新版无 sudo 写操作会对它们失败。`doctor` 会检测并给出迁移命令——**这是升级唯一需要 sudo 的一步**：

```bash
sudo chown -R "$(id -un):staff" /Applications/WeChat[0-9].app
```

迁移后 `doctor` 的 `legacy_migration_required` 变 `false`，所有写操作恢复无 sudo。

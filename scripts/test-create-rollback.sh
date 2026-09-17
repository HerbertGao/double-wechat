#!/bin/bash
# 自检 do_create_instance 的修复：
#   1. 签名前清掉 bundle 根目录杂物（codesign "unsealed contents in the bundle root" 的根因）
#   2. 任一步骤失败 → 回滚到既有实例，而不是把它删掉
#   3. Team ID 补丁：只给本 bundle 内的代码补 5A4RE8SF68；编译失败时不碰既有实例
# 用法: bash scripts/test-create-rollback.sh
set -uo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# 把脚本里写死的路径重定向到临时沙盒（二者是 readonly，只能改文本）；lsregister 置空，免得污染真实 LaunchServices
sed -e "s#^readonly ORIGINAL_WECHAT=.*#readonly ORIGINAL_WECHAT=\"$TMP/WeChat.app\"#" \
    -e "s#^readonly TARGET_DIR=.*#readonly TARGET_DIR=\"$TMP\"#" \
    -e "s#^\\( *\\)/System/.*/lsregister .*#\\1true#" \
    "$ROOT/double-wechat.sh" > "$TMP/dw.sh"
grep -q lsregister "$TMP/dw.sh" && { echo "lsregister 未屏蔽，拒绝运行"; exit 1; }
source "$TMP/dw.sh"

make_original() {
    rm -rf "$TMP/WeChat.app"
    mkdir -p "$TMP/WeChat.app/Contents/MacOS"
    cat > "$TMP/WeChat.app/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>com.tencent.xinWeChat</string>
<key>CFBundleExecutable</key><string>WeChat</string>
</dict></plist>
EOF
    printf '#!/bin/sh\n' > "$TMP/WeChat.app/Contents/MacOS/WeChat"
    chmod +x "$TMP/WeChat.app/Contents/MacOS/WeChat"
}

fail=0
check() { if [[ "$1" == "$2" ]]; then echo "  ok: $3"; else echo "  FAIL: $3 (期望 '$2'，实际 '$1')"; fail=1; fi; }

echo "[1] 原版根目录带杂物时，重建出的副本应被清干净且签名成功"
make_original
touch "$TMP/WeChat.app/update.tmp"                   # 就是它让 codesign 报 unsealed contents
do_create_instance 1 >/dev/null 2>&1
check "$?" "0" "do_create_instance 成功"
check "$(ls -A "$TMP/WeChat1.app" | tr '\n' ' ')" "Contents " "副本根目录只剩 Contents"
check "$(get_app_bundle_id "$TMP/WeChat1.app")" "com.tencent.xinWeChat1" "bundle id 已改写"
fix=$(teamfix_path "$TMP/WeChat1.app")
check "$(/usr/libexec/PlistBuddy -c 'Print :LSEnvironment:DYLD_INSERT_LIBRARIES' "$TMP/WeChat1.app/Contents/Info.plist")" "$fix" "LSEnvironment 注入 Team ID 补丁"
# 探针打印自身签名的 Team ID：放在副本内应被补上，放在副本外应原样（空）
cat > "$TMP/probe.c" <<'EOF'
#include <Security/Security.h>
#include <stdio.h>
int main(void) {
    SecCodeRef self; CFDictionaryRef info; char team[64] = "";
    if (SecCodeCopySelf(kSecCSDefaultFlags, &self) == errSecSuccess &&
        SecCodeCopySigningInformation((SecStaticCodeRef)self, kSecCSSigningInformation, &info) == errSecSuccess) {
        CFStringRef t = CFDictionaryGetValue(info, kSecCodeInfoTeamIdentifier);
        if (t) CFStringGetCString(t, team, sizeof team, kCFStringEncodingUTF8);
    }
    printf("team=%s\n", team);
    return 0;
}
EOF
xcrun clang -framework Security -framework CoreFoundation -o "$TMP/probe" "$TMP/probe.c" && codesign -f -s - "$TMP/probe" 2>/dev/null
cp "$TMP/probe" "$TMP/WeChat1.app/Contents/MacOS/probe"
check "$(DYLD_INSERT_LIBRARIES="$fix" "$TMP/WeChat1.app/Contents/MacOS/probe")" "team=5A4RE8SF68" "副本内代码被补上腾讯 Team ID"
check "$(DYLD_INSERT_LIBRARIES="$fix" "$TMP/probe")" "team=" "副本外代码不受影响（探针正常运行、未被补）"
for a in arm64 x86_64; do   # 探针只跑本机架构，另一切片得单独查
    check "$(otool -arch $a -l "$fix" | grep -c 'sectname __interpose')" "1" "补丁 $a 切片含 interpose"
done

echo "[2] 重建中途失败时，既有实例必须原样回滚"
touch "$TMP/WeChat1.app/Contents/MARKER"             # 标记「旧实例」，回滚后应仍在
make_original
echo 'not a plist' > "$TMP/WeChat.app/Contents/Info.plist"   # 让 PlistBuddy 那步失败
do_create_instance 1 >/dev/null 2>&1
check "$?" "1" "do_create_instance 返回失败"
check "$([[ -f "$TMP/WeChat1.app/Contents/MARKER" ]] && echo yes || echo no)" "yes" "旧实例被完整回滚（没有消失）"
check "$([[ -e "$TMP/.WeChat1.app.bak" ]] && echo yes || echo no)" "no" "没有留下备份残骸"

echo "[3] 补丁编译失败时，既有实例必须原封不动（不强退、不搬走）"
make_original
# stub 放子 shell：不污染后续用例里真实的 force_quit_instance
( xcrun() { return 1; }; force_quit_instance() { touch "$TMP/quit-called"; }; do_create_instance 1 ) >/dev/null 2>&1
check "$?" "1" "do_create_instance 返回失败"
check "$([[ -e "$TMP/quit-called" ]] && echo yes || echo no)" "no" "没有强退实例"
check "$([[ -f "$TMP/WeChat1.app/Contents/MARKER" ]] && echo yes || echo no)" "yes" "旧实例原样保留"
check "$([[ -e "$TMP/.WeChat1.app.bak" ]] && echo yes || echo no)" "no" "没有产生备份"

echo "[4] 4.1.15+ 缺补丁的旧副本要被识别为需要重建，更早版本不打扰"
app="$TMP/WeChat1.app"
/usr/libexec/PlistBuddy -c "Add :CFBundleShortVersionString string 4.1.15" "$TMP/WeChat.app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Add :CFBundleShortVersionString string 4.1.15" "$app/Contents/Info.plist"
check "$(needs_teamfix "$app" && echo yes || echo no)" "no" "有补丁 → 不需要"
rm -f "$(teamfix_path "$app")"
check "$(needs_teamfix "$app" && echo yes || echo no)" "yes" "4.1.15 缺补丁 → 需要"
do_start_instance 1 >/dev/null 2>&1
check "$?" "1" "start 拒绝启动缺补丁的副本"
check "$(cmd_list --json 2>/dev/null | grep -o '"needs_update":[a-z]*')" '"needs_update":true' "list 标记为需要更新"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier com.tencent.xinWeChat" "$app/Contents/Info.plist"
check "$(needs_teamfix "$app" && echo yes || echo no)" "no" "自更新写回的官方包（id 已回退）→ 交给 brand check，不算"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier com.tencent.xinWeChat1" "$app/Contents/Info.plist"
check "$(needs_teamfix "$TMP/WeChat.app" && echo yes || echo no)" "no" "原版不算"
cmd_update --all --yes >/dev/null 2>&1
check "$([[ -f "$(teamfix_path "$app")" ]] && echo yes || echo no)" "yes" "update --all 重建缺补丁的副本"
rm -f "$(teamfix_path "$app")"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString 4.1.14" "$app/Contents/Info.plist"
check "$(needs_teamfix "$app" && echo yes || echo no)" "no" "4.1.14 缺补丁 → 不需要"

[[ $fail -eq 0 ]] && echo "全部通过" || echo "存在失败项"
exit $fail

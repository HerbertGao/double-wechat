#!/bin/bash
# 自检 do_create_instance 的两条修复：
#   1. 签名前清掉 bundle 根目录杂物（codesign "unsealed contents in the bundle root" 的根因）
#   2. 任一步骤失败 → 回滚到既有实例，而不是把它删掉
# 用法: bash scripts/test-create-rollback.sh
set -uo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# 把脚本里写死的路径重定向到临时沙盒（二者是 readonly，只能改文本）
sed -e "s#^readonly ORIGINAL_WECHAT=.*#readonly ORIGINAL_WECHAT=\"$TMP/WeChat.app\"#" \
    -e "s#^readonly TARGET_DIR=.*#readonly TARGET_DIR=\"$TMP\"#" \
    "$ROOT/double-wechat.sh" > "$TMP/dw.sh"
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

echo "[2] 重建中途失败时，既有实例必须原样回滚"
touch "$TMP/WeChat1.app/Contents/MARKER"             # 标记「旧实例」，回滚后应仍在
make_original
echo 'not a plist' > "$TMP/WeChat.app/Contents/Info.plist"   # 让 PlistBuddy 那步失败
do_create_instance 1 >/dev/null 2>&1
check "$?" "1" "do_create_instance 返回失败"
check "$([[ -f "$TMP/WeChat1.app/Contents/MARKER" ]] && echo yes || echo no)" "yes" "旧实例被完整回滚（没有消失）"
check "$([[ -e "$TMP/.WeChat1.app.bak" ]] && echo yes || echo no)" "no" "没有留下备份残骸"

[[ $fail -eq 0 ]] && echo "全部通过" || echo "存在失败项"
exit $fail

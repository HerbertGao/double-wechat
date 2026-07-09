#!/bin/bash
# ============================================================
# double-wechat — macOS 微信多开管理工具
#
# 用法（人类）:
#   double-wechat                              # 交互菜单
#
# 用法（脚本/AI Skill）:
#   double-wechat list [--json]
#   double-wechat create <0-9> [--no-launch] [--yes]
#   double-wechat start <0-9>
#   double-wechat delete <0-9> [--yes]
#   double-wechat update [--all | <n>...] [--yes]
#   double-wechat adopt [<0-9>] [--yes]
#   double-wechat doctor [--json]
#   double-wechat help
#   double-wechat version
#
# 设计要点:
#   - 所有写操作不需要 sudo（前提：当前用户在 admin 组且 /Applications 可写）
#   - 所有日志写 stderr，stdout 仅输出数据（JSON 或纯文本数据）
#   - --json 输出供脚本/AI 解析；非 --json 输出供人类阅读
# ============================================================

set -uo pipefail

readonly VERSION="2.1.1"

# ----- 配置 -----
readonly ORIGINAL_WECHAT="/Applications/WeChat.app"
readonly ORIGINAL_BUNDLE_ID="com.tencent.xinWeChat"
readonly TARGET_DIR="/Applications"

# 提示里让用户键入的命令名：装进 PATH 就用 double-wechat，否则回退到实际调用路径（bash double-wechat.sh
# 时 $0 是纯文件名，补 ./ 方可直接运行）。仅影响提示文案；自动修复走脚本内函数，与是否安装无关。
if command -v double-wechat >/dev/null 2>&1; then
    readonly SELF="double-wechat"
else
    case "$0" in */*) readonly SELF="$0";; *) readonly SELF="./$0";; esac
fi

# ----- 颜色（仅 stderr 是 tty 时启用）-----
if [[ -t 2 ]]; then
    RED=$'\033[0;31m'; GREEN=$'\033[0;32m'; YELLOW=$'\033[1;33m'; BLUE=$'\033[0;34m'; NC=$'\033[0m'
else
    RED=''; GREEN=''; YELLOW=''; BLUE=''; NC=''
fi

# ----- 日志（统一到 stderr）-----
log_info()  { printf '%s[INFO]%s %s\n'  "$GREEN"  "$NC" "$1" >&2; }
log_warn()  { printf '%s[WARN]%s %s\n'  "$YELLOW" "$NC" "$1" >&2; }
log_error() { printf '%s[ERROR]%s %s\n' "$RED"    "$NC" "$1" >&2; }
log_step()  { printf '%s[STEP]%s %s\n'  "$BLUE"   "$NC" "$1" >&2; }

# ----- 工具函数 -----
get_app_version()   { /usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$1/Contents/Info.plist" 2>/dev/null || true; }
get_app_build()     { /usr/libexec/PlistBuddy -c "Print :CFBundleVersion"            "$1/Contents/Info.plist" 2>/dev/null || true; }
get_app_bundle_id() { /usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier"         "$1/Contents/Info.plist" 2>/dev/null || true; }

format_version_info() {
    local s="$1" b="$2"
    if   [[ -z "$s" && -z "$b" ]]; then echo "未知版本"
    elif [[ -n "$s" && -n "$b" ]]; then echo "${s} (Build ${b})"
    elif [[ -n "$s" ]];            then echo "$s"
    else                                echo "Build ${b}"
    fi
}

# 比较两个版本，echo: 1 (a>b) / 0 (a==b) / -1 (a<b)
# 先比 short_version（点分数值，逐段比较），相等再比 build（数值，非数值降级为字符串比较）
version_compare() {
    local a_short="$1" a_build="$2" b_short="$3" b_build="$4"
    local -a as bs
    local IFS=.
    read -ra as <<< "$a_short"
    read -ra bs <<< "$b_short"
    local i max=${#as[@]}
    [[ ${#bs[@]} -gt $max ]] && max=${#bs[@]}
    for ((i=0; i<max; i++)); do
        local x="${as[i]:-0}" y="${bs[i]:-0}"
        [[ "$x" =~ ^[0-9]+$ ]] || x=0
        [[ "$y" =~ ^[0-9]+$ ]] || y=0
        if   ((10#$x > 10#$y)); then echo 1;  return; fi
        if   ((10#$x < 10#$y)); then echo -1; return; fi
    done
    if [[ "$a_build" =~ ^[0-9]+$ && "$b_build" =~ ^[0-9]+$ ]]; then
        if   ((10#$a_build > 10#$b_build)); then echo 1
        elif ((10#$a_build < 10#$b_build)); then echo -1
        else echo 0
        fi
        return
    fi
    if   [[ "$a_build" > "$b_build" ]]; then echo 1
    elif [[ "$a_build" < "$b_build" ]]; then echo -1
    else echo 0
    fi
}

# JSON 字符串 escape（最小够用：反斜杠、引号、换行/回车/制表符）
json_str() {
    local s="${1-}"
    s="${s//\\/\\\\}"
    s="${s//\"/\\\"}"
    s="${s//$'\n'/\\n}"
    s="${s//$'\r'/\\r}"
    s="${s//$'\t'/\\t}"
    printf '"%s"' "$s"
}

require_original_wechat() {
    if [[ ! -d "$ORIGINAL_WECHAT" ]]; then
        log_error "未找到原始微信应用: $ORIGINAL_WECHAT"
        log_error "请确保微信已正确安装在应用程序文件夹中"
        return 1
    fi
}

# 拒绝以 root 身份执行写操作。原因：root 创建的副本归 root 所有，
# 后续无 sudo 的覆盖/删除/更新无法处理这些副本
require_unprivileged() {
    if [[ $EUID -eq 0 ]]; then
        log_error "请不要以 root 身份（或 sudo）运行此命令"
        log_error "原因：root 创建的副本会归 root 所有，后续无 sudo 操作会失败"
        log_error "去掉 sudo 重试即可（本工具的写操作设计为完全无需特权）"
        return 1
    fi
}

validate_number() {
    [[ "${1:-}" =~ ^[0-9]$ ]] || { log_error "实例编号必须是 0-9 之间的单个数字（收到: ${1:-空})"; return 1; }
}

# 扫描所有副本实例（严格只匹配 WeChat<0-9>.app，避免误伤其它命名）
scan_instances() {
    local app
    for app in "$TARGET_DIR"/WeChat[0-9].app; do
        [[ -d "$app" ]] || continue
        echo "$app"
    done
}

extract_number_from_app() {
    local name; name=$(basename "$1")
    echo "${name#WeChat}" | sed 's/\.app$//'
}

# 检查 app bundle 是否归当前用户所有
# 返回 0 = 归当前用户; 1 = 归他人（典型是 root）
is_owned_by_current_user() {
    local app="$1"
    [[ -e "$app" ]] || return 1
    local uid; uid=$(stat -f '%u' "$app" 2>/dev/null)
    [[ "$uid" == "$EUID" ]]
}

# 扫描所有归非当前用户所有的副本实例（典型：旧版 sudo 创建的 root-owned 副本）
scan_legacy_owned_instances() {
    local app
    for app in "$TARGET_DIR"/WeChat[0-9].app; do
        [[ -d "$app" ]] || continue
        if ! is_owned_by_current_user "$app"; then
            echo "$app"
        fi
    done
}

# 扫描「改名被自更新回退」的副本：bundle id 与编号不匹配。
# WeChat<N>.app 应为 com.tencent.xinWeChat<N>；自更新器写回完整官方包时会抹掉改名，
# id 退回原版 id（与原版撞车，多开失效）。与版本无关——版本可能与原版相同，
# 因此 update/adopt（靠版本比对）发现不了它。bundle id 读不出时跳过（不误报）。
scan_brand_mismatched_instances() {
    local app
    while IFS= read -r app; do
        [[ -z "$app" ]] && continue
        local n bid
        n=$(extract_number_from_app "$app")
        bid=$(get_app_bundle_id "$app")
        [[ -n "$bid" && "$bid" != "${ORIGINAL_BUNDLE_ID}${n}" ]] && echo "$app"
    done < <(scan_instances)
}

# 决定「改名被回退」副本的修复动作，echo adopt/create：副本比原版新且原版版本可读 → adopt 收编为新原版
#（用 create 会从较旧原版重建导致降级）；否则 → create 重建。hint 与 startup 自动修复共用，保持决策一致。
brand_fix_action() {
    local app="$1" ov="$2" ob="$3"
    local v b
    v=$(get_app_version "$app"); b=$(get_app_build "$app")
    if [[ "$(version_compare "$v" "$b" "$ov" "$ob")" == "1" && -n "$ov" && -n "$ob" ]]; then
        echo adopt
    else
        echo create
    fi
}

# 给「改名被回退」的副本一条正确的修复命令（doctor 用；startup 会直接执行对应命令）。
brand_fix_hint() {
    local app="$1" ov="$2" ob="$3"
    local n; n=$(extract_number_from_app "$app")
    if [[ "$(brand_fix_action "$app" "$ov" "$ob")" == adopt ]]; then
        echo "$SELF adopt ${n}   # 副本较新，收编为原版（create 会降级）"
    else
        echo "$SELF create ${n}"
    fi
}

# 打印单个「改名被回退」副本的报告行：现值/应为 + 版本安全的修复命令。
# doctor 与 startup 共用，避免两处重复维护同一格式。
print_brand_mismatch() {
    local app="$1" ov="$2" ob="$3"
    local n bid
    n=$(extract_number_from_app "$app")
    bid=$(get_app_bundle_id "$app")
    printf "  • %s: 现为 %s，应为 %s%s%s\n" "$(basename "$app")" "$bid" "$GREEN" "${ORIGINAL_BUNDLE_ID}${n}" "$NC" >&2
    printf "    修复：%s\n" "$(brand_fix_hint "$app" "$ov" "$ob")" >&2
}

# 判断 app 是否为「干净的官方 WeChat bundle」——带正规腾讯签名（非 adhoc）、
# 签名校验通过、bundle id 为原版 id。满足时该副本可安全提升为原版。
# 副本自更新后会恢复成这个状态（自更新器写下完整官方包，抹掉我们的改动）。
is_genuine_official_bundle() {
    local app="$1"
    [[ -d "$app" ]] || return 1
    codesign --verify --deep --strict "$app" >/dev/null 2>&1 || return 1
    local team
    team=$(codesign -dv "$app" 2>&1 | sed -n 's/^TeamIdentifier=//p')
    [[ -n "$team" && "$team" != "not set" ]] || return 1
    [[ "$(get_app_bundle_id "$app")" == "$ORIGINAL_BUNDLE_ID" ]] || return 1
    return 0
}

print_migration_hint() {
    local apps_str="$1"
    log_error "请先一次性迁移所有权（这是唯一需要 sudo 的步骤）："
    log_error "  sudo chown -R \"\$(id -un):staff\" $apps_str"
    log_error "完成后重试当前命令"
}

# ============================================================
# 核心操作（无 sudo）
# ============================================================

do_create_instance() {
    local number="$1"
    local target_app="${TARGET_DIR}/WeChat${number}.app"
    local new_bundle_id="${ORIGINAL_BUNDLE_ID}${number}"

    log_step "创建 WeChat${number}.app..."

    if [[ -d "$target_app" ]]; then
        if ! is_owned_by_current_user "$target_app"; then
            log_error "无法覆盖 WeChat${number}.app：该实例归非当前用户所有（典型为旧版 sudo 创建）"
            print_migration_hint "\"$target_app\""
            return 1
        fi
        log_step "覆盖既有实例 WeChat${number}.app..."
        force_quit_instance "$target_app"   # 覆盖前强制退出，避免 rm -rf/重签一个正在运行的副本
        rm -rf "$target_app" || { log_error "删除既有实例失败"; return 1; }
    fi

    if ! cp -R "$ORIGINAL_WECHAT" "$target_app"; then
        log_error "复制微信应用失败"
        return 1
    fi
    log_info "应用复制完成"

    log_step "修改应用标识符..."
    if ! /usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $new_bundle_id" "$target_app/Contents/Info.plist"; then
        log_error "修改 Bundle Identifier 失败"
        rm -rf "$target_app"
        return 1
    fi
    log_info "标识符: $new_bundle_id"

    log_step "重新签名应用..."
    local sign_out
    if ! sign_out=$(codesign --force --deep --sign - "$target_app" 2>&1); then
        log_error "应用签名失败: $sign_out"
        rm -rf "$target_app"
        return 1
    fi
    if ! codesign --verify --deep "$target_app" 2>/dev/null; then
        log_error "签名校验失败"
        rm -rf "$target_app"
        return 1
    fi
    log_info "应用签名完成"
}

do_start_instance() {
    local number="$1"
    local target_app="${TARGET_DIR}/WeChat${number}.app"
    local wechat_binary="$target_app/Contents/MacOS/WeChat"

    if [[ ! -f "$wechat_binary" ]]; then
        log_error "微信可执行文件不存在: $wechat_binary"
        return 1
    fi

    log_step "启动 WeChat${number}..."
    nohup "$wechat_binary" >/dev/null 2>&1 &
    local pid=$!
    if [[ -n "$pid" && $pid -gt 0 ]]; then
        log_info "WeChat${number} 启动成功 (PID: $pid)"
        return 0
    fi
    log_error "WeChat${number} 启动失败"
    return 1
}

# 强制退出指定 app 的所有进程。按「可执行文件路径」匹配（锚定命令行开头 ^ 并转义 .），
# 只命中可执行文件即该副本的进程，不误伤仅在参数里出现该路径的无关进程（如 less/编辑器）；
# 绝不用 bundle id——被自更新回退的副本 id 与原版撞车，按 id 退会误杀正在运行的原版微信。
# 先 SIGTERM 并等待其退出（最多 ~3 秒），仍在则 SIGKILL。（聊天数据在独立容器、WCDB 崩溃安全，
# 强退不致损坏；SIGTERM 不保证 GUI 优雅退出，故不承诺落盘。）
force_quit_instance() {
    local app="$1"
    local pat="^${app//./\\.}/Contents/MacOS/WeChat"
    pgrep -f "$pat" >/dev/null 2>&1 || return 0
    log_step "退出正在运行的 $(basename "$app")..."
    pkill -TERM -f "$pat" 2>/dev/null || true
    local i=0
    while pgrep -f "$pat" >/dev/null 2>&1 && (( i < 15 )); do
        sleep 0.2; i=$((i + 1))
    done
    if pgrep -f "$pat" >/dev/null 2>&1; then
        pkill -KILL -f "$pat" 2>/dev/null || true
        sleep 0.3
    fi
}

do_delete_instance() {
    local number="$1"
    local target_app="${TARGET_DIR}/WeChat${number}.app"
    if [[ ! -d "$target_app" ]]; then
        log_error "实例不存在: WeChat${number}.app"
        return 1
    fi
    if ! is_owned_by_current_user "$target_app"; then
        log_error "无法删除 WeChat${number}.app：该实例归非当前用户所有（典型为旧版 sudo 创建）"
        print_migration_hint "\"$target_app\""
        return 1
    fi
    force_quit_instance "$target_app"
    if rm -rf "$target_app"; then
        log_info "WeChat${number}.app 已删除"
        return 0
    fi
    log_error "删除失败: WeChat${number}.app"
    return 1
}

# ============================================================
# 子命令
# ============================================================

cmd_doctor() {
    local json=false
    [[ "${1:-}" == "--json" ]] && json=true

    local in_admin="false"
    if id -Gn | tr ' ' '\n' | grep -qx admin; then in_admin="true"; fi

    local apps_writable="false"
    [[ -w "$TARGET_DIR" ]] && apps_writable="true"

    local original_present="false"
    [[ -d "$ORIGINAL_WECHAT" ]] && original_present="true"

    local original_owner=""
    local original_version=""
    local original_build=""
    if [[ "$original_present" == "true" ]]; then
        original_owner=$(stat -f '%Su:%Sg' "$ORIGINAL_WECHAT" 2>/dev/null || true)
        original_version=$(get_app_version "$ORIGINAL_WECHAT")
        original_build=$(get_app_build "$ORIGINAL_WECHAT")
    fi

    # 是否需要 sudo：只有当 /Applications 不可写时才必须 sudo
    local sudo_required="false"
    [[ "$apps_writable" != "true" ]] && sudo_required="true"

    local can_run="true"
    [[ "$original_present" == "true" && "$apps_writable" == "true" ]] || can_run="false"

    # 扫描 legacy（root-owned）副本：环境总体可用，但这些具体副本无法直接覆盖/删除/更新
    local legacy_apps=()
    if [[ "$original_present" == "true" ]]; then
        local app
        while IFS= read -r app; do
            [[ -z "$app" ]] && continue
            legacy_apps+=("$app")
        done < <(scan_legacy_owned_instances)
    fi
    local legacy_count=${#legacy_apps[@]}
    local legacy_required="false"
    [[ $legacy_count -gt 0 ]] && legacy_required="true"

    # 扫描 bundle id 与编号不匹配的副本（自更新回退了改名；与版本无关）
    local brand_apps=()
    if [[ "$original_present" == "true" ]]; then
        local app
        while IFS= read -r app; do
            [[ -z "$app" ]] && continue
            brand_apps+=("$app")
        done < <(scan_brand_mismatched_instances)
    fi
    local brand_count=${#brand_apps[@]}
    local brand_required="false"
    [[ $brand_count -gt 0 ]] && brand_required="true"

    if [[ "$json" == "true" ]]; then
        local legacy_json="["
        local migration_hint=""
        if [[ $legacy_count -gt 0 ]]; then
            local lf=true
            local lapp
            for lapp in "${legacy_apps[@]}"; do
                $lf || legacy_json+=","
                lf=false
                legacy_json+=$(json_str "$lapp")
            done
            migration_hint="sudo chown -R \"\$(id -un):staff\""
            for lapp in "${legacy_apps[@]}"; do
                migration_hint+=" \"$lapp\""
            done
        fi
        legacy_json+="]"
        local brand_json="["
        if [[ $brand_count -gt 0 ]]; then
            local bf=true bapp
            for bapp in "${brand_apps[@]}"; do
                $bf || brand_json+=","
                bf=false
                brand_json+=$(json_str "$bapp")
            done
        fi
        brand_json+="]"
        printf '{"version":%s,"in_admin_group":%s,"applications_writable":%s,"original_wechat_present":%s,"original_wechat_owner":%s,"original_short_version":%s,"original_build_version":%s,"sudo_required":%s,"can_run_unprivileged":%s,"target_dir":%s,"legacy_owned_instances":%s,"legacy_migration_required":%s,"migration_hint":%s,"brand_mismatched_instances":%s,"brand_mismatch_required":%s}\n' \
            "$(json_str "$VERSION")" \
            "$in_admin" \
            "$apps_writable" \
            "$original_present" \
            "$(json_str "$original_owner")" \
            "$(json_str "$original_version")" \
            "$(json_str "$original_build")" \
            "$sudo_required" \
            "$can_run" \
            "$(json_str "$TARGET_DIR")" \
            "$legacy_json" \
            "$legacy_required" \
            "$(json_str "$migration_hint")" \
            "$brand_json" \
            "$brand_required"
        return 0
    fi

    echo "double-wechat doctor v${VERSION}"
    echo "  当前用户在 admin 组:        $in_admin"
    echo "  /Applications 可写:         $apps_writable"
    echo "  原始 WeChat.app 存在:       $original_present"
    [[ -n "$original_owner" ]] && echo "  原始 WeChat.app 所有者:     $original_owner"
    if [[ "$original_present" == "true" ]]; then
        echo "  原始 WeChat 版本:           $(format_version_info "$original_version" "$original_build")"
    fi
    echo "  目标目录:                   $TARGET_DIR"
    echo "  需要 sudo:                  $sudo_required"
    echo "  可以无特权运行:             $can_run"
    if [[ $legacy_count -gt 0 ]]; then
        echo
        log_warn "检测到 ${legacy_count} 个旧版 sudo 创建的实例（root 所有），无法直接覆盖/更新/删除："
        local lapp
        for lapp in "${legacy_apps[@]}"; do
            echo "  • $(basename "$lapp")" >&2
        done
        log_warn "一次性迁移命令（这是唯一需要 sudo 的步骤）："
        local cmd="  sudo chown -R \"\$(id -un):staff\""
        for lapp in "${legacy_apps[@]}"; do
            cmd+=" \"$lapp\""
        done
        echo "$cmd" >&2
    fi
    if [[ $brand_count -gt 0 ]]; then
        echo
        log_warn "检测到 ${brand_count} 个实例的 Bundle ID 被自更新回退（与编号不符，多开会失效）："
        local bapp
        for bapp in "${brand_apps[@]}"; do
            print_brand_mismatch "$bapp" "$original_version" "$original_build"
        done
        log_warn "修复后登录态与聊天记录保留（存于独立沙盒容器，不受影响）"
    fi
    if [[ "$can_run" != "true" ]]; then
        log_warn "环境不满足，请按上方信息排查"
        return 1
    fi
}

cmd_list() {
    local json=false
    [[ "${1:-}" == "--json" ]] && json=true

    require_original_wechat || return 1

    local original_version original_build
    original_version=$(get_app_version "$ORIGINAL_WECHAT")
    original_build=$(get_app_build "$ORIGINAL_WECHAT")

    if [[ "$json" == "true" ]]; then
        local first=true
        printf '{"original":{"path":%s,"short_version":%s,"build_version":%s},"instances":[' \
            "$(json_str "$ORIGINAL_WECHAT")" \
            "$(json_str "$original_version")" \
            "$(json_str "$original_build")"
        local app
        while IFS= read -r app; do
            [[ -z "$app" ]] && continue
            local number inst_v inst_b bid needs
            number=$(extract_number_from_app "$app")
            inst_v=$(get_app_version "$app")
            inst_b=$(get_app_build "$app")
            bid=$(get_app_bundle_id "$app")
            needs="false"
            if [[ -n "$original_version" || -n "$original_build" ]]; then
                if [[ "$inst_v" != "$original_version" || "$inst_b" != "$original_build" ]]; then
                    needs="true"
                fi
            fi
            $first || printf ','
            first=false
            printf '{"number":%s,"path":%s,"bundle_id":%s,"short_version":%s,"build_version":%s,"needs_update":%s}' \
                "$(json_str "$number")" \
                "$(json_str "$app")" \
                "$(json_str "$bid")" \
                "$(json_str "$inst_v")" \
                "$(json_str "$inst_b")" \
                "$needs"
        done < <(scan_instances)
        printf ']}\n'
        return 0
    fi

    local original_info; original_info=$(format_version_info "$original_version" "$original_build")
    echo
    printf '%s已安装的微信实例:%s\n' "$BLUE" "$NC"
    if [[ -d "$ORIGINAL_WECHAT" ]]; then
        printf '• WeChat.app (原始)  版本: %s%s%s\n' "$GREEN" "$original_info" "$NC"
    fi
    local count=0 needs_count=0
    local app
    while IFS= read -r app; do
        [[ -z "$app" ]] && continue
        local app_name inst_v inst_b inst_info status
        app_name=$(basename "$app")
        inst_v=$(get_app_version "$app")
        inst_b=$(get_app_build "$app")
        inst_info=$(format_version_info "$inst_v" "$inst_b")
        status=""
        if [[ -n "$original_version" && -n "$inst_v" ]]; then
            if [[ "$inst_v" != "$original_version" || "$inst_b" != "$original_build" ]]; then
                status=$(printf '  %s[需要更新: %s → %s]%s' "$RED" "$inst_info" "$original_info" "$NC")
                ((needs_count++))
            fi
        fi
        printf '• %s  版本: %s%s\n' "$app_name" "$inst_info" "$status"
        ((count++))
    done < <(scan_instances)
    if [[ $count -eq 0 ]]; then
        echo "• 未找到其他微信实例"
    else
        echo
        echo "共 ${count} 个实例"
        if [[ $needs_count -gt 0 ]]; then
            printf "%s提示: 有 %d 个实例需要更新，可运行 '%s update --all'%s\n" "$YELLOW" "$needs_count" "$SELF" "$NC"
        fi
    fi
    echo
}

cmd_create() {
    require_unprivileged || return 1
    local number="" no_launch=false yes=false
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --no-launch) no_launch=true; shift;;
            --yes|-y)    yes=true; shift;;
            -*)          log_error "未知参数: $1"; return 2;;
            *) [[ -z "$number" ]] && number="$1" || { log_error "多余参数: $1"; return 2; }; shift;;
        esac
    done
    [[ -z "$number" ]] && { log_error "用法: $SELF create <0-9> [--no-launch] [--yes]"; return 2; }
    validate_number "$number" || return 2
    require_original_wechat || return 1

    local target_app="${TARGET_DIR}/WeChat${number}.app"
    if [[ -d "$target_app" && "$yes" != "true" ]]; then
        if [[ -t 0 ]]; then
            read -p "已存在 WeChat${number}.app，是否覆盖？(y/n，默认: y): " confirm
            [[ "$confirm" =~ ^[Nn]$ ]] && { log_info "操作已取消"; return 0; }
        else
            log_error "已存在 WeChat${number}.app；非交互模式下请加 --yes 才会覆盖"
            return 1
        fi
    fi

    do_create_instance "$number" || return 1
    if [[ "$no_launch" != "true" ]]; then
        do_start_instance "$number" || return 1
    fi
    log_info "✓ WeChat${number} 创建完成"
}

cmd_start() {
    require_unprivileged || return 1
    local number="${1:-}"
    [[ -z "$number" ]] && { log_error "用法: $SELF start <0-9>"; return 2; }
    validate_number "$number" || return 2
    do_start_instance "$number"
}

cmd_delete() {
    require_unprivileged || return 1
    local number="" yes=false
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --yes|-y) yes=true; shift;;
            -*)       log_error "未知参数: $1"; return 2;;
            *) [[ -z "$number" ]] && number="$1" || { log_error "多余参数: $1"; return 2; }; shift;;
        esac
    done
    [[ -z "$number" ]] && { log_error "用法: $SELF delete <0-9> [--yes]"; return 2; }
    validate_number "$number" || return 2

    local target_app="${TARGET_DIR}/WeChat${number}.app"
    if [[ ! -d "$target_app" ]]; then
        log_error "实例不存在: WeChat${number}.app"
        return 1
    fi

    if [[ "$yes" != "true" ]]; then
        if [[ -t 0 ]]; then
            read -p "确定要删除 WeChat${number}.app 吗？(y/n，默认: n): " confirm
            [[ "$confirm" =~ ^[Yy]$ ]] || { log_info "操作已取消"; return 0; }
        else
            log_error "非交互模式下请加 --yes 才会删除"
            return 1
        fi
    fi

    do_delete_instance "$number"
}

cmd_update() {
    require_unprivileged || return 1
    local all=false yes=false
    local nums=()
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --all)    all=true; shift;;
            --yes|-y) yes=true; shift;;
            -*)       log_error "未知参数: $1"; return 2;;
            *)        nums+=("$1"); shift;;
        esac
    done

    require_original_wechat || return 1

    local original_version original_build
    original_version=$(get_app_version "$ORIGINAL_WECHAT")
    original_build=$(get_app_build "$ORIGINAL_WECHAT")
    [[ -z "$original_version" && -z "$original_build" ]] && { log_error "无法读取原始 WeChat 版本"; return 1; }

    local targets=()
    if [[ "$all" == "true" ]]; then
        local app
        while IFS= read -r app; do
            [[ -z "$app" ]] && continue
            local v b
            v=$(get_app_version "$app")
            b=$(get_app_build "$app")
            if [[ "$v" != "$original_version" || "$b" != "$original_build" ]]; then
                targets+=("$app")
            fi
        done < <(scan_instances)
    else
        [[ ${#nums[@]} -eq 0 ]] && { log_error "用法: $SELF update [--all | <n>...] [--yes]"; return 2; }
        local n
        for n in "${nums[@]}"; do
            validate_number "$n" || return 2
            local app="${TARGET_DIR}/WeChat${n}.app"
            [[ -d "$app" ]] || { log_warn "跳过不存在的实例: WeChat${n}.app"; continue; }
            targets+=("$app")
        done
    fi

    if [[ ${#targets[@]} -eq 0 ]]; then
        log_info "没有需要更新的实例"
        return 0
    fi

    local original_info; original_info=$(format_version_info "$original_version" "$original_build")
    log_info "将要更新 ${#targets[@]} 个实例 → ${original_info}"
    local app
    for app in "${targets[@]}"; do
        local n inst_v inst_b
        n=$(extract_number_from_app "$app")
        inst_v=$(get_app_version "$app")
        inst_b=$(get_app_build "$app")
        printf "  • WeChat%s.app (%s)\n" "$n" "$(format_version_info "$inst_v" "$inst_b")" >&2
    done

    if [[ "$yes" != "true" ]]; then
        if [[ -t 0 ]]; then
            read -p "确认开始更新？(y/n，默认: y): " confirm
            [[ "$confirm" =~ ^[Nn]$ ]] && { log_info "已取消"; return 0; }
        else
            log_error "非交互模式下请加 --yes 才会执行更新"
            return 1
        fi
    fi

    # 批量检测：如果有 legacy root-owned 实例，给一次性迁移命令而不是逐个失败
    local legacy_targets=()
    local app
    for app in "${targets[@]}"; do
        if ! is_owned_by_current_user "$app"; then
            legacy_targets+=("$app")
        fi
    done
    if [[ ${#legacy_targets[@]} -gt 0 ]]; then
        log_error "下列 ${#legacy_targets[@]} 个实例归非当前用户所有（典型为旧版 sudo 创建），无法直接更新："
        for app in "${legacy_targets[@]}"; do
            log_error "  • $(basename "$app")"
        done
        local quoted_paths=""
        for app in "${legacy_targets[@]}"; do
            quoted_paths+="\"$app\" "
        done
        print_migration_hint "${quoted_paths% }"
        return 1
    fi

    local updated=0 failed=0
    for app in "${targets[@]}"; do
        local n; n=$(extract_number_from_app "$app")
        if do_create_instance "$n"; then
            ((updated++))
        else
            ((failed++))
        fi
    done

    log_info "更新汇总：成功 ${updated} 失败 ${failed}"
    [[ $failed -gt 0 ]] && return 1 || return 0
}

# adopt：当某个副本因自更新而版本高于原版时，把它「收编」为新的原版，
# 再从新原版重新打包该副本。全程不降级、不动用户数据容器。
cmd_adopt() {
    require_unprivileged || return 1
    local number="" yes=false
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --yes|-y) yes=true; shift;;
            -*)       log_error "未知参数: $1"; return 2;;
            *) [[ -z "$number" ]] && number="$1" || { log_error "多余参数: $1"; return 2; }; shift;;
        esac
    done
    [[ -n "$number" ]] && { validate_number "$number" || return 2; }
    require_original_wechat || return 1

    local original_version original_build
    original_version=$(get_app_version "$ORIGINAL_WECHAT")
    original_build=$(get_app_build "$ORIGINAL_WECHAT")
    # 原版版本读不出则基线无法确定；否则 version_compare 拿空串当基线会误判任意实例更新
    [[ -z "$original_version" && -z "$original_build" ]] && { log_error "无法读取原始 WeChat 版本"; return 1; }

    # 确定候选副本：显式指定，或自动挑选「版本最高」的副本
    local candidate=""
    if [[ -n "$number" ]]; then
        candidate="${TARGET_DIR}/WeChat${number}.app"
        [[ -d "$candidate" ]] || { log_error "实例不存在: WeChat${number}.app"; return 1; }
    else
        local best="" best_v="$original_version" best_b="$original_build"
        local app
        while IFS= read -r app; do
            [[ -z "$app" ]] && continue
            local v b
            v=$(get_app_version "$app")
            b=$(get_app_build "$app")
            if [[ "$(version_compare "$v" "$b" "$best_v" "$best_b")" == "1" ]]; then
                best="$app"; best_v="$v"; best_b="$b"
            fi
        done < <(scan_instances)
        if [[ -z "$best" ]]; then
            log_info "没有副本比原版更新，无需 adopt"
            return 0
        fi
        candidate="$best"
    fi

    local cand_name cand_n cand_v cand_b
    cand_name=$(basename "$candidate")
    cand_n=$(extract_number_from_app "$candidate")
    cand_v=$(get_app_version "$candidate")
    cand_b=$(get_app_build "$candidate")

    # 校验 1：候选必须确实比原版新
    if [[ "$(version_compare "$cand_v" "$cand_b" "$original_version" "$original_build")" != "1" ]]; then
        log_error "${cand_name}（$(format_version_info "$cand_v" "$cand_b")）不比原版（$(format_version_info "$original_version" "$original_build")）新，无需 adopt"
        log_error "若只是想把它同步到原版，请用: $SELF update ${cand_n}"
        return 1
    fi

    # 校验 2：候选必须是干净的官方 bundle，否则提升为原版会让原版失去正规签名
    if ! is_genuine_official_bundle "$candidate"; then
        log_error "${cand_name} 不是干净的官方 WeChat bundle（缺正规腾讯签名 / 签名校验未通过 / bundle id 非原版）"
        log_error "拒绝将其提升为原版——这会让原版失去正规签名"
        return 1
    fi

    # 校验 3：原版与候选均需归当前用户所有
    if ! is_owned_by_current_user "$ORIGINAL_WECHAT"; then
        log_error "原始 WeChat.app 归非当前用户所有，无法覆盖"
        print_migration_hint "\"$ORIGINAL_WECHAT\""
        return 1
    fi
    if ! is_owned_by_current_user "$candidate"; then
        log_error "${cand_name} 归非当前用户所有（典型为旧版 sudo 创建）"
        print_migration_hint "\"$candidate\""
        return 1
    fi

    log_info "将把 ${cand_name} 收编为新的原始 WeChat.app"
    printf '  原始 WeChat.app : %s → %s\n' "$(format_version_info "$original_version" "$original_build")" "$(format_version_info "$cand_v" "$cand_b")" >&2
    printf '  随后重新打包    : %s（恢复多开标识符 + 重签名）\n' "$cand_name" >&2

    if [[ "$yes" != "true" ]]; then
        if [[ -t 0 ]]; then
            read -p "确认执行？(y/n，默认: y): " confirm
            [[ "$confirm" =~ ^[Nn]$ ]] && { log_info "已取消"; return 0; }
        else
            log_error "非交互模式下请加 --yes 才会执行"
            return 1
        fi
    fi

    # 退出原版与候选实例（按可执行文件路径精确退出；二者 bundle id 可能相同，故绝不按 id 退）
    force_quit_instance "$ORIGINAL_WECHAT"
    force_quit_instance "$candidate"

    # 第一步：候选 → 原版。先拷到临时目录再 mv，尽量缩小「原版缺失」窗口。
    log_step "用 ${cand_name} 覆盖原始 WeChat.app..."
    local tmp="${ORIGINAL_WECHAT}.adopt-tmp"
    rm -rf "$tmp"
    if ! cp -R "$candidate" "$tmp"; then
        log_error "复制候选实例失败"
        rm -rf "$tmp"
        return 1
    fi
    if ! rm -rf "$ORIGINAL_WECHAT"; then
        log_error "删除旧的原始 WeChat.app 失败"
        rm -rf "$tmp"
        return 1
    fi
    if ! mv "$tmp" "$ORIGINAL_WECHAT"; then
        log_error "致命：替换原始 WeChat.app 失败，原版可能已缺失！临时副本仍在: $tmp"
        return 1
    fi
    log_info "原始 WeChat.app 已更新至 $(format_version_info "$cand_v" "$cand_b")"

    # 第二步：从新原版重新打包候选副本（恢复 bundle id + adhoc 重签名）
    log_step "重新打包 ${cand_name}..."
    if ! do_create_instance "$cand_n"; then
        log_error "重新打包 ${cand_name} 失败"
        log_error "原版已更新成功，但 ${cand_name} 未重建；请运行: $SELF create ${cand_n}"
        return 1
    fi

    log_info "✓ adopt 完成：原版与 ${cand_name} 均为 $(format_version_info "$cand_v" "$cand_b")"

    # 提示其它落后副本
    local stale=()
    local app
    while IFS= read -r app; do
        [[ -z "$app" ]] && continue
        [[ "$app" == "$candidate" ]] && continue
        local v b
        v=$(get_app_version "$app")
        b=$(get_app_build "$app")
        if [[ "$v" != "$cand_v" || "$b" != "$cand_b" ]]; then
            stale+=("$app")
        fi
    done < <(scan_instances)
    if [[ ${#stale[@]} -gt 0 ]]; then
        log_warn "另有 ${#stale[@]} 个副本版本落后于新原版，建议运行: $SELF update --all"
    fi
}

# echo "true" 若存在副本版本高于原版，否则 "false"。供 cmd_sync 判定是否需要 adopt。
has_newer_instance() {
    local ov ob
    ov=$(get_app_version "$ORIGINAL_WECHAT")
    ob=$(get_app_build "$ORIGINAL_WECHAT")
    local app v b
    while IFS= read -r app; do
        [[ -z "$app" ]] && continue
        v=$(get_app_version "$app")
        b=$(get_app_build "$app")
        if [[ "$(version_compare "$v" "$b" "$ov" "$ob")" == "1" ]]; then
            echo "true"; return 0
        fi
    done < <(scan_instances)
    echo "false"
}

# 一键同步：把所有实例对齐到最高版本，不降级。
# 若有副本因自更新而高于原版 → 先 adopt（提升为原版并重打包）；
# 随后把落后副本 update 到（可能已被提升的）原版。
# 已知限制：若多个副本自更新到完全相同的最高版本，只有其一会被 adopt，
# 其余同版本副本的多开身份不会被修复（update 跳过同版本副本）。
# 供交互菜单「5」与根命令启动自检复用。
cmd_sync() {
    require_unprivileged || return 1
    require_original_wechat || return 1
    local yes=false
    [[ "${1:-}" =~ ^(--yes|-y)$ ]] && yes=true

    # 存在比原版更新的副本（自更新所致）→ 需先 adopt，避免被 update 降级
    if [[ "$(has_newer_instance)" == "true" ]]; then
        if $yes; then cmd_adopt --yes || return 1
        else          cmd_adopt       || return 1
        fi
        # adopt 后仍有更新副本 → adopt 未执行（交互模式下用户取消了确认）。
        # cmd_adopt 取消时返回 0，无法靠退出码区分；此处复查实际状态。
        # 若继续 update 会把较新副本降级，违背 adopt 初衷，故中止同步。
        if [[ "$(has_newer_instance)" == "true" ]]; then
            log_info "adopt 未执行，已中止同步（继续会降级较新副本）"
            return 0
        fi
    fi

    if $yes; then cmd_update --all --yes
    else          cmd_update --all
    fi
}

cmd_help() {
    cat <<EOF
double-wechat v${VERSION} — macOS 微信多开管理工具

用法:
  ${SELF}                                     # 交互菜单（人类入口）
  ${SELF} list [--json]                       # 列出所有实例
  ${SELF} create <0-9> [--no-launch] [--yes] # 创建（默认创建后启动）
  ${SELF} start <0-9>                         # 启动指定实例
  ${SELF} delete <0-9> [--yes]                # 删除指定实例
  ${SELF} update [--all | <n>...] [--yes]     # 同步副本到原始版本
  ${SELF} adopt [<0-9>] [--yes]               # 收编自更新的较新副本为原版
  ${SELF} doctor [--json]                     # 自检环境
  ${SELF} help                                # 显示本帮助
  ${SELF} version                             # 显示版本

所有写操作均不需要 sudo（前提：当前用户在 admin 组且 /Applications 可写）。
若需要确认环境是否满足，运行: ${SELF} doctor
EOF
}

# ============================================================
# 交互菜单（人类入口）
# ============================================================

show_menu() {
    printf '\n%s=== 微信多开管理工具 ===%s\n' "$BLUE" "$NC"
    echo "1. 创建新的微信实例"
    echo "2. 启动现有微信实例"
    echo "3. 列出所有微信实例"
    echo "4. 删除微信实例"
    echo "5. 一键同步所有实例到最新版本"
    echo "0. 退出"
    printf '%s=======================%s\n\n' "$BLUE" "$NC"
}

interactive_start() {
    printf '\n%s可启动的微信实例:%s\n' "$BLUE" "$NC"
    local instances=()
    local idx=1
    local app
    for app in "$TARGET_DIR"/WeChat.app "$TARGET_DIR"/WeChat[0-9].app; do
        if [[ -d "$app" ]]; then
            echo "$idx. $(basename "$app")"
            instances+=("$app")
            ((idx++))
        fi
    done
    [[ ${#instances[@]} -eq 0 ]] && { log_warn "未找到微信实例"; return; }
    read -p "请选择编号 (1-${#instances[@]}): " choice
    if [[ "$choice" =~ ^[0-9]+$ && $choice -ge 1 && $choice -le ${#instances[@]} ]]; then
        local sel="${instances[$((choice-1))]}"
        local bin="$sel/Contents/MacOS/WeChat"
        [[ -f "$bin" ]] || { log_error "找不到可执行文件: $bin"; return; }
        log_step "启动 $(basename "$sel")..."
        nohup "$bin" >/dev/null 2>&1 &
        log_info "$(basename "$sel") 启动成功 (PID: $!)"
    else
        log_error "无效的选择"
    fi
}

interactive_delete() {
    printf '\n%s可删除的微信实例:%s\n' "$BLUE" "$NC"
    local instances=()
    local idx=1
    local app
    while IFS= read -r app; do
        [[ -z "$app" ]] && continue
        echo "$idx. $(basename "$app")"
        instances+=("$app")
        ((idx++))
    done < <(scan_instances)
    [[ ${#instances[@]} -eq 0 ]] && { log_warn "没有可删除的实例"; return; }
    read -p "请选择要删除的实例编号 (1-${#instances[@]}): " choice
    if [[ "$choice" =~ ^[0-9]+$ && $choice -ge 1 && $choice -le ${#instances[@]} ]]; then
        local sel="${instances[$((choice-1))]}"
        local n; n=$(extract_number_from_app "$sel")
        cmd_delete "$n"
    else
        log_error "无效的选择"
    fi
}

startup_version_check() {
    [[ -d "$ORIGINAL_WECHAT" ]] || return 0
    local ov ob
    ov=$(get_app_version "$ORIGINAL_WECHAT")
    ob=$(get_app_build "$ORIGINAL_WECHAT")
    [[ -z "$ov" && -z "$ob" ]] && return 0

    local mismatched=()
    local app
    while IFS= read -r app; do
        [[ -z "$app" ]] && continue
        local v b
        v=$(get_app_version "$app")
        b=$(get_app_build "$app")
        if [[ "$v" != "$ov" || "$b" != "$ob" ]]; then
            mismatched+=("$app")
        fi
    done < <(scan_instances)

    [[ ${#mismatched[@]} -eq 0 ]] && return 0

    local oi; oi=$(format_version_info "$ov" "$ob")
    printf '\n%s检测到 %d 个实例版本与原始微信不一致%s\n' "$YELLOW" "${#mismatched[@]}" "$NC" >&2
    printf '原始微信版本: %s%s%s\n' "$GREEN" "$oi" "$NC" >&2
    for app in "${mismatched[@]}"; do
        local v b cmp tag
        v=$(get_app_version "$app")
        b=$(get_app_build "$app")
        cmp=$(version_compare "$v" "$b" "$ov" "$ob")
        if   [[ "$cmp" == "1" ]];  then tag="较新，将收编为原版"
        elif [[ "$cmp" == "-1" ]]; then tag="较旧，将更新"
        else                            tag="版本不同，将更新"
        fi
        printf "  • %s (%s) — %s\n" "$(basename "$app")" "$(format_version_info "$v" "$b")" "$tag" >&2
    done
    echo >&2
    read -p "是否一键同步到最新版本？(y/n，默认: y): " confirm || confirm=n
    [[ "$confirm" =~ ^[Nn]$ ]] && { log_info "已跳过同步"; return 0; }
    cmd_sync --yes
}

# 启动时立即检测 bundle id 被自更新回退的副本（版本检查漏掉的那类，尤其版本与原版相同时），
# 确认后自动修复：按版本关系在 adopt（副本较新，收编为原版）/create（从原版重建）间选择，避免降级。
# 两者都会先精确退出相关实例（按可执行文件路径，绝不按 id，避免误杀正在运行的原版微信）再重建。
startup_brand_check() {
    [[ -d "$ORIGINAL_WECHAT" ]] || return 0
    local ov ob
    ov=$(get_app_version "$ORIGINAL_WECHAT")
    ob=$(get_app_build "$ORIGINAL_WECHAT")
    # 原版版本读不出则无法可靠判断新旧（与 startup_version_check / cmd_adopt / cmd_update 一致），跳过
    [[ -z "$ov" && -z "$ob" ]] && return 0
    local mism=()
    local app
    while IFS= read -r app; do
        [[ -z "$app" ]] && continue
        mism+=("$app")
    done < <(scan_brand_mismatched_instances)
    [[ ${#mism[@]} -eq 0 ]] && return 0

    printf '\n%s检测到 %d 个实例的 Bundle ID 被回退，多开会失效%s\n' "$YELLOW" "${#mism[@]}" "$NC" >&2
    for app in "${mism[@]}"; do
        local n bid tag
        n=$(extract_number_from_app "$app")
        bid=$(get_app_bundle_id "$app")
        if [[ "$(brand_fix_action "$app" "$ov" "$ob")" == adopt ]]; then
            tag="收编为原版"
        else
            tag="从原版重建"
        fi
        printf "  • %s：%s → %s%s%s（%s）\n" "$(basename "$app")" "$bid" "$GREEN" "${ORIGINAL_BUNDLE_ID}${n}" "$NC" "$tag" >&2
    done
    printf '%s修复会退出相关微信后重建，登录态与聊天记录保留%s\n' "$YELLOW" "$NC" >&2
    echo >&2
    read -p "是否自动修复？(y/n，默认: y): " confirm || confirm=n
    [[ "$confirm" =~ ^[Nn]$ ]] && { log_info "已跳过修复"; return 0; }

    # 每轮重读原版版本：前一个 adopt 会提升原版，用陈旧基线会把同版本副本误判为可 adopt 而被 cmd_adopt 拒绝；
    # 重读后同版本副本正确落到 create（不降级）。adopt 被拒（副本非干净官方 bundle / 归属他人）时退回 create。
    local failed=()
    for app in "${mism[@]}"; do
        local n; n=$(extract_number_from_app "$app")
        ov=$(get_app_version "$ORIGINAL_WECHAT")
        ob=$(get_app_build "$ORIGINAL_WECHAT")
        if [[ "$(brand_fix_action "$app" "$ov" "$ob")" == adopt ]]; then
            cmd_adopt "$n" --yes || cmd_create "$n" --yes --no-launch || failed+=("$n")
        else
            cmd_create "$n" --yes --no-launch || failed+=("$n")
        fi
    done
    [[ ${#failed[@]} -gt 0 ]] && log_warn "以下实例修复失败，仍需手动处理: ${failed[*]}"
    return 0
}

interactive_main() {
    require_unprivileged || exit 1
    require_original_wechat || exit 1
    startup_version_check
    startup_brand_check

    while true; do
        show_menu
        read -p "请选择操作 (1-5, 0退出): " choice || { echo >&2; log_info "输入流结束，退出程序"; exit 0; }
        choice=$(echo "$choice" | tr -d '\n\r' | xargs)
        case "$choice" in
            1)
                printf '\n%s=== 创建新的微信实例 ===%s\n' "$BLUE" "$NC"
                read -p "请输入实例编号 (0-9): " number
                number=$(echo "$number" | tr -d '\n\r' | xargs)
                cmd_create "$number"
                ;;
            2) interactive_start;;
            3) cmd_list;;
            4) interactive_delete;;
            5) cmd_sync;;
            0) log_info "退出程序"; exit 0;;
            *) [[ -n "$choice" ]] && log_error "无效的选择，请输入 1-5 或 0";;
        esac
        echo
        read -p "按回车键继续..." || { echo >&2; log_info "输入流结束，退出程序"; exit 0; }
    done
}

# ============================================================
# 入口
# ============================================================
main() {
    local cmd="${1:-}"
    case "$cmd" in
        ""|menu)               interactive_main;;
        list)                  shift; cmd_list   "$@";;
        create)                shift; cmd_create "$@";;
        start)                 shift; cmd_start  "$@";;
        delete|rm)             shift; cmd_delete "$@";;
        update)                shift; cmd_update "$@";;
        adopt)                 shift; cmd_adopt  "$@";;
        doctor)                shift; cmd_doctor "$@";;
        help|-h|--help)        cmd_help;;
        version|-v|--version)  echo "double-wechat v${VERSION}";;
        *)                     log_error "未知命令: $cmd"; cmd_help; exit 2;;
    esac
}

# 被 source 时不执行（便于对内部函数做单元测试）；用 if 而非 && 以免 source 时留下 $?=1
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi

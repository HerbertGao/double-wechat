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

readonly VERSION="2.0.0"

# ----- 配置 -----
readonly ORIGINAL_WECHAT="/Applications/WeChat.app"
readonly ORIGINAL_BUNDLE_ID="com.tencent.xinWeChat"
readonly TARGET_DIR="/Applications"

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

try_quit_instance() {
    local app="$1"
    local bid; bid=$(get_app_bundle_id "$app")
    if [[ -n "$bid" ]]; then
        osascript -e "tell application id \"${bid}\" to quit" >/dev/null 2>&1 || true
        sleep 1
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
    try_quit_instance "$target_app"
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

    if [[ "$json" == "true" ]]; then
        local legacy_json="["
        local lf=true
        local lapp
        for lapp in "${legacy_apps[@]}"; do
            $lf || legacy_json+=","
            lf=false
            legacy_json+=$(json_str "$lapp")
        done
        legacy_json+="]"
        local migration_hint=""
        if [[ $legacy_count -gt 0 ]]; then
            migration_hint="sudo chown -R \"\$(id -un):staff\""
            for lapp in "${legacy_apps[@]}"; do
                migration_hint+=" \"$lapp\""
            done
        fi
        printf '{"version":%s,"in_admin_group":%s,"applications_writable":%s,"original_wechat_present":%s,"original_wechat_owner":%s,"original_short_version":%s,"original_build_version":%s,"sudo_required":%s,"can_run_unprivileged":%s,"target_dir":%s,"legacy_owned_instances":%s,"legacy_migration_required":%s,"migration_hint":%s}\n' \
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
            "$(json_str "$migration_hint")"
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
            printf "%s提示: 有 %d 个实例需要更新，可运行 'double-wechat update --all'%s\n" "$YELLOW" "$needs_count" "$NC"
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
    [[ -z "$number" ]] && { log_error "用法: double-wechat create <0-9> [--no-launch] [--yes]"; return 2; }
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
    [[ -z "$number" ]] && { log_error "用法: double-wechat start <0-9>"; return 2; }
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
    [[ -z "$number" ]] && { log_error "用法: double-wechat delete <0-9> [--yes]"; return 2; }
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
        [[ ${#nums[@]} -eq 0 ]] && { log_error "用法: double-wechat update [--all | <n>...] [--yes]"; return 2; }
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
        try_quit_instance "$app"
        if do_create_instance "$n"; then
            ((updated++))
        else
            ((failed++))
        fi
    done

    log_info "更新汇总：成功 ${updated} 失败 ${failed}"
    [[ $failed -gt 0 ]] && return 1 || return 0
}

cmd_help() {
    cat <<EOF
double-wechat v${VERSION} — macOS 微信多开管理工具

用法:
  double-wechat                                     # 交互菜单（人类入口）
  double-wechat list [--json]                       # 列出所有实例
  double-wechat create <0-9> [--no-launch] [--yes] # 创建（默认创建后启动）
  double-wechat start <0-9>                         # 启动指定实例
  double-wechat delete <0-9> [--yes]                # 删除指定实例
  double-wechat update [--all | <n>...] [--yes]     # 同步副本到原始版本
  double-wechat doctor [--json]                     # 自检环境
  double-wechat help                                # 显示本帮助
  double-wechat version                             # 显示版本

所有写操作均不需要 sudo（前提：当前用户在 admin 组且 /Applications 可写）。
若需要确认环境是否满足，运行: double-wechat doctor
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
    echo "5. 一键更新所有过期实例"
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

    local needs=()
    local app
    while IFS= read -r app; do
        [[ -z "$app" ]] && continue
        local v b
        v=$(get_app_version "$app")
        b=$(get_app_build "$app")
        if [[ "$v" != "$ov" || "$b" != "$ob" ]]; then
            needs+=("$app")
        fi
    done < <(scan_instances)

    [[ ${#needs[@]} -eq 0 ]] && return 0

    local oi; oi=$(format_version_info "$ov" "$ob")
    printf '\n%s检测到 %d 个实例版本与原始微信不一致%s\n' "$YELLOW" "${#needs[@]}" "$NC" >&2
    printf '原始微信版本: %s%s%s\n' "$GREEN" "$oi" "$NC" >&2
    for app in "${needs[@]}"; do
        local v b
        v=$(get_app_version "$app")
        b=$(get_app_build "$app")
        printf "  • %s (%s)\n" "$(basename "$app")" "$(format_version_info "$v" "$b")" >&2
    done
    echo >&2
    read -p "是否一键更新这些实例？(y/n，默认: y): " confirm
    [[ "$confirm" =~ ^[Nn]$ ]] && { log_info "已跳过更新"; return 0; }
    cmd_update --all --yes
}

interactive_main() {
    require_unprivileged || exit 1
    require_original_wechat || exit 1
    startup_version_check

    while true; do
        show_menu
        read -p "请选择操作 (1-5, 0退出): " choice
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
            5) cmd_update --all;;
            0) log_info "退出程序"; exit 0;;
            *) [[ -n "$choice" ]] && log_error "无效的选择，请输入 1-5 或 0";;
        esac
        echo
        read -p "按回车键继续..."
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
        doctor)                shift; cmd_doctor "$@";;
        help|-h|--help)        cmd_help;;
        version|-v|--version)  echo "double-wechat v${VERSION}";;
        *)                     log_error "未知命令: $cmd"; cmd_help; exit 2;;
    esac
}

main "$@"

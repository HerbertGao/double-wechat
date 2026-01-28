#!/bin/bash

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# 原始微信应用路径
ORIGINAL_WECHAT="/Applications/WeChat.app"
ORIGINAL_BUNDLE_ID="com.tencent.xinWeChat"

# 日志函数
log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

log_step() {
    echo -e "${BLUE}[STEP]${NC} $1"
}

# 获取应用版本号
get_app_version() {
    local app_path="$1"
    /usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$app_path/Contents/Info.plist" 2>/dev/null
}

# 检查原始微信应用是否存在
check_original_wechat() {
    if [[ ! -d "$ORIGINAL_WECHAT" ]]; then
        log_error "未找到原始微信应用: $ORIGINAL_WECHAT"
        log_error "请确保微信已正确安装在应用程序文件夹中"
        exit 1
    fi
    log_info "找到原始微信应用"
}

# 检查磁盘空间
check_disk_space() {
    local required_space=200000000  # 200MB in bytes (微信应用大约150-200MB)
    local available_space=$(df /Applications | awk 'NR==2 {print $4}')
    
    if [[ $available_space -lt $required_space ]]; then
        log_warn "磁盘空间可能不足，建议至少200MB可用空间"
        log_warn "当前可用空间: $((available_space / 1000000))MB"
        read -p "是否继续创建？(y/n，默认: y): " confirm
        if [[ $confirm =~ ^[Nn]$ ]]; then
            log_info "操作已取消"
            exit 0
        fi
    else
        log_info "磁盘空间检查通过"
    fi
}

# 检查是否已存在指定编号的应用
check_existing_instance() {
    local number=$1
    local target_app="/Applications/WeChat${number}.app"
    
    if [[ -d "$target_app" ]]; then
        log_warn "已存在 WeChat${number}.app"
        read -p "是否要删除现有实例并重新创建？(y/n，默认: y): " confirm
        if [[ $confirm =~ ^[Nn]$ ]]; then
            log_info "操作已取消"
            exit 0
        fi
        log_step "删除现有实例..."
        sudo rm -rf "$target_app"
        log_info "现有实例已删除"
    fi
}

# 创建微信实例
create_wechat_instance() {
    local number=$1
    local target_app="/Applications/WeChat${number}.app"
    local new_bundle_id="${ORIGINAL_BUNDLE_ID}${number}"
    
    log_step "创建 WeChat${number}.app..."
    
    # 复制应用
    if ! sudo cp -R "$ORIGINAL_WECHAT" "$target_app"; then
        log_error "复制微信应用失败"
        exit 1
    fi
    log_info "应用复制完成"
    
    # 修改Bundle Identifier
    log_step "修改应用标识符..."
    if ! sudo /usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $new_bundle_id" "$target_app/Contents/Info.plist"; then
        log_error "修改Bundle Identifier失败"
        sudo rm -rf "$target_app"
        exit 1
    fi
    log_info "标识符修改完成: $new_bundle_id"
    
    # 重新签名
    log_step "重新签名应用..."
    if ! sudo codesign --force --deep --sign - "$target_app"; then
        log_error "应用签名失败"
        sudo rm -rf "$target_app"
        exit 1
    fi
    log_info "应用签名完成"
    
    return 0
}

# 启动微信实例
start_wechat_instance() {
    local number=$1
    local target_app="/Applications/WeChat${number}.app"
    local wechat_binary="$target_app/Contents/MacOS/WeChat"
    
    log_step "启动 WeChat${number}..."
    
    if [[ ! -f "$wechat_binary" ]]; then
        log_error "微信可执行文件不存在: $wechat_binary"
        return 1
    fi
    
    # 启动应用
    nohup "$wechat_binary" >/dev/null 2>&1 &
    local pid=$!
    
    if [[ -n "$pid" && $pid -gt 0 ]]; then
        log_info "WeChat${number} 启动成功 (PID: $pid)"
        return 0
    else
        log_error "WeChat${number} 启动失败"
        return 1
    fi
}

# 显示菜单
show_menu() {
    echo -e "\n${BLUE}=== 微信多开管理工具 ===${NC}"
    echo "1. 创建新的微信实例"
    echo "2. 启动现有微信实例"
    echo "3. 列出所有微信实例"
    echo "4. 删除微信实例"
    echo "5. 一键更新所有实例"
    echo "6. 退出"
    echo -e "${BLUE}=======================${NC}\n"
}

# 列出所有微信实例
list_instances() {
    log_step "扫描微信实例..."

    local original_version=$(get_app_version "$ORIGINAL_WECHAT")
    echo -e "\n${BLUE}已安装的微信实例:${NC}"

    # 原始微信
    if [[ -d "$ORIGINAL_WECHAT" ]]; then
        echo -e "• WeChat.app (原始)  版本: ${GREEN}${original_version:-未知}${NC}"
    fi

    # 查找所有WeChat*.app
    local found=false
    local count=0
    for app in /Applications/WeChat*.app; do
        if [[ -d "$app" && "$app" != "$ORIGINAL_WECHAT" ]]; then
            local app_name=$(basename "$app")
            local inst_version=$(get_app_version "$app")
            local version_status=""
            if [[ -n "$original_version" && -n "$inst_version" && "$inst_version" != "$original_version" ]]; then
                version_status="  ${RED}[需要更新: ${inst_version} → ${original_version}]${NC}"
            fi
            echo -e "• $app_name  版本: ${inst_version:-未知}${version_status}"
            found=true
            ((count++))
        fi
    done

    if [[ "$found" == false ]]; then
        echo "• 未找到其他微信实例"
    else
        echo -e "\n共 ${count} 个实例"
    fi
    echo
}

# 删除微信实例
delete_instance() {
    echo -e "\n${BLUE}可删除的微信实例:${NC}"
    local instances=()
    local index=1
    
    for app in /Applications/WeChat*.app; do
        if [[ -d "$app" && "$app" != "$ORIGINAL_WECHAT" ]]; then
            local app_name=$(basename "$app")
            echo "$index. $app_name"
            instances+=("$app")
            ((index++))
        fi
    done
    
    if [[ ${#instances[@]} -eq 0 ]]; then
        log_warn "没有找到可删除的微信实例"
        return
    fi
    
    read -p "请选择要删除的实例编号 (1-${#instances[@]}): " choice
    
    if [[ $choice =~ ^[0-9]+$ && $choice -ge 1 && $choice -le ${#instances[@]} ]]; then
        local selected_app="${instances[$((choice-1))]}"
        local app_name=$(basename "$selected_app")
        
        read -p "确定要删除 $app_name 吗？(y/n，默认: n): " confirm
        if [[ $confirm =~ ^[Yy]$ ]]; then
            log_step "删除 $app_name..."
            if sudo rm -rf "$selected_app"; then
                log_info "$app_name 删除成功"
            else
                log_error "删除失败"
            fi
        else
            log_info "操作已取消"
        fi
    else
        log_error "无效的选择"
    fi
}

# 启动现有实例
start_existing_instance() {
    echo -e "\n${BLUE}可启动的微信实例:${NC}"
    local instances=()
    local index=1
    
    for app in /Applications/WeChat*.app; do
        if [[ -d "$app" ]]; then
            local app_name=$(basename "$app")
            echo "$index. $app_name"
            instances+=("$app")
            ((index++))
        fi
    done
    
    read -p "请选择要启动的实例编号 (1-${#instances[@]}): " choice
    
    if [[ $choice =~ ^[0-9]+$ && $choice -ge 1 && $choice -le ${#instances[@]} ]]; then
        local selected_app="${instances[$((choice-1))]}"
        local app_name=$(basename "$selected_app")
        local wechat_binary="$selected_app/Contents/MacOS/WeChat"
        
        if [[ -f "$wechat_binary" ]]; then
            log_step "启动 $app_name..."
            nohup "$wechat_binary" >/dev/null 2>&1 &
            local pid=$!
            
            if [[ -n "$pid" && $pid -gt 0 ]]; then
                log_info "$app_name 启动成功 (PID: $pid)"
            else
                log_error "$app_name 启动失败"
            fi
        else
            log_error "找不到可执行文件: $wechat_binary"
        fi
    else
        log_error "无效的选择"
    fi
}

# 一键更新所有实例
update_all_instances() {
    local original_version=$(get_app_version "$ORIGINAL_WECHAT")
    if [[ -z "$original_version" ]]; then
        log_error "无法获取原始微信版本号"
        return
    fi
    log_info "原始微信版本: $original_version"

    local updated=0
    local skipped=0
    local failed=0

    for app in /Applications/WeChat*.app; do
        if [[ ! -d "$app" || "$app" == "$ORIGINAL_WECHAT" ]]; then
            continue
        fi

        local app_name=$(basename "$app")
        local inst_version=$(get_app_version "$app")
        local number=$(echo "$app_name" | sed 's/WeChat\(.*\)\.app/\1/')

        if [[ "$inst_version" == "$original_version" ]]; then
            log_info "$app_name 版本一致 ($inst_version)，跳过"
            ((skipped++))
            continue
        fi

        log_step "更新 $app_name ($inst_version → $original_version)..."

        # 删除旧副本
        if ! sudo rm -rf "$app"; then
            log_error "$app_name 删除失败"
            ((failed++))
            continue
        fi

        # 重新创建实例
        if create_wechat_instance "$number"; then
            log_info "$app_name 更新成功"
            ((updated++))
        else
            log_error "$app_name 更新失败"
            ((failed++))
        fi
    done

    echo -e "\n${BLUE}=== 更新汇总 ===${NC}"
    echo "已更新: $updated"
    echo "已跳过 (版本一致): $skipped"
    if [[ $failed -gt 0 ]]; then
        echo -e "${RED}失败: $failed${NC}"
    fi
}

# 主函数
main() {
    # 检查是否为root用户
    if [[ $EUID -eq 0 ]]; then
        log_error "请不要以root用户身份运行此脚本"
        exit 1
    fi
    
    # 检查原始微信应用
    check_original_wechat
    
    while true; do
        show_menu
        read -p "请选择操作 (1-6): " choice
        
        # 清理输入，移除可能的换行符和空格
        choice=$(echo "$choice" | tr -d '\n\r' | xargs)
        
        case $choice in
            1)
                echo -e "\n${BLUE}=== 创建新的微信实例 ===${NC}"
                read -p "请输入实例编号 (0-9): " number
                
                # 清理输入
                number=$(echo "$number" | tr -d '\n\r' | xargs)
                
                if [[ $number =~ ^[0-9]$ ]]; then
                    check_disk_space
                    check_existing_instance "$number"
                    
                    if create_wechat_instance "$number"; then
                        if start_wechat_instance "$number"; then
                            echo -e "\n${GREEN}✓ 微信实例创建并启动成功！${NC}"
                            echo -e "${YELLOW}提示: 可以在程序坞中右键保留此应用，方便下次使用${NC}"
                        fi
                    fi
                else
                    log_error "请输入0-9之间的单个数字"
                fi
                ;;
            2)
                start_existing_instance
                ;;
            3)
                list_instances
                ;;
            4)
                delete_instance
                ;;
            5)
                update_all_instances
                ;;
            6)
                log_info "退出程序"
                exit 0
                ;;
            *)
                if [[ -n "$choice" ]]; then
                    log_error "无效的选择，请输入1-6"
                fi
                ;;
        esac
        
        echo
        read -p "按回车键继续..."
    done
}

# 运行主函数
main 
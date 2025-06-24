#!/bin/bash
set -e # Exit immediately if a command exits with a non-zero status.

# 脚本全局配置
SCRIPT_NAME="个人自用数据备份 (Rclone 版)"
# 使用 XDG Base Directory Specification
CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/personal_backup_rclone"
LOG_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/personal_backup_rclone"
CONFIG_FILE="$CONFIG_DIR/config"
LOG_FILE="$LOG_DIR/log.txt"

# 默认值 (如果配置文件未找到)
declare -a BACKUP_SOURCE_PATHS_ARRAY=() # 要备份的源路径数组
BACKUP_SOURCE_PATHS_STRING="" # 用于配置文件保存的路径字符串

AUTO_BACKUP_INTERVAL_DAYS=7 # 默认自动备份间隔天数
LAST_AUTO_BACKUP_TIMESTAMP=0 # 上次自动备份的 Unix 时间戳

# 备份保留策略默认值
RETENTION_POLICY_TYPE="none" # "none", "count", "days"
RETENTION_VALUE=0            # 要保留的备份数量或天数

# --- Rclone 配置 ---
# 数组，用于存储格式为 "remote_name:remote/path" 的 Rclone 目标
declare -a RCLONE_TARGETS_ARRAY=() 
# 用于配置文件保存的目标字符串，使用 ;; 作为分隔符
RCLONE_TARGETS_STRING="" 
# 数组，用于存储 RCLONE_TARGETS_ARRAY 中已启用的目标的索引
declare -a ENABLED_RCLONE_TARGET_INDICES_ARRAY=()
# 用于配置文件保存的已启用目标的索引字符串
ENABLED_RCLONE_TARGET_INDICES_STRING=""

# Telegram 通知变量
TELEGRAM_BOT_TOKEN=""
TELEGRAM_CHAT_ID=""

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m' # 无颜色

# 临时目录
TEMP_DIR=""

# --- 辅助函数 ---

# 确保在脚本退出时清理临时目录
cleanup_temp_dir() {
    if [[ -n "$TEMP_DIR" && -d "$TEMP_DIR" ]]; then
        rm -rf "$TEMP_DIR"
        echo "$(date '+%Y-%m-%d %H:%M:%S') - 清理临时目录: $TEMP_DIR" >> "$LOG_FILE"
    fi
}

# 注册清理函数
trap cleanup_temp_dir EXIT

# 清屏
clear_screen() {
    clear
}

# 显示脚本头部
display_header() {
    clear_screen
    echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${GREEN}      $SCRIPT_NAME      ${NC}"
    echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
}

# 显示消息并记录到日志
log_and_display() {
    local message="$1"
    local color="$2"
    local output_destination="${3:-/dev/stdout}"
    local plain_message
    plain_message=$(echo -e "$message" | sed 's/\x1b\[[0-9;]*m//g')

    echo "$(date '+%Y-%m-%d %H:%M:%S') - ${plain_message}" >> "$LOG_FILE"

    if [[ -n "$color" ]]; then
        echo -e "$color$message$NC" > "$output_destination"
    else
        echo -e "$message" > "$output_destination"
    fi
}

# 等待用户按 Enter 键继续
press_enter_to_continue() {
    echo ""
    log_and_display "${BLUE}按 Enter 键继续...${NC}" ""
    read -r
    clear_screen
}

# --- 配置保存和加载 ---

# 保存配置到文件
save_config() {
    mkdir -p "$CONFIG_DIR" 2>/dev/null
    if [ ! -d "$CONFIG_DIR" ]; then
        log_and_display "${RED}错误：无法创建配置目录 $CONFIG_DIR，请检查权限。${NC}"
        return 1
    fi

    # 转换数组为字符串
    BACKUP_SOURCE_PATHS_STRING=$(IFS=';;'; echo "${BACKUP_SOURCE_PATHS_ARRAY[*]}")
    RCLONE_TARGETS_STRING=$(IFS=';;'; echo "${RCLONE_TARGETS_ARRAY[*]}")
    ENABLED_RCLONE_TARGET_INDICES_STRING=$(IFS=';;'; echo "${ENABLED_RCLONE_TARGET_INDICES_ARRAY[*]}")

    {
        echo "BACKUP_SOURCE_PATHS_STRING=\"$BACKUP_SOURCE_PATHS_STRING\""
        echo "AUTO_BACKUP_INTERVAL_DAYS=$AUTO_BACKUP_INTERVAL_DAYS"
        echo "LAST_AUTO_BACKUP_TIMESTAMP=$LAST_AUTO_BACKUP_TIMESTAMP"
        echo "RETENTION_POLICY_TYPE=\"$RETENTION_POLICY_TYPE\""
        echo "RETENTION_VALUE=$RETENTION_VALUE"
        echo "RCLONE_TARGETS_STRING=\"$RCLONE_TARGETS_STRING\""
        echo "ENABLED_RCLONE_TARGET_INDICES_STRING=\"$ENABLED_RCLONE_TARGET_INDICES_STRING\""
        echo "TELEGRAM_BOT_TOKEN=\"$TELEGRAM_BOT_TOKEN\""
        echo "TELEGRAM_CHAT_ID=\"$TELEGRAM_CHAT_ID\""
    } > "$CONFIG_FILE"

    log_and_display "配置已保存到 $CONFIG_FILE"
    chmod 600 "$CONFIG_FILE" 2>/dev/null
    log_and_display "${YELLOW}已将配置文件 $CONFIG_FILE 权限设置为 600。${NC}"
}

# 从文件加载配置
load_config() {
    mkdir -p "$LOG_DIR" 2>/dev/null
    if [ ! -d "$LOG_DIR" ]; then
        echo "$(date '+%Y-%m-%d %H:%M:%S') - 错误：无法创建日志目录 $LOG_DIR，请检查权限。" | tee -a "$LOG_FILE"
        return 1
    fi

    if [[ -f "$CONFIG_FILE" ]]; then
        current_perms=$(stat -c "%a" "$CONFIG_FILE" 2>/dev/null)
        if [[ "$current_perms" != "600" ]]; then
            log_and_display "${YELLOW}警告：配置文件 $CONFIG_FILE 权限不安全 (${current_perms})，建议设置为 600。${NC}"
            chmod 600 "$CONFIG_FILE" 2>/dev/null
        fi
        
        source "$CONFIG_FILE"
        log_and_display "配置已从 $CONFIG_FILE 加载。" "${BLUE}"

        # 解析字符串到数组
        if [[ -n "$BACKUP_SOURCE_PATHS_STRING" ]]; then
            IFS=';;'; read -r -a BACKUP_SOURCE_PATHS_ARRAY <<< "$BACKUP_SOURCE_PATHS_STRING"
        else
            BACKUP_SOURCE_PATHS_ARRAY=()
        fi
        if [[ -n "$RCLONE_TARGETS_STRING" ]]; then
            IFS=';;'; read -r -a RCLONE_TARGETS_ARRAY <<< "$RCLONE_TARGETS_STRING"
        else
            RCLONE_TARGETS_ARRAY=()
        fi
        if [[ -n "$ENABLED_RCLONE_TARGET_INDICES_STRING" ]]; then
            IFS=';;'; read -r -a ENABLED_RCLONE_TARGET_INDICES_ARRAY <<< "$ENABLED_RCLONE_TARGET_INDICES_STRING"
        else
            ENABLED_RCLONE_TARGET_INDICES_ARRAY=()
        fi
    else
        log_and_display "未找到配置文件 $CONFIG_FILE，将使用默认配置。" "${YELLOW}"
    fi
}

# --- 核心功能 ---

# 检查所需依赖项
check_dependencies() {
    local missing_deps=()
    command -v zip &> /dev/null || missing_deps+=("zip")
    command -v realpath &> /dev/null || missing_deps+=("realpath")
    command -v rclone &> /dev/null || missing_deps+=("rclone") # 主要依赖

    if [[ -n "$TELEGRAM_BOT_TOKEN" && -n "$TELEGRAM_CHAT_ID" ]]; then
        command -v curl &> /dev/null || missing_deps+=("curl (用于Telegram)")
    fi

    if [ ${#missing_deps[@]} -gt 0 ]; then
        log_and_display "${RED}检测到以下依赖项缺失，请安装后重试：${missing_deps[*]}${NC}"
        log_and_display "例如 (Debian/Ubuntu): sudo apt update && sudo apt install zip realpath curl" "${YELLOW}"
        log_and_display "要安装 Rclone, 请运行: curl https://rclone.org/install.sh | sudo bash" "${YELLOW}"
        press_enter_to_continue
        return 1
    fi
    return 0
}

# 发送 Telegram 消息
send_telegram_message() {
    local message_content="$1"
    if [[ -z "$TELEGRAM_BOT_TOKEN" || -z "$TELEGRAM_CHAT_ID" ]]; then
        log_and_display "${YELLOW}Telegram 通知未配置，跳过发送消息。${NC}" "" "/dev/stderr"
        return 1
    fi
    if ! command -v curl &> /dev/null; then
        log_and_display "${RED}错误：发送 Telegram 消息需要 'curl'。${NC}" "" "/dev/stderr"
        return 1
    fi
    log_and_display "正在发送 Telegram 消息..." "" "/dev/stderr"
    if curl -s -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
        --data-urlencode "chat_id=${TELEGRAM_CHAT_ID}" \
        --data-urlencode "text=${message_content}" \
        --data-urlencode "parse_mode=Markdown" > /dev/null; then
        log_and_display "${GREEN}Telegram 消息发送成功。${NC}" "" "/dev/stderr"
    else
        log_and_display "${RED}Telegram 消息发送失败！${NC}" "" "/dev/stderr"
    fi
}

# 1. 设置自动备份间隔 (逻辑不变)
set_auto_backup_interval() {
    display_header
    echo -e "${BLUE}=== 1. 自动备份设定 ===${NC}"
    echo "当前自动备份间隔: ${AUTO_BACKUP_INTERVAL_DAYS} 天"
    read -rp "请输入新的自动备份间隔时间（天数，最小1天）: " interval_input
    if [[ "$interval_input" =~ ^[0-9]+$ ]] && [ "$interval_input" -ge 1 ]; then
        AUTO_BACKUP_INTERVAL_DAYS="$interval_input"
        save_config
        log_and_display "${GREEN}自动备份间隔已成功设置为：${AUTO_BACKUP_INTERVAL_DAYS} 天。${NC}"
    else
        log_and_display "${RED}输入无效。${NC}"
    fi
    press_enter_to_continue
}

# 2. 手动备份 (逻辑不变)
manual_backup() {
    display_header
    echo -e "${BLUE}=== 2. 手动备份 ===${NC}"
    if [ ${#BACKUP_SOURCE_PATHS_ARRAY[@]} -eq 0 ]; then
        log_and_display "${RED}错误：没有设置任何备份源路径。${NC}"
        press_enter_to_continue
        return 1
    fi
    perform_backup "手动备份"
    press_enter_to_continue
}

# 3. 自定义备份路径 (逻辑不变)
set_backup_path() {
    # 此处省略了原脚本中 add_backup_path, view_and_manage_backup_paths 的代码
    # 因为它们与云存储无关，可以直接复用。为保持简洁，这里不重复粘贴。
    # 请将您原脚本中的 `set_backup_path` 及其子函数 `add_backup_path`, `view_and_manage_backup_paths` 粘贴到这里。
    # -------------------------------------------------------------
    # --- 将原脚本中 "3. 自定义备份路径" 的所有相关函数粘贴在此处 ---
    # -------------------------------------------------------------
    # --- 修改后的 3. 自定义备份路径 ---
    add_backup_path() {
        display_header
        echo -e "${BLUE}=== 添加备份路径 ===${NC}"
        read -rp "请输入要备份的文件或文件夹的绝对路径（例如 /home/user/mydata 或 /etc/nginx/nginx.conf）: " path_input

        local resolved_path
        resolved_path=$(realpath -q "$path_input" 2>/dev/null)

        if [[ -z "$resolved_path" ]]; then
            log_and_display "${RED}错误：输入的路径无效或不存在。${NC}"
        elif [[ ! -d "$resolved_path" && ! -f "$resolved_path" ]]; then
            log_and_display "${RED}错误：输入的路径 '$resolved_path' 不存在或不是有效的文件/目录。${NC}"
        else
            local found=false
            for p in "${BACKUP_SOURCE_PATHS_ARRAY[@]}"; do
                if [[ "$p" == "$resolved_path" ]]; then
                    found=true
                    break
                fi
            done

            if "$found"; then
                log_and_display "${YELLOW}该路径 '$resolved_path' 已存在于备份列表中。${NC}"
            else
                BACKUP_SOURCE_PATHS_ARRAY+=("$resolved_path")
                save_config
                log_and_display "${GREEN}备份路径 '$resolved_path' 已成功添加。${NC}"
            fi
        fi
        press_enter_to_continue
    }

    view_and_manage_backup_paths() {
        while true; do
            display_header
            echo -e "${BLUE}=== 查看/管理备份路径 ===${NC}"
            if [ ${#BACKUP_SOURCE_PATHS_ARRAY[@]} -eq 0 ]; then
                log_and_display "${YELLOW}当前没有设置任何备份路径。${NC}"
                press_enter_to_continue
                break
            fi

            echo "当前备份路径列表:"
            for i in "${!BACKUP_SOURCE_PATHS_ARRAY[@]}"; do
                echo "  $((i+1)). ${BACKUP_SOURCE_PATHS_ARRAY[$i]}"
            done
            echo ""
            echo "1. 修改现有路径"
            echo "2. 删除路径"
            echo "0. 返回自定义备份路径菜单"
            echo -e "${BLUE}------------------------------------------------${NC}"
            read -rp "请输入选项: " sub_choice

            case $sub_choice in
                1) # 修改路径
                    read -rp "请输入要修改的路径序号: " path_index
                    if [[ "$path_index" =~ ^[0-9]+$ ]] && [ "$path_index" -ge 1 ] && [ "$path_index" -le ${#BACKUP_SOURCE_PATHS_ARRAY[@]} ]; then
                        local current_path="${BACKUP_SOURCE_PATHS_ARRAY[$((path_index-1))]}"
                        read -rp "您正在修改路径 '${current_path}'。请输入新的绝对路径: " new_path_input

                        local resolved_new_path
                        resolved_new_path=$(realpath -q "$new_path_input" 2>/dev/null)

                        if [[ -z "$resolved_new_path" ]]; then
                            log_and_display "${RED}错误：输入的路径无效或不存在。${NC}"
                        elif [[ ! -d "$resolved_new_path" && ! -f "$resolved_new_path" ]]; then
                            log_and_display "${RED}错误：输入的路径 '$resolved_new_path' 不存在或不是有效的文件/目录。${NC}"
                        else
                            if [[ -d "$resolved_new_path" ]]; then
                                resolved_new_path="${resolved_new_path%/}"
                            fi
                            BACKUP_SOURCE_PATHS_ARRAY[$((path_index-1))]="$resolved_new_path"
                            save_config
                            log_and_display "${GREEN}路径已成功修改为：${resolved_new_path}${NC}"
                        fi
                    else
                        log_and_display "${RED}无效的路径序号。${NC}"
                    fi
                    press_enter_to_continue
                    ;;
                2) # 删除路径
                    read -rp "请输入要删除的路径序号: " path_index
                    if [[ "$path_index" =~ ^[0-9]+$ ]] && [ "$path_index" -ge 1 ] && [ "$path_index" -le ${#BACKUP_SOURCE_PATHS_ARRAY[@]} ]; then
                        log_and_display "${YELLOW}警告：您确定要删除路径 '${BACKUP_SOURCE_PATHS_ARRAY[$((path_index-1))]}'吗？(y/N)${NC}"
                        read -rp "请确认: " confirm_delete
                        if [[ "$confirm_delete" =~ ^[Yy]$ ]]; then
                            unset 'BACKUP_SOURCE_PATHS_ARRAY[$((path_index-1))]'
                            BACKUP_SOURCE_PATHS_ARRAY=("${BACKUP_SOURCE_PATHS_ARRAY[@]}") # 重新索引数组
                            save_config
                            log_and_display "${GREEN}路径已成功删除。${NC}"
                        else
                            log_and_display "取消删除路径。" "${BLUE}"
                        fi
                    else
                        log_and_display "${RED}无效的路径序号。${NC}"
                    fi
                    press_enter_to_continue
                    ;;
                0)
                    break
                    ;;
                *)
                    log_and_display "${RED}无效的选项，请重新输入。${NC}"
                    press_enter_to_continue
                    ;;
            esac
        done
    }

    # 3. 自定义备份路径主函数
    while true; do
        display_header
        echo -e "${BLUE}=== 3. 自定义备份路径 ===${NC}"
        echo "当前已配置备份路径数量: ${#BACKUP_SOURCE_PATHS_ARRAY[@]} 个"
        echo ""
        echo "1. 添加新的备份路径"
        echo "2. 查看/修改/删除现有备份路径"
        echo "0. 返回主菜单"
        echo -e "${BLUE}------------------------------------------------${NC}"
        read -rp "请输入选项: " choice

        case $choice in
            1) add_backup_path ;;
            2) view_and_manage_backup_paths ;;
            0)
                break
                ;;
            *)
                log_and_display "${RED}无效的选项，请重新输入。${NC}"
                press_enter_to_continue
                ;;
        esac
    done
}


# 4. 压缩格式信息 (逻辑不变)
display_compression_info() {
    display_header
    echo -e "${BLUE}=== 4. 压缩包格式 ===${NC}"
    log_and_display "本脚本当前支持的压缩格式为：${GREEN}ZIP${NC}。"
    press_enter_to_continue
}

# ================================================================
# ===         [RCLONE] 云存储设定 (新)                       ===
# ================================================================

# 检查 Rclone 远程端是否存在
check_rclone_remote_exists() {
    local remote_name="$1"
    if rclone listremotes | grep -q "^${remote_name}:"; then
        return 0
    else
        return 1
    fi
}

# 获取 Rclone 远程端的目录内容
get_rclone_direct_contents() {
    local rclone_target="$1" # 格式 "remote:path"
    log_and_display "正在获取 Rclone 目标 '${rclone_target}' 的内容..." "${BLUE}" "/dev/stderr"
    
    local contents=()
    local folders_list
    folders_list=$(rclone lsf --dirs-only "${rclone_target}" 2>/dev/null)
    local files_list
    files_list=$(rclone lsf --files-only "${rclone_target}" 2>/dev/null)

    if [[ -n "$folders_list" ]]; then
        while IFS= read -r folder; do
            contents+=("${folder%/} (文件夹)")
        done <<< "$folders_list"
    fi
    if [[ -n "$files_list" ]]; then
        while IFS= read -r file; do
            contents+=("$file (文件)")
        done <<< "$files_list"
    fi

    IFS=$'\n' contents=($(sort <<<"${contents[*]}"))
    unset IFS
    printf '%s\n' "${contents[@]}"
    return 0
}

# 交互式选择 Rclone 路径
choose_rclone_path() {
    local remote_name="$1"
    local current_remote_path="/"
    local final_selected_path=""

    while true; do
        display_header
        echo -e "${BLUE}=== 设置 Rclone 备份目标路径 (${remote_name}) ===${NC}"
        echo -e "当前浏览路径: ${YELLOW}${remote_name}:${current_remote_path}${NC}\n"

        local remote_contents_array=()
        local remote_contents_str
        remote_contents_str=$(get_rclone_direct_contents "${remote_name}:${current_remote_path}")
        if [[ -n "$remote_contents_str" ]]; then
            mapfile -t remote_contents_array <<< "$remote_contents_str"
        fi

        if [ ${#remote_contents_array[@]} -gt 0 ]; then
            for i in "${!remote_contents_array[@]}"; do
                echo "  $((i+1)). ${remote_contents_array[$i]}"
            done
        else
            echo "当前路径下无内容。"
        fi

        echo -e "${BLUE}------------------------------------------------${NC}"
        echo "操作选项:"
        if [[ "$current_remote_path" != "/" ]]; then
            echo -e "  ${GREEN}m${NC} - 返回上一级目录"
        fi
        echo -e "  ${GREEN}k${NC} - 将当前路径 '${current_remote_path}' 设置为备份目标"
        echo -e "  ${GREEN}a${NC} - 手动输入新路径"
        echo -e "  ${GREEN}x${NC} - 取消并返回"
        echo -e "${BLUE}------------------------------------------------${NC}"
        read -rp "请输入您的选择 (数字或字母): " choice

        case "$choice" in
            "m" | "M" )
                if [[ "$current_remote_path" != "/" ]]; then
                    current_remote_path=$(realpath -m "${current_remote_path}/../")
                fi
                ;;
            [0-9]* )
                if [ "$choice" -ge 1 ] && [ "$choice" -le ${#remote_contents_array[@]} ]; then
                    local chosen_item="${remote_contents_array[$((choice-1))]}"
                    if echo "$chosen_item" | grep -q " (文件夹)$"; then
                        local chosen_folder
                        chosen_folder=$(echo "$chosen_item" | sed 's/\ (文件夹)$//')
                        current_remote_path="${current_remote_path}${chosen_folder}/"
                        current_remote_path=$(realpath -m "$current_remote_path")
                    else
                        log_and_display "${YELLOW}不能进入文件。${NC}"; press_enter_to_continue
                    fi
                else
                    log_and_display "${RED}无效序号。${NC}"; press_enter_to_continue
                fi
                ;;
            [kK] )
                final_selected_path="$current_remote_path"
                break
                ;;
            [aA] )
                read -rp "请输入新的目标路径 (绝对路径, e.g., /backups/): " new_path_input
                final_selected_path=$(realpath -m "$new_path_input")
                break
                ;;
            [xX] ) return 1 ;;
            * ) log_and_display "${RED}无效输入。${NC}"; press_enter_to_continue ;;
        esac
    done

    WEBDAV_BACKUP_PATH="$final_selected_path" # 使用一个临时全局变量来返回路径
    return 0
}

# 管理 Rclone 备份目标
manage_rclone_targets() {
    while true; do
        display_header
        echo -e "${BLUE}=== 管理 Rclone 备份目标 ===${NC}"
        if [ ${#RCLONE_TARGETS_ARRAY[@]} -eq 0 ]; then
            log_and_display "${YELLOW}当前没有配置任何 Rclone 目标。${NC}"
        else
            echo "已配置的 Rclone 目标:"
            for i in "${!RCLONE_TARGETS_ARRAY[@]}"; do
                echo "  $((i+1)). ${RCLONE_TARGETS_ARRAY[$i]}"
            done
        fi
        echo ""
        echo "1. 添加新的 Rclone 目标"
        echo "2. 删除一个 Rclone 目标"
        echo "0. 返回"
        echo -e "${BLUE}------------------------------------------------${NC}"
        read -rp "请输入选项: " choice

        case "$choice" in
            1) # 添加
                read -rp "请输入您已通过 'rclone config' 配置好的远程端名称: " remote_name
                if ! check_rclone_remote_exists "$remote_name"; then
                    log_and_display "${RED}错误: Rclone 远程端 '${remote_name}' 不存在！${NC}"
                    log_and_display "${YELLOW}请先运行 'rclone config' 创建它。${NC}"
                    press_enter_to_continue
                    continue
                fi
                
                if choose_rclone_path "$remote_name"; then
                    local remote_path="$WEBDAV_BACKUP_PATH" # 从临时变量获取路径
                    RCLONE_TARGETS_ARRAY+=("${remote_name}:${remote_path}")
                    save_config
                    log_and_display "${GREEN}已成功添加目标: ${remote_name}:${remote_path}${NC}"
                else
                    log_and_display "${YELLOW}已取消添加目标。${NC}"
                fi
                press_enter_to_continue
                ;;
            2) # 删除
                if [ ${#RCLONE_TARGETS_ARRAY[@]} -eq 0 ]; then
                    log_and_display "${YELLOW}没有可删除的目标。${NC}"
                    press_enter_to_continue
                    continue
                fi
                read -rp "请输入要删除的目标序号: " index
                if [[ "$index" =~ ^[0-9]+$ ]] && [ "$index" -ge 1 ] && [ "$index" -le ${#RCLONE_TARGETS_ARRAY[@]} ]; then
                    local target_to_delete="${RCLONE_TARGETS_ARRAY[$((index-1))]}"
                    read -rp "确定要删除目标 '${target_to_delete}' 吗? (y/N): " confirm
                    if [[ "$confirm" =~ ^[Yy]$ ]]; then
                        unset 'RCLONE_TARGETS_ARRAY[$((index-1))]'
                        RCLONE_TARGETS_ARRAY=("${RCLONE_TARGETS_ARRAY[@]}")
                        # 同时从启用列表中移除
                        local new_enabled_indices=()
                        for enabled_idx in "${ENABLED_RCLONE_TARGET_INDICES_ARRAY[@]}"; do
                            if (( enabled_idx < index - 1 )); then
                                new_enabled_indices+=("$enabled_idx")
                            elif (( enabled_idx > index - 1 )); then
                                new_enabled_indices+=("$((enabled_idx - 1))")
                            fi
                        done
                        ENABLED_RCLONE_TARGET_INDICES_ARRAY=("${new_enabled_indices[@]}")
                        save_config
                        log_and_display "${GREEN}目标已删除。${NC}"
                    fi
                else
                    log_and_display "${RED}无效序号。${NC}"
                fi
                press_enter_to_continue
                ;;
            0) break ;;
            *) log_and_display "${RED}无效选项。${NC}"; press_enter_to_continue ;;
        esac
    done
}

# 选择启用的 Rclone 备份目标
select_backup_targets() {
    while true; do
        display_header
        echo -e "${BLUE}=== 选择启用的云备份目标 (Rclone) ===${NC}"
        echo "输入序号来切换目标的 [启用/禁用] 状态。"
        
        if [ ${#RCLONE_TARGETS_ARRAY[@]} -eq 0 ]; then
            log_and_display "${YELLOW}请先在 '管理 Rclone 备份目标' 菜单中添加目标。${NC}"
            press_enter_to_continue
            break
        fi

        for i in "${!RCLONE_TARGETS_ARRAY[@]}"; do
            local is_enabled="false"
            for enabled_idx in "${ENABLED_RCLONE_TARGET_INDICES_ARRAY[@]}"; do
                if [[ "$i" -eq "$enabled_idx" ]]; then
                    is_enabled="true"; break;
                fi
            done
            
            echo -n "$((i+1)). ${RCLONE_TARGETS_ARRAY[$i]} (当前: "
            if [[ "$is_enabled" == "true" ]]; then
                echo -e "${GREEN}启用${NC})"
            else
                echo -e "${YELLOW}禁用${NC})"
            fi
        done

        echo ""
        echo "0. 保存并返回"
        echo -e "${BLUE}------------------------------------------------${NC}"
        read -rp "请输入要切换状态的目标序号 (0 保存并退出): " choice

        if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le ${#RCLONE_TARGETS_ARRAY[@]} ]; then
            local choice_idx=$((choice - 1))
            local found_in_enabled=-1
            local index_in_enabled_array=-1
            for i in "${!ENABLED_RCLONE_TARGET_INDICES_ARRAY[@]}"; do
                if [[ "${ENABLED_RCLONE_TARGET_INDICES_ARRAY[$i]}" -eq "$choice_idx" ]]; then
                    found_in_enabled=1
                    index_in_enabled_array=$i
                    break
                fi
            done

            if [[ "$found_in_enabled" -eq 1 ]]; then # 禁用
                unset 'ENABLED_RCLONE_TARGET_INDICES_ARRAY[$index_in_enabled_array]'
                ENABLED_RCLONE_TARGET_INDICES_ARRAY=("${ENABLED_RCLONE_TARGET_INDICES_ARRAY[@]}")
                log_and_display "目标已 ${YELLOW}禁用${NC}。"
            else # 启用
                ENABLED_RCLONE_TARGET_INDICES_ARRAY+=("$choice_idx")
                log_and_display "目标已 ${GREEN}启用${NC}。"
            fi
            press_enter_to_continue
        elif [[ "$choice" == "0" ]]; then
            save_config
            log_and_display "备份目标设置已保存。" "${BLUE}"
            break
        else
            log_and_display "${RED}无效选项。${NC}"; press_enter_to_continue
        fi
    done
}


# 5. 云存储设定 (Rclone 主菜单)
set_cloud_storage() {
    while true; do
        display_header
        echo -e "${BLUE}=== 5. 云存储设定 (Rclone) ===${NC}"
        echo -e "${YELLOW}请确保您已通过 'rclone config' 命令配置好了您的云存储。${NC}"
        echo ""
        echo "1. 选择启用的云备份目标 (当前启用 ${#ENABLED_RCLONE_TARGET_INDICES_ARRAY[@]} 个)"
        echo "2. 管理 Rclone 备份目标 (当前配置 ${#RCLONE_TARGETS_ARRAY[@]} 个)"
        echo "0. 返回主菜单"
        echo -e "${BLUE}------------------------------------------------${NC}"
        read -rp "请输入选项: " choice

        case $choice in
            1) select_backup_targets ;;
            2) manage_rclone_targets ;;
            0) break ;;
            *) log_and_display "${RED}无效选项。${NC}"; press_enter_to_continue ;;
        esac
    done
}


# 6. 设置 Telegram 通知设定 (逻辑不变)
set_telegram_notification() {
    display_header
    echo -e "${BLUE}=== 6. 消息通知设定 (Telegram) ===${NC}"
    log_and_display "${YELLOW}凭证将保存到本地配置文件！${NC}"
    read -rp "请输入 Telegram Bot Token [当前: ${TELEGRAM_BOT_TOKEN}]: " input_token
    TELEGRAM_BOT_TOKEN="${input_token:-$TELEGRAM_BOT_TOKEN}"

    read -rp "请输入 Telegram Chat ID [当前: ${TELEGRAM_CHAT_ID}]: " input_chat_id
    TELEGRAM_CHAT_ID="${input_chat_id:-$TELEGRAM_CHAT_ID}"
    
    save_config
    log_and_display "${GREEN}Telegram 通知配置已更新并保存。${NC}"
    press_enter_to_continue
}

# 7. 设置备份保留策略 (逻辑不变，实现会改变)
set_retention_policy() {
    # 此处省略了原脚本中 `set_retention_policy` 的菜单代码
    # 因为它与云存储的实现无关，可以直接复用。
    # 请将您原脚本中的 `set_retention_policy` 函数粘贴到这里。
    # ---
    while true; do
        display_header
        echo -e "${BLUE}=== 7. 设置备份保留策略 (云端) ===${NC}"
        echo "当前策略: "
        case "$RETENTION_POLICY_TYPE" in
            "none") echo -e "  ${YELLOW}无保留策略（所有备份将保留）${NC}" ;;
            "count") echo -e "  ${YELLOW}保留最新 ${RETENTION_VALUE} 个备份${NC}" ;;
            "days")  echo -e "  ${YELLOW}保留最近 ${RETENTION_VALUE} 天内的备份${NC}" ;;
            *)       echo -e "  ${YELLOW}未知策略或未设置${NC}" ;;
        esac
        echo ""
        echo "1. 设置按数量保留 (例如：保留最新的 5 个备份)"
        echo "2. 设置按天数保留 (例如：保留最近 30 天内的备份)"
        echo "3. 关闭保留策略"
        echo "0. 返回主菜单"
        echo -e "${BLUE}------------------------------------------------${NC}"
        read -rp "请输入选项: " sub_choice

        case $sub_choice in
            1)
                read -rp "请输入要保留的备份数量 (例如 5): " value_input
                if [[ "$value_input" =~ ^[0-9]+$ ]] && [ "$value_input" -ge 1 ]; then
                    RETENTION_POLICY_TYPE="count"
                    RETENTION_VALUE="$value_input"
                    save_config
                    log_and_display "${GREEN}已设置保留最新 ${RETENTION_VALUE} 个备份的策略。${NC}"
                else
                    log_and_display "${RED}输入无效，请输入一个大于等于 1 的整数。${NC}"
                fi
                press_enter_to_continue
                ;;
            2)
                read -rp "请输入要保留备份的天数 (例如 30): " value_input
                if [[ "$value_input" =~ ^[0-9]+$ ]] && [ "$value_input" -ge 1 ]; then
                    RETENTION_POLICY_TYPE="days"
                    RETENTION_VALUE="$value_input"
                    save_config
                    log_and_display "${GREEN}已设置保留最近 ${RETENTION_VALUE} 天内的备份策略。${NC}"
                else
                    log_and_display "${RED}输入无效，请输入一个大于等于 1 的整数。${NC}"
                fi
                press_enter_to_continue
                ;;
            3)
                RETENTION_POLICY_TYPE="none"
                RETENTION_VALUE=0
                save_config
                log_and_display "${GREEN}已关闭备份保留策略。${NC}"
                press_enter_to_continue
                ;;
            0)
                break
                ;;
            *)
                log_and_display "${RED}无效的选项，请重新输入。${NC}"
                press_enter_to_continue
                ;;
        esac
    done
}


# [RCLONE] 应用保留策略
apply_retention_policy() {
    log_and_display "${BLUE}--- 正在应用备份保留策略 (Rclone) ---${NC}"

    if [[ "$RETENTION_POLICY_TYPE" == "none" ]]; then
        log_and_display "未设置保留策略，跳过清理。" "${YELLOW}"
        return 0
    fi

    local retention_summary="*个人自用数据备份：保留策略完成*"
    retention_summary+=$'\n'"保留策略执行完毕。"

    for enabled_idx in "${ENABLED_RCLONE_TARGET_INDICES_ARRAY[@]}"; do
        local rclone_target="${RCLONE_TARGETS_ARRAY[$enabled_idx]}"
        log_and_display "正在为目标 ${rclone_target} 应用保留策略..."

        local backups_list
        # 获取文件名和修改时间戳
        backups_list=$(rclone lsf --format "p;T" "${rclone_target}" | grep -E '_[0-9]{14}\.zip;')
        if [[ -z "$backups_list" ]]; then
            log_and_display "在 ${rclone_target} 中未找到备份文件，跳过。" "${YELLOW}"
            continue
        fi
        
        # 按时间排序 (旧的在前)
        local sorted_backups
        sorted_backups=$(echo "$backups_list" | sort -t ';' -k 2)

        local backups_to_process=()
        mapfile -t backups_to_process <<< "$sorted_backups"

        local deleted_count=0
        local total_found=${#backups_to_process[@]}
        
        if [[ "$RETENTION_POLICY_TYPE" == "count" ]]; then
            local num_to_delete=$(( total_found - RETENTION_VALUE ))
            if [ "$num_to_delete" -gt 0 ]; then
                log_and_display "发现 ${num_to_delete} 个备份超过保留数量，将删除最旧的..." "${YELLOW}"
                for (( i=0; i<num_to_delete; i++ )); do
                    local file_path_to_delete
                    file_path_to_delete=$(echo "${backups_to_process[$i]}" | cut -d ';' -f 1)
                    log_and_display "正在删除: ${rclone_target}${file_path_to_delete}"
                    if rclone deletefile "${rclone_target}${file_path_to_delete}"; then
                        deleted_count=$((deleted_count + 1))
                    fi
                done
            fi
        elif [[ "$RETENTION_POLICY_TYPE" == "days" ]]; then
            local current_timestamp=$(date +%s)
            local cutoff_timestamp=$(( current_timestamp - RETENTION_VALUE * 24 * 3600 ))
            log_and_display "将删除 ${RETENTION_VALUE} 天前的备份..." "${YELLOW}"
            for item in "${backups_to_process[@]}"; do
                local file_path
                file_path=$(echo "$item" | cut -d ';' -f 1)
                local file_date
                file_date=$(echo "$item" | cut -d ';' -f 2 | cut -d 'T' -f 1)
                local file_timestamp
                file_timestamp=$(date -d "$file_date" +%s)

                if [[ "$file_timestamp" -lt "$cutoff_timestamp" ]]; then
                    log_and_display "正在删除: ${rclone_target}${file_path}"
                    if rclone deletefile "${rclone_target}${file_path}"; then
                        deleted_count=$((deleted_count + 1))
                    fi
                fi
            done
        fi
        log_and_display "${GREEN}${rclone_target} 清理完成，删除 ${deleted_count} 个文件。${NC}"
        retention_summary+=$'\n'"${rclone_target}: 找到 ${total_found} 个，删除了 ${deleted_count} 个。"
    done
    send_telegram_message "${retention_summary}"
}

# [RCLONE] 执行备份上传的核心逻辑
perform_backup() {
    local backup_type="$1"
    local readable_time=$(date '+%Y-%m-%d %H:%M:%S')
    local overall_succeeded_count=0
    local total_paths_to_backup=${#BACKUP_SOURCE_PATHS_ARRAY[@]}

    log_and_display "${BLUE}--- ${backup_type} 过程开始 ---${NC}"
    send_telegram_message "*${SCRIPT_NAME}：开始 (${backup_type})*\n时间: ${readable_time}\n将备份 ${total_paths_to_backup} 个路径。"

    if [ "$total_paths_to_backup" -eq 0 ]; then
        log_and_display "${RED}错误：未设置任何备份源路径。${NC}"
        send_telegram_message "*${SCRIPT_NAME}：失败*\n原因: 未设置备份源路径。"
        return 1
    fi

    for i in "${!BACKUP_SOURCE_PATHS_ARRAY[@]}"; do
        local current_backup_path="${BACKUP_SOURCE_PATHS_ARRAY[$i]}"
        local path_display_name
        path_display_name=$(basename "$current_backup_path")
        local timestamp
        timestamp=$(date +%Y%m%d%H%M%S)
        local sanitized_path_name
        sanitized_path_name=$(echo "$path_display_name" | sed 's/[^a-zA-Z0-9_-]/_/g')
        local archive_name="${sanitized_path_name}_${timestamp}.zip"
        local temp_archive_path="${TEMP_DIR}/${archive_name}"
        local any_upload_succeeded_for_path="false"

        log_and_display "${BLUE}--- 正在处理路径 $((i+1))/${total_paths_to_backup}: ${current_backup_path} ---${NC}"

        if [[ ! -e "$current_backup_path" ]]; then
            log_and_display "${RED}错误：路径 '$current_backup_path' 不存在，跳过。${NC}"
            send_telegram_message "*${SCRIPT_NAME}：路径失败*\n路径: \`${current_backup_path}\`\n原因: 路径不存在。"
            continue
        fi

        log_and_display "正在压缩到 '$archive_name'..."
        if [[ -d "$current_backup_path" ]]; then
            (cd "$(dirname "$current_backup_path")" && zip -r "$temp_archive_path" "$(basename "$current_backup_path")")
        else
            zip "$temp_archive_path" "$current_backup_path"
        fi

        if [ $? -ne 0 ]; then
            log_and_display "${RED}文件压缩失败！${NC}"
            send_telegram_message "*${SCRIPT_NAME}：压缩失败*\n路径: \`${current_backup_path}\`"
            continue
        fi
        
        local backup_file_size
        backup_file_size=$(du -h "$temp_archive_path" | awk '{print $1}')
        local path_summary_message="*${SCRIPT_NAME}：路径完成*\n路径: \`${current_backup_path}\`\n文件: \`${archive_name}\` (${backup_file_size})\n\n*上传状态:*"

        local upload_statuses=""
        for enabled_idx in "${ENABLED_RCLONE_TARGET_INDICES_ARRAY[@]}"; do
            local rclone_target="${RCLONE_TARGETS_ARRAY[$enabled_idx]}"
            log_and_display "正在上传到 Rclone 目标: ${rclone_target}"
            if rclone copyto "$temp_archive_path" "${rclone_target}${archive_name}" --progress; then
                log_and_display "${GREEN}上传到 ${rclone_target} 成功！${NC}"
                upload_statuses+="\n- ${rclone_target}: 成功"
                any_upload_succeeded_for_path="true"
            else
                log_and_display "${RED}上传到 ${rclone_target} 失败！${NC}"
                upload_statuses+="\n- ${rclone_target}: 失败"
            fi
        done
        
        path_summary_message+="${upload_statuses}"
        if [[ "$any_upload_succeeded_for_path" == "true" ]]; then
            overall_succeeded_count=$((overall_succeeded_count + 1))
            path_summary_message=${path_summary_message/\*路径完成/\*路径完成 (成功)\*}
        else
            path_summary_message=${path_summary_message/\*路径完成/\*路径完成 (失败)\*}
        fi
        send_telegram_message "$path_summary_message"

        rm -f "$temp_archive_path"
    done

    local overall_status="失败"
    if [ "$overall_succeeded_count" -eq "$total_paths_to_backup" ] && [ "$total_paths_to_backup" -gt 0 ]; then
        overall_status="全部成功"
    elif [ "$overall_succeeded_count" -gt 0 ]; then
        overall_status="部分成功"
    fi

    log_and_display "${BLUE}--- ${backup_type} 过程结束 ---${NC}"
    if [[ "$backup_type" == "自动备份 (Cron)" ]]; then
        LAST_AUTO_BACKUP_TIMESTAMP=$(date +%s)
        save_config
    fi
    
    send_telegram_message "*${SCRIPT_NAME}：总览 (${overall_status})*\n成功备份路径数: ${overall_succeeded_count}/${total_paths_to_backup}"

    if [[ "$overall_succeeded_count" -gt 0 ]]; then
        apply_retention_policy
    else
        log_and_display "${YELLOW}无成功上传，跳过保留策略。${NC}"
    fi
}

# 99. 卸载脚本 (逻辑不变)
uninstall_script() {
    display_header
    echo -e "${RED}=== 99. 卸载脚本 ===${NC}"
    read -rp "警告：这将删除所有脚本文件、配置文件和日志文件。确定吗？(y/N): " confirm
    if [[ "$confirm" =~ ^[Yy]$ ]]; then
        log_and_display "开始卸载..."
        rm -f "$CONFIG_FILE" 2>/dev/null && log_and_display "删除配置文件: $CONFIG_FILE"
        rmdir "$CONFIG_DIR" 2>/dev/null && log_and_display "删除配置目录: $CONFIG_DIR"
        rm -f "$LOG_FILE" 2>/dev/null && log_and_display "删除日志文件: $LOG_FILE"
        rmdir "$LOG_DIR" 2>/dev/null && log_and_display "删除日志目录: $LOG_DIR"
        log_and_display "删除脚本文件: $(readlink -f "$0")" && rm -f "$(readlink -f "$0")"
        log_and_display "${GREEN}卸载完成。${NC}"
        exit 0
    else
        log_and_display "取消卸载。" "${BLUE}"
    fi
    press_enter_to_continue
}

# 主菜单
show_main_menu() {
    display_header
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━ 功能选项 ━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "  1. ${YELLOW}自动备份设定${NC} (间隔: ${AUTO_BACKUP_INTERVAL_DAYS} 天)"
    echo -e "  2. ${YELLOW}手动备份${NC}"
    echo -e "  3. ${YELLOW}自定义备份路径${NC} (数量: ${#BACKUP_SOURCE_PATHS_ARRAY[@]})"
    echo -e "  4. ${YELLOW}压缩包格式${NC} (ZIP)"
    echo -e "  5. ${YELLOW}云存储设定 (Rclone)${NC}"
    local retention_status_text="已禁用"
    if [[ "$RETENTION_POLICY_TYPE" == "count" ]]; then
        retention_status_text="保留 ${RETENTION_VALUE} 个"
    elif [[ "$RETENTION_POLICY_TYPE" == "days" ]]; then
        retention_status_text="保留 ${RETENTION_VALUE} 天"
    fi
    echo -e "  6. ${YELLOW}消息通知设定 (Telegram)${NC}"
    echo -e "  7. ${YELLOW}设置备份保留策略${NC} (当前: ${retention_status_text})"
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "  0. ${RED}退出脚本${NC}"
    echo -e "  99. ${RED}卸载脚本${NC}"
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
}

# 处理菜单选择
process_menu_choice() {
    read -rp "请输入选项: " choice
    case $choice in
        1) set_auto_backup_interval ;;
        2) manual_backup ;;
        3) set_backup_path ;;
        4) display_compression_info ;;
        5) set_cloud_storage ;;
        6) set_telegram_notification ;;
        7) set_retention_policy ;;
        0) log_and_display "${GREEN}感谢使用！${NC}"; exit 0 ;;
        99) uninstall_script ;;
        *) log_and_display "${RED}无效选项。${NC}"; press_enter_to_continue ;;
    esac
}

# 检查是否应该运行自动备份
check_auto_backup() {
    load_config
    local current_timestamp=$(date +%s)
    local interval_seconds=$(( AUTO_BACKUP_INTERVAL_DAYS * 24 * 3600 ))

    if [ ${#BACKUP_SOURCE_PATHS_ARRAY[@]} -eq 0 ]; then
        log_and_display "${RED}自动备份失败：未设置备份源。${NC}"
        send_telegram_message "*${SCRIPT_NAME}：自动备份失败*\n原因: 未设置备份源。"
        return 1
    fi
    if [ ${#ENABLED_RCLONE_TARGET_INDICES_ARRAY[@]} -eq 0 ]; then
        log_and_display "${RED}自动备份失败：未启用 Rclone 目标。${NC}"
        send_telegram_message "*${SCRIPT_NAME}：自动备份失败*\n原因: 未启用 Rclone 目标。"
        return 1
    fi
    
    if [[ "$LAST_AUTO_BACKUP_TIMESTAMP" -eq 0 || $(( current_timestamp - LAST_AUTO_BACKUP_TIMESTAMP >= interval_seconds )) ]]; then
        log_and_display "执行自动备份..." "${BLUE}"
        perform_backup "自动备份 (Cron)"
    else
        log_and_display "未到自动备份时间。" "${YELLOW}"
    fi
}

# --- 脚本入口点 ---
main() {
    TEMP_DIR=$(mktemp -d -t personal_backup_rclone_XXXXXX)
    if [ ! -d "$TEMP_DIR" ]; then
        log_and_display "${RED}错误：无法创建临时目录。${NC}"
        exit 1
    fi

    load_config

    if [[ "$1" == "check_auto_backup" ]]; then
        log_and_display "由 Cron 任务触发自动备份检查。" "${BLUE}"
        check_auto_backup
        exit 0
    fi

    if ! check_dependencies; then
        exit 1
    fi

    while true; do
        show_main_menu
        process_menu_choice
    done
}

# 执行主函数
main "$@"

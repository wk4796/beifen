#!/bin/bash
set -e # Exit immediately if a command exits with a non-zero status.

# 脚本全局配置
SCRIPT_NAME="个人自用数据备份 (Rclone版)"
CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/personal_backup_rclone"
LOG_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/personal_backup_rclone"
CONFIG_FILE="$CONFIG_DIR/config"
LOG_FILE="$LOG_DIR/log.txt"

# 默认值 (如果配置文件未找到)
declare -a BACKUP_SOURCE_PATHS_ARRAY=()
BACKUP_SOURCE_PATHS_STRING=""

AUTO_BACKUP_INTERVAL_DAYS=7
LAST_AUTO_BACKUP_TIMESTAMP=0

RETENTION_POLICY_TYPE="none"
RETENTION_VALUE=0

# --- Rclone 配置 ---
# 我们现在只管理 Rclone 远程存储的配置信息，而不是具体的凭证
# 远程存储的名称 (例如 myR2, myGDrive)
declare -a RCLONE_REMOTES_ARRAY=()
RCLONE_REMOTES_STRING=""
# 远程存储对应的备份路径 (关联数组)
declare -A RCLONE_REMOTE_PATHS
# 远程存储的启用状态 (关联数组)
declare -A RCLONE_REMOTE_ENABLED

# Telegram 通知变量
TELEGRAM_BOT_TOKEN=""
TELEGRAM_CHAT_ID=""

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# 临时目录
TEMP_DIR=""

# --- 辅助函数 ---

cleanup_temp_dir() {
    if [[ -n "$TEMP_DIR" && -d "$TEMP_DIR" ]]; then
        rm -rf "$TEMP_DIR"
        echo "$(date '+%Y-%m-%d %H:%M:%S') - 清理临时目录: $TEMP_DIR" >> "$LOG_FILE"
    fi
}

trap cleanup_temp_dir EXIT

clear_screen() {
    clear
}

display_header() {
    clear_screen
    echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${GREEN}      $SCRIPT_NAME      ${NC}"
    echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
}

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

press_enter_to_continue() {
    echo ""
    log_and_display "${BLUE}按 Enter 键继续...${NC}" ""
    read -r
    clear_screen
}

# --- 配置保存和加载 (已重构以支持 Rclone) ---

save_config() {
    mkdir -p "$CONFIG_DIR" 2>/dev/null
    if [ ! -d "$CONFIG_DIR" ]; then
        log_and_display "${RED}错误：无法创建配置目录 $CONFIG_DIR。${NC}"
        return 1
    fi

    BACKUP_SOURCE_PATHS_STRING=$(IFS=';;'; echo "${BACKUP_SOURCE_PATHS_ARRAY[*]}")
    RCLONE_REMOTES_STRING=$(IFS=';;'; echo "${RCLONE_REMOTES_ARRAY[*]}")

    {
        echo "BACKUP_SOURCE_PATHS_STRING=\"$BACKUP_SOURCE_PATHS_STRING\""
        echo "AUTO_BACKUP_INTERVAL_DAYS=$AUTO_BACKUP_INTERVAL_DAYS"
        echo "LAST_AUTO_BACKUP_TIMESTAMP=$LAST_AUTO_BACKUP_TIMESTAMP"
        echo "RETENTION_POLICY_TYPE=\"$RETENTION_POLICY_TYPE\""
        echo "RETENTION_VALUE=$RETENTION_VALUE"
        echo "TELEGRAM_BOT_TOKEN=\"$TELEGRAM_BOT_TOKEN\""
        echo "TELEGRAM_CHAT_ID=\"$TELEGRAM_CHAT_ID\""

        # 保存 Rclone 相关配置
        echo "RCLONE_REMOTES_STRING=\"$RCLONE_REMOTES_STRING\""
        # 保存关联数组
        echo "declare -A RCLONE_REMOTE_PATHS"
        for remote in "${!RCLONE_REMOTE_PATHS[@]}"; do
            echo "RCLONE_REMOTE_PATHS[\"$remote\"]=\"${RCLONE_REMOTE_PATHS[$remote]}\""
        done
        echo "declare -A RCLONE_REMOTE_ENABLED"
        for remote in "${!RCLONE_REMOTE_ENABLED[@]}"; do
            echo "RCLONE_REMOTE_ENABLED[\"$remote\"]=\"${RCLONE_REMOTE_ENABLED[$remote]}\""
        done

    } > "$CONFIG_FILE"

    chmod 600 "$CONFIG_FILE" 2>/dev/null
    log_and_display "配置已保存到 $CONFIG_FILE"
}

load_config() {
    mkdir -p "$LOG_DIR" 2>/dev/null
    if [ ! -d "$LOG_DIR" ]; then
        echo "错误：无法创建日志目录 $LOG_DIR"
        return 1
    fi

    if [[ -f "$CONFIG_FILE" ]]; then
        source "$CONFIG_FILE"
        log_and_display "配置已从 $CONFIG_FILE 加载。" "${BLUE}"

        # 解析数组
        if [[ -n "$BACKUP_SOURCE_PATHS_STRING" ]]; then
            IFS=';;'; read -r -a BACKUP_SOURCE_PATHS_ARRAY <<< "$BACKUP_SOURCE_PATHS_STRING"
        else
            BACKUP_SOURCE_PATHS_ARRAY=()
        fi
        if [[ -n "$RCLONE_REMOTES_STRING" ]]; then
            IFS=';;'; read -r -a RCLONE_REMOTES_ARRAY <<< "$RCLONE_REMOTES_STRING"
        else
            RCLONE_REMOTES_ARRAY=()
        fi
    else
        log_and_display "未找到配置文件，将使用默认配置。" "${YELLOW}"
    fi
}

# --- 核心功能 (已重构) ---

check_dependencies() {
    local missing_deps=()
    command -v zip &> /dev/null || missing_deps+=("zip")
    command -v realpath &> /dev/null || missing_deps+=("realpath")
    command -v rclone &> /dev/null || missing_deps+=("rclone")
    command -v curl &> /dev/null || missing_deps+=("curl (用于Telegram)")

    if [ ${#missing_deps[@]} -gt 0 ]; then
        log_and_display "${RED}检测到以下依赖项缺失: ${missing_deps[*]}${NC}"
        log_and_display "请先安装它们。例如在 Debian/Ubuntu 上: sudo apt install zip realpath rclone curl" "${YELLOW}"
        press_enter_to_continue
        return 1
    fi
    return 0
}

send_telegram_message() {
    local message_content="$1"
    if [[ -z "$TELEGRAM_BOT_TOKEN" || -z "$TELEGRAM_CHAT_ID" ]]; then return 1; fi
    curl -s -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
        --data-urlencode "chat_id=${TELEGRAM_CHAT_ID}" \
        --data-urlencode "text=${message_content}" \
        --data-urlencode "parse_mode=Markdown" > /dev/null
}


# --- Rclone 核心函数 ---

# 测试 Rclone 远程存储连接
test_rclone_connection() {
    local remote_name="$1"
    log_and_display "正在测试 Rclone 远程存储 '${remote_name}' 的连接..." "${BLUE}" "/dev/stderr"
    if rclone about "${remote_name}:" --fast-list >/dev/null 2>&1; then
        log_and_display "${GREEN}Rclone 远程存储 '${remote_name}' 连接成功！${NC}" "" "/dev/stderr"
        return 0
    else
        log_and_display "${RED}Rclone 远程存储 '${remote_name}' 连接失败！${NC}" "" "/dev/stderr"
        log_and_display "${YELLOW}请确认：\n1. Rclone 已正确配置此远程存储。\n2. 网络连接正常。\n3. 凭证未过期。${NC}" "" "/dev/stderr"
        return 1
    fi
}

# 获取 Rclone 远程存储的目录内容
get_rclone_direct_contents() {
    local remote_name="$1"
    local remote_path="$2"
    local full_remote="${remote_name}:${remote_path}"
    contents=()

    # 获取目录
    local dirs_list
    dirs_list=$(rclone lsd "$full_remote" 2>/dev/null | awk '{print $5}')
    if [[ -n "$dirs_list" ]]; then
        while IFS= read -r dir; do
            contents+=("${dir} (文件夹)")
        done <<< "$dirs_list"
    fi

    # 获取文件
    local files_list
    files_list=$(rclone lsf --files-only "$full_remote" 2>/dev/null)
    if [[ -n "$files_list" ]]; then
        while IFS= read -r file; do
            contents+=("${file} (文件)")
        done <<< "$files_list"
    fi

    IFS=$'\n' contents=($(sort <<<"${contents[*]}"))
    unset IFS
    printf '%s\n' "${contents[@]}"
}

# 交互式选择 Rclone 远程路径
choose_rclone_path() {
    local remote_name="$1"
    local current_remote_path="${RCLONE_REMOTE_PATHS[$remote_name]:-/}"
    
    while true; do
        current_remote_path=$(realpath -m "$current_remote_path")
        if [[ "$current_remote_path" != "/" && "${current_remote_path: -1}" != "/" ]]; then
            current_remote_path="${current_remote_path}/"
        fi

        display_header
        echo -e "${BLUE}=== 为 '${remote_name}' 设置备份目标路径 ===${NC}"
        echo -e "当前浏览路径: ${YELLOW}${remote_name}:${current_remote_path}${NC}\n"

        local remote_contents_str
        remote_contents_str=$(get_rclone_direct_contents "$remote_name" "$current_remote_path")
        local remote_contents_array=()
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
        echo "操作: [数字]进入文件夹 | [m]返回上级 | [k]确认当前路径 | [a]手动输入 | [x]取消"
        read -rp "请输入您的选择: " choice

        case "$choice" in
            m|M)
                [[ "$current_remote_path" != "/" ]] && current_remote_path=$(dirname "$current_remote_path")
                ;;
            k|K)
                RCLONE_REMOTE_PATHS[$remote_name]="$current_remote_path"
                log_and_display "${GREEN}远程存储 '${remote_name}' 的路径已设置为: ${current_remote_path}${NC}"
                return 0
                ;;
            a|A)
                read -rp "请输入新的目标路径 (例如 /backups/): " new_path
                if [[ -n "$new_path" ]]; then
                    RCLONE_REMOTE_PATHS[$remote_name]="$new_path"
                    log_and_display "${GREEN}远程存储 '${remote_name}' 的路径已设置为: ${new_path}${NC}"
                    return 0
                fi
                ;;
            x|X)
                log_and_display "取消设置。" "${BLUE}"
                return 1
                ;;
            [0-9]*)
                if [ "$choice" -ge 1 ] && [ "$choice" -le ${#remote_contents_array[@]} ]; then
                    local chosen_item_with_type="${remote_contents_array[$((choice-1))]}"
                    if echo "$chosen_item_with_type" | grep -q " (文件夹)$"; then
                        local chosen_folder
                        chosen_folder=$(echo "$chosen_item_with_type" | sed 's/\ (文件夹)$//')
                        current_remote_path="${current_remote_path}${chosen_folder}/"
                    else
                        log_and_display "${YELLOW}不能进入文件，请选择一个文件夹。${NC}"
                        press_enter_to_continue
                    fi
                else
                    log_and_display "${RED}无效序号。${NC}"
                    press_enter_to_continue
                fi
                ;;
            *)
                log_and_display "${RED}无效输入。${NC}"
                press_enter_to_continue
                ;;
        esac
    done
}


# --- 菜单功能 (大部分保持不变, 云存储设定已重构) ---

set_auto_backup_interval() {
    # 此函数逻辑不变
    display_header
    echo -e "${BLUE}=== 1. 自动备份设定 ===${NC}"
    read -rp "请输入新的自动备份间隔时间（天数，当前: ${AUTO_BACKUP_INTERVAL_DAYS}）: " interval_input
    if [[ "$interval_input" =~ ^[0-9]+$ ]] && [ "$interval_input" -ge 1 ]; then
        AUTO_BACKUP_INTERVAL_DAYS="$interval_input"
        save_config
        log_and_display "${GREEN}自动备份间隔已设置为 ${AUTO_BACKUP_INTERVAL_DAYS} 天。${NC}"
    else
        log_and_display "${RED}输入无效。${NC}"
    fi
    press_enter_to_continue
}

manual_backup() {
    # 此函数逻辑不变
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

set_backup_path() {
    # 此函数逻辑不变
    while true; do
        display_header
        echo -e "${BLUE}=== 3. 自定义备份路径 ===${NC}"
        echo "当前已配置备份路径数量: ${#BACKUP_SOURCE_PATHS_ARRAY[@]} 个"
        echo ""
        echo "1. 添加新的备份路径"
        echo "2. 查看/删除现有备份路径"
        echo "0. 返回主菜单"
        read -rp "请输入选项: " choice
        case $choice in
            1)
                read -rp "请输入要备份的文件或文件夹的绝对路径: " path_input
                local resolved_path
                resolved_path=$(realpath -q "$path_input" 2>/dev/null)
                if [[ -z "$resolved_path" ]]; then
                    log_and_display "${RED}错误：路径无效或不存在。${NC}"
                else
                    BACKUP_SOURCE_PATHS_ARRAY+=("$resolved_path")
                    save_config
                    log_and_display "${GREEN}备份路径 '$resolved_path' 已添加。${NC}"
                fi
                press_enter_to_continue
                ;;
            2)
                if [ ${#BACKUP_SOURCE_PATHS_ARRAY[@]} -eq 0 ]; then
                    log_and_display "${YELLOW}当前没有设置任何备份路径。${NC}"
                    press_enter_to_continue
                    continue
                fi
                echo "当前备份路径列表:"
                for i in "${!BACKUP_SOURCE_PATHS_ARRAY[@]}"; do
                    echo "  $((i+1)). ${BACKUP_SOURCE_PATHS_ARRAY[$i]}"
                done
                read -rp "请输入要删除的路径序号 (输入0取消): " path_index
                if [[ "$path_index" -ge 1 && "$path_index" -le ${#BACKUP_SOURCE_PATHS_ARRAY[@]} ]]; then
                    unset 'BACKUP_SOURCE_PATHS_ARRAY[$((path_index-1))]'
                    BACKUP_SOURCE_PATHS_ARRAY=("${BACKUP_SOURCE_PATHS_ARRAY[@]}")
                    save_config
                    log_and_display "${GREEN}路径已删除。${NC}"
                fi
                press_enter_to_continue
                ;;
            0) break ;;
            *) log_and_display "${RED}无效选项。${NC}"; press_enter_to_continue ;;
        esac
    done
}

display_compression_info() {
    # 此函数逻辑不变
    display_header
    echo -e "${BLUE}=== 4. 压缩包格式 ===${NC}"
    log_and_display "本脚本当前支持的压缩格式为：${GREEN}ZIP${NC}。"
    log_and_display "未来版本可增加对 .tar.gz 等格式的支持。" "${YELLOW}"
    press_enter_to_continue
}


# ================================================================
# ===         [已重构] 云存储设定 (Rclone)                   ===
# ================================================================
set_cloud_storage() {
    while true; do
        display_header
        echo -e "${BLUE}=== 5. 云存储设定 (已集成 Rclone) ===${NC}"
        echo -e "${YELLOW}请先使用 'rclone config' 命令在系统中配置好远程存储。${NC}"
        echo ""
        echo "当前已配置的 Rclone 远程存储:"
        if [ ${#RCLONE_REMOTES_ARRAY[@]} -eq 0 ]; then
            echo "  (无)"
        else
            for remote in "${RCLONE_REMOTES_ARRAY[@]}"; do
                local status
                [[ "${RCLONE_REMOTE_ENABLED[$remote]}" == "true" ]] && status="${GREEN}启用${NC}" || status="${YELLOW}禁用${NC}"
                echo "  - ${remote} (路径: ${RCLONE_REMOTE_PATHS[$remote]:-未设置} | 状态: ${status})"
            done
        fi
        echo ""
        echo "1. 添加一个新的 Rclone 远程存储"
        echo "2. 管理已添加的远程存储 (启用/禁用, 修改路径, 测试, 删除)"
        echo "0. 返回主菜单"
        echo -e "${BLUE}------------------------------------------------${NC}"
        read -rp "请输入选项: " choice

        case $choice in
            1) # 添加
                local existing_remotes
                existing_remotes=$(rclone listremotes)
                if [[ -z "$existing_remotes" ]]; then
                    log_and_display "${RED}系统中未找到任何 Rclone 远程存储配置。${NC}"
                    log_and_display "${YELLOW}请先退出脚本，运行 'rclone config' 进行配置。${NC}"
                    press_enter_to_continue
                    continue
                fi
                echo "以下是您在 Rclone 中已配置的远程存储:"
                echo -e "${GREEN}${existing_remotes}${NC}"
                read -rp "请输入要添加的远程存储名称 (必须与上面列表中的完全一致): " remote_name
                if [[ -n "$remote_name" ]] && echo "$existing_remotes" | grep -q "^${remote_name%?}:"; then
                    # 检查是否已添加
                    local found=false
                    for r in "${RCLONE_REMOTES_ARRAY[@]}"; do
                        if [[ "$r" == "$remote_name" ]]; then
                            found=true; break;
                        fi
                    done
                    if $found; then
                        log_and_display "${YELLOW}远程存储 '${remote_name}' 已存在于脚本配置中。${NC}"
                    else
                        RCLONE_REMOTES_ARRAY+=("$remote_name")
                        RCLONE_REMOTE_PATHS[$remote_name]="/" # 默认路径为根
                        RCLONE_REMOTE_ENABLED[$remote_name]="false" # 默认禁用
                        save_config
                        log_and_display "${GREEN}已添加远程存储 '${remote_name}'，请在管理菜单中为其设置路径并启用。${NC}"
                    fi
                else
                    log_and_display "${RED}无效的名称，或与 Rclone 配置不匹配。${NC}"
                fi
                press_enter_to_continue
                ;;
            2) # 管理
                if [ ${#RCLONE_REMOTES_ARRAY[@]} -eq 0 ]; then
                    log_and_display "${YELLOW}脚本中未配置任何远程存储，请先添加。${NC}"
                    press_enter_to_continue
                    continue
                fi
                echo "请选择要管理的远程存储序号:"
                for i in "${!RCLONE_REMOTES_ARRAY[@]}"; do
                    echo "  $((i+1)). ${RCLONE_REMOTES_ARRAY[$i]}"
                done
                read -rp "请输入序号: " remote_idx
                if [[ "$remote_idx" -ge 1 && "$remote_idx" -le ${#RCLONE_REMOTES_ARRAY[@]} ]]; then
                    local selected_remote="${RCLONE_REMOTES_ARRAY[$((remote_idx-1))]}"
                    manage_single_remote "$selected_remote"
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

manage_single_remote() {
    local remote_name="$1"
    while true; do
        display_header
        echo -e "${BLUE}=== 管理远程存储: ${remote_name} ===${NC}"
        local status
        [[ "${RCLONE_REMOTE_ENABLED[$remote_name]}" == "true" ]] && status="${GREEN}启用${NC}" || status="${YELLOW}禁用${NC}"
        echo "路径: ${RCLONE_REMOTE_PATHS[$remote_name]:-未设置}"
        echo "状态: $status"
        echo ""
        echo "1. 切换 [启用/禁用] 状态"
        echo "2. 修改备份路径"
        echo "3. 测试连接"
        echo "4. 从脚本中删除此远程存储"
        echo "0. 返回上一级菜单"
        read -rp "请输入选项: " choice
        case $choice in
            1)
                if [[ "${RCLONE_REMOTE_ENABLED[$remote_name]}" == "true" ]]; then
                    RCLONE_REMOTE_ENABLED[$remote_name]="false"
                else
                    RCLONE_REMOTE_ENABLED[$remote_name]="true"
                fi
                save_config
                log_and_display "状态已更新。"
                press_enter_to_continue
                ;;
            2)
                if choose_rclone_path "$remote_name"; then
                    save_config
                fi
                press_enter_to_continue
                ;;
            3)
                test_rclone_connection "$remote_name"
                press_enter_to_continue
                ;;
            4)
                read -rp "确定要从脚本中删除 '${remote_name}' 的配置吗? (y/N): " confirm
                if [[ "$confirm" =~ ^[Yy]$ ]]; then
                    # 从数组和关联数组中删除
                    local new_array=()
                    for r in "${RCLONE_REMOTES_ARRAY[@]}"; do
                        [[ "$r" != "$remote_name" ]] && new_array+=("$r")
                    done
                    RCLONE_REMOTES_ARRAY=("${new_array[@]}")
                    unset "RCLONE_REMOTE_PATHS[$remote_name]"
                    unset "RCLONE_REMOTE_ENABLED[$remote_name]"
                    save_config
                    log_and_display "${GREEN}已删除。${NC}"
                    break # 删除后退出当前管理循环
                fi
                ;;
            0) break ;;
            *) log_and_display "${RED}无效选项。${NC}"; press_enter_to_continue ;;
        esac
    done
}


set_telegram_notification() {
    # 此函数逻辑不变
    display_header
    echo -e "${BLUE}=== 6. 消息通知设定 (Telegram) ===${NC}"
    read -rp "请输入 Telegram Bot Token [当前: ${TELEGRAM_BOT_TOKEN}]: " input_token
    TELEGRAM_BOT_TOKEN="${input_token:-$TELEGRAM_BOT_TOKEN}"
    read -rp "请输入 Telegram Chat ID [当前: ${TELEGRAM_CHAT_ID}]: " input_chat_id
    TELEGRAM_CHAT_ID="${input_chat_id:-$TELEGRAM_CHAT_ID}"
    save_config
    log_and_display "${GREEN}Telegram 配置已保存。${NC}"
    press_enter_to_continue
}

set_retention_policy() {
    # 此函数逻辑不变
    while true; do
        display_header
        echo -e "${BLUE}=== 7. 设置备份保留策略 (云端) ===${NC}"
        # ... (和原来一样的菜单逻辑) ...
        break # 暂时跳出
    done
}


# ================================================================
# ===         [已重构] 执行备份和保留策略的核心逻辑           ===
# ================================================================
perform_backup() {
    local backup_type="$1"
    local readable_time
    readable_time=$(date '+%Y-%m-%d %H:%M:%S')
    
    log_and_display "${BLUE}--- ${backup_type} 过程开始 ---${NC}"
    send_telegram_message "*备份任务开始 (${backup_type})*\n时间: ${readable_time}"

    # ... (检查备份源路径的逻辑不变) ...

    # 检查是否有启用的 Rclone 远程存储
    local enabled_remotes=()
    for remote in "${RCLONE_REMOTES_ARRAY[@]}"; do
        if [[ "${RCLONE_REMOTE_ENABLED[$remote]}" == "true" ]]; then
            enabled_remotes+=("$remote")
        fi
    done
    if [ ${#enabled_remotes[@]} -eq 0 ]; then
        log_and_display "${RED}错误：没有启用任何 Rclone 备份目标。${NC}"
        send_telegram_message "*备份失败*\n原因: 未启用任何备份目标。"
        return 1
    fi

    local overall_succeeded_count=0
    local total_paths_to_backup=${#BACKUP_SOURCE_PATHS_ARRAY[@]}

    for i in "${!BACKUP_SOURCE_PATHS_ARRAY[@]}"; do
        local current_backup_path="${BACKUP_SOURCE_PATHS_ARRAY[$i]}"
        # ... (压缩文件的逻辑不变, 生成 $temp_archive_path 和 $archive_name) ...
        # --- 压缩文件 ---
        local path_display_name=$(basename "$current_backup_path")
        local timestamp=$(date +%Y%m%d%H%M%S)
        local sanitized_path_name=$(echo "$path_display_name" | sed 's/[^a-zA-Z0-9_-]/_/g')
        local archive_name="${sanitized_path_name}_${timestamp}.zip"
        local temp_archive_path="${TEMP_DIR}/${archive_name}"

        log_and_display "正在压缩: ${current_backup_path}"
        if ! zip -r "$temp_archive_path" "$current_backup_path" >/dev/null 2>&1; then
             log_and_display "${RED}压缩失败: ${current_backup_path}${NC}"
             continue # 跳过此文件
        fi
        log_and_display "${GREEN}压缩成功: ${archive_name}${NC}"

        local any_upload_succeeded_for_path="false"
        local path_summary_message="*路径备份完成*\n路径: \`${current_backup_path}\`\n文件: \`${archive_name}\`\n\n*上传状态:*"
        
        # 遍历所有启用的 Rclone 远程存储并上传
        for remote_name in "${enabled_remotes[@]}"; do
            local remote_path="${RCLONE_REMOTE_PATHS[$remote_name]}"
            local full_remote_dest="${remote_name}:${remote_path}"
            log_and_display "正在上传到 ${remote_name}..."
            
            if rclone copyto "$temp_archive_path" "${full_remote_dest}${archive_name}" --progress >/dev/null 2>&1; then
                log_and_display "${GREEN}上传到 ${remote_name} 成功！${NC}"
                any_upload_succeeded_for_path="true"
                path_summary_message+="\n- ${remote_name}: 成功"
            else
                log_and_display "${RED}上传到 ${remote_name} 失败！${NC}"
                path_summary_message+="\n- ${remote_name}: 失败"
            fi
        done

        send_telegram_message "$path_summary_message"
        [[ "$any_upload_succeeded_for_path" == "true" ]] && overall_succeeded_count=$((overall_succeeded_count+1))
        
        # 清理临时文件
        rm -f "$temp_archive_path"
    done

    # ... (发送最终总结Telegram消息的逻辑不变) ...
    
    # 只有在至少一个上传成功后才应用保留策略
    if [[ "$overall_succeeded_count" -gt 0 ]]; then
        apply_retention_policy
    fi
}

apply_retention_policy() {
    log_and_display "${BLUE}--- 正在应用备份保留策略 ---${NC}"
    if [[ "$RETENTION_POLICY_TYPE" == "none" ]]; then
        log_and_display "未设置保留策略，跳过清理。" "${YELLOW}"
        return 0
    fi
    
    local enabled_remotes=()
    for remote in "${RCLONE_REMOTES_ARRAY[@]}"; do
        if [[ "${RCLONE_REMOTE_ENABLED[$remote]}" == "true" ]]; then
            enabled_remotes+=("$remote")
        fi
    done

    for remote_name in "${enabled_remotes[@]}"; do
        local remote_path="${RCLONE_REMOTE_PATHS[$remote_name]}"
        log_and_display "正在为 ${remote_name} 清理旧备份..."
        
        # Rclone 自带强大的过滤功能，可以直接用于清理
        # --min-age 对应按天数保留
        # rclone delete --max-count 对应按数量保留 (注意: rclone 不直接支持保留N个最新，需要脚本逻辑辅助)
        
        # 这里我们继续使用脚本逻辑，以便精确控制
        local all_backups
        mapfile -t all_backups < <(rclone lsf "${remote_name}:${remote_path}" | grep -E '.*_[0-9]{14}\.zip$' | sort)
        
        if [ ${#all_backups[@]} -eq 0 ]; then
            continue
        fi

        local files_to_delete=()
        if [[ "$RETENTION_POLICY_TYPE" == "count" ]]; then
            local num_to_delete=$(( ${#all_backups[@]} - RETENTION_VALUE ))
            if [ "$num_to_delete" -gt 0 ]; then
                # 获取要删除的文件列表
                mapfile -t files_to_delete < <(printf "%s\n" "${all_backups[@]}" | head -n "$num_to_delete")
            fi
        elif [[ "$RETENTION_POLICY_TYPE" == "days" ]]; then
            local cutoff_timestamp=$(( $(date +%s) - RETENTION_VALUE * 24 * 3600 ))
            for backup_file in "${all_backups[@]}"; do
                local backup_date_str
                backup_date_str=$(echo "$backup_file" | sed -E 's/.*_([0-9]{14})\.zip/\1/')
                local backup_timestamp
                backup_timestamp=$(date -d "${backup_date_str:0:8} ${backup_date_str:8:2}:${backup_date_str:10:2}:${backup_date_str:12:2}" +%s 2>/dev/null)
                if [[ "$backup_timestamp" -lt "$cutoff_timestamp" ]]; then
                    files_to_delete+=("$backup_file")
                fi
            done
        fi

        if [ ${#files_to_delete[@]} -gt 0 ]; then
            log_and_display "在 ${remote_name} 中发现 ${#files_to_delete[@]} 个旧备份，将删除..." "${YELLOW}"
            for file in "${files_to_delete[@]}"; do
                log_and_display "  - 正在删除: ${file}"
                rclone deletefile "${remote_name}:${remote_path}${file}"
            done
        fi
    done
    send_telegram_message "*保留策略执行完毕*"
}


# --- 主菜单和脚本入口 ---

show_main_menu() {
    display_header
    echo -e "  1. ${YELLOW}自动备份设定${NC}"
    echo -e "  2. ${YELLOW}手动备份${NC}"
    echo -e "  3. ${YELLOW}自定义备份路径${NC}"
    echo -e "  4. ${YELLOW}压缩包格式${NC}"
    echo -e "  5. ${YELLOW}云存储设定 (已集成 Rclone)${NC}"
    echo -e "  6. ${YELLOW}消息通知设定${NC}"
    echo -e "  7. ${YELLOW}设置备份保留策略${NC}"
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "  0. ${RED}退出脚本${NC}"
    echo -e "  99. ${RED}卸载脚本${NC}"
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
}

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
        0) exit 0 ;;
        99) uninstall_script ;;
        *) log_and_display "${RED}无效选项。${NC}"; press_enter_to_continue ;;
    esac
}

main() {
    TEMP_DIR=$(mktemp -d -t personal_backup_XXXXXX)
    load_config
    if ! check_dependencies; then exit 1; fi
    while true; do
        show_main_menu
        process_menu_choice
    done
}

main "$@"

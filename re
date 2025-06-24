#!/bin/bash
set -e # Exit immediately if a command exits with a non-zero status.

# 脚本全局配置
SCRIPT_NAME="个人自用数据备份 (Rclone)"
# 使用 XDG Base Directory Specification
CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/personal_backup_rclone"
LOG_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/personal_backup_rclone"
CONFIG_FILE="$CONFIG_DIR/config"
LOG_FILE="$LOG_DIR/log.txt"
LOCK_FILE="$CONFIG_DIR/.lock" # [NEW] 锁文件路径

# 默认值 (如果配置文件未找到)
declare -a BACKUP_SOURCE_PATHS_ARRAY=() # 要备份的源路径数组
BACKUP_SOURCE_PATHS_STRING="" # 用于配置文件保存的路径字符串

AUTO_BACKUP_INTERVAL_DAYS=7 # 默认自动备份间隔天数
LAST_AUTO_BACKUP_TIMESTAMP=0 # 上次自动备份的 Unix 时间戳

# 备份保留策略默认值
RETENTION_POLICY_TYPE="none" # "none", "count", "days"
RETENTION_VALUE=0           # 要保留的备份数量或天数

# [NEW] 带宽和打包策略
RCLONE_BWLIMIT="0" # 默认无限制
PACKING_STRATEGY="separate" # "separate" 或 "single"

# --- Rclone 配置 ---
declare -a RCLONE_TARGETS_ARRAY=()
RCLONE_TARGETS_STRING=""
declare -a ENABLED_RCLONE_TARGET_INDICES_ARRAY=()
ENABLED_RCLONE_TARGET_INDICES_STRING=""
declare -a RCLONE_TARGETS_METADATA_ARRAY=()
RCLONE_TARGETS_METADATA_STRING=""


# --- Telegram 通知变量 ---
TELEGRAM_ENABLED="false"
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

# [NEW] 创建锁文件以防止重复执行
create_lock() {
    # 使用 set -C 原子性地创建文件，如果文件已存在则失败
    if (set -C; echo $$ > "$LOCK_FILE") 2>/dev/null; then
        return 0 # 成功创建锁
    else
        local locked_pid
        locked_pid=$(cat "$LOCK_FILE")
        if ! ps -p "$locked_pid" > /dev/null; then
            # 进程不存在，可能是上次异常退出留下的
            log_and_display "发现残留的锁文件，但进程 ($locked_pid) 不存在，正在移除..." "${YELLOW}"
            rm -f "$LOCK_FILE"
            create_lock # 再次尝试创建
        else
            return 1 # 锁有效，脚本已在运行
        fi
    fi
}

# [NEW] 移除锁文件
remove_lock() {
    rm -f "$LOCK_FILE"
}

# 确保在脚本退出时清理临时目录和锁文件
cleanup() {
    remove_lock
    if [[ -n "$TEMP_DIR" && -d "$TEMP_DIR" ]]; then
        rm -rf "$TEMP_DIR"
        echo "$(date '+%Y-%m-%d %H:%M:%S') - 清理临时目录: $TEMP_DIR" >> "$LOG_FILE"
    fi
}

# 注册清理函数
trap cleanup EXIT INT TERM

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

    # 将纯文本消息记录到日志文件
    echo "$(date '+%Y-%m-%d %H:%M:%S') - ${plain_message}" >> "$LOG_FILE"

    # 在标准输出或标准错误中显示带颜色的消息
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
    RCLONE_TARGETS_METADATA_STRING=$(IFS=';;'; echo "${RCLONE_TARGETS_METADATA_ARRAY[*]}")

    {
        echo "BACKUP_SOURCE_PATHS_STRING=\"$BACKUP_SOURCE_PATHS_STRING\""
        echo "AUTO_BACKUP_INTERVAL_DAYS=$AUTO_BACKUP_INTERVAL_DAYS"
        echo "LAST_AUTO_BACKUP_TIMESTAMP=$LAST_AUTO_BACKUP_TIMESTAMP"
        echo "RETENTION_POLICY_TYPE=\"$RETENTION_POLICY_TYPE\""
        echo "RETENTION_VALUE=$RETENTION_VALUE"
        echo "RCLONE_TARGETS_STRING=\"$RCLONE_TARGETS_STRING\""
        echo "ENABLED_RCLONE_TARGET_INDICES_STRING=\"$ENABLED_RCLONE_TARGET_INDICES_STRING\""
        echo "RCLONE_TARGETS_METADATA_STRING=\"$RCLONE_TARGETS_METADATA_STRING\""
        echo "TELEGRAM_ENABLED=\"$TELEGRAM_ENABLED\""
        echo "TELEGRAM_BOT_TOKEN=\"$TELEGRAM_BOT_TOKEN\""
        echo "TELEGRAM_CHAT_ID=\"$TELEGRAM_CHAT_ID\""
        echo "RCLONE_BWLIMIT=\"$RCLONE_BWLIMIT\""
        echo "PACKING_STRATEGY=\"$PACKING_STRATEGY\""
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
        
        if [[ -n "$RCLONE_TARGETS_METADATA_STRING" ]]; then
            IFS=';;'; read -r -a RCLONE_TARGETS_METADATA_ARRAY <<< "$RCLONE_TARGETS_METADATA_STRING"
        fi
        
        # 确保元数据数组和目标数组长度一致，以兼容旧配置文件
        if [[ ${#RCLONE_TARGETS_METADATA_ARRAY[@]} -ne ${#RCLONE_TARGETS_ARRAY[@]} ]]; then
            log_and_display "检测到旧版配置，正在更新目标元数据..." "${YELLOW}"
            local temp_meta_array=()
            for i in "${!RCLONE_TARGETS_ARRAY[@]}"; do
                local meta="${RCLONE_TARGETS_METADATA_ARRAY[$i]:-手动添加}"
                temp_meta_array+=("$meta")
            done
            RCLONE_TARGETS_METADATA_ARRAY=("${temp_meta_array[@]}")
            save_config # 立即保存以更新配置文件
        fi

    else
        log_and_display "未找到配置文件 $CONFIG_FILE，将使用默认配置。" "${YELLOW}"
    fi
}

# --- 核心功能 ---

# [NEW] 检查并尝试交互式安装依赖项
check_dependencies() {
    local missing_deps=()
    local deps_to_check=("zip" "unzip" "realpath" "rclone")
    
    if [[ "$TELEGRAM_ENABLED" == "true" ]]; then
        deps_to_check+=("curl")
    fi

    for dep in "${deps_to_check[@]}"; do
        command -v "$dep" &> /dev/null || missing_deps+=("$dep")
    done

    if [ ${#missing_deps[@]} -gt 0 ]; then
        log_and_display "${RED}检测到以下依赖项缺失: ${missing_deps[*]}${NC}"
        read -rp "是否需要我为您尝试自动安装这些依赖？(y/N): " confirm_install
        if [[ "$confirm_install" =~ ^[Yy]$ ]]; then
            if command -v apt-get &>/dev/null; then
                log_and_display "正在使用 apt-get 安装..." "${BLUE}"
                sudo apt-get update
                sudo apt-get install -y "${missing_deps[@]}"
            elif command -v yum &>/dev/null; then
                 log_and_display "正在使用 yum 安装..." "${BLUE}"
                 sudo yum install -y "${missing_deps[@]}"
            else
                log_and_display "${RED}未找到 apt-get 或 yum，无法自动安装。请手动安装。${NC}"
                return 1
            fi
            # 重新检查
            for dep in "${missing_deps[@]}"; do
                 command -v "$dep" &> /dev/null || { log_and_display "${RED}依赖 '$dep' 安装失败，请手动安装。${NC}"; return 1; }
            done
            log_and_display "${GREEN}所有依赖项已安装成功！${NC}"
        else
            log_and_display "请手动安装缺失的依赖后重试。"
            return 1
        fi
    fi
    return 0
}

# [NEW] 备份前检查临时目录空间
check_temp_space() {
    local total_size_kb=0
    for src_path in "$@"; do
        if [[ -e "$src_path" ]]; then
            total_size_kb=$(( total_size_kb + $(du -sk "$src_path" | awk '{print $1}') ))
        fi
    done
    
    local available_kb
    available_kb=$(df -k "$(dirname "$TEMP_DIR")" | awk 'NR==2{print $4}')
    
    # 增加20%的缓冲
    local required_kb=$(( total_size_kb * 12 / 10 ))

    if (( available_kb < required_kb )); then
        local total_size_hr
        total_size_hr=$(numfmt --to=iec-i --suffix=B --format="%.1f" "$((total_size_kb * 1024))")
        local available_hr
        available_hr=$(numfmt --to=iec-i --suffix=B --format="%.1f" "$((available_kb * 1024))")
        log_and_display "${RED}错误：临时目录空间不足！${NC}"
        log_and_display "需要空间: ~${total_size_hr}，可用空间: ${available_hr}。"
        return 1
    fi
    return 0
}


# 发送 Telegram 消息
send_telegram_message() {
    if [[ "$TELEGRAM_ENABLED" != "true" ]]; then
        return 0 
    fi

    local message_content="$1"
    if [[ -z "$TELEGRAM_BOT_TOKEN" || -z "$TELEGRAM_CHAT_ID" ]]; then
        log_and_display "${YELLOW}Telegram 通知已启用，但凭证未配置，跳过发送消息。${NC}" "" "/dev/stderr"
        return 0 
    fi
    if ! command -v curl &> /dev/null; then
        log_and_display "${RED}错误：发送 Telegram 消息需要 'curl'，但未安装。${NC}" "" "/dev/stderr"
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

# --- 备份与恢复 ---

# 1. 手动备份
manual_backup() {
    display_header
    echo -e "${BLUE}=== 1. 手动备份 ===${NC}"

    if [ ${#BACKUP_SOURCE_PATHS_ARRAY[@]} -eq 0 ]; then
        log_and_display "${RED}错误：没有设置任何备份源路径。${NC}"
        log_and_display "${YELLOW}请先使用选项 [3] 添加要备份的路径。${NC}"
        press_enter_to_continue
        return 1
    fi
    if [ ${#ENABLED_RCLONE_TARGET_INDICES_ARRAY[@]} -eq 0 ]; then
        log_and_display "${RED}错误：没有启用任何 Rclone 备份目标。${NC}"
        log_and_display "${YELLOW}请先使用选项 [4] -> [1] 来配置并启用一个或多个目标。${NC}"
        press_enter_to_continue
        return 1
    fi

    perform_backup "手动备份"
    press_enter_to_continue
}

# 2. 从备份恢复文件
restore_backup() {
    display_header
    echo -e "${BLUE}=== 2. 从云端恢复到本地 ===${NC}"

    if [ ${#ENABLED_RCLONE_TARGET_INDICES_ARRAY[@]} -eq 0 ]; then
        log_and_display "${RED}错误：没有已启用的备份目标可供恢复。${NC}"
        press_enter_to_continue
        return
    fi

    log_and_display "请选择要从哪个目标恢复："
    local enabled_targets=()
    for index in "${ENABLED_RCLONE_TARGET_INDICES_ARRAY[@]}"; do
        enabled_targets+=("${RCLONE_TARGETS_ARRAY[$index]}")
    done

    for i in "${!enabled_targets[@]}"; do
        echo " $((i+1)). ${enabled_targets[$i]}"
    done
    echo " 0. 返回"
    read -rp "请输入选项: " target_choice

    if ! [[ "$target_choice" =~ ^[0-9]+$ ]] || [ "$target_choice" -eq 0 ] || [ "$target_choice" -gt ${#enabled_targets[@]} ]; then
        log_and_display "${RED}无效选项或已取消。${NC}"
        press_enter_to_continue
        return
    fi
    
    local selected_target="${enabled_targets[$((target_choice-1))]}"
    log_and_display "正在从 ${selected_target} 获取备份列表..."
    
    local backup_files_str
    backup_files_str=$(rclone lsf --files-only "${selected_target}" | grep -E '_[0-9]{14}\.zip$' | sort -r)

    if [[ -z "$backup_files_str" ]]; then
        log_and_display "${RED}在 ${selected_target} 中未找到任何备份文件。${NC}"
        press_enter_to_continue
        return
    fi
    
    local backup_files=()
    mapfile -t backup_files <<< "$backup_files_str"
    
    log_and_display "发现以下备份文件（按最新排序）："
    for i in "${!backup_files[@]}"; do
        echo " $((i+1)). ${backup_files[$i]}"
    done
    echo " 0. 返回"
    read -rp "请选择要恢复的备份文件序号: " file_choice

    if ! [[ "$file_choice" =~ ^[0-9]+$ ]] || [ "$file_choice" -eq 0 ] || [ "$file_choice" -gt ${#backup_files[@]} ]; then
        log_and_display "${RED}无效选项或已取消。${NC}"
        press_enter_to_continue
        return
    fi

    local selected_file="${backup_files[$((file_choice-1))]}"
    local remote_file_path="${selected_target}"
    if [[ "${remote_file_path: -1}" != "/" ]]; then
        remote_file_path+="/"
    fi
    remote_file_path+="${selected_file}"

    local temp_archive_path="${TEMP_DIR}/${selected_file}"
    log_and_display "正在下载备份文件: ${selected_file}..." "${YELLOW}"
    if ! rclone copyto "${remote_file_path}" "${temp_archive_path}" --progress; then
        log_and_display "${RED}下载备份文件失败！${NC}"
        press_enter_to_continue
        return
    fi
    log_and_display "${GREEN}下载成功！${NC}"
    
    echo ""
    echo "您想如何处理这个备份文件？"
    echo " 1. 解压到指定目录"
    echo " 2. 仅列出压缩包内容"
    echo " 0. 取消"
    read -rp "请输入选项: " action_choice
    
    case "$action_choice" in
        1)
            read -rp "请输入要解压到的绝对路径 (例如: /root/restore/): " restore_dir
            if [[ -z "$restore_dir" ]]; then
                log_and_display "${RED}路径不能为空！${NC}"
            else
                mkdir -p "$restore_dir"
                log_and_display "正在解压到 ${restore_dir} ..." "${YELLOW}"
                if unzip -o "${temp_archive_path}" -d "${restore_dir}"; then
                     log_and_display "${GREEN}解压完成！${NC}"
                else
                     log_and_display "${RED}解压失败！${NC}"
                fi
            fi
            ;;
        2)
            log_and_display "备份文件 '${selected_file}' 内容如下：" "${BLUE}"
            unzip -l "${temp_archive_path}"
            ;;
        *)
            log_and_display "已取消操作。"
            ;;
    esac
    rm -f "${temp_archive_path}"
    press_enter_to_continue
}


# --- 配置菜单 ---

# 3. 自定义备份路径
manage_sources() {
    while true; do
        display_header
        echo -e "${BLUE}=== 3. 自定义备份源 ===${NC}"
        echo "当前已配置备份路径数量: ${#BACKUP_SOURCE_PATHS_ARRAY[@]} 个"
        echo ""
        echo -e "${BLUE}━━━━━━━━━━━━━━━━━━ 操作选项 ━━━━━━━━━━━━━━━━━━${NC}"
        echo -e "  1. ${YELLOW}添加新的备份路径${NC}"
        echo -e "  2. ${YELLOW}查看/管理现有路径${NC}"
        echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
        echo -e "  0. ${RED}返回主菜单${NC}"
        echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
        read -rp "请输入选项: " choice

        case $choice in
            1) add_backup_path ;;
            2) view_and_manage_backup_paths ;;
            0) break ;;
            *) log_and_display "${RED}无效选项。${NC}"; press_enter_to_continue ;;
        esac
    done
}

add_backup_path() {
    display_header
    echo -e "${BLUE}--- 添加备份路径 ---${NC}"
    read -rp "请输入要备份的文件或文件夹的绝对路径: " path_input

    local resolved_path
    resolved_path=$(realpath -q "$path_input" 2>/dev/null)

    if [[ -z "$resolved_path" ]]; then
        log_and_display "${RED}错误：输入的路径无效或不存在。${NC}"
    elif [[ ! -d "$resolved_path" && ! -f "$resolved_path" ]]; then
        log_and_display "${RED}错误：输入的路径 '$resolved_path' 不是有效的文件/目录。${NC}"
    else
        local found=false
        for p in "${BACKUP_SOURCE_PATHS_ARRAY[@]}"; do
            if [[ "$p" == "$resolved_path" ]]; then
                found=true
                break
            fi
        done

        if "$found"; then
            log_and_display "${YELLOW}该路径 '$resolved_path' 已存在。${NC}"
        else
            BACKUP_SOURCE_PATHS_ARRAY+=("$resolved_path")
            save_config
            log_and_display "${GREEN}备份路径 '$resolved_path' 已添加。${NC}"
        fi
    fi
    press_enter_to_continue
}

view_and_manage_backup_paths() {
    while true; do
        display_header
        echo -e "${BLUE}--- 查看/管理备份路径 ---${NC}"
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
        echo -e "${BLUE}━━━━━━━━━━━━━━━━━━ 操作选项 ━━━━━━━━━━━━━━━━━━${NC}"
        echo -e "  1. ${YELLOW}修改现有路径${NC}"
        echo -e "  2. ${YELLOW}删除路径${NC}"
        echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
        echo -e "  0. ${RED}返回${NC}"
        echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
        read -rp "请输入选项: " sub_choice

        case $sub_choice in
            1) # 修改
                read -rp "请输入要修改的路径序号: " path_index
                if [[ "$path_index" =~ ^[0-9]+$ ]] && [ "$path_index" -ge 1 ] && [ "$path_index" -le ${#BACKUP_SOURCE_PATHS_ARRAY[@]} ]; then
                    local current_path="${BACKUP_SOURCE_PATHS_ARRAY[$((path_index-1))]}"
                    read -rp "修改路径 '${current_path}'。请输入新路径: " new_path_input

                    local resolved_new_path
                    resolved_new_path=$(realpath -q "$new_path_input" 2>/dev/null)

                    if [[ -z "$resolved_new_path" || (! -d "$resolved_new_path" && ! -f "$resolved_new_path") ]]; then
                        log_and_display "${RED}错误：新路径无效或不存在。${NC}"
                    else
                        BACKUP_SOURCE_PATHS_ARRAY[$((path_index-1))]="$resolved_new_path"
                        save_config
                        log_and_display "${GREEN}路径已修改。${NC}"
                    fi
                else
                    log_and_display "${RED}无效序号。${NC}"
                fi
                press_enter_to_continue
                ;;
            2) # 删除
                read -rp "请输入要删除的路径序号: " path_index
                if [[ "$path_index" =~ ^[0-9]+$ ]] && [ "$path_index" -ge 1 ] && [ "$path_index" -le ${#BACKUP_SOURCE_PATHS_ARRAY[@]} ]; then
                    read -rp "确定要删除路径 '${BACKUP_SOURCE_PATHS_ARRAY[$((path_index-1))]}'吗？(y/N): " confirm
                    if [[ "$confirm" =~ ^[Yy]$ ]]; then
                        unset 'BACKUP_SOURCE_PATHS_ARRAY[$((path_index-1))]'
                        BACKUP_SOURCE_PATHS_ARRAY=("${BACKUP_SOURCE_PATHS_ARRAY[@]}")
                        save_config
                        log_and_display "${GREEN}路径已删除。${NC}"
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

# 4. 云存储设定
manage_cloud_targets() {
    while true; do
        display_header
        echo -e "${BLUE}=== 4. 云存储设定 (Rclone) ===${NC}"
        echo -e "${YELLOW}提示: '备份目标' 是 '远程端' + 具体路径 (例如 mydrive:/backups)。${NC}"
        echo -e "${YELLOW}      '远程端' 是您在 Rclone 中的云存储账户配置。${NC}"
        echo ""
        echo -e "${BLUE}━━━━━━━━━━━━━━━━━━ 操作选项 ━━━━━━━━━━━━━━━━━━${NC}"
        echo -e "  1. ${YELLOW}查看、管理和启用备份目标${NC}"
        echo -e "  2. ${YELLOW}[助手] 创建新的 Rclone 远程端${NC}"
        echo -e "  3. ${YELLOW}测试 Rclone 远程端连接${NC}"
        echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
        echo -e "  0. ${RED}返回主菜单${NC}"
        echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
        read -rp "请输入选项: " choice

        case $choice in
            1) view_and_manage_rclone_targets ;;
            2) create_rclone_remote_wizard ;;
            3) test_rclone_remotes ;;
            0) break ;;
            *) log_and_display "${RED}无效选项。${NC}"; press_enter_to_continue ;;
        esac
    done
}

# 5. 自动备份与计划任务
manage_automation() {
    while true; do
        display_header
        echo -e "${BLUE}=== 5. 自动备份与计划任务 ===${NC}"
        echo -e "  1. ${YELLOW}设置自动备份间隔${NC} (当前: ${AUTO_BACKUP_INTERVAL_DAYS} 天)"
        echo -e "  2. ${YELLOW}[助手] 配置 Cron 定时任务${NC}"
        echo ""
        echo -e "  0. ${RED}返回主菜单${NC}"
        read -rp "请输入选项: " choice
        
        case $choice in
            1) set_auto_backup_interval ;;
            2) setup_cron_job ;;
            0) break ;;
            *) log_and_display "${RED}无效选项。${NC}"; press_enter_to_continue ;;
        esac
    done
}

set_auto_backup_interval() {
    display_header
    echo -e "${BLUE}--- 设置自动备份间隔 ---${NC}"
    read -rp "请输入新的自动备份间隔时间（天数，最小1天）[当前: ${AUTO_BACKUP_INTERVAL_DAYS}]: " interval_input
    if [[ "$interval_input" =~ ^[0-9]+$ ]] && [ "$interval_input" -ge 1 ]; then
        AUTO_BACKUP_INTERVAL_DAYS="$interval_input"
        save_config
        log_and_display "${GREEN}自动备份间隔已成功设置为：${AUTO_BACKUP_INTERVAL_DAYS} 天。${NC}"
    else
        log_and_display "${RED}输入无效。${NC}"
    fi
    press_enter_to_continue
}

setup_cron_job() {
    display_header
    echo -e "${BLUE}--- Cron 定时任务助手 ---${NC}"
    echo "此助手可以帮助您添加一个系统的定时任务，以实现无人值守自动备份。"
    echo -e "${YELLOW}脚本将每天在您指定的时间运行一次，并根据您设置的间隔天数决定是否执行备份。${NC}"
    
    read -rp "请输入您希望每天执行检查的时间 (24小时制, HH:MM, 例如 03:00): " cron_time
    if ! [[ "$cron_time" =~ ^([01][0-9]|2[0-3]):[0-5][0-9]$ ]]; then
        log_and_display "${RED}时间格式无效！请输入 HH:MM 格式。${NC}"
        press_enter_to_continue
        return
    fi
    
    local cron_minute="${cron_time#*:}"
    local cron_hour="${cron_time%%:*}"
    
    # 确保分钟和小时的前导零被正确处理
    cron_minute=$(printf "%d" "$cron_minute")
    cron_hour=$(printf "%d" "$cron_hour")

    local script_path
    script_path=$(readlink -f "$0")
    local cron_command="${cron_minute} ${cron_hour} * * * ${script_path} check_auto_backup >/dev/null 2>&1"
    
    # 检查是否已存在相同的任务
    if crontab -l 2>/dev/null | grep -qF "$script_path check_auto_backup"; then
        log_and_display "${YELLOW}检测到已存在此脚本的定时任务。${NC}"
        read -rp "您想用新的时间设置覆盖它吗？(y/N): " confirm_replace
        if [[ "$confirm_replace" =~ ^[Yy]$ ]]; then
            # 移除旧的，添加新的
            local temp_crontab
            temp_crontab=$(crontab -l 2>/dev/null | grep -vF "$script_path check_auto_backup")
            (echo "${temp_crontab}"; echo "$cron_command") | crontab -
            log_and_display "${GREEN}定时任务已更新！${NC}"
        else
            log_and_display "已取消操作。"
        fi
    else
        # 直接添加新的
        (crontab -l 2>/dev/null; echo "$cron_command") | crontab -
        log_and_display "${GREEN}定时任务添加成功！${NC}"
    fi

    log_and_display "您可以使用 'crontab -l' 命令查看所有定时任务。"
    press_enter_to_continue
}

# 6. 策略设置
manage_policies() {
     while true; do
        display_header
        echo -e "${BLUE}=== 6. 高级策略 ===${NC}"
        echo -e "  1. ${YELLOW}设置备份保留策略${NC}"
        echo -e "  2. ${YELLOW}设置打包与压缩策略${NC}"
        echo -e "  3. ${YELLOW}设置上传带宽限制${NC}"
        echo ""
        echo -e "  0. ${RED}返回主菜单${NC}"
        read -rp "请输入选项: " choice
        
        case $choice in
            1) set_retention_policy ;;
            2) set_packing_strategy ;;
            3) set_bandwidth_limit ;;
            0) break ;;
            *) log_and_display "${RED}无效选项。${NC}"; press_enter_to_continue ;;
        esac
    done
}

set_retention_policy() {
    while true; do
        display_header
        echo -e "${BLUE}--- 设置备份保留策略 ---${NC}"
        echo "当前策略: "
        case "$RETENTION_POLICY_TYPE" in
            "none") echo -e "  ${YELLOW}无保留策略（所有备份将保留）${NC}" ;;
            "count") echo -e "  ${YELLOW}保留最新 ${RETENTION_VALUE} 个备份${NC}" ;;
            "days")  echo -e "  ${YELLOW}保留最近 ${RETENTION_VALUE} 天内的备份${NC}" ;;
            *)       echo -e "  ${YELLOW}未知策略或未设置${NC}" ;;
        esac
        echo ""
        echo -e "${BLUE}━━━━━━━━━━━━━━━━━━ 操作选项 ━━━━━━━━━━━━━━━━━━${NC}"
        echo -e "  1. ${YELLOW}设置按数量保留 (例: 保留最新的 5 个)${NC}"
        echo -e "  2. ${YELLOW}设置按天数保留 (例: 保留最近 30 天)${NC}"
        echo -e "  3. ${YELLOW}关闭保留策略${NC}"
        echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
        echo -e "  0. ${RED}返回${NC}"
        echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
        read -rp "请输入选项: " sub_choice

        case $sub_choice in
            1)
                read -rp "请输入要保留的备份数量 (例如 5): " value_input
                if [[ "$value_input" =~ ^[0-9]+$ ]] && [ "$value_input" -ge 1 ]; then
                    RETENTION_POLICY_TYPE="count"
                    RETENTION_VALUE="$value_input"
                    save_config
                    log_and_display "${GREEN}已设置保留最新 ${RETENTION_VALUE} 个备份。${NC}"
                else
                    log_and_display "${RED}输入无效。${NC}"
                fi
                press_enter_to_continue
                ;;
            2)
                read -rp "请输入要保留备份的天数 (例如 30): " value_input
                if [[ "$value_input" =~ ^[0-9]+$ ]] && [ "$value_input" -ge 1 ]; then
                    RETENTION_POLICY_TYPE="days"
                    RETENTION_VALUE="$value_input"
                    save_config
                    log_and_display "${GREEN}已设置保留最近 ${RETENTION_VALUE} 天。${NC}"
                else
                    log_and_display "${RED}输入无效。${NC}"
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
            0) break ;;
            *) log_and_display "${RED}无效选项。${NC}"; press_enter_to_continue ;;
        esac
    done
}

set_packing_strategy() {
    display_header
    echo -e "${BLUE}--- 设置打包策略 ---${NC}"
    local current_strategy_text="未知"
    if [[ "$PACKING_STRATEGY" == "separate" ]]; then
        current_strategy_text="每个源单独打包"
    elif [[ "$PACKING_STRATEGY" == "single" ]]; then
        current_strategy_text="所有源打包成一个文件"
    fi
    echo "当前策略: $current_strategy_text"
    echo ""
    echo "1. 每个源单独打包 (默认, 推荐)"
    echo "2. 所有源打包成一个文件"
    read -rp "请输入选项: " choice
    case $choice in
        1) PACKING_STRATEGY="separate" ;;
        2) PACKING_STRATEGY="single" ;;
        *) log_and_display "${RED}无效选项，未作更改。${NC}"; press_enter_to_continue; return ;;
    esac
    save_config
    log_and_display "${GREEN}打包策略已更新！${NC}"
    press_enter_to_continue
}

set_bandwidth_limit() {
    display_header
    echo -e "${BLUE}--- 设置上传带宽限制 ---${NC}"
    echo "此设置可以限制 Rclone 上传时占用的带宽，以避免影响服务器上的其他服务。"
    echo "格式为 数字+单位，例如 8M (8 MByte/s), 512k (512 KByte/s)。"
    echo -e "输入 ${YELLOW}0${NC} 表示不限制。"
    
    read -rp "请输入新的带宽限制 [当前: ${RCLONE_BWLIMIT}]: " bw_input
    if [[ "$bw_input" =~ ^[0-9]+([kKmM]?)?$ ]]; then
        RCLONE_BWLIMIT="$bw_input"
        save_config
        if [[ "$RCLONE_BWLIMIT" == "0" ]]; then
            log_and_display "${GREEN}已取消带宽限制。${NC}"
        else
            log_and_display "${GREEN}带宽限制已设置为 ${RCLONE_BWLIMIT}。${NC}"
        fi
    else
        log_and_display "${RED}输入格式无效，未作更改。${NC}"
    fi
    press_enter_to_continue
}

# 7. 设置 Telegram 通知设定
set_telegram_notification() {
    local needs_saving="false"
    while true; do
        display_header
        echo -e "${BLUE}=== 7. 消息通知 ===${NC}"
        
        local status_text
        if [[ "$TELEGRAM_ENABLED" == "true" ]]; then
            status_text="${GREEN}已启用${NC}"
        else
            status_text="${YELLOW}已禁用${NC}"
        fi
        echo -e "当前状态: ${status_text}"
        echo -e "Bot Token: ${TELEGRAM_BOT_TOKEN}"
        echo -e "Chat ID:   ${TELEGRAM_CHAT_ID}"
        echo ""
        
        echo -e "${BLUE}━━━━━━━━━━━━━━━━━━ 操作选项 ━━━━━━━━━━━━━━━━━━${NC}"
        if [[ "$TELEGRAM_ENABLED" == "true" ]]; then
            echo -e "  1. ${YELLOW}禁用通知${NC}"
        else
            echo -e "  1. ${GREEN}启用通知${NC}"
        fi
        echo -e "  2. ${YELLOW}设置/修改凭证 (Token 和 Chat ID)${NC}"
        echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
        echo -e "  0. ${RED}保存并返回${NC}"
        echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
        read -rp "请输入选项: " choice

        case $choice in
            1) # 启用/禁用
                if [[ "$TELEGRAM_ENABLED" == "true" ]]; then
                    TELEGRAM_ENABLED="false"
                    log_and_display "Telegram 通知已禁用。" "${YELLOW}"
                else
                    TELEGRAM_ENABLED="true"
                    log_and_display "Telegram 通知已启用。" "${GREEN}"
                fi
                needs_saving="true"
                press_enter_to_continue
                ;;
            2) # 设置凭证
                log_and_display "${YELLOW}凭证将保存到本地配置文件！${NC}"
                read -rp "请输入新的 Telegram Bot Token [留空不修改]: " input_token
                TELEGRAM_BOT_TOKEN="${input_token:-$TELEGRAM_BOT_TOKEN}"

                read -rp "请输入新的 Telegram Chat ID [留空不修改]: " input_chat_id
                TELEGRAM_CHAT_ID="${input_chat_id:-$TELEGRAM_CHAT_ID}"

                log_and_display "${GREEN}Telegram 凭证已更新。${NC}"
                needs_saving="true"
                press_enter_to_continue
                ;;
            0) # 返回
                if [[ "$needs_saving" == "true" ]]; then
                    save_config
                    log_and_display "Telegram 设置已保存。" "${BLUE}"
                fi
                break
                ;;
            *)
                log_and_display "${RED}无效选项。${NC}"
                press_enter_to_continue
                ;;
        esac
    done
}


# --- 维护菜单 ---

# 8. Rclone 安装/卸载管理
manage_rclone_installation() {
    while true; do
        display_header
        echo -e "${BLUE}=== 8. Rclone 安装/卸载 ===${NC}"
        
        if command -v rclone &> /dev/null; then
            local rclone_version
            rclone_version=$(rclone --version | head -n 1)
            echo -e "当前状态: ${GREEN}已安装${NC} (版本: ${rclone_version})"
        else
            echo -e "当前状态: ${RED}未安装${NC}"
        fi
        echo ""

        echo -e "${BLUE}━━━━━━━━━━━━━━━━━━ 操作选项 ━━━━━━━━━━━━━━━━━━${NC}"
        echo -e "  1. ${YELLOW}安装或更新 Rclone${NC}"
        echo -e "  2. ${YELLOW}卸载 Rclone${NC}"
        echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
        echo -e "  0. ${RED}返回主菜单${NC}"
        echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
        read -rp "请输入选项: " choice

        case $choice in
            1)
                log_and_display "正在从 rclone.org 下载并执行官方安装脚本..." "${BLUE}"
                if curl https://rclone.org/install.sh | sudo bash; then
                    log_and_display "${GREEN}Rclone 安装/更新成功！${NC}"
                else
                    log_and_display "${RED}Rclone 安装/更新失败，请检查网络或 sudo 权限。${NC}"
                fi
                press_enter_to_continue
                ;;
            2)
                if ! command -v rclone &> /dev/null; then
                    log_and_display "${YELLOW}Rclone 未安装，无需卸载。${NC}"
                    press_enter_to_continue
                    continue
                fi
                read -rp "警告: 这将从系统中移除 Rclone 本体程序。本脚本将无法工作，确定吗？(y/N): " confirm
                if [[ "$confirm" =~ ^[Yy]$ ]]; then
                    log_and_display "正在卸载 Rclone..."
                    sudo rm -f /usr/bin/rclone /usr/local/bin/rclone
                    sudo rm -f /usr/local/share/man/man1/rclone.1
                    log_and_display "${GREEN}Rclone 已卸载。${NC}"
                else
                    log_and_display "已取消卸载。" "${BLUE}"
                fi
                press_enter_to_continue
                ;;
            0)
                break
                ;;
            *)
                log_and_display "${RED}无效选项。${NC}"
                press_enter_to_continue
                ;;
        esac
    done
}

# 9. 配置导入/导出助手
manage_config_import_export() {
    display_header
    echo -e "${BLUE}=== 9. [助手] 配置导入/导出 ===${NC}"
    echo "此功能可将当前所有设置导出为便携文件，或从文件导入。"
    echo ""
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━ 操作选项 ━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "  1. ${YELLOW}导出配置到文件${NC}"
    echo -e "  2. ${YELLOW}从文件导入配置${NC}"
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "  0. ${RED}返回主菜单${NC}"
    read -rp "请输入选项: " choice

    case $choice in
        1) # 导出
            local export_file
            export_file="$(dirname "$0")/personal_backup.conf"
            read -rp "确定要将当前配置导出到 ${export_file} 吗？(Y/n): " confirm_export
            if [[ ! "$confirm_export" =~ ^[Nn]$ ]]; then
                # 先保存一次，确保导出的是最新内存中的配置
                save_config &> /dev/null
                cp "$CONFIG_FILE" "$export_file"
                log_and_display "${GREEN}配置已成功导出到: ${export_file}${NC}"
            else
                log_and_display "已取消导出。"
            fi
            press_enter_to_continue
            ;;
        2) # 导入
            read -rp "请输入配置文件的绝对路径: " import_file
            if [[ -f "$import_file" ]]; then
                read -rp "${RED}警告：这将覆盖当前所有设置！确定要从 '${import_file}' 导入吗？(y/N): ${NC}" confirm_import
                if [[ "$confirm_import" =~ ^[Yy]$ ]]; then
                    # 备份当前配置
                    if [[ -f "$CONFIG_FILE" ]]; then
                        cp "$CONFIG_FILE" "${CONFIG_FILE}.bak"
                        log_and_display "当前配置已备份到 ${CONFIG_FILE}.bak" "${YELLOW}"
                    fi
                    # 导入新配置
                    cp "$import_file" "$CONFIG_FILE"
                    log_and_display "${GREEN}配置导入成功！请重启脚本以使新配置生效。${NC}"
                    press_enter_to_continue
                    exit 0
                else
                    log_and_display "已取消导入。"
                fi
            else
                log_and_display "${RED}错误：文件 '${import_file}' 不存在。${NC}"
            fi
            press_enter_to_continue
            ;;
        0) ;;
        *) log_and_display "${RED}无效选项。${NC}"; press_enter_to_continue ;;
    esac
}

# 99. 卸载脚本
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

    # [NEW] 状态总览面板
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━ 状态总览 ━━━━━━━━━━━━━━━━━━━${NC}"
    local last_backup_str="从未"
    if [[ "$LAST_AUTO_BACKUP_TIMESTAMP" -ne 0 ]]; then
        last_backup_str=$(date -d "@$LAST_AUTO_BACKUP_TIMESTAMP" '+%Y-%m-%d %H:%M:%S')
    fi
    echo -e "上次备份: ${last_backup_str}"
    local next_backup_str="取决于间隔设置"
    if [[ "$LAST_AUTO_BACKUP_TIMESTAMP" -ne 0 ]]; then
        local next_ts=$((LAST_AUTO_BACKUP_TIMESTAMP + AUTO_BACKUP_INTERVAL_DAYS * 86400))
        next_backup_str=$(date -d "@$next_ts" '+%Y-%m-%d %H:%M:%S')
    fi
    echo -e "下次预估: ${next_backup_str}"
    echo -e "备份源: ${#BACKUP_SOURCE_PATHS_ARRAY[@]} 个路径   已启用目标: ${#ENABLED_RCLONE_TARGET_INDICES_ARRAY[@]} 个"

    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━ 核心操作 ━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "  1. ${YELLOW}手动备份${NC}"
    echo -e "  2. ${YELLOW}从云端恢复到本地${NC}"
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━ 配置中心 ━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "  3. ${YELLOW}备份源路径${NC} (数量: ${#BACKUP_SOURCE_PATHS_ARRAY[@]})"
    echo -e "  4. ${YELLOW}云存储目标${NC} (Rclone)"
    echo -e "  5. ${YELLOW}自动化与计划任务${NC} (间隔: ${AUTO_BACKUP_INTERVAL_DAYS} 天)"
    
    local retention_status_text="已禁用"
    if [[ "$RETENTION_POLICY_TYPE" != "none" ]]; then
        retention_status_text="已启用"
    fi
    local packing_strategy_text="独立打包"
    if [[ "$PACKING_STRATEGY" == "single" ]]; then
        packing_strategy_text="合并打包"
    fi
    local bwlimit_text="无限制"
    if [[ "$RCLONE_BWLIMIT" != "0" ]]; then
        bwlimit_text="${RCLONE_BWLIMIT}"
    fi
    echo -e "  6. ${YELLOW}高级策略${NC} (保留: ${retention_status_text}, 打包: ${packing_strategy_text}, 限速: ${bwlimit_text})"

    local telegram_status_text
    if [[ "$TELEGRAM_ENABLED" == "true" ]]; then
        telegram_status_text="已启用"
    else
        telegram_status_text="已禁用"
    fi
    echo -e "  7. ${YELLOW}消息通知${NC} (Telegram, 当前: ${telegram_status_text})"

    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━ 系统维护 ━━━━━━━━━━━━━━━━━━━${NC}"
    local rclone_version_text
    if command -v rclone &> /dev/null; then
        local rclone_version
        rclone_version=$(rclone --version | head -n 1)
        rclone_version_text="(${rclone_version})"
    else
        rclone_version_text="(未安装)"
    fi
    echo -e "  8. ${YELLOW}Rclone 安装/卸载${NC} ${rclone_version_text}"
    echo -e "  9. ${YELLOW}[助手] 配置导入/导出${NC}"
    
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "  0. ${RED}退出脚本${NC}"
    echo -e "  99. ${RED}卸载脚本${NC}"
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
}

# 处理菜单选择
process_menu_choice() {
    read -rp "请输入选项: " choice
    case $choice in
        1) manual_backup ;;
        2) restore_backup ;;
        3) manage_sources ;;
        4) manage_cloud_targets ;;
        5) manage_automation ;;
        6) manage_policies ;;
        7) set_telegram_notification ;;
        8) manage_rclone_installation ;; 
        9) manage_config_import_export ;;
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
        if ! create_lock; then
            log_and_display "Cron 任务中止：脚本已在运行。" "${YELLOW}"
            exit 1
        fi
        log_and_display "由 Cron 任务触发自动备份检查。" "${BLUE}"
        check_auto_backup
        exit 0
    fi
    
    if ! create_lock; then
        log_and_display "${RED}错误：脚本的另一个实例正在运行。${NC}"
        exit 1
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

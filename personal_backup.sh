#!/bin/bash
set -e # Exit immediately if a command exits with a non-zero status.

# 脚本全局配置
SCRIPT_NAME="个人自用数据备份 (Rclone)"
# 使用 XDG Base Directory Specification
CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/personal_backup_rclone"
LOG_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/personal_backup_rclone"
CONFIG_FILE="$CONFIG_DIR/config"
LOG_FILE="$LOG_DIR/log.txt"
LOCK_FILE="$CONFIG_DIR/script.lock"

# JSON 配置文件路径
TELEGRAM_BOTS_CONFIG_FILE="$CONFIG_DIR/telegram_bots.json"
EMAIL_SENDERS_CONFIG_FILE="$CONFIG_DIR/email_senders.json"


# 日志轮转配置 (8MB)
LOG_MAX_SIZE_BYTES=8388608

# --- 日志级别定义 ---
# 值越小，级别越低，输出越详细
LOG_LEVEL_DEBUG=1
LOG_LEVEL_INFO=2
LOG_LEVEL_WARN=3
LOG_LEVEL_ERROR=4

# 默认值 (如果配置文件未找到)
declare -a BACKUP_SOURCE_PATHS_ARRAY=() # 要备份的源路径数组
BACKUP_SOURCE_PATHS_STRING="" # 用于配置文件保存的路径字符串
PACKAGING_STRATEGY="separate" # "separate" (独立打包) or "single" (合并打包)

# 新增功能配置
BACKUP_MODE="archive"         # "archive" (归档模式) or "sync" (同步模式)
ENABLE_INTEGRITY_CHECK="true" # "true" or "false"，备份后完整性校验

# 压缩格式配置
COMPRESSION_FORMAT="zip"      # "zip" or "tar.gz"
COMPRESSION_LEVEL=6           # 1 (fastest) to 9 (best)
ZIP_PASSWORD=""               # Password for zip files, empty for none

# 日志与维护配置
CONSOLE_LOG_LEVEL=$LOG_LEVEL_INFO # 终端输出的日志级别
FILE_LOG_LEVEL=$LOG_LEVEL_DEBUG   # 文件记录的日志级别
ENABLE_SPACE_CHECK="true"         # [新增] "true" or "false", 备份前临时空间检查


AUTO_BACKUP_INTERVAL_DAYS=7 # 默认自动备份间隔天数
LAST_AUTO_BACKUP_TIMESTAMP=0 # 上次自动备份的 Unix 时间戳

# 备份保留策略默认值
RETENTION_POLICY_TYPE="none" # "none", "count", "days"
RETENTION_VALUE=0            # 要保留的备份数量或天数

# --- Rclone 配置 ---
declare -a RCLONE_TARGETS_ARRAY=()
RCLONE_TARGETS_STRING=""
declare -a ENABLED_RCLONE_TARGET_INDICES_ARRAY=()
ENABLED_RCLONE_TARGET_INDICES_STRING=""
declare -a RCLONE_TARGETS_METADATA_ARRAY=()
RCLONE_TARGETS_METADATA_STRING=""
RCLONE_BWLIMIT="" # 带宽限制 (例如 "8M" 代表 8 MByte/s)

# [新增] 通知报告生成用的全局变量
GLOBAL_NOTIFICATION_REPORT_BODY=""
GLOBAL_NOTIFICATION_FAILURE_REASON=""
GLOBAL_NOTIFICATION_OVERALL_STATUS="success"


# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m' # 无颜色

# 临时目录
TEMP_DIR=""

# --- 辅助函数 ---

# [新增] 初始化目录，确保脚本所需路径存在
initialize_directories() {
    # 使用 mkdir -p 可以安全地创建目录，如果目录已存在则什么也不做。
    # 这是解决新设备上首次运行脚本时 "No such file or directory" 错误的关键。
    if ! mkdir -p "$CONFIG_DIR" 2>/dev/null; then
        # 在日志系统完全工作前，只能用 echo 输出到标准错误流
        echo -e "${RED}[ERROR] 无法创建配置目录: $CONFIG_DIR。请检查权限。${NC}" >&2
        exit 1
    fi
    if ! mkdir -p "$LOG_DIR" 2>/dev/null; then
        echo -e "${RED}[ERROR] 无法创建日志目录: $LOG_DIR。请检查权限。${NC}" >&2
        exit 1
    fi
}


# 确保在脚本退出时清理临时目录和锁文件
cleanup() {
    if [[ -n "$TEMP_DIR" && -d "$TEMP_DIR" ]]; then
        rm -rf "$TEMP_DIR"
        log_debug "清理临时目录: $TEMP_DIR"
    fi
    if [ -f "$LOCK_FILE" ] && [ "$(cat "$LOCK_FILE")" -eq "$$" ]; then
        rm -f "$LOCK_FILE"
        log_debug "移除进程锁: $LOCK_FILE"
    fi
}

# 注册清理函数
trap cleanup EXIT SIGINT SIGTERM

# [NEW] 日志核心函数
_log() {
    local level_value=$1
    local level_name=$2
    local color=$3
    local message="$4"
    local plain_message
    plain_message=$(echo -e "$message" | sed 's/\x1b\[[0-9;]*m//g')

    # 写入日志文件
    if [[ $level_value -ge $FILE_LOG_LEVEL ]]; then
        # '>>' 操作符会自动创建文件（如果目录存在）
        echo "$(date '+%Y-%m-%d %H:%M:%S') [${level_name}] - ${plain_message}" >> "$LOG_FILE"
    fi

    # 输出到终端
    if [[ $level_value -ge $CONSOLE_LOG_LEVEL ]]; then
        echo -e "${color}[${level_name}] ${message}${NC}"
    fi
}

log_debug() { _log $LOG_LEVEL_DEBUG "DEBUG" "${BLUE}" "$1"; }
log_info() { _log $LOG_LEVEL_INFO "INFO" "${GREEN}" "$1"; }
log_warn() { _log $LOG_LEVEL_WARN "WARN" "${YELLOW}" "$1"; }
log_error() { _log $LOG_LEVEL_ERROR "ERROR" "${RED}" "$1"; }


# 进程锁功能
acquire_lock() {
    if [ -e "$LOCK_FILE" ]; then
        local old_pid
        old_pid=$(cat "$LOCK_FILE")
        if ps -p "$old_pid" > /dev/null; then
            log_error "另一个脚本实例 (PID: $old_pid) 正在运行。已退出。"
            exit 1
        else
            log_warn "发现一个过期的锁文件 (PID: $old_pid)，已自动移除。"
            rm -f "$LOCK_FILE"
        fi
    fi
    # '>' 操作符会自动创建文件（如果目录存在）
    echo $$ > "$LOCK_FILE"
}

# 日志文件轮转功能
rotate_log_if_needed() {
    if [[ ! -f "$LOG_FILE" ]]; then
        touch "$LOG_FILE"
        return
    fi

    local log_size
    log_size=$(stat -c%s "$LOG_FILE" 2>/dev/null || echo 0)

    if (( log_size > LOG_MAX_SIZE_BYTES )); then
        local rotated_log_file="${LOG_FILE}.$(date +%Y%m%d-%H%M%S).rotated"
        log_warn "日志文件已轮转 (超过 8MB)，旧日志已保存为 ${rotated_log_file}。"
        mv "$LOG_FILE" "${rotated_log_file}"
        touch "$LOG_FILE"
    fi
}


# 清屏
clear_screen() {
    clear
}

# 显示脚本头部
display_header() {
    clear_screen
    echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${GREEN}        $SCRIPT_NAME        ${NC}"
    echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
}

# 等待用户按 Enter 键继续
press_enter_to_continue() {
    echo ""
    echo -e "${BLUE}按 Enter 键继续...${NC}"
    read -r
    clear_screen
}

# --- 获取 Cron 任务信息 ---
get_cron_job_info() {
    local script_path
    script_path=$(readlink -f "$0")
    # 从 crontab 中查找包含脚本路径和特定命令的行
    local cron_job
    cron_job=$(crontab -l 2>/dev/null | grep -F "$script_path check_auto_backup")
    
    if [[ -n "$cron_job" ]]; then
        # 提取 cron 表达式 (前五个字段)
        echo "$cron_job" | awk '{print $1,$2,$3,$4,$5}'
    else
        echo "未设置"
    fi
}

# [重构 & 修复] 将 Cron 表达式转化为易于理解的说明
parse_cron_to_human() {
    local cron_string="$1"
    if [[ "$cron_string" == "未设置" ]]; then
        echo "未设置"
        return
    fi
    
    # 使用 awk 来健壮地解析，无论有多少空格
    local minute hour day_of_month month day_of_week
    minute=$(echo "$cron_string" | awk '{print $1}')
    hour=$(echo "$cron_string" | awk '{print $2}')
    day_of_month=$(echo "$cron_string" | awk '{print $3}')
    month=$(echo "$cron_string" | awk '{print $4}')
    day_of_week=$(echo "$cron_string" | awk '{print $5}')

    # 仅处理 'M H * * *' 这种由本脚本创建的简单格式
    if [[ "$day_of_month" == "*" && "$month" == "*" && "$day_of_week" == "*" && "$minute" =~ ^[0-9]+$ && "$hour" =~ ^[0-9]+$ ]]; then
        # [FIX] 强制使用 10 进制处理小时和分钟，避免 08, 09 被当作无效八进制数
        local hour_decimal=$((10#$hour))
        local minute_decimal=$((10#$minute))
        
        local formatted_hour=$(printf "%02d" "$hour_decimal")
        local formatted_minute=$(printf "%02d" "$minute_decimal")
        
        local period="凌晨"
        if (( hour_decimal >= 6 && hour_decimal < 12 )); then period="早上";
        elif (( hour_decimal >= 12 && hour_decimal < 13 )); then period="中午";
        elif (( hour_decimal >= 13 && hour_decimal < 18 )); then period="下午";
        elif (( hour_decimal >= 18 && hour_decimal < 24 )); then period="晚上";
        fi

        echo "每天${period} ${formatted_hour} 点 ${formatted_minute} 分"
    else
        # 对于更复杂的 cron 表达式，直接返回原始值
        echo "$cron_string"
    fi
}


# --- 配置保存和加载 ---

# 保存配置到文件
save_config() {
    if [ ! -d "$CONFIG_DIR" ]; then
        log_error "配置目录 $CONFIG_DIR 不存在或不是一个目录。请检查权限。"
        return 1
    fi

    BACKUP_SOURCE_PATHS_STRING=$(IFS=';;'; echo "${BACKUP_SOURCE_PATHS_ARRAY[*]}")
    RCLONE_TARGETS_STRING=$(IFS=';;'; echo "${RCLONE_TARGETS_ARRAY[*]}")
    ENABLED_RCLONE_TARGET_INDICES_STRING=$(IFS=';;'; echo "${ENABLED_RCLONE_TARGET_INDICES_ARRAY[*]}")
    RCLONE_TARGETS_METADATA_STRING=$(IFS=';;'; echo "${RCLONE_TARGETS_METADATA_ARRAY[*]}")

    {
        echo "BACKUP_SOURCE_PATHS_STRING=\"$BACKUP_SOURCE_PATHS_STRING\""
        echo "PACKAGING_STRATEGY=\"$PACKAGING_STRATEGY\""
        echo "BACKUP_MODE=\"$BACKUP_MODE\""
        echo "ENABLE_INTEGRITY_CHECK=\"$ENABLE_INTEGRITY_CHECK\""
        echo "COMPRESSION_FORMAT=\"$COMPRESSION_FORMAT\""
        echo "COMPRESSION_LEVEL=$COMPRESSION_LEVEL"
        echo "ZIP_PASSWORD=\"$ZIP_PASSWORD\""
        echo "CONSOLE_LOG_LEVEL=${CONSOLE_LOG_LEVEL:-$LOG_LEVEL_INFO}"
        echo "FILE_LOG_LEVEL=${FILE_LOG_LEVEL:-$LOG_LEVEL_DEBUG}"
        echo "ENABLE_SPACE_CHECK=\"${ENABLE_SPACE_CHECK}\""
        echo "RCLONE_BWLIMIT=\"$RCLONE_BWLIMIT\""
        echo "AUTO_BACKUP_INTERVAL_DAYS=$AUTO_BACKUP_INTERVAL_DAYS"
        echo "LAST_AUTO_BACKUP_TIMESTAMP=$LAST_AUTO_BACKUP_TIMESTAMP"
        echo "RETENTION_POLICY_TYPE=\"$RETENTION_POLICY_TYPE\""
        echo "RETENTION_VALUE=$RETENTION_VALUE"
        echo "RCLONE_TARGETS_STRING=\"$RCLONE_TARGETS_STRING\""
        echo "ENABLED_RCLONE_TARGET_INDICES_STRING=\"$ENABLED_RCLONE_TARGET_INDICES_STRING\""
        echo "RCLONE_TARGETS_METADATA_STRING=\"$RCLONE_TARGETS_METADATA_STRING\""
    } > "$CONFIG_FILE"

    log_info "配置已保存到 $CONFIG_FILE"
    chmod 600 "$CONFIG_FILE" 2>/dev/null
}

# 从文件加载配置
load_config() {
    if [[ -f "$CONFIG_FILE" ]]; then
        current_perms=$(stat -c "%a" "$CONFIG_FILE" 2>/dev/null)
        if [[ "$current_perms" != "600" ]]; then
            log_warn "配置文件 $CONFIG_FILE 权限不安全 (${current_perms})，建议设置为 600。"
            chmod 600 "$CONFIG_FILE" 2>/dev/null
        fi

        source "$CONFIG_FILE"
        log_info "配置已从 $CONFIG_FILE 加载。"

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
        
        if [[ ${#RCLONE_TARGETS_METADATA_ARRAY[@]} -ne ${#RCLONE_TARGETS_ARRAY[@]} ]]; then
            log_warn "检测到旧版配置，正在更新目标元数据..."
            local temp_meta_array=()
            for i in "${!RCLONE_TARGETS_ARRAY[@]}"; do
                local meta="${RCLONE_TARGETS_METADATA_ARRAY[$i]:-手动添加}"
                temp_meta_array+=("$meta")
            done
            RCLONE_TARGETS_METADATA_ARRAY=("${temp_meta_array[@]}")
            save_config
            log_info "配置已自动更新以兼容新版本，下次运行将使用最新配置。"
        fi

    else
        log_warn "未找到配置文件 $CONFIG_FILE，将使用默认配置。"
    fi
}

# --- 核心功能 ---

# [优化] 交互式依赖检查和安装
check_dependencies() {
    # 使用关联数组定义依赖项及其元数据
    declare -A deps
    deps["zip"]="zip;用于创建 .zip 压缩包"
    deps["unzip"]="unzip;用于解压和恢复 .zip 文件"
    deps["tar"]="tar;用于创建 .tar.gz 压缩包"
    deps["realpath"]="coreutils;用于解析文件真实路径"
    deps["rclone"]="rclone;核心工具，用于与云存储同步"
    deps["df"]="coreutils;用于检查磁盘空间"
    deps["du"]="coreutils;用于计算文件大小"
    deps["less"]="less;用于分页查看日志文件"
    deps["curl"]="curl;用于发送 Telegram 和邮件通知，以及安装 rclone"
    # [新增] jq 是新版通知管理的核心依赖
    deps["jq"]="jq;用于处理 JSON 格式的通知配置"


    local missing_deps=()
    local dep_info=()
    
    # 首先检查所有依赖
    for cmd in "${!deps[@]}"; do
        if ! command -v "$cmd" &> /dev/null; then
            missing_deps+=("$cmd")
            dep_info+=("${deps[$cmd]}")
        fi
    done

    if [ ${#missing_deps[@]} -eq 0 ]; then
        return 0
    fi

    log_warn "检测到 ${#missing_deps[@]} 个缺失的依赖项。"
    
    local install_all=false
    local installed_count=0
    local skipped_count=0
    local any_critical_skipped=false

    for i in "${!missing_deps[@]}"; do
        local cmd="${missing_deps[$i]}"
        local info="${dep_info[$i]}"
        local pkg="${info%%;*}"
        local desc="${info#*;}"

        if [[ "$install_all" == false ]]; then
            echo -e "${YELLOW}依赖缺失: ${cmd}${NC} - ${desc}"
            read -rp "是否安装此依赖? (y/n/a/q) " -n 1 choice
            echo ""
        else
            choice="y"
        fi

        case "$choice" in
            y|Y|a|A)
                if [[ "$choice" =~ ^[aA]$ ]]; then
                    install_all=true
                fi

                log_info "正在尝试安装 '${pkg}'..."
                local install_ok=false
                if [[ "$pkg" == "rclone" ]]; then
                    if command -v curl >/dev/null; then
                        if curl https://rclone.org/install.sh | sudo bash; then
                            log_info "Rclone 安装成功。"
                            install_ok=true
                        else
                            log_error "Rclone 安装失败。"
                        fi
                    else
                        log_error "安装 Rclone 需要 'curl'，但它也缺失了。请先安装 curl。"
                    fi
                elif command -v apt-get &> /dev/null; then
                    if sudo apt-get update -qq >/dev/null && sudo apt-get install -y "$pkg"; then
                        log_info "'${pkg}' 安装成功。"
                        install_ok=true
                    else
                        log_error "'${pkg}' 安装失败。"
                    fi
                elif command -v yum &> /dev/null; then
                    if sudo yum install -y "$pkg"; then
                        log_info "'${pkg}' 安装成功。"
                        install_ok=true
                    else
                        log_error "'${pkg}' 安装失败。"
                    fi
                else
                    log_error "未知的包管理器。请手动安装 '${pkg}'。"
                fi

                if [[ "$install_ok" == true ]]; then
                    ((installed_count++))
                else
                    ((skipped_count++))
                    if [[ "$pkg" == "rclone" || "$pkg" == "curl" || "$pkg" == "jq" ]]; then any_critical_skipped=true; fi
                fi
                ;;
            n|N)
                log_warn "已跳过安装 '${cmd}'。"
                ((skipped_count++))
                if [[ "$cmd" == "rclone" || "$cmd" == "curl" || "$cmd" == "jq" ]]; then any_critical_skipped=true; fi
                ;;
            q|Q)
                log_error "用户中止了依赖安装。脚本无法继续。"
                exit 1
                ;;
            *)
                log_warn "无效输入，已跳过 '${cmd}'。"
                ((skipped_count++))
                if [[ "$cmd" == "rclone" || "$cmd" == "curl" || "$cmd" == "jq" ]]; then any_critical_skipped=true; fi
                ;;
        esac
    done

    log_info "依赖检查完成。安装: ${installed_count} 个, 跳过: ${skipped_count} 个。"
    
    if [[ "$installed_count" -gt 0 ]]; then
        log_warn "已安装新的依赖项，建议重新运行脚本以确保所有功能正常。"
        press_enter_to_continue
        exit 0
    fi
    
    if [[ "$any_critical_skipped" == true ]]; then
        log_error "核心依赖 'rclone', 'curl' 或 'jq' 未安装。脚本无法执行核心任务。"
        press_enter_to_continue
        return 1
    fi
    
    return 0
}


# --- [重构] Telegram 发送函数, 接受 Bot 的 JSON 配置 ---
send_telegram_message() {
    local bot_config_json="$1"
    local message_content="$2"
    
    local bot_token chat_id
    bot_token=$(echo "$bot_config_json" | jq -r '.token')
    chat_id=$(echo "$bot_config_json" | jq -r '.chat_id')

    if [[ -z "$bot_token" || -z "$chat_id" || "$bot_token" == "null" || "$chat_id" == "null" ]]; then
        log_warn "Telegram Bot 配置不完整，跳过发送。"
        return 1
    fi
    if ! command -v curl &> /dev/null; then
        log_error "发送 Telegram 消息需要 'curl'，但未安装。"
        return 1
    fi
    
    local bot_alias
    bot_alias=$(echo "$bot_config_json" | jq -r '.alias')
    log_info "正在通过 Bot [${bot_alias}] 发送 Telegram 消息..."

    if curl -s -X POST "https://api.telegram.org/bot${bot_token}/sendMessage" \
        --data-urlencode "chat_id=${chat_id}" \
        --data-urlencode "text=${message_content}" > /dev/null; then
        log_info "Telegram 消息发送成功 ([${bot_alias}])。"
        return 0
    else
        log_error "Telegram 消息发送失败 ([${bot_alias}])！"
        return 1
    fi
}

# --- [重构] 邮件发送函数, 接受发件人的 JSON 配置 ---
send_email_message() {
    local sender_config_json="$1"
    local message_content="$2"
    local subject="$3"

    # 使用 jq 从 JSON 中提取所有必要的变量
    local alias host port user pass from use_tls
    alias=$(echo "$sender_config_json" | jq -r '.alias')
    host=$(echo "$sender_config_json" | jq -r '.host')
    port=$(echo "$sender_config_json" | jq -r '.port')
    user=$(echo "$sender_config_json" | jq -r '.user')
    pass=$(echo "$sender_config_json" | jq -r '.pass')
    from=$(echo "$sender_config_json" | jq -r '.from')
    use_tls=$(echo "$sender_config_json" | jq -r '.use_tls')
    
    # 提取收件人数组
    local recipients_json
    recipients_json=$(echo "$sender_config_json" | jq -c '.recipients')

    if [[ -z "$host" || -z "$port" || -z "$user" || -z "$pass" || -z "$from" || "$recipients_json" == "[]" || "$recipients_json" == "null" ]]; then
        log_warn "邮件发件人 [${alias}] 配置不完整或没有收件人，跳过发送。"
        return 1
    fi
    
    if ! command -v curl &> /dev/null; then
        log_error "发送邮件需要 'curl'，但未安装。"
        return 1
    fi

    log_info "正在通过邮箱 [${alias}] 发送邮件..."

    # 为 curl 构建收件人参数列表
    local mail_rcpt_args=()
    for recipient in $(echo "$recipients_json" | jq -r '.[]'); do
        mail_rcpt_args+=(--mail-rcpt "<${recipient}>")
    done

    # 将收件人地址格式化用于邮件头
    local to_header
    to_header=$(echo "$recipients_json" | jq -r 'join(", ")')

    local mail_body_file="${TEMP_DIR}/mail.txt"
    cat << EOF > "$mail_body_file"
From: "$SCRIPT_NAME" <$from>
To: $to_header
Subject: $subject
Date: $(date -R)
Content-Type: text/plain; charset=UTF-8

$message_content
EOF

    local curl_protocol="smtp"
    local curl_tls_option="--ssl-reqd" # 默认为 STARTTLS

    if [[ "$use_tls" == "true" ]]; then
        if [[ "$port" == "465" ]]; then
            curl_protocol="smtps"
            curl_tls_option=""
        fi
    else
        curl_tls_option=""
    fi

    if curl --silent --show-error --url "${curl_protocol}://${host}:${port}" \
        ${curl_tls_option} \
        --user "${user}:${pass}" \
        --mail-from "<${from}>" \
        "${mail_rcpt_args[@]}" \
        --upload-file "$mail_body_file"; then
        log_info "邮件发送成功 ([${alias}])。"
        return 0
    else
        log_error "邮件发送失败 ([${alias}])！请检查配置、网络或 curl 错误输出。"
        return 1
    fi

    rm -f "$mail_body_file"
}

# --- [重构 & 修复] 统一的通知发送函数，支持多通道 ---
send_notification() {
    local message_content="$1"
    local subject="$2"

    # --- 发送 Telegram ---
    local telegram_bots_file="$TELEGRAM_BOTS_CONFIG_FILE"
    if [[ -f "$telegram_bots_file" ]]; then
        local enabled_bots
        enabled_bots=$(jq -c '.[] | select(.enabled == true)' "$telegram_bots_file" 2>/dev/null)
        
        if [[ -n "$enabled_bots" ]]; then
            while IFS= read -r bot_config; do
                send_telegram_message "$bot_config" "$message_content" || true
            done <<< "$enabled_bots"
        fi
    fi

    # --- 发送 邮件 ---
    local email_senders_file="$EMAIL_SENDERS_CONFIG_FILE"
    if [[ -f "$email_senders_file" ]]; then
        local enabled_senders
        enabled_senders=$(jq -c '.[] | select(.enabled == true)' "$email_senders_file" 2>/dev/null)

        if [[ -n "$enabled_senders" ]]; then
            while IFS= read -r sender_config; do
                send_email_message "$sender_config" "$message_content" "$subject" || true
            done <<< "$enabled_senders"
        fi
    fi
}

restore_backup() {
    display_header
    echo -e "${BLUE}=== 从云端恢复到本地 ===${NC}"
    log_info "请注意：此功能仅适用于“归档模式”创建的备份文件。"

    if [ ${#ENABLED_RCLONE_TARGET_INDICES_ARRAY[@]} -eq 0 ]; then
        log_error "没有已启用的备份目标可供恢复。"
        press_enter_to_continue
        return
    fi

    log_info "请选择要从哪个目标恢复："
    local enabled_targets=()
    for index in "${ENABLED_RCLONE_TARGET_INDICES_ARRAY[@]}"; do
        enabled_targets+=("${RCLONE_TARGETS_ARRAY[$index]}")
    done

    for i in "${!enabled_targets[@]}"; do
        echo " $((i+1)). ${enabled_targets[$i]}"
    done
    echo " 0. 返回"
    read -rp "请输入选项: " target_choice

    if [[ "$target_choice" == "0" ]]; then
        log_info "已取消。"
        press_enter_to_continue
        return
    fi

    if ! [[ "$target_choice" =~ ^[0-9]+$ ]] || [ "$target_choice" -gt ${#enabled_targets[@]} ]; then
        log_error "无效选项。"
        press_enter_to_continue
        return
    fi
    
    local selected_target="${enabled_targets[$((target_choice-1))]}"
    log_info "正在从 ${selected_target} 获取备份列表..."
    
    local backup_files_str
    backup_files_str=$(rclone lsf --files-only "${selected_target}" | grep -E '\.zip$|\.tar\.gz$' | sort -r)

    if [[ -z "$backup_files_str" ]]; then
        log_error "在 ${selected_target} 中未找到任何 .zip 或 .tar.gz 备份文件。"
        press_enter_to_continue
        return
    fi
    
    local backup_files=()
    mapfile -t backup_files <<< "$backup_files_str"
    
    log_info "发现以下备份文件（按名称逆序排序）："
    for i in "${!backup_files[@]}"; do
        echo " $((i+1)). ${backup_files[$i]}"
    done
    echo " 0. 返回"
    read -rp "请选择要恢复的备份文件序号: " file_choice

    if [[ "$file_choice" == "0" ]]; then
        log_info "已取消。"
        press_enter_to_continue
        return
    fi

    if ! [[ "$file_choice" =~ ^[0-9]+$ ]] || [ "$file_choice" -gt ${#backup_files[@]} ]; then
        log_error "无效选项。"
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
    log_warn "正在下载备份文件: ${selected_file}..."
    
    local bw_limit_arg=""
    if [[ -n "$RCLONE_BWLIMIT" ]]; then
        bw_limit_arg="--bwlimit ${RCLONE_BWLIMIT}"
        log_info "下载将使用带宽限制: ${RCLONE_BWLIMIT}"
    fi

    if ! rclone copyto "${remote_file_path}" "${temp_archive_path}" --progress ${bw_limit_arg}; then
        log_error "下载备份文件失败！"
        press_enter_to_continue
        return
    fi
    log_info "下载成功！"
    
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
                log_error "路径不能为空！"
            else
                mkdir -p "$restore_dir"
                log_warn "正在解压到 ${restore_dir} ..."
                if [[ "$selected_file" == *.zip ]]; then
                    if unzip -o "${temp_archive_path}" -d "${restore_dir}" &>/dev/null; then
                        log_info "解压完成！"
                    else
                        read -s -p "解压失败，文件可能已加密。请输入密码 (留空则跳过): " restore_pass
                        echo ""
                        if [[ -n "$restore_pass" ]]; then
                            if unzip -o -P "$restore_pass" "${temp_archive_path}" -d "${restore_dir}"; then
                                log_info "解压完成！"
                            else
                                log_error "密码错误或文件损坏，解压失败！"
                            fi
                        else
                            log_error "解压失败！"
                        fi
                    fi
                elif [[ "$selected_file" == *.tar.gz ]]; then
                    if tar -xzf "${temp_archive_path}" -C "${restore_dir}"; then
                        log_info "解压完成！"
                    else
                        log_error "解压失败！"
                    fi
                else
                    log_error "未知的压缩格式！"
                fi
            fi
            ;;
        2)
            log_info "备份文件 '${selected_file}' 内容如下："
            if [[ "$selected_file" == *.zip ]]; then
                unzip -l "${temp_archive_path}"
            elif [[ "$selected_file" == *.tar.gz ]]; then
                tar -tzvf "${temp_archive_path}"
            fi
            ;;
        *)
            log_info "已取消操作。"
            ;;
    esac
    rm -f "${temp_archive_path}"
    press_enter_to_continue
}

manage_auto_backup_menu() {
    while true; do
        local human_cron_info
        human_cron_info=$(parse_cron_to_human "$(get_cron_job_info)")
        display_header
        echo -e "${BLUE}=== 1. 自动备份与计划任务 ===${NC}"
        echo -e "  1. ${YELLOW}设置自动备份间隔${NC} (间隔: ${AUTO_BACKUP_INTERVAL_DAYS} 天)"
        echo -e "  2. ${YELLOW}配置 Cron 定时任务${NC} (当前: ${human_cron_info})"
        echo ""
        echo -e "  0. ${RED}返回主菜单${NC}"
        read -rp "请输入选项: " choice
        
        case $choice in
            1) set_auto_backup_interval ;;
            2) setup_cron_job ;;
            0) break ;;
            *) log_error "无效选项。"; press_enter_to_continue ;;
        esac
    done
}

set_auto_backup_interval() {
    display_header
    echo -e "${BLUE}--- 设置自动备份间隔 ---${NC}"
    read -rp "请输入新的自动备份间隔时间（天数，最小1天）[间隔: ${AUTO_BACKUP_INTERVAL_DAYS}]: " interval_input
    if [[ "$interval_input" =~ ^[0-9]+$ ]] && [ "$interval_input" -ge 1 ]; then
        AUTO_BACKUP_INTERVAL_DAYS="$interval_input"
        save_config
        log_info "自动备份间隔已成功设置为：${AUTO_BACKUP_INTERVAL_DAYS} 天。"
    else
        log_error "输入无效。"
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
        log_error "时间格式无效！请输入 HH:MM 格式。"
        press_enter_to_continue
        return
    fi
    
    local cron_minute="${cron_time#*:}"
    local cron_hour="${cron_time%%:*}"
    
    # [FIX] 强制使用 10 进制处理数字，避免 08, 09 被当作无效八进制数
    cron_minute=$((10#${cron_minute}))
    cron_hour=$((10#${cron_hour}))

    local script_path
    script_path=$(readlink -f "$0")
    local cron_command="${cron_minute} ${cron_hour} * * * ${script_path} check_auto_backup >> \"${LOG_FILE}\" 2>&1"
    
    if crontab -l 2>/dev/null | grep -qF "$script_path check_auto_backup"; then
        log_warn "检测到已存在此脚本的定时任务。"
        read -rp "您想用新的时间设置覆盖它吗？(y/N): " confirm_replace
        if [[ "$confirm_replace" =~ ^[Yy]$ ]]; then
            local temp_crontab
            temp_crontab=$(crontab -l 2>/dev/null | grep -vF "$script_path check_auto_backup")
            (echo "${temp_crontab}"; echo "$cron_command") | crontab -
            log_info "定时任务已更新！"
        else
            log_info "已取消操作。"
        fi
    else
        (crontab -l 2>/dev/null; echo "$cron_command") | crontab -
        log_info "定时任务添加成功！"
    fi

    log_info "您可以使用 'crontab -l' 命令查看所有定时任务。"
    press_enter_to_continue
}

manual_backup() {
    display_header
    echo -e "${BLUE}=== 2. 手动备份 ===${NC}"

    if [ ${#BACKUP_SOURCE_PATHS_ARRAY[@]} -eq 0 ]; then
        log_error "没有设置任何备份源路径。"
        log_warn "请先在选项 [3] 中添加要备份的路径。"
        press_enter_to_continue
        return 1
    fi
    if [ ${#ENABLED_RCLONE_TARGET_INDICES_ARRAY[@]} -eq 0 ]; then
        log_error "没有启用任何 Rclone 备份目标。"
        log_warn "请先在选项 [5] 中配置并启用一个或多个目标。"
        press_enter_to_continue
        return 1
    fi

    perform_backup "手动备份"
    press_enter_to_continue
}

add_backup_path() {
    display_header
    echo -e "${BLUE}=== 添加备份路径 ===${NC}"
    read -rp "请输入要备份的文件或文件夹的绝对路径: " path_input

    if [[ -z "$path_input" ]]; then
        log_error "路径不能为空。"
        press_enter_to_continue
        return
    fi

    local resolved_path
    resolved_path=$(realpath -q "$path_input" 2>/dev/null)

    if [[ -z "$resolved_path" ]]; then
        log_error "输入的路径 '$path_input' 无效或不存在。"
    elif [[ ! -d "$resolved_path" && ! -f "$resolved_path" ]]; then
        log_error "输入的路径 '$resolved_path' 不是有效的文件/目录。"
    else
        local found=false
        for p in "${BACKUP_SOURCE_PATHS_ARRAY[@]}"; do
            if [[ "$p" == "$resolved_path" ]]; then
                found=true
                break
            fi
        done

        if "$found"; then
            log_warn "该路径 '$resolved_path' 已存在。"
        else
            BACKUP_SOURCE_PATHS_ARRAY+=("$resolved_path")
            save_config
            log_info "备份路径 '$resolved_path' 已添加。"
        fi
    fi
    press_enter_to_continue
}

view_and_manage_backup_paths() {
    while true; do
        display_header
        echo -e "${BLUE}=== 查看/管理备份路径 ===${NC}"
        if [ ${#BACKUP_SOURCE_PATHS_ARRAY[@]} -eq 0 ]; then
            log_warn "当前没有设置任何备份路径。"
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
        read -rp "请输入选项: " sub_choice

        case $sub_choice in
            1)
                read -rp "请输入要修改的路径序号: " path_index
                if [[ "$path_index" =~ ^[0-9]+$ ]] && [ "$path_index" -ge 1 ] && [ "$path_index" -le ${#BACKUP_SOURCE_PATHS_ARRAY[@]} ]; then
                    local current_path="${BACKUP_SOURCE_PATHS_ARRAY[$((path_index-1))]}"
                    read -rp "修改路径 '${current_path}'。请输入新路径: " new_path_input
                    
                    if [[ -z "$new_path_input" ]]; then
                        log_error "错误：路径不能为空。"
                        press_enter_to_continue
                        continue
                    fi

                    local resolved_new_path
                    resolved_new_path=$(realpath -q "$new_path_input" 2>/dev/null)

                    if [[ -z "$resolved_new_path" || (! -d "$resolved_new_path" && ! -f "$resolved_new_path") ]]; then
                        log_error "错误：新路径无效或不存在。"
                    else
                        BACKUP_SOURCE_PATHS_ARRAY[$((path_index-1))]="$resolved_new_path"
                        save_config
                        log_info "路径已修改。"
                    fi
                else
                    log_error "无效序号。"
                fi
                press_enter_to_continue
                ;;
            2)
                read -rp "请输入要删除的路径序号: " path_index
                if [[ "$path_index" =~ ^[0-9]+$ ]] && [ "$path_index" -ge 1 ] && [ "$path_index" -le ${#BACKUP_SOURCE_PATHS_ARRAY[@]} ]; then
                    read -rp "确定要删除路径 '${BACKUP_SOURCE_PATHS_ARRAY[$((path_index-1))]}'吗？(y/N): " confirm
                    if [[ "$confirm" =~ ^[Yy]$ ]]; then
                        unset 'BACKUP_SOURCE_PATHS_ARRAY[$((path_index-1))]'
                        BACKUP_SOURCE_PATHS_ARRAY=("${BACKUP_SOURCE_PATHS_ARRAY[@]}")
                        save_config
                        log_info "路径已删除。"
                    fi
                else
                    log_error "无效序号。"
                fi
                press_enter_to_continue
                ;;
            0) break ;;
            *) log_error "无效选项。"; press_enter_to_continue ;;
        esac
    done
}

set_packaging_strategy() {
    display_header
    echo -e "${BLUE}--- 设置打包策略 ---${NC}"
    echo "请选择在“归档模式”下如何打包多个源文件/目录："
    echo ""
    echo -e "  1. ${YELLOW}每个源单独打包${NC} (Separate)"
    echo -e "  2. ${YELLOW}所有源打包成一个${NC} (Single)"
    echo ""
    echo -e "当前策略: ${GREEN}${PACKAGING_STRATEGY}${NC}"
    read -rp "请输入选项 (1 或 2): " choice

    case $choice in
        1)
            PACKAGING_STRATEGY="separate"
            save_config
            log_info "打包策略已设置为: 每个源单独打包。"
            ;;
        2)
            PACKAGING_STRATEGY="single"
            save_config
            log_info "打包策略已设置为: 所有源打包成一个。"
            ;;
        *)
            log_error "无效选项。"
            ;;
    esac
    press_enter_to_continue
}

set_backup_mode() {
    display_header
    echo -e "${BLUE}--- 设置备份模式 ---${NC}"
    echo "请选择您的主要备份策略："
    echo ""
    echo -e "  1. ${YELLOW}归档模式${NC} (Archive) - 先打包成 .zip 再上传。支持版本保留和恢复。适合重要文件归档。"
    echo -e "  2. ${YELLOW}同步模式${NC} (Sync) - 直接将本地目录结构同步到云端，效率高。适合频繁变动的大量文件。(此模式下保留策略和恢复功能无效)"
    echo ""
    local current_mode_text="归档模式 (Archive)"
    if [[ "$BACKUP_MODE" == "sync" ]]; then
        current_mode_text="同步模式 (Sync)"
    fi
    echo -e "当前模式: ${GREEN}${current_mode_text}${NC}"
    read -rp "请输入选项 (1 或 2): " choice

    case $choice in
        1)
            BACKUP_MODE="archive"
            save_config
            log_info "备份模式已设置为: 归档模式。"
            ;;
        2)
            BACKUP_MODE="sync"
            save_config
            log_info "备份模式已设置为: 同步模式。"
            ;;
        *)
            log_error "无效选项。"
            ;;
    esac
    press_enter_to_continue
}

set_backup_path_and_mode() {
    while true; do
        display_header
        echo -e "${BLUE}=== 3. 自定义备份路径与模式 ===${NC}"
        echo "当前已配置备份路径数量: ${#BACKUP_SOURCE_PATHS_ARRAY[@]} 个"

        local mode_text="归档模式 (Archive)"
        if [[ "$BACKUP_MODE" == "sync" ]]; then
            mode_text="同步模式 (Sync)"
        fi
        echo -e "当前备份模式: ${GREEN}${mode_text}${NC}"
        
        local strategy_text="每个源单独打包"
        if [[ "$PACKAGING_STRATEGY" == "single" ]]; then
            strategy_text="所有源打包成一个"
        fi
        echo -e "归档模式打包策略: ${GREEN}${strategy_text}${NC}"

        echo ""
        echo -e "${BLUE}━━━━━━━━━━━━━━━━━━ 操作选项 ━━━━━━━━━━━━━━━━━━${NC}"
        echo -e "  1. ${YELLOW}添加新的备份路径${NC}"
        echo -e "  2. ${YELLOW}查看/管理现有路径${NC}"
        echo -e "  3. ${YELLOW}设置打包策略${NC} (仅归档模式有效)"
        echo -e "  4. ${YELLOW}设置备份模式${NC} (归档/同步)"
        echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
        echo -e "  0. ${RED}返回主菜单${NC}"
        read -rp "请输入选项: " choice

        case $choice in
            1) add_backup_path ;;
            2) view_and_manage_backup_paths ;;
            3) set_packaging_strategy ;;
            4) set_backup_mode ;;
            0) break ;;
            *) log_error "无效选项。"; press_enter_to_continue ;;
        esac
    done
}

manage_compression_settings() {
    while true; do
        display_header
        echo -e "${BLUE}=== 4. 压缩包格式与选项 ===${NC}"
        local pass_status="未设置"
        if [[ -n "$ZIP_PASSWORD" ]]; then
            pass_status="已设置"
        fi
        echo -e "当前格式: ${COMPRESSION_FORMAT}"
        echo -e "压缩级别: ${COMPRESSION_LEVEL} (1=最快, 9=最高)"
        echo -e "ZIP 密码: ${pass_status}"
        echo ""
        echo -e "${BLUE}━━━━━━━━━━━━━━━━━━ 操作选项 ━━━━━━━━━━━━━━━━━━${NC}"
        echo -e "  1. ${YELLOW}切换压缩格式${NC} (zip / tar.gz)"
        echo -e "  2. ${YELLOW}设置压缩级别${NC}"
        echo -e "  3. ${YELLOW}设置/清除 ZIP 密码${NC} (仅对 zip 格式有效)"
        echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
        echo -e "  0. ${RED}返回主菜单${NC}"
        read -rp "请输入选项: " choice

        case "$choice" in
            1)
                if [[ "$COMPRESSION_FORMAT" == "zip" ]]; then
                    COMPRESSION_FORMAT="tar.gz"
                    log_info "压缩格式已切换为 tar.gz"
                else
                    COMPRESSION_FORMAT="zip"
                    log_info "压缩格式已切换为 zip"
                fi
                save_config
                press_enter_to_continue
                ;;
            2)
                read -rp "请输入新的压缩级别 (1-9) [当前: ${COMPRESSION_LEVEL}]: " level_input
                if [[ "$level_input" =~ ^[1-9]$ ]]; then
                    COMPRESSION_LEVEL="$level_input"
                    save_config
                    log_info "压缩级别已设置为 ${COMPRESSION_LEVEL}"
                else
                    log_error "无效输入，请输入 1 到 9 之间的数字。"
                fi
                press_enter_to_continue
                ;;
            3)
                if [[ "$COMPRESSION_FORMAT" != "zip" ]]; then
                    log_warn "警告：密码保护仅对 zip 格式有效。"
                    press_enter_to_continue
                    continue
                fi
                read -s -p "请输入新的 ZIP 密码 (留空则清除密码): " pass_input
                echo ""
                ZIP_PASSWORD="$pass_input"
                save_config
                if [[ -n "$ZIP_PASSWORD" ]]; then
                    log_info "ZIP 密码已设置。"
                else
                    log_info "ZIP 密码已清除。"
                fi
                press_enter_to_continue
                ;;
            0) break ;;
            *) log_error "无效选项。"; press_enter_to_continue ;;
        esac
    done
}


set_bandwidth_limit() {
    display_header
    echo -e "${BLUE}--- 设置 Rclone 带宽限制 ---${NC}"
    echo "此设置将限制 Rclone 上传和下载的速度，以避免占用过多网络资源。"
    echo "格式示例: 8M (8 MByte/s), 512k (512 KByte/s)。留空或输入 0 表示不限制。"
    
    local bw_limit_display="${RCLONE_BWLIMIT}"
    if [[ -z "$bw_limit_display" ]]; then
        bw_limit_display="不限制"
    fi

    read -rp "请输入新的带宽限制 [当前: ${bw_limit_display}]: " bw_input
    
    if [[ -z "$bw_input" || "$bw_input" == "0" ]]; then
        RCLONE_BWLIMIT=""
        log_info "带宽限制已取消。"
    else
        if [[ "$bw_input" =~ ^[0-9]+([kKmM])?$ ]]; then
            RCLONE_BWLIMIT="$bw_input"
            log_info "带宽限制已设置为: ${RCLONE_BWLIMIT}"
        else
            log_error "格式无效！请输入类似 '8M' 或 '512k' 的值。"
        fi
    fi
    save_config
    press_enter_to_continue
}

toggle_integrity_check() {
    display_header
    echo -e "${BLUE}--- 备份后完整性校验 ---${NC}"
    echo "开启后，在“归档模式”下每次上传文件成功后，会额外执行一次校验，确保云端文件未损坏。"
    echo -e "${YELLOW}这会增加备份时间，但能极大地提升数据可靠性。${NC}"
    
    local check_status="已开启"
    if [[ "$ENABLE_INTEGRITY_CHECK" != "true" ]]; then
        check_status="已关闭"
    fi
    echo -e "当前状态: ${GREEN}${check_status}${NC}"
    
    read -rp "您想切换状态吗？ (y/N): " choice
    if [[ "$choice" =~ ^[Yy]$ ]]; then
        if [[ "$ENABLE_INTEGRITY_CHECK" == "true" ]]; then
            ENABLE_INTEGRITY_CHECK="false"
            log_warn "完整性校验已关闭。"
        else
            ENABLE_INTEGRITY_CHECK="true"
            log_info "完整性校验已开启。"
        fi
        save_config
    else
        log_info "状态未改变。"
    fi
    press_enter_to_continue
}


set_cloud_storage() {
    while true; do
        display_header
        echo -e "${BLUE}=== 5. 云存储设定 (Rclone) ===${NC}"
        echo -e "提示: '备份目标' 是 '远程端' + 具体路径 (例如 mydrive:/backups)。"
        echo ""
        echo -e "${BLUE}━━━━━━━━━━━━━━━━━━ 操作选项 ━━━━━━━━━━━━━━━━━━${NC}"
        echo -e "  1. ${YELLOW}查看、管理和启用备份目标${NC}"
        echo -e "  2. ${YELLOW}创建新的 Rclone 远程端${NC}"
        echo -e "  3. ${YELLOW}测试 Rclone 远程端连接${NC}"
        
        local bw_limit_display="${RCLONE_BWLIMIT}"
        if [[ -z "$bw_limit_display" ]]; then
            bw_limit_display="不限制"
        fi
        echo -e "  4. ${YELLOW}设置带宽限制${NC} (当前: ${bw_limit_display})"

        local check_status_text="已开启"
        if [[ "$ENABLE_INTEGRITY_CHECK" != "true" ]]; then
            check_status_text="已关闭"
        fi
        echo -e "  5. ${YELLOW}备份后完整性校验${NC} (当前: ${check_status_text})"
        
        echo -e "  6. ${YELLOW}启动 Rclone 官方配置工具${NC} (用于 Google Drive, Dropbox 等)"
        echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
        echo -e "  0. ${RED}返回主菜单${NC}"
        read -rp "请输入选项: " choice

        case $choice in
            1) view_and_manage_rclone_targets ;;
            2) create_rclone_remote_wizard || true ;;
            3) test_rclone_remotes ;;
            4) set_bandwidth_limit ;;
            5) toggle_integrity_check ;;
            6) 
                log_info "正在启动 Rclone 官方配置工具。请根据 Rclone 提示进行操作。"
                log_info "完成后，您可以将配置好的远程端在选项 [1] 中添加为备份目标。"
                press_enter_to_continue # 让用户先看完提示
                rclone config
                press_enter_to_continue
                ;;
            0) break ;;
            *) log_error "无效选项。"; press_enter_to_continue ;;
        esac
    done
}


# ==============================================================================
# ===                         新版消息通知模块 (JSON 版本)                       ===
# ==============================================================================

# --- JSON 配置文件辅助函数 ---

# 加载 Telegram Bot 配置, 如果文件不存在则返回空数组
load_telegram_bots() {
    if [[ ! -f "$TELEGRAM_BOTS_CONFIG_FILE" ]]; then
        echo "[]"
        return
    fi
    jq '.' "$TELEGRAM_BOTS_CONFIG_FILE" 2>/dev/null || echo "[]"
}

# 保存 Telegram Bot 配置
save_telegram_bots() {
    local bots_json="$1"
    echo "$bots_json" | jq '.' > "$TELEGRAM_BOTS_CONFIG_FILE"
    chmod 600 "$TELEGRAM_BOTS_CONFIG_FILE" 2>/dev/null
}

# 加载 Email 发件人配置, 如果文件不存在则返回空数组
load_email_senders() {
    if [[ ! -f "$EMAIL_SENDERS_CONFIG_FILE" ]]; then
        echo "[]"
        return
    fi
    jq '.' "$EMAIL_SENDERS_CONFIG_FILE" 2>/dev/null || echo "[]"
}

# 保存 Email 发件人配置
save_email_senders() {
    local senders_json="$1"
    echo "$senders_json" | jq '.' > "$EMAIL_SENDERS_CONFIG_FILE"
    chmod 600 "$EMAIL_SENDERS_CONFIG_FILE" 2>/dev/null
}


# --- Telegram 管理模块 ---

manage_telegram_bots() {
    while true; do
        display_header
        echo -e "${BLUE}=== 管理 Telegram 机器人 ===${NC}"
        
        local bots_json
        bots_json=$(load_telegram_bots)
        local bot_count
        bot_count=$(echo "$bots_json" | jq 'length')

        if [[ "$bot_count" -eq 0 ]]; then
            log_warn "当前未配置任何 Telegram 机器人。"
        else
            echo "已配置的机器人列表:"
            for i in $(seq 0 $((bot_count - 1))); do
                local alias enabled status
                # 提取数据，确保在 jq 失败时有默认值，防止脚本退出
                alias=$(echo "$bots_json" | jq -r ".[$i].alias" 2>/dev/null || echo "无效条目")
                enabled=$(echo "$bots_json" | jq -r ".[$i].enabled" 2>/dev/null || echo "false")
                status=$([[ "$enabled" == "true" ]] && echo -e "[${GREEN}已启用${NC}]" || echo "[已禁用]")
                echo -e "  $((i+1)). ${alias} ${status}"
            done
        fi
        
        echo ""
        echo -e "${BLUE}━━━━━━━━━━━━━━━━━━ 操作选项 ━━━━━━━━━━━━━━━━━━${NC}"
        echo "  a - 添加新机器人"
        echo "  m - 修改机器人"
        echo "  d - 删除机器人"
        echo "  t - 切换启用/禁用状态"
        echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
        echo -e "  0 - ${RED}返回上一级${NC}"
        read -rp "请输入选项: " choice

        case "$choice" in
            a|A)
                read -rp "为机器人起一个别名 (例如: 家庭NAS通知): " new_alias
                read -rp "请输入 Bot Token: " new_token
                read -rp "请输入 Chat ID: " new_chat_id
                if [[ -n "$new_alias" && -n "$new_token" && -n "$new_chat_id" ]]; then
                    local new_bot
                    new_bot=$(jq -n --arg alias "$new_alias" --arg token "$new_token" --arg chat_id "$new_chat_id" \
                        '{alias: $alias, token: $token, chat_id: $chat_id, enabled: true}')
                    bots_json=$(echo "$bots_json" | jq ". += [$new_bot]")
                    save_telegram_bots "$bots_json"
                    log_info "机器人 '${new_alias}' 已添加并启用。"
                else
                    log_error "信息不完整，添加失败。"
                fi
                press_enter_to_continue
                ;;
            m|M)
                if [[ "$bot_count" -eq 0 ]]; then log_warn "没有可修改的机器人。"; press_enter_to_continue; continue; fi
                read -rp "请输入要修改的机器人序号: " index
                if [[ "$index" =~ ^[0-9]+$ ]] && [ "$index" -ge 1 ] && [ "$index" -le "$bot_count" ]; then
                    local real_index=$((index - 1))
                    local current_alias current_token current_chat_id
                    current_alias=$(echo "$bots_json" | jq -r ".[$real_index].alias")
                    current_token=$(echo "$bots_json" | jq -r ".[$real_index].token")
                    current_chat_id=$(echo "$bots_json" | jq -r ".[$real_index].chat_id")
                    
                    echo "正在修改 '${current_alias}' (序号: $index)。按 Enter 跳过不修改的项。"
                    read -rp "新别名 [${current_alias}]: " new_alias
                    read -rp "新 Bot Token [${current_token:0:8}******]: " new_token
                    read -rp "新 Chat ID [${current_chat_id}]: " new_chat_id

                    bots_json=$(echo "$bots_json" | jq ".[$real_index].alias = \"${new_alias:-$current_alias}\"")
                    if [[ -n "$new_token" ]]; then
                        bots_json=$(echo "$bots_json" | jq ".[$real_index].token = \"$new_token\"")
                    fi
                    bots_json=$(echo "$bots_json" | jq ".[$real_index].chat_id = \"${new_chat_id:-$current_chat_id}\"")
                    
                    save_telegram_bots "$bots_json"
                    log_info "机器人信息已更新。"
                else
                    log_error "无效序号。"
                fi
                press_enter_to_continue
                ;;

            d|D)
                if [[ "$bot_count" -eq 0 ]]; then log_warn "没有可删除的机器人。"; press_enter_to_continue; continue; fi
                read -rp "请输入要删除的机器人序号: " index
                if [[ "$index" =~ ^[0-9]+$ ]] && [ "$index" -ge 1 ] && [ "$index" -le "$bot_count" ]; then
                    local alias_to_delete
                    alias_to_delete=$(echo "$bots_json" | jq -r ".[$((index-1))].alias")
                    read -rp "确定要删除机器人 '${alias_to_delete}' 吗？(y/N): " confirm
                    if [[ "$confirm" =~ ^[Yy]$ ]]; then
                        bots_json=$(echo "$bots_json" | jq "del(.[$((index-1))])")
                        save_telegram_bots "$bots_json"
                        log_info "机器人已删除。"
                    fi
                else
                    log_error "无效序号。"
                fi
                press_enter_to_continue
                ;;
            t|T)
                if [[ "$bot_count" -eq 0 ]]; then log_warn "没有可切换状态的机器人。"; press_enter_to_continue; continue; fi
                read -rp "请输入要切换状态的机器人序号: " index
                if [[ "$index" =~ ^[0-9]+$ ]] && [ "$index" -ge 1 ] && [ "$index" -le "$bot_count" ]; then
                    local real_index=$((index - 1))
                    local current_state
                    current_state=$(echo "$bots_json" | jq ".["$real_index"].enabled")
                    local new_state
                    new_state=$([[ "$current_state" == "true" ]] && echo "false" || echo "true")
                    bots_json=$(echo "$bots_json" | jq ".["$real_index"].enabled = $new_state")
                    save_telegram_bots "$bots_json"
                    log_info "机器人状态已更新为: $new_state"
                else
                    log_error "无效序号。"
                fi
                press_enter_to_continue
                ;;
            0) break ;;
            *) log_error "无效选项。"; press_enter_to_continue ;;
        esac
    done
}


# --- Email 管理模块 ---

manage_email_recipients() {
    local sender_index="$1"
    
    while true; do
        local senders_json
        senders_json=$(load_email_senders)
        local sender_alias
        sender_alias=$(echo "$senders_json" | jq -r ".[$sender_index].alias")
        local recipients_json
        recipients_json=$(echo "$senders_json" | jq ".["$sender_index"].recipients")
        
        display_header
        echo -e "${BLUE}=== 管理收件人 for '${sender_alias}' ===${NC}"
        
        if [[ "$(echo "$recipients_json" | jq 'length')" -eq 0 ]]; then
            log_warn "当前没有收件人。"
        else
            echo "收件人列表:"
            local recipients_array
            mapfile -t recipients_array < <(echo "$recipients_json" | jq -r '.[]')
            for i in "${!recipients_array[@]}"; do
                echo "  $((i+1)). ${recipients_array[$i]}"
            done
        fi

        echo ""
        echo -e "${BLUE}━━━━━━━━━━━━━━━━━━ 操作选项 ━━━━━━━━━━━━━━━━━━${NC}"
        echo "  a - 添加收件人"
        echo "  d - 删除收件人"
        echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
        echo "  0 - 返回"
        read -rp "请输入选项: " choice
        
        case "$choice" in
            a|A)
                read -rp "请输入要添加的收件人邮箱地址: " new_recipient
                if [[ -n "$new_recipient" ]]; then
                    senders_json=$(echo "$senders_json" | jq ".[$sender_index].recipients += [\"$new_recipient\"] | .[$sender_index].recipients |= unique")
                    save_email_senders "$senders_json"
                    log_info "收件人已添加。"
                else
                    log_error "邮箱地址不能为空。"
                fi
                press_enter_to_continue
                ;;
            d|D)
                if [[ "$(echo "$recipients_json" | jq 'length')" -eq 0 ]]; then log_warn "没有可删除的收件人。"; press_enter_to_continue; continue; fi
                read -rp "请输入要删除的收件人序号: " recipient_index
                if [[ "$recipient_index" =~ ^[0-9]+$ ]] && [ "$recipient_index" -ge 1 ] && [ "$recipient_index" -le "$(echo "$recipients_json" | jq 'length')" ]; then
                    senders_json=$(echo "$senders_json" | jq "del(.[$sender_index].recipients[$((recipient_index-1))])")
                    save_email_senders "$senders_json"
                    log_info "收件人已删除。"
                else
                    log_error "无效序号。"
                fi
                press_enter_to_continue
                ;;
            0) break ;;
            *) log_error "无效选项。"; press_enter_to_continue ;;
        esac
    done
}

manage_email_senders() {
     while true; do
        display_header
        echo -e "${BLUE}=== 管理邮件发件人 ===${NC}"
        
        local senders_json
        senders_json=$(load_email_senders)
        local sender_count
        sender_count=$(echo "$senders_json" | jq 'length')

        if [[ "$sender_count" -eq 0 ]]; then
            log_warn "当前未配置任何邮件发件人。"
        else
            echo "已配置的发件人列表:"
            for i in $(seq 0 $((sender_count - 1))); do
                local alias enabled status recipients_count
                alias=$(echo "$senders_json" | jq -r ".[$i].alias" 2>/dev/null || echo "无效条目")
                enabled=$(echo "$senders_json" | jq -r ".[$i].enabled" 2>/dev/null || echo "false")
                recipients_count=$(echo "$senders_json" | jq ".[$i].recipients | length" 2>/dev/null || echo "0")
                status=$([[ "$enabled" == "true" ]] && echo -e "[${GREEN}已启用${NC}]" || echo "[已禁用]")
                echo -e "  $((i+1)). ${alias} (收件人: ${recipients_count}) ${status}"
            done
        fi
        
        echo ""
        echo -e "${BLUE}━━━━━━━━━━━━━━━━━━ 操作选项 ━━━━━━━━━━━━━━━━━━${NC}"
        echo "  a - 添加新发件人"
        echo "  m - 修改发件人"
        echo "  r - 管理收件人"
        echo "  d - 删除发件人"
        echo "  t - 切换启用/禁用状态"
        echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
        echo -e "  0 - ${RED}返回上一级${NC}"
        read -rp "请输入选项: " choice

        case "$choice" in
            a|A)
                echo "--- 添加新发件人 ---"
                read -rp "为发件人起一个别名 (例如: 公司邮箱): " new_alias
                read -rp "SMTP 服务器地址 (例如: smtp.qq.com): " new_host
                read -rp "SMTP 端口 (例如: 465 或 587): " new_port
                read -rp "发件人邮箱地址: " new_from
                read -rp "SMTP 用户名 (通常等于发件人): " new_user
                read -s -rp "SMTP 密码/授权码: " new_pass; echo
                read -rp "是否使用 TLS 加密 (y/N): " use_tls_choice
                local new_use_tls=$([[ "$use_tls_choice" =~ ^[Yy]$ ]] && echo "true" || echo "false")

                if [[ -n "$new_alias" && -n "$new_host" && -n "$new_port" && -n "$new_user" && -n "$new_pass" && -n "$new_from" ]]; then
                    local new_sender
                    new_sender=$(jq -n \
                        --arg alias "$new_alias" --arg host "$new_host" --arg port "$new_port" \
                        --arg user "$new_user" --arg pass "$new_pass" --arg from "$new_from" \
                        --argjson use_tls "$new_use_tls" \
                        '{alias: $alias, host: $host, port: $port, user: $user, pass: $pass, from: $from, use_tls: $use_tls, enabled: true, recipients: []}')
                    
                    senders_json=$(echo "$senders_json" | jq ". += [$new_sender]")
                    save_email_senders "$senders_json"
                    log_info "发件人 '${new_alias}' 已添加。请记得为其 '管理收件人'。"
                else
                    log_error "信息不完整，添加失败。"
                fi
                press_enter_to_continue
                ;;
            m|M)
                if [[ "$sender_count" -eq 0 ]]; then log_warn "没有可修改的发件人。"; press_enter_to_continue; continue; fi
                read -rp "请输入要修改的发件人序号: " index
                if [[ "$index" =~ ^[0-9]+$ ]] && [ "$index" -ge 1 ] && [ "$index" -le "$sender_count" ]; then
                    local real_index=$((index - 1))
                    
                    local current_data
                    current_data=$(echo "$senders_json" | jq ".[$real_index]")
                    local current_alias current_host current_port current_user current_from current_use_tls
                    current_alias=$(echo "$current_data" | jq -r '.alias')
                    current_host=$(echo "$current_data" | jq -r '.host')
                    current_port=$(echo "$current_data" | jq -r '.port')
                    current_user=$(echo "$current_data" | jq -r '.user')
                    current_from=$(echo "$current_data" | jq -r '.from')
                    current_use_tls=$(echo "$current_data" | jq -r '.use_tls')

                    echo "正在修改 '${current_alias}' (序号: $index)。按 Enter 跳过不修改的项。"
                    read -rp "新别名 [${current_alias}]: " new_alias
                    read -rp "新 SMTP Host [${current_host}]: " new_host
                    read -rp "新 SMTP Port [${current_port}]: " new_port
                    read -rp "新发件人地址 [${current_from}]: " new_from
                    read -rp "新 SMTP 用户名 [${current_user}]: " new_user
                    read -s -rp "新 SMTP 密码 [留空不修改]: " new_pass; echo
                    read -rp "是否使用 TLS (当前: ${current_use_tls}) (y/n/留空): " use_tls_choice

                    senders_json=$(echo "$senders_json" | jq ".[$real_index].alias = \"${new_alias:-$current_alias}\"")
                    senders_json=$(echo "$senders_json" | jq ".[$real_index].host = \"${new_host:-$current_host}\"")
                    senders_json=$(echo "$senders_json" | jq ".[$real_index].port = \"${new_port:-$current_port}\"")
                    senders_json=$(echo "$senders_json" | jq ".[$real_index].from = \"${new_from:-$current_from}\"")
                    senders_json=$(echo "$senders_json" | jq ".[$real_index].user = \"${new_user:-$current_user}\"")

                    if [[ -n "$new_pass" ]]; then
                        senders_json=$(echo "$senders_json" | jq ".[$real_index].pass = \"$new_pass\"")
                    fi
                    if [[ "$use_tls_choice" =~ ^[Yy]$ ]]; then
                        senders_json=$(echo "$senders_json" | jq ".[$real_index].use_tls = true")
                    elif [[ "$use_tls_choice" =~ ^[Nn]$ ]]; then
                        senders_json=$(echo "$senders_json" | jq ".[$real_index].use_tls = false")
                    fi

                    save_email_senders "$senders_json"
                    log_info "发件人信息已更新。"
                else
                    log_error "无效序号。"
                fi
                press_enter_to_continue
                ;;
            r|R)
                if [[ "$sender_count" -eq 0 ]]; then log_warn "没有发件人可管理。"; press_enter_to_continue; continue; fi
                read -rp "请输入要管理收件人的发件人序号: " index
                if [[ "$index" =~ ^[0-9]+$ ]] && [ "$index" -ge 1 ] && [ "$index" -le "$sender_count" ]; then
                    manage_email_recipients "$((index - 1))"
                else
                    log_error "无效序号。"
                    press_enter_to_continue
                fi
                ;;
            d|D)
                if [[ "$sender_count" -eq 0 ]]; then log_warn "没有可删除的发件人。"; press_enter_to_continue; continue; fi
                read -rp "请输入要删除的发件人序号: " index
                if [[ "$index" =~ ^[0-9]+$ ]] && [ "$index" -ge 1 ] && [ "$index" -le "$sender_count" ]; then
                    local alias_to_delete
                    alias_to_delete=$(echo "$senders_json" | jq -r ".[$((index-1))].alias")
                    read -rp "确定要删除发件人 '${alias_to_delete}' 吗？(y/N): " confirm
                    if [[ "$confirm" =~ ^[Yy]$ ]]; then
                        senders_json=$(echo "$senders_json" | jq "del(.[$((index-1))])")
                        save_email_senders "$senders_json"
                        log_info "发件人已删除。"
                    fi
                else
                    log_error "无效序号。"
                fi
                press_enter_to_continue
                ;;
            t|T)
                if [[ "$sender_count" -eq 0 ]]; then log_warn "没有可切换状态的发件人。"; press_enter_to_continue; continue; fi
                read -rp "请输入要切换状态的发件人序号: " index
                 if [[ "$index" =~ ^[0-9]+$ ]] && [ "$index" -ge 1 ] && [ "$index" -le "$sender_count" ]; then
                    local real_index=$((index - 1))
                    local current_state new_state
                    current_state=$(echo "$senders_json" | jq ".["$real_index"].enabled")
                    new_state=$([[ "$current_state" == "true" ]] && echo "false" || echo "true")
                    senders_json=$(echo "$senders_json" | jq ".["$real_index"].enabled = $new_state")
                    save_email_senders "$senders_json"
                    log_info "发件人状态已更新为: $new_state"
                else
                    log_error "无效序号。"
                fi
                press_enter_to_continue
                ;;
            0) break ;;
            *) log_error "无效选项。"; press_enter_to_continue ;;
        esac
    done
}


# --- 主通知设定菜单 ---
set_notification_settings() {
    while true; do
        display_header
        echo -e "${BLUE}=== 6. 消息通知设定 ===${NC}"
        echo "此菜单用于管理所有通知方式 (Telegram, 邮件等)。"
        echo ""
        echo -e "${BLUE}━━━━━━━━━━━━━━━━━━ 操作选项 ━━━━━━━━━━━━━━━━━━${NC}"
        echo -e "  1. ${YELLOW}管理 Telegram 机器人${NC}"
        echo -e "  2. ${YELLOW}管理 邮件发件人${NC}"
        echo -e "  3. ${YELLOW}发送测试通知${NC}"
        echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
        echo -e "  0. ${RED}返回主菜单${NC}"
        read -rp "请输入选项: " choice

        case $choice in
            1) manage_telegram_bots ;;
            2) manage_email_senders ;;
            3) send_test_notification_menu ;;
            0) break ;;
            *) log_error "无效选项。"; press_enter_to_continue ;;
        esac
    done
}

# --- [新增 & 修复] 发送测试通知的专用菜单 ---
send_test_notification_menu() {
    while true; do
        display_header
        echo -e "${BLUE}=== 消息通知设定 -> 发送测试通知 ===${NC}"

        local all_configs=()
        local idx=1

        # 加载并显示 Telegram 配置
        local bots_json=$(load_telegram_bots)
        if [[ "$(echo "$bots_json" | jq 'length')" -gt 0 ]]; then
            echo "--- Telegram 机器人 ---"
            local temp_bots_configs
            mapfile -t temp_bots_configs < <(echo "$bots_json" | jq -c '.[]')
            for bot_config in "${temp_bots_configs[@]}"; do
                local alias enabled status
                alias=$(echo "$bot_config" | jq -r '.alias')
                enabled=$(echo "$bot_config" | jq -r '.enabled')
                status=$([[ "$enabled" == "true" ]] && echo -e "${GREEN}已启用${NC}" || echo "已禁用")
                echo "  ${idx}. [TG] ${alias} (${status})"
                all_configs+=("tg_bot||$bot_config")
                ((idx++))
            done
        fi

        # 加载并显示 Email 配置
        local senders_json=$(load_email_senders)
        if [[ "$(echo "$senders_json" | jq 'length')" -gt 0 ]]; then
            echo "--- 邮件发件人 ---"
            local temp_senders_configs
            mapfile -t temp_senders_configs < <(echo "$senders_json" | jq -c '.[]')
            for sender_config in "${temp_senders_configs[@]}"; do
                local alias enabled status
                alias=$(echo "$sender_config" | jq -r '.alias')
                enabled=$(echo "$sender_config" | jq -r '.enabled')
                status=$([[ "$enabled" == "true" ]] && echo -e "${GREEN}已启用${NC}" || echo "已禁用")
                echo "  ${idx}. [Mail] ${alias} (${status})"
                all_configs+=("email_sender||$sender_config")
                ((idx++))
            done
        fi

        if [ ${#all_configs[@]} -eq 0 ]; then
            log_warn "没有配置任何通知方式。请先在 '消息通知设定' 中添加。"
            press_enter_to_continue
            break
        fi

        echo ""
        echo -e "${BLUE}━━━━━━━━━━━━━━━━━━ 操作选项 ━━━━━━━━━━━━━━━━━━${NC}"
        echo "  (输入上方序号以单独测试)"
        echo "  a - 测试所有已启用的通知"
        echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
        echo -e "  0 - ${RED}返回上一级${NC}"
        read -rp "请输入选项: " choice

        # --- 测试消息内容准备 ---
        local test_date_line; test_date_line=$(date)
        local test_subject="[${SCRIPT_NAME}] 测试通知"
        
        case "$choice" in
            a|A)
                log_info "正在向所有已启用的通知方式发送测试消息..."
                local test_body_all="这是一条对所有已启用通道的群发测试消息。"$'\n'"- ${test_date_line}"
                send_notification "$test_body_all" "$test_subject"
                press_enter_to_continue
                ;;
            0) break ;;
            *)
                if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le ${#all_configs[@]} ]; then
                    local config_line="${all_configs[$((choice-1))]}"
                    local config_type="${config_line%%||*}"
                    local config_json="${config_line#*||}"
                    local alias enabled
                    alias=$(echo "$config_json" | jq -r '.alias')
                    enabled=$(echo "$config_json" | jq -r '.enabled')

                    if [[ "$enabled" != "true" ]]; then
                        log_warn "该配置 (${alias}) 未启用，无法发送测试。"
                    else
                        log_info "正在为 [${alias}] 发送测试消息..."
                        if [[ "$config_type" == "tg_bot" ]]; then
                            local test_body_tg="这是一条来自脚本的测试消息。如果您收到此消息，说明您的 'Telegram' 通知配置正确。"$'\n'"- ${test_date_line}"
                            send_telegram_message "$config_json" "$test_body_tg" || true
                        elif [[ "$config_type" == "email_sender" ]]; then
                             local test_body_email="这是一条来自脚本的测试消息。如果您收到此消息，说明您的 '邮件' 通知配置正确。"$'\n'"- ${test_date_line}"
                            send_email_message "$config_json" "$test_body_email" "$test_subject" || true
                        fi
                    fi
                else
                    log_error "无效选项。"
                fi
                press_enter_to_continue
                ;;
        esac
    done
}


set_retention_policy() {
    while true; do
        display_header
        echo -e "${BLUE}=== 7. 设置备份保留策略 (云端) ===${NC}"
        echo -e "请注意：此策略仅对“归档模式”生成的备份文件有效。"
        echo "当前策略: "
        case "$RETENTION_POLICY_TYPE" in
            "none") echo -e "  无保留策略（所有备份将保留）" ;;
            "count") echo -e "  保留最新 ${RETENTION_VALUE} 个备份" ;;
            "days")  echo -e "  保留最近 ${RETENTION_VALUE} 天内的备份" ;;
            *)       echo -e "  未知策略或未设置" ;;
        esac
        echo ""
        echo -e "${BLUE}━━━━━━━━━━━━━━━━━━ 操作选项 ━━━━━━━━━━━━━━━━━━${NC}"
        echo -e "  1. ${YELLOW}设置按数量保留${NC} (例: 保留最新的 5 个)"
        echo -e "  2. ${YELLOW}设置按天数保留${NC} (例: 保留最近 30 天)"
        echo -e "  3. ${YELLOW}关闭保留策略${NC}"
        echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
        echo -e "  0. ${RED}返回主菜单${NC}"
        read -rp "请输入选项: " sub_choice

        case $sub_choice in
            1)
                read -rp "请输入要保留的备份数量 (例如 5): " value_input
                if [[ "$value_input" =~ ^[0-9]+$ ]] && [ "$value_input" -ge 1 ]; then
                    RETENTION_POLICY_TYPE="count"
                    RETENTION_VALUE="$value_input"
                    save_config
                    log_info "已设置保留最新 ${RETENTION_VALUE} 个备份。"
                else
                    log_error "输入无效。"
                fi
                press_enter_to_continue
                ;;
            2)
                read -rp "请输入要保留备份的天数 (例如 30): " value_input
                if [[ "$value_input" =~ ^[0-9]+$ ]] && [ "$value_input" -ge 1 ]; then
                    RETENTION_POLICY_TYPE="days"
                    RETENTION_VALUE="$value_input"
                    save_config
                    log_info "已设置保留最近 ${RETENTION_VALUE} 天。"
                else
                    log_error "输入无效。"
                fi
                press_enter_to_continue
                ;;
            3)
                RETENTION_POLICY_TYPE="none"
                RETENTION_VALUE=0
                save_config
                log_info "已关闭备份保留策略。"
                press_enter_to_continue
                ;;
            0) break ;;
            *) log_error "无效选项。"; press_enter_to_continue ;;
        esac
    done
}


apply_retention_policy() {
    log_info "--- 正在应用备份保留策略 (Rclone) ---"

    if [[ "$RETENTION_POLICY_TYPE" == "none" ]]; then
        log_info "未设置保留策略，跳过清理。"
        return 0
    fi

    local retention_block=$'\n\n'"🧹 保留策略执行完毕"

    for enabled_idx in "${ENABLED_RCLONE_TARGET_INDICES_ARRAY[@]}"; do
        local rclone_target="${RCLONE_TARGETS_ARRAY[$enabled_idx]}"
        log_info "正在为目标 ${rclone_target} 应用保留策略..."

        local backups_list
        backups_list=$(rclone lsf --files-only "${rclone_target}" | grep -E '\.zip$|\.tar\.gz$' || true)
        
        if [[ -z "$backups_list" ]]; then
            log_warn "在 ${rclone_target} 中未找到备份文件，跳过。"
            continue
        fi

        local sorted_backups
        sorted_backups=$(echo "$backups_list" | sort)

        local backups_to_process=()
        mapfile -t backups_to_process <<< "$sorted_backups"

        local deleted_count=0
        local total_found=${#backups_to_process[@]}

        if [[ "$RETENTION_POLICY_TYPE" == "count" ]]; then
            local num_to_delete=$(( total_found - RETENTION_VALUE ))
            if [ "$num_to_delete" -gt 0 ]; then
                log_warn "发现 ${num_to_delete} 个旧备份，将删除..."
                for (( i=0; i<num_to_delete; i++ )); do
                    local file_to_delete="${backups_to_process[$i]}"
                    
                    local target_path_for_delete="${rclone_target}"
                    if [[ "${target_path_for_delete: -1}" != "/" ]]; then
                        target_path_for_delete+="/"
                    fi
                    
                    log_info "正在删除: ${target_path_for_delete}${file_to_delete}"
                    if rclone deletefile "${target_path_for_delete}${file_to_delete}"; then
                        deleted_count=$((deleted_count + 1))
                    fi
                done
            fi
        elif [[ "$RETENTION_POLICY_TYPE" == "days" ]]; then
            local current_timestamp=$(date +%s)
            local cutoff_timestamp=$(( current_timestamp - RETENTION_VALUE * 24 * 3600 ))
            log_warn "将删除 ${RETENTION_VALUE} 天前的备份..."
            for item in "${backups_to_process[@]}"; do
                local timestamp_str
                timestamp_str=$(echo "$item" | grep -o -E '[0-9]{14}' || true)
                if [[ -z "$timestamp_str" ]]; then continue; fi

                local file_timestamp
                file_timestamp=$(date -d "${timestamp_str}" +%s 2>/dev/null || echo 0)

                if [[ "$file_timestamp" -ne 0 && "$file_timestamp" -lt "$cutoff_timestamp" ]]; then
                    local target_path_for_delete="${rclone_target}"
                    if [[ "${target_path_for_delete: -1}" != "/" ]]; then
                        target_path_for_delete+="/"
                    fi

                    log_info "正在删除: ${target_path_for_delete}${item}"
                    if rclone deletefile "${target_path_for_delete}${item}"; then
                        deleted_count=$((deleted_count + 1))
                    fi
                fi
            done
        fi
        log_info "${rclone_target} 清理完成，删除 ${deleted_count} 个文件。"
        retention_block+=$'\n'"路径：${rclone_target}"
        retention_block+=$'\n'"共检测到：${total_found} 个归档文件"
        retention_block+=$'\n'"删除旧文件：${deleted_count} 个 🗑️"
    done
    GLOBAL_NOTIFICATION_REPORT_BODY+="${retention_block}"
}

check_temp_space() {
    local required_space_kb=0
    log_info "正在计算所需临时空间..."
    for path in "${BACKUP_SOURCE_PATHS_ARRAY[@]}"; do
        if [[ -e "$path" ]]; then
            local size_kb
            size_kb=$(du -sk "$path" | awk '{print $1}')
            required_space_kb=$((required_space_kb + size_kb))
        fi
    done

    required_space_kb=$((required_space_kb * 12 / 10))

    local available_space_kb
    available_space_kb=$(df -k "$(dirname "$TEMP_DIR")" | awk 'NR==2 {print $4}')
    
    local required_hr
    required_hr=$(numfmt --to=iec-i --suffix=B --format="%.1f" "$((required_space_kb * 1024))")
    local available_hr
    available_hr=$(numfmt --to=iec-i --suffix=B --format="%.1f" "$((available_space_kb * 1024))")

    log_info "预估需要临时空间: ~${required_hr}, 可用空间: ${available_hr}"

    if [[ "$available_space_kb" -lt "$required_space_kb" ]]; then
        log_error "临时目录空间不足！"
        GLOBAL_NOTIFICATION_FAILURE_REASON="临时目录空间不足 (需要 ~${required_hr}, 可用 ${available_hr})"
        return 1
    fi
    return 0
}

perform_sync_backup() {
    local backup_type="$1"
    local total_paths_to_backup=${#BACKUP_SOURCE_PATHS_ARRAY[@]}
    local any_sync_failed="false"

    log_info "--- ${backup_type} 过程开始 (同步模式) ---"
    log_warn "备份模式: [同步模式]。保留策略和恢复功能在此模式下不可用。"

    local bw_limit_arg=""
    if [[ -n "$RCLONE_BWLIMIT" ]]; then
        bw_limit_arg="--bwlimit ${RCLONE_BWLIMIT}"
        log_info "同步将使用带宽限制: ${RCLONE_BWLIMIT}"
    fi

    for ((i=0; i<total_paths_to_backup; i++)); do
        local path_to_sync="${BACKUP_SOURCE_PATHS_ARRAY[$i]}"
        local path_basename
        path_basename=$(basename "$path_to_sync")
        
        log_info "--- 正在处理路径 $((i+1))/${total_paths_to_backup}: ${path_to_sync} ---"
        
        if [[ ! -e "$path_to_sync" ]]; then
            log_error "路径 '$path_to_sync' 不存在，跳过。"
            GLOBAL_NOTIFICATION_REPORT_BODY+=$'\n\n'"🔄 路径同步"$'\n'"源目录：${path_to_sync}"$'\n'"状态：❌ 失败 (路径不存在)"
            any_sync_failed="true"
            continue
        fi
        
        local path_sync_block=$'\n\n'"🔄 路径同步"$'\n'"源目录：${path_to_sync}"
        path_sync_block+=$'\n'"☁️ 上传状态"
        
        local path_has_failure="false"
        for enabled_idx in "${ENABLED_RCLONE_TARGET_INDICES_ARRAY[@]}"; do
            local rclone_target="${RCLONE_TARGETS_ARRAY[$enabled_idx]}"
            local sync_destination="${rclone_target%/}/${path_basename}"
            local formatted_target
            formatted_target=$(echo "$rclone_target" | sed 's/:/: /')
            
            log_info "正在同步 ${path_to_sync} 到 ${sync_destination}..."
            if rclone sync "$path_to_sync" "$sync_destination" --progress ${bw_limit_arg}; then
                log_info "同步到 ${rclone_target} 成功！"
                path_sync_block+=$'\n'"${formatted_target} ✅ 同步成功"
            else
                log_error "同步到 ${rclone_target} 失败！"
                path_sync_block+=$'\n'"${formatted_target} ❌ 同步失败"
                path_has_failure="true"
                any_sync_failed="true"
            fi
        done
        GLOBAL_NOTIFICATION_REPORT_BODY+="${path_sync_block}"
    done

    if [[ "$any_sync_failed" == "true" ]]; then
        GLOBAL_NOTIFICATION_OVERALL_STATUS="failure"
        return 1
    fi
    return 0
}

perform_archive_backup() {
    local backup_type="$1"
    local total_paths_to_backup=${#BACKUP_SOURCE_PATHS_ARRAY[@]}

    log_info "--- ${backup_type} 过程开始 (归档模式) ---"

    if [[ "$ENABLE_SPACE_CHECK" == "true" ]]; then
        if ! check_temp_space; then
            return 1
        fi
    else
        log_warn "已跳过备份前临时空间检查。"
    fi


    local timestamp
    timestamp=$(date +%Y%m%d%H%M%S)
    
    local archive_ext=".zip"
    if [[ "$COMPRESSION_FORMAT" == "tar.gz" ]]; then
        archive_ext=".tar.gz"
    fi

    local any_op_failed="false"

    if [[ "$PACKAGING_STRATEGY" == "single" ]]; then
        log_info "打包策略: [所有源打包成一个]。"
        local archive_name="all_sources_${timestamp}${archive_ext}"
        local temp_archive_path="${TEMP_DIR}/${archive_name}"

        log_info "正在压缩到 '$archive_name'..."
        local compress_success=true
        if [[ "$COMPRESSION_FORMAT" == "zip" ]]; then
            local zip_args=(-rq -${COMPRESSION_LEVEL})
            if [[ -n "$ZIP_PASSWORD" ]]; then
                zip_args+=(-P "$ZIP_PASSWORD")
            fi
            zip "${zip_args[@]}" "$temp_archive_path" "${BACKUP_SOURCE_PATHS_ARRAY[@]}" || compress_success=false
        else # tar.gz
            GZIP="-${COMPRESSION_LEVEL}" tar -czf "$temp_archive_path" "${BACKUP_SOURCE_PATHS_ARRAY[@]}" || compress_success=false
        fi

        if $compress_success; then
            if ! upload_archive "$temp_archive_path" "$archive_name" "所有源"; then
                any_op_failed="true"
            fi
            rm -f "$temp_archive_path"
        else
            log_error "创建合并压缩包失败！"
            GLOBAL_NOTIFICATION_REPORT_BODY+=$'\n\n'"❌ 错误：创建合并压缩包失败！"
            any_op_failed="true"
        fi

    else # separate
        log_info "打包策略: [每个源单独打包]。"
        for i in "${!BACKUP_SOURCE_PATHS_ARRAY[@]}"; do
            local current_backup_path="${BACKUP_SOURCE_PATHS_ARRAY[$i]}"
            local path_display_name
            path_display_name=$(basename "$current_backup_path")
            local sanitized_path_name
            sanitized_path_name=$(echo "$path_display_name" | sed 's/[^a-zA-Z0-9_-]/_/g')
            local archive_name="${sanitized_path_name}_${timestamp}${archive_ext}"
            local temp_archive_path="${TEMP_DIR}/${archive_name}"
            
            log_info "--- 正在处理路径 $((i+1))/${total_paths_to_backup}: ${current_backup_path} ---"

            if [[ ! -e "$current_backup_path" ]]; then
                log_error "路径 '$current_backup_path' 不存在，跳过。"
                GLOBAL_NOTIFICATION_REPORT_BODY+=$'\n\n'"📂 路径归档"$'\n'"源目录：${current_backup_path}"$'\n'"状态：❌ 失败 (路径不存在)"
                any_op_failed="true"
                continue
            fi

            log_info "正在压缩到 '$archive_name'..."
            local compress_success=true
            if [[ "$COMPRESSION_FORMAT" == "zip" ]]; then
                local zip_args=(-rq -${COMPRESSION_LEVEL})
                if [[ -n "$ZIP_PASSWORD" ]]; then
                    zip_args+=(-P "$ZIP_PASSWORD")
                fi
                (cd "$(dirname "$current_backup_path")" && zip "${zip_args[@]}" "$temp_archive_path" "$(basename "$current_backup_path")") || compress_success=false
            else # tar.gz
                (cd "$(dirname "$current_backup_path")" && GZIP="-${COMPRESSION_LEVEL}" tar -czf "$temp_archive_path" "$(basename "$current_backup_path")") || compress_success=false
            fi

            if ! $compress_success; then
                log_error "文件压缩失败！"
                GLOBAL_NOTIFICATION_REPORT_BODY+=$'\n\n'"📂 路径归档"$'\n'"源目录：${current_backup_path}"$'\n'"状态：❌ 压缩失败"
                any_op_failed="true"
                continue
            fi
            
            if ! upload_archive "$temp_archive_path" "$archive_name" "$current_backup_path"; then
                any_op_failed="true"
            fi
            
            rm -f "$temp_archive_path"
        done
    fi

    if [[ "$any_op_failed" == "false" ]]; then
        apply_retention_policy
        return 0 # Success
    else
        GLOBAL_NOTIFICATION_OVERALL_STATUS="failure"
        return 1 # Failure
    fi
}

perform_backup() {
    local backup_type="$1"
    
    # --- 通知报告生成 ---
    GLOBAL_NOTIFICATION_REPORT_BODY=""
    GLOBAL_NOTIFICATION_FAILURE_REASON=""
    GLOBAL_NOTIFICATION_OVERALL_STATUS="success"

    local readable_time
    readable_time=$(date '+%Y-%m-%d %H:%M:%S')
    local hostname
    hostname=$(hostname)

    local final_subject="[${SCRIPT_NAME}] "

    # 预检
    if [ ${#BACKUP_SOURCE_PATHS_ARRAY[@]} -eq 0 ]; then
        log_error "未设置任何备份源路径。"
        local error_message="📦 ${SCRIPT_NAME}"$'\n'"💻 主机名：${hostname}"$'\n'"🕒 时间：${readable_time}"$'\n'"❌ 状态：备份失败"$'\n'"原因：未设置任何备份源路径。"
        send_notification "$error_message" "${final_subject}备份失败"
        return 1
    fi
    if [ ${#ENABLED_RCLONE_TARGET_INDICES_ARRAY[@]} -eq 0 ]; then
        log_error "未启用任何 Rclone 目标。"
        local error_message="📦 ${SCRIPT_NAME}"$'\n'"💻 主机名：${hostname}"$'\n'"🕒 时间：${readable_time}"$'\n'"❌ 状态：备份失败"$'\n'"原因：未启用任何 Rclone 备份目标。"
        send_notification "$error_message" "${final_subject}备份失败"
        return 1
    fi
    
    # 执行备份
    local backup_result=0
    if [[ "$BACKUP_MODE" == "sync" ]]; then
        perform_sync_backup "$backup_type"
        backup_result=$?
    else
        perform_archive_backup "$backup_type"
        backup_result=$?
    fi

    # --- 构建并发送最终报告 ---
    local final_status_emoji="✅"
    local final_status_text="备份完成"
    local mode_name=$([[ "$BACKUP_MODE" == "sync" ]] && echo "同步模式" || echo "归档模式")


    if [[ "$GLOBAL_NOTIFICATION_OVERALL_STATUS" != "success" ]] || [[ "$backup_result" -ne 0 ]]; then
        final_status_emoji="❌"
        final_status_text="备份失败"
        final_subject+="${final_status_text}"
        if [[ -n "$GLOBAL_NOTIFICATION_FAILURE_REASON" ]]; then
             GLOBAL_NOTIFICATION_REPORT_BODY+=$'\n\n'"原因：${GLOBAL_NOTIFICATION_FAILURE_REASON}"
        fi
    else
        final_subject+="备份成功"
    fi

    local final_header="📦 ${SCRIPT_NAME}"$'\n'"💻 主机名：${hostname}"$'\n'"🕒 时间：${readable_time}"$'\n'"🔧 模式：${backup_type} · ${mode_name}"$'\n'"📁 备份路径：共 ${#BACKUP_SOURCE_PATHS_ARRAY[@]} 个"

    local final_footer="${final_status_emoji} 状态：${final_status_text}"

    GLOBAL_NOTIFICATION_REPORT_BODY="${GLOBAL_NOTIFICATION_REPORT_BODY#"${GLOBAL_NOTIFICATION_REPORT_BODY%%[![:space:]]*}"}"
    
    local final_message="${final_header}"$'\n\n'"${GLOBAL_NOTIFICATION_REPORT_BODY}"$'\n\n'"${final_footer}"

    send_notification "$final_message" "$final_subject"

    if [[ "$final_status_text" == "备份完成" ]]; then
        LAST_AUTO_BACKUP_TIMESTAMP=$(date +%s)
        save_config
    fi
    
    return $backup_result
}


upload_archive() {
    local temp_archive_path="$1"
    local archive_name="$2"
    local source_description="$3"
    local any_upload_succeeded_for_path="false"

    local backup_file_size
    backup_file_size=$(du -h "$temp_archive_path" | awk '{print $1}')
    
    local num_enabled_targets=${#ENABLED_RCLONE_TARGET_INDICES_ARRAY[@]}
    log_info "压缩完成 (大小: ${backup_file_size})。准备上传到 ${num_enabled_targets} 个已启用的目标..."

    local archive_block=$'\n\n'"📂 路径归档"$'\n'"源目录：${source_description}"$'\n'"归档文件：${archive_name}（${backup_file_size}）"
    local upload_block=$'\n'"☁️ 上传状态"
    local has_upload_failure="false"

    local bw_limit_arg=""
    if [[ -n "$RCLONE_BWLIMIT" ]]; then
        bw_limit_arg="--bwlimit ${RCLONE_BWLIMIT}"
        log_info "上传将使用带宽限制: ${RCLONE_BWLIMIT}"
    fi

    for enabled_idx in "${ENABLED_RCLONE_TARGET_INDICES_ARRAY[@]}"; do
        local rclone_target="${RCLONE_TARGETS_ARRAY[$enabled_idx]}"
        local formatted_target
        formatted_target=$(echo "$rclone_target" | sed 's/:/: /')
        
        local destination_path="${rclone_target}"
        if [[ "${destination_path: -1}" != "/" ]]; then
            destination_path+="/"
        fi

        log_info "正在上传到 Rclone 目标: ${destination_path}"
        if rclone copyto "$temp_archive_path" "${destination_path}${archive_name}" --progress ${bw_limit_arg}; then
            log_info "上传到 ${rclone_target} 成功！"
            upload_block+=$'\n'"${formatted_target} ✅ 上传成功"
            any_upload_succeeded_for_path="true"

            if [[ "$ENABLE_INTEGRITY_CHECK" == "true" ]]; then
                log_info "正在对 ${rclone_target} 上的文件进行完整性校验..."
                local check_output=""
                if ! check_output=$(rclone check "$temp_archive_path" "${destination_path}${archive_name}" 2>&1); then
                    log_error "校验失败！云端文件可能已损坏！详细信息:\n${check_output}"
                    upload_block+=" (校验失败 ❌)"
                    has_upload_failure="true"
                else
                    log_info "校验成功！文件完整。"
                    upload_block+=" (校验通过 ✔️)"
                fi
            fi
        else
            log_error "上传到 ${rclone_target} 失败！"
            upload_block+=$'\n'"${formatted_target} ❌ 上传失败"
            has_upload_failure="true"
        fi
    done

    GLOBAL_NOTIFICATION_REPORT_BODY+="${archive_block}${upload_block}"
    
    if [[ "$has_upload_failure" == "true" ]]; then
        GLOBAL_NOTIFICATION_OVERALL_STATUS="failure"
    fi

    if [[ "$any_upload_succeeded_for_path" == "true" ]]; then
        return 0
    else
        GLOBAL_NOTIFICATION_OVERALL_STATUS="failure"
        return 1
    fi
}


manage_rclone_installation() {
    while true; do
        display_header
        echo -e "${BLUE}=== 8. Rclone 安装/卸载 ===${NC}"
        
        if command -v rclone &> /dev/null; then
            local rclone_version
            rclone_version=$(rclone --version | head -n 1)
            echo -e "当前状态: ${GREEN}已安装${NC} (${rclone_version})"
        else
            echo -e "当前状态: ${RED}未安装${NC}"
        fi
        echo ""

        echo -e "${BLUE}━━━━━━━━━━━━━━━━━━ 操作选项 ━━━━━━━━━━━━━━━━━━${NC}"
        echo -e "  1. ${YELLOW}安装或更新 Rclone${NC}"
        echo -e "  2. ${YELLOW}卸载 Rclone${NC}"
        echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
        echo -e "  0. ${RED}返回主菜单${NC}"
        read -rp "请输入选项: " choice

        case $choice in
            1)
                log_info "正在从 rclone.org 下载并执行官方安装脚本..."
                if curl https://rclone.org/install.sh | sudo bash; then
                    log_info "Rclone 安装/更新成功！"
                else
                    log_error "Rclone 安装/更新失败，请检查网络或 sudo 权限。"
                fi
                press_enter_to_continue
                ;;
            2)
                if ! command -v rclone &> /dev/null; then
                    log_warn "Rclone 未安装，无需卸载。"
                    press_enter_to_continue
                    continue
                fi
                read -rp "警告: 这将从系统中移除 Rclone 本体程序。本脚本将无法工作，确定吗？(y/N): " confirm
                if [[ "$confirm" =~ ^[Yy]$ ]]; then
                    log_warn "正在卸载 Rclone..."
                    sudo rm -f /usr/bin/rclone /usr/local/bin/rclone
                    sudo rm -f /usr/local/share/man/man1/rclone.1
                    log_info "Rclone 已卸载。"
                else
                    log_info "已取消卸载。"
                fi
                press_enter_to_continue
                ;;
            0)
                break
                ;;
            *)
                log_error "无效选项。"
                press_enter_to_continue
                ;;
        esac
    done
}

manage_config_import_export() {
    while true; do
        display_header
        echo -e "${BLUE}=== 10. 配置导入/导出 ===${NC}"
        echo "此功能可将当前所有设置导出为便携文件，或从文件导入。"
        
        if [[ -f "$CONFIG_FILE" ]]; then
            local config_size
            config_size=$(du -h "$CONFIG_FILE" 2>/dev/null | awk '{print $1}')
            echo "当前配置文件的位置: ${CONFIG_FILE} (大小: ${config_size:-未知})"
        else
            echo "当前配置文件的位置: 文件不存在"
        fi

        echo ""
        echo -e "${BLUE}━━━━━━━━━━━━━━━━━━ 操作选项 ━━━━━━━━━━━━━━━━━━${NC}"
        echo -e "  1. ${YELLOW}导出配置到文件${NC}"
        echo -e "  2. ${YELLOW}从文件导入配置${NC}"
        echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
        echo -e "  0. ${RED}返回主菜单${NC}"
        read -rp "请输入选项: " choice

        case $choice in
            1)
                local export_file
                export_file="$(dirname "$0")/personal_backup.conf"
                read -rp "确定要将当前配置导出到 ${export_file} 吗？(Y/n): " confirm_export
                if [[ ! "$confirm_export" =~ ^[Nn]$ ]]; then
                    save_config # 确保导出的是最新配置
                    cp "$CONFIG_FILE" "$export_file"
                    log_info "配置已成功导出到: ${export_file}"
                else
                    log_info "已取消导出。"
                fi
                press_enter_to_continue
                ;;
            2)
                read -rp "请输入配置文件的绝对路径: " import_file
                if [[ -f "$import_file" ]]; then
                    read -rp "${RED}警告：这将覆盖当前所有设置！确定要从 '${import_file}' 导入吗？(y/N): ${NC}" confirm_import
                    if [[ "$confirm_import" =~ ^[Yy]$ ]]; then
                        if [[ -f "$CONFIG_FILE" ]]; then
                            cp "$CONFIG_FILE" "${CONFIG_FILE}.bak"
                            log_warn "当前配置已备份到 ${CONFIG_FILE}.bak"
                        fi
                        cp "$import_file" "$CONFIG_FILE"
                        log_info "配置导入成功！请重启脚本以使新配置生效。"
                        press_enter_to_continue
                        exit 0
                    else
                        log_info "已取消导入。"
                    fi
                else
                    log_error "文件 '${import_file}' 不存在。"
                fi
                press_enter_to_continue
                ;;
            0) break ;;
            *) log_error "无效选项。"; press_enter_to_continue ;;
        esac
    done
}

toggle_space_check() {
    display_header
    echo -e "${BLUE}--- 备份前临时空间检查 ---${NC}"
    echo "开启后，在“归档模式”开始前，脚本会先计算所需空间并与可用空间对比。"
    echo -e "关闭此选项可略微加快备份启动速度，但有因空间不足导致备份中途失败的风险。"

    local check_status="已开启"
    if [[ "$ENABLE_SPACE_CHECK" != "true" ]]; then
        check_status="已关闭"
    fi
    echo -e "当前状态: ${GREEN}${check_status}${NC}"

    read -rp "您想切换状态吗？ (y/N): " choice
    if [[ "$choice" =~ ^[Yy]$ ]]; then
        if [[ "$ENABLE_SPACE_CHECK" == "true" ]]; then
            ENABLE_SPACE_CHECK="false"
            log_warn "备份前临时空间检查已关闭。"
        else
            ENABLE_SPACE_CHECK="true"
            log_info "备份前临时空间检查已开启。"
        fi
        save_config
    else
        log_info "状态未改变。"
    fi
    press_enter_to_continue
}

system_maintenance_menu() {
    while true; do
        display_header
        echo -e "${BLUE}=== 11. 日志与维护 ===${NC}"
        echo ""
        local log_info_str="(文件不存在)"
        if [[ -f "$LOG_FILE" ]]; then
            local log_size
            log_size=$(du -h "$LOG_FILE" 2>/dev/null | awk '{print $1}')
            log_info_str="(大小: ${log_size}, 位置: ${LOG_FILE})"
        fi

        local level_names=("" "DEBUG" "INFO" "WARN" "ERROR")
        local console_level_name=${level_names[$CONSOLE_LOG_LEVEL]}
        local file_level_name=${level_names[$FILE_LOG_LEVEL]}

        echo -e "  1. ${YELLOW}设置日志级别${NC} (终端: ${console_level_name}, 文件: ${file_level_name})"
        echo -e "  2. ${YELLOW}查看日志文件${NC} ${log_info_str}"
        local space_check_status=$([[ "$ENABLE_SPACE_CHECK" == "true" ]] && echo "已开启" || echo "已关闭")
        echo -e "  3. ${YELLOW}切换备份前空间检查${NC} (当前: ${space_check_status})"
        echo ""
        echo -e "  0. ${RED}返回主菜单${NC}"
        read -rp "请输入选项: " choice

        case $choice in
            1) manage_log_settings ;;
            2)
                if [[ -f "$LOG_FILE" ]]; then
                    less "$LOG_FILE"
                else
                    log_warn "日志文件不存在。"
                    press_enter_to_continue
                fi
                ;;
            3) toggle_space_check ;;
            0) break ;;
            *) log_error "无效选项。"; press_enter_to_continue ;;
        esac
    done
}

manage_log_settings() {
    while true; do
        display_header
        echo -e "${BLUE}--- 设置日志级别 ---${NC}"

        local level_names=("" "DEBUG" "INFO" "WARN" "ERROR")
        local console_level_name=${level_names[$CONSOLE_LOG_LEVEL]}
        local file_level_name=${level_names[$FILE_LOG_LEVEL]}

        echo -e "当前终端日志级别: ${GREEN}${console_level_name}${NC}"
        echo -e "当前文件日志级别: ${GREEN}${file_level_name}${NC}"
        echo ""
        echo "日志级别说明:"
        echo "  - DEBUG: 最详细，用于排错"
        echo "  - INFO : 显示主要流程信息 (默认)"
        echo "  - WARN : 只显示警告和错误"
        echo "  - ERROR: 只显示错误"
        echo ""
        echo -e "${BLUE}━━━━━━━━━━━━━━━━━━ 操作选项 ━━━━━━━━━━━━━━━━━━${NC}"
        echo -e "  1. ${YELLOW}设置终端日志级别${NC}"
        echo -e "  2. ${YELLOW}设置文件日志级别${NC}"
        echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
        echo -e "  0. ${RED}返回${NC}"
        read -rp "请输入选项: " choice

        case $choice in
            1) set_log_level "console" ;;
            2) set_log_level "file" ;;
            0) break ;;
            *) log_error "无效选项。"; press_enter_to_continue ;;
        esac
    done
}

set_log_level() {
    local target="$1" # "console" or "file"
    
    local current_level_val
    if [[ "$target" == "console" ]]; then
        current_level_val=$CONSOLE_LOG_LEVEL
    else
        current_level_val=$FILE_LOG_LEVEL
    fi
    
    echo "请为 ${target} 选择新的日志级别 [当前: ${current_level_val}]:"
    echo "  1. DEBUG"
    echo "  2. INFO"
    echo "  3. WARN"
    echo "  4. ERROR"
    read -rp "请输入选项 (1-4): " level_choice
    
    if [[ "$level_choice" =~ ^[1-4]$ ]]; then
        if [[ "$target" == "console" ]]; then
            CONSOLE_LOG_LEVEL=$level_choice
        else
            FILE_LOG_LEVEL=$level_choice
        fi
        save_config
        log_info "${target} 日志级别已更新。"
    else
        log_error "无效输入。"
    fi
    press_enter_to_continue
}


uninstall_script() {
    display_header
    echo -e "${RED}=== 99. 卸载脚本 ===${NC}"
    read -rp "警告：这将删除所有脚本文件、配置文件和日志文件。确定吗？(y/N): " confirm
    if [[ "$confirm" =~ ^[Yy]$ ]]; then
        log_warn "开始卸载..."
        rm -f "$CONFIG_FILE" 2>/dev/null && log_info "删除配置文件: $CONFIG_FILE"
        rm -f "$TELEGRAM_BOTS_CONFIG_FILE" 2>/dev/null && log_info "删除 Telegram 配置: $TELEGRAM_BOTS_CONFIG_FILE"
        rm -f "$EMAIL_SENDERS_CONFIG_FILE" 2>/dev/null && log_info "删除 Email 配置: $EMAIL_SENDERS_CONFIG_FILE"
        rmdir "$CONFIG_DIR" 2>/dev/null && log_info "删除配置目录: $CONFIG_DIR"
        rm -f "$LOG_FILE" 2>/dev/null && log_info "删除日志文件: $LOG_FILE"
        rm -f "${LOG_FILE}".*.rotated 2>/dev/null && log_info "删除轮转日志"
        rmdir "$LOG_DIR" 2>/dev/null && log_info "删除日志目录: $LOG_DIR"
        log_warn "删除脚本文件: $(readlink -f "$0")" && rm -f "$(readlink -f "$0")"
        echo -e "${GREEN}卸载完成。${NC}"
        exit 0
    else
        log_info "取消卸载。"
    fi
    press_enter_to_continue
}

show_main_menu() {
    display_header

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
    
    local mode_text="归档模式"
    if [[ "$BACKUP_MODE" == "sync" ]]; then
        mode_text="同步模式"
    fi
    echo -e "备份模式: ${GREEN}${mode_text}${NC}    备份源: ${#BACKUP_SOURCE_PATHS_ARRAY[@]} 个  已启用目标: ${#ENABLED_RCLONE_TARGET_INDICES_ARRAY[@]} 个"

    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━ 功能选项 ━━━━━━━━━━━━━━━━━━${NC}"
    local human_cron_info
    human_cron_info=$(parse_cron_to_human "$(get_cron_job_info)")
    echo -e "  1. ${YELLOW}自动备份与计划任务${NC} (间隔: ${AUTO_BACKUP_INTERVAL_DAYS} 天, Cron: ${human_cron_info})"
    echo -e "  2. ${YELLOW}手动备份${NC}"
    
    local strategy_text="独立打包"
    if [[ "$PACKAGING_STRATEGY" == "single" ]]; then
        strategy_text="合并打包"
    fi
    local mode_text_short="归档"
    if [[ "$BACKUP_MODE" == "sync" ]]; then
        mode_text_short="同步"
    fi
    echo -e "  3. ${YELLOW}自定义备份路径与模式${NC} (路径: ${#BACKUP_SOURCE_PATHS_ARRAY[@]} 个, 打包: ${strategy_text}, 模式: ${mode_text_short})"
    
    local format_text="$COMPRESSION_FORMAT"
    if [[ "$COMPRESSION_FORMAT" == "zip" && -n "$ZIP_PASSWORD" ]]; then
        format_text+=" (有密码)"
    fi
    echo -e "  4. ${YELLOW}压缩包格式与选项${NC} (当前: ${format_text})"
    echo -e "  5. ${YELLOW}云存储设定${NC} (Rclone)"

    # --- [重构] 新的通知状态显示逻辑 ---
    local enabled_methods=()
    if [[ -f "$TELEGRAM_BOTS_CONFIG_FILE" ]] && [[ "$(jq 'map(select(.enabled == true)) | length' "$TELEGRAM_BOTS_CONFIG_FILE" 2>/dev/null)" -gt 0 ]]; then
        enabled_methods+=("Telegram")
    fi
    if [[ -f "$EMAIL_SENDERS_CONFIG_FILE" ]] && [[ "$(jq 'map(select(.enabled == true)) | length' "$EMAIL_SENDERS_CONFIG_FILE" 2>/dev/null)" -gt 0 ]]; then
        enabled_methods+=("邮件")
    fi

    local notification_status_display
    if [ ${#enabled_methods[@]} -gt 0 ]; then
        notification_status_display=$(IFS=,; echo "${enabled_methods[*]}")
    else
        notification_status_display="已禁用"
    fi
    echo -e "  6. ${YELLOW}消息通知设定${NC} (当前: ${notification_status_display})"

    local retention_status_text="已禁用"
    if [[ "$RETENTION_POLICY_TYPE" == "count" ]]; then
        retention_status_text="保留 ${RETENTION_VALUE} 个"
    elif [[ "$RETENTION_POLICY_TYPE" == "days" ]]; then
        retention_status_text="保留 ${RETENTION_VALUE} 天"
    fi
    echo -e "  7. ${YELLOW}设置备份保留策略${NC} (当前: ${retention_status_text})"

    local rclone_version_text="(未安装)"
    if command -v rclone &> /dev/null; then
        local rclone_version
        rclone_version=$(rclone --version | head -n 1)
        rclone_version_text="(${rclone_version})"
    fi
    echo -e "  8. ${YELLOW}Rclone 安装/卸载${NC} ${rclone_version_text}"
    
    echo -e "  9. ${YELLOW}从云端恢复到本地${NC} (仅适用于归档模式)"
    echo -e "  10. ${YELLOW}配置导入/导出${NC}"
    echo -e "  11. ${YELLOW}日志与维护${NC}"

    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "  0. ${RED}退出脚本${NC}"
    echo -e "  99. ${RED}卸载脚本${NC}"
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
}

process_menu_choice() {
    read -rp "请输入选项: " choice
    case $choice in
        1) manage_auto_backup_menu ;;
        2) manual_backup || true ;;
        3) set_backup_path_and_mode ;;
        4) manage_compression_settings ;;
        5) set_cloud_storage ;;
        6) set_notification_settings ;;
        7) set_retention_policy ;;
        8) manage_rclone_installation ;;
        9) restore_backup ;;
        10) manage_config_import_export ;;
        11) system_maintenance_menu ;;
        0) echo -e "${GREEN}感谢使用！${NC}"; exit 0 ;;
        99) uninstall_script ;;
        *) log_error "无效选项。"; press_enter_to_continue ;;
    esac
}

check_auto_backup() {
    load_config
    rotate_log_if_needed
    acquire_lock
    
    local current_timestamp
    current_timestamp=$(date +%s)
    local interval_seconds
    interval_seconds=$(( AUTO_BACKUP_INTERVAL_DAYS * 24 * 3600 ))

    if [ ${#BACKUP_SOURCE_PATHS_ARRAY[@]} -eq 0 ]; then
        log_error "自动备份失败：未设置备份源。"
        return 1
    fi
    if [ ${#ENABLED_RCLONE_TARGET_INDICES_ARRAY[@]} -eq 0 ]; then
        log_error "自动备份失败：未启用 Rclone 目标。"
        return 1
    fi

    # [修复] 将时间计算和比较操作分开，以确保逻辑正确
    local elapsed_time=$(( current_timestamp - LAST_AUTO_BACKUP_TIMESTAMP ))
    if [[ "$LAST_AUTO_BACKUP_TIMESTAMP" -eq 0 || "$elapsed_time" -ge "$interval_seconds" ]]; then
        log_info "执行自动备份..."
        perform_backup "自动备份 (Cron)"
    else
        log_info "未到自动备份时间。"
    fi
}

main() {
    initialize_directories

    TEMP_DIR=$(mktemp -d -t personal_backup_rclone_XXXXXX)
    if [ ! -d "$TEMP_DIR" ]; then
        echo -e "${RED}[ERROR] 无法创建临时目录。${NC}"
        exit 1
    fi
    
    if [[ "$1" == "check_auto_backup" ]]; then
        check_auto_backup
        exit 0
    fi
    
    # 交互模式
    load_config
    rotate_log_if_needed
    acquire_lock

    if ! check_dependencies; then
        exit 1
    fi

    while true; do
        show_main_menu
        process_menu_choice
    done
}

# ================================================================
# ===           RCLONE 云存储管理函数 (无需修改)                 ===
# ================================================================

prompt_and_add_target() {
    local remote_name="$1"
    local source_of_creation="$2"

    read -rp "您想现在就为此新远程端设置一个备份目标路径吗? (Y/n): " confirm_add_target
    if [[ ! "$confirm_add_target" =~ ^[Nn]$ ]]; then
        log_info "正在为远程端 '${remote_name}' 选择路径..."
        if choose_rclone_path "$remote_name"; then
            local remote_path="$CHOSEN_RCLONE_PATH"
            RCLONE_TARGETS_ARRAY+=("${remote_name}:${remote_path}")
            RCLONE_TARGETS_METADATA_ARRAY+=("${source_of_creation}")
            save_config
            log_info "已成功添加并保存备份目标: ${remote_name}:${remote_path}"
        else
            log_warn "已取消为 '${remote_name}' 添加备份目标。您可以稍后在“查看/管理目标”菜单中添加。"
        fi
    fi
}

get_remote_name() {
    local prompt_message="$1"
    read -rp "为这个新的远程端起一个名字 (例如: ${prompt_message}): " remote_name
    if [[ -z "$remote_name" || "$remote_name" =~ [[:space:]] ]]; then
        log_error "错误: 远程端名称不能为空或包含空格。"
        return 1
    fi
    REPLY="$remote_name"
    return 0
}

create_rclone_s3_remote() {
    display_header
    echo -e "${BLUE}--- 创建 S3 兼容远程端 ---${NC}"
    get_remote_name "myr2" || { press_enter_to_continue; return 1; }
    local remote_name=$REPLY

    echo "请选择您的 S3 提供商:"
    echo "1. Cloudflare R2"
    echo "2. Amazon Web Services (AWS) S3"
    echo "3. MinIO"
    echo "4. 其他 (手动输入)"
    read -rp "请输入选项: " provider_choice

    local provider=""
    local endpoint=""

    case "$provider_choice" in
        1) provider="Cloudflare"; read -rp "请输入 Cloudflare R2 Endpoint URL (例如 https://<account_id>.r2.cloudflarestorage.com): " endpoint ;;
        2) provider="AWS" ;;
        3) provider="Minio"; read -rp "请输入 MinIO Endpoint URL (例如 http://192.168.1.10:9000): " endpoint ;;
        4) read -rp "请输入提供商代码 (例如 Ceph, DigitalOcean, Wasabi): " provider; read -rp "请输入 Endpoint URL (如果需要): " endpoint ;;
        *) log_error "无效选项。"; press_enter_to_continue; return 1;
    esac

    read -rp "请输入 Access Key ID: " access_key_id
    read -s -rp "请输入 Secret Access Key: " secret_access_key
    echo ""

    log_info "正在创建 Rclone 远程端: ${remote_name}..."

    local rclone_create_cmd
    rclone_create_cmd=(rclone config create "$remote_name" s3 provider "$provider" access_key_id "$access_key_id" secret_access_key "$secret_access_key")
    if [[ -n "$endpoint" ]]; then
        rclone_create_cmd+=(endpoint "$endpoint")
    fi

    if "${rclone_create_cmd[@]}"; then
        log_info "远程端 '${remote_name}' 创建成功！"
        prompt_and_add_target "$remote_name" "由助手创建"
    else
        log_error "远程端创建失败！请检查您的输入或 Rclone 的错误提示。"
        return 1
    fi
    press_enter_to_continue
}

create_rclone_b2_remote() {
    display_header
    echo -e "${BLUE}--- 创建 Backblaze B2 远程端 ---${NC}"
    get_remote_name "b2_backup" || { press_enter_to_continue; return 1; }
    local remote_name=$REPLY

    read -rp "请输入 B2 Account ID 或 Application Key ID: " account_id
    read -s -rp "请输入 B2 Application Key: " app_key
    echo ""

    log_info "正在创建 Rclone 远程端: ${remote_name}..."
    if rclone config create "$remote_name" b2 account "$account_id" key "$app_key"; then
        log_info "远程端 '${remote_name}' 创建成功！"
        prompt_and_add_target "$remote_name" "由助手创建"
    else
        log_error "远程端创建失败！"
        return 1
    fi
    press_enter_to_continue
}

create_rclone_azureblob_remote() {
    display_header
    echo -e "${BLUE}--- 创建 Microsoft Azure Blob Storage 远程端 ---${NC}"
    get_remote_name "myazure" || { press_enter_to_continue; return 1; }
    local remote_name=$REPLY

    read -rp "请输入 Azure Storage Account Name: " account_name
    read -s -rp "请输入 Azure Storage Account Key: " account_key
    echo ""

    log_info "正在创建 Rclone 远程端: ${remote_name}..."
    if rclone config create "$remote_name" azureblob account "$account_name" key "$account_key"; then
        log_info "远程端 '${remote_name}' 创建成功！"
        prompt_and_add_target "$remote_name" "由助手创建"
    else
        log_error "远程端创建失败！"
        return 1
    fi
    press_enter_to_continue
}

create_rclone_mega_remote() {
    display_header
    echo -e "${BLUE}--- 创建 Mega.nz 远程端 ---${NC}"
    get_remote_name "mymega" || { press_enter_to_continue; return 1; }
    local remote_name=$REPLY

    read -rp "请输入 Mega 用户名 (邮箱): " user
    read -s -rp "请输入 Mega 密码: " password
    echo ""
    local obscured_pass=$(rclone obscure "$password")

    log_info "正在创建 Rclone 远程端: ${remote_name}..."
    if rclone config create "$remote_name" mega user "$user" pass "$obscured_pass"; then
        log_info "远程端 '${remote_name}' 创建成功！"
        prompt_and_add_target "$remote_name" "由助手创建"
    else
        log_error "远程端创建失败！"
        return 1
    fi
    press_enter_to_continue
}

create_rclone_pcloud_remote() {
    display_header
    echo -e "${BLUE}--- 创建 pCloud 远程端 ---${NC}"
    get_remote_name "mypcloud" || { press_enter_to_continue; return 1; }
    local remote_name=$REPLY

    read -rp "请输入 pCloud 用户名 (邮箱): " user
    read -s -rp "请输入 pCloud 密码: " password
    echo ""
    local obscured_pass=$(rclone obscure "$password")

    log_info "正在创建 Rclone 远程端: ${remote_name}..."
    log_warn "Rclone 将尝试使用您的用户名和密码获取授权令牌..."

    if rclone config create "$remote_name" pcloud username "$user" password "$obscured_pass"; then
        log_info "远程端 '${remote_name}' 创建成功！"
        prompt_and_add_target "$remote_name" "由助手创建"
    else
        log_error "远程端创建失败！可能是密码错误或需要双因素认证。"
        return 1
    fi
    press_enter_to_continue
}

create_rclone_webdav_remote() {
    display_header
    echo -e "${BLUE}--- 创建 WebDAV 远程端 ---${NC}"
    get_remote_name "mydav" || { press_enter_to_continue; return 1; }
    local remote_name=$REPLY

    read -rp "请输入 WebDAV URL (例如 https://dav.box.com/dav): " url
    read -rp "请输入用户名: " user
    read -s -rp "请输入密码: " password
    echo ""
    local obscured_pass=$(rclone obscure "$password")

    log_info "正在创建 Rclone 远程端: ${remote_name}..."
    if rclone config create "$remote_name" webdav url "$url" user "$user" pass "$obscured_pass"; then
        log_info "远程端 '${remote_name}' 创建成功！"
        prompt_and_add_target "$remote_name" "由助手创建"
    else
        log_error "远程端创建失败！"
        return 1
    fi
    press_enter_to_continue
}

create_rclone_sftp_remote() {
    display_header
    echo -e "${BLUE}--- 创建 SFTP 远程端 ---${NC}"
    get_remote_name "myserver" || { press_enter_to_continue; return 1; }
    local remote_name=$REPLY

    read -rp "请输入主机名或 IP 地址: " host
    read -rp "请输入用户名: " user
    read -rp "请输入端口号 [默认 22]: " port
    port=${port:-22}

    read -rp "使用密码(p)还是 SSH 密钥文件(k)进行认证? (p/k): " auth_choice
    local pass_obscured=""
    local key_file=""

    if [[ "$auth_choice" == "p" ]]; then
        read -s -rp "请输入密码: " password
        echo ""
        pass_obscured=$(rclone obscure "$password")
    elif [[ "$auth_choice" == "k" ]]; then
        read -rp "请输入 SSH 私钥文件的绝对路径 (例如 /home/user/.ssh/id_rsa): " key_file
        if [[ ! -f "$key_file" ]]; then
            log_error "错误: 密钥文件不存在。"; press_enter_to_continue; return 1;
        fi
    else
        log_error "无效选项。"; press_enter_to_continue; return 1;
    fi

    log_info "正在创建 Rclone 远程端: ${remote_name}..."

    local rclone_create_cmd
    rclone_create_cmd=(rclone config create "$remote_name" sftp host "$host" user "$user" port "$port")
    if [[ -n "$pass_obscured" ]]; then
        rclone_create_cmd+=(pass "$pass_obscured")
    elif [[ -n "$key_file" ]]; then
        rclone_create_cmd+=(key_file "$key_file")
    fi

    if "${rclone_create_cmd[@]}"; then
        log_info "远程端 '${remote_name}' 创建成功！"
        prompt_and_add_target "$remote_name" "由助手创建"
        log_warn "提示: 首次连接 SFTP 服务器时，Rclone 可能需要您确认主机的密钥指纹。"
    else
        log_error "远程端创建失败！"
        return 1
    fi
    press_enter_to_continue
}

create_rclone_ftp_remote() {
    display_header
    echo -e "${BLUE}--- 创建 FTP 远程端 ---${NC}"
    get_remote_name "myftp" || { press_enter_to_continue; return 1; }
    local remote_name=$REPLY

    read -rp "请输入主机名或 IP 地址: " host
    read -rp "请输入用户名: " user
    read -s -rp "请输入密码: " password
    echo ""
    local obscured_pass=$(rclone obscure "$password")
    read -rp "请输入端口号 [默认 21]: " port
    port=${port:-21}

    log_info "正在创建 Rclone 远程端: ${remote_name}..."
    if rclone config create "$remote_name" ftp host "$host" user "$user" pass "$obscured_pass" port "$port"; then
        log_info "远程端 '${remote_name}' 创建成功！"
        prompt_and_add_target "$remote_name" "由助手创建"
    else
        log_error "远程端创建失败！"
        return 1
    fi
    press_enter_to_continue
}

create_rclone_crypt_remote() {
    display_header
    echo -e "${BLUE}--- 创建 Crypt 加密远程端 ---${NC}"
    echo -e "${YELLOW}Crypt 会加密您上传到另一个远程端的文件名和内容。${NC}"
    get_remote_name "my_encrypted_remote" || { press_enter_to_continue; return 1; }
    local remote_name=$REPLY

    echo ""
    log_info "可用的远程端列表："
    rclone listremotes
    echo ""
    read -rp "请输入您要加密的目标远程端路径 (例如: myr2:my_encrypted_bucket): " target_remote

    echo -e "${YELLOW}您需要设置两个密码，第二个是盐值，用于进一步增强安全性。请务必牢记！${NC}"
    read -s -rp "请输入密码 (password): " pass1
    echo ""
    read -s -rp "请再次输入密码进行确认: " pass1_confirm
    echo ""
    if [[ "$pass1" != "$pass1_confirm" ]]; then
        log_error "两次输入的密码不匹配！"; press_enter_to_continue; return 1;
    fi

    read -s -rp "请输入盐值密码 (salt/password2)，可以与上一个不同: " pass2
    echo ""
    read -s -rp "请再次输入盐值密码进行确认: " pass2_confirm
    echo ""
    if [[ "$pass2" != "$pass2_confirm" ]]; then
        log_error "两次输入的盐值密码不匹配！"; press_enter_to_continue; return 1;
    fi

    local obscured_pass1=$(rclone obscure "$pass1")
    local obscured_pass2=$(rclone obscure "$pass2")

    log_info "正在创建 Rclone 远程端: ${remote_name}..."
    if rclone config create "$remote_name" crypt remote "$target_remote" password "$obscured_pass1" password2 "$obscured_pass2"; then
        log_info "加密远程端 '${remote_name}' 创建成功！"
        prompt_and_add_target "$remote_name" "由助手创建"
        log_info "现在您可以像使用普通远程端一样使用 '${remote_name}:'，所有数据都会在后台自动加解密。"
    else
        log_error "远程端创建失败！"
        return 1
    fi
    press_enter_to_continue
}

create_rclone_alias_remote() {
    display_header
    echo -e "${BLUE}--- 创建 Alias 别名远程端 ---${NC}"
    echo -e "${YELLOW}Alias 可以为另一个远程端的深层路径创建一个简短的别名。${NC}"
    get_remote_name "my_shortcut" || { press_enter_to_continue; return 1; }
    local remote_name=$REPLY

    echo ""
    log_info "可用的远程端列表："
    rclone listremotes
    echo ""
    read -rp "请输入您要为其创建别名的目标远程端路径 (例如: myr2:path/to/my/files): " target_remote

    log_info "正在创建 Rclone 远程端: ${remote_name}..."
    if rclone config create "$remote_name" alias remote "$target_remote"; then
        log_info "别名远程端 '${remote_name}' 创建成功！"
        prompt_and_add_target "$remote_name" "由助手创建"
        log_info "现在 '${remote_name}:' 就等同于 '${target_remote}'。"
    else
        log_error "远程端创建失败！"
        return 1
    fi
    press_enter_to_continue
}

create_rclone_remote_wizard() {
    while true; do
        display_header
        echo -e "${BLUE}=== 创建新的 Rclone 远程端 ===${NC}"
        echo "请选择您要创建的云存储类型："
        echo ""
        echo -e "${BLUE}━━━━━━━━━━━━━━━━━━ 对象存储/云盘 ━━━━━━━━━━━━━━━━━━${NC}"
        echo -e "  1. ${YELLOW}S3 兼容存储 (如 R2, AWS S3, MinIO)${NC}"
        echo -e "  2. ${YELLOW}Backblaze B2${NC}"
        echo -e "  3. ${YELLOW}Microsoft Azure Blob Storage${NC}"
        echo -e "  4. ${YELLOW}Mega.nz${NC}"
        echo -e "  5. ${YELLOW}pCloud${NC}"
        echo ""
        echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━ 传统协议 ━━━━━━━━━━━━━━━━━━━${NC}"
        echo -e "  6. ${YELLOW}WebDAV${NC}"
        echo -e "  7. ${YELLOW}SFTP${NC}"
        echo -e "  8. ${YELLOW}FTP${NC}"
        echo ""
        echo -e "${BLUE}━━━━━━━━━━━━━━ 功能性远程端 (包装器) ━━━━━━━━━━━━━━${NC}"
        echo -e "  9. ${YELLOW}Crypt (加密一个现有远程端)${NC}"
        echo -e "  10. ${YELLOW}Alias (为一个远程路径创建别名)${NC}"
        echo ""
        echo -e "重要提示: 对于 Google Drive, Dropbox, OneDrive 等需要"
        echo -e "浏览器授权的云服务，请在主菜单 (选项 5) 中选择"
        echo -e "*启动 Rclone 官方配置工具* 来进行设置。"
        echo ""
        echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
        echo -e "  0. ${RED}返回上一级菜单${NC}"
        read -rp "请输入选项: " choice

        case "$choice" in
            1) create_rclone_s3_remote || true ;;
            2) create_rclone_b2_remote || true ;;
            3) create_rclone_azureblob_remote || true ;;
            4) create_rclone_mega_remote || true ;;
            5) create_rclone_pcloud_remote || true ;;
            6) create_rclone_webdav_remote || true ;;
            7) create_rclone_sftp_remote || true ;;
            8) create_rclone_ftp_remote || true ;;
            9) create_rclone_crypt_remote || true ;;
            10) create_rclone_alias_remote || true ;;
            0) break ;;
            *) log_error "无效选项。"; press_enter_to_continue ;;
        esac
    done
}

check_rclone_remote_exists() {
    local remote_name="$1"
    if rclone listremotes | grep -q "^${remote_name}:"; then
        return 0
    else
        return 1
    fi
}

get_rclone_direct_contents() {
    local rclone_target="$1"
    log_debug "正在获取 Rclone 目标 '${rclone_target}' 的内容..."

    local contents=()
    local folders_list
    folders_list=$(rclone lsf --dirs-only "${rclone_target}" 2>/dev/null || true)
    local files_list
    files_list=$(rclone lsf --files-only "${rclone_target}" 2>/dev/null || true)

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

        echo ""
        echo -e "${BLUE}━━━━━━━━━━━━━━━━━━ 操作选项 ━━━━━━━━━━━━━━━━━━${NC}"
        echo "  (输入上方序号以进入文件夹)"
        if [[ "$current_remote_path" != "/" ]]; then
            echo -e "  ${YELLOW}m${NC} - 返回上一级目录"
        fi
        echo -e "  ${YELLOW}k${NC} - 将当前路径 '${current_remote_path}' 设为目标"
        echo -e "  ${YELLOW}a${NC} - 手动输入新路径"
        echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
        echo -e "  ${RED}x${NC} - 取消并返回"
        read -rp "请输入您的选择 (数字或字母): " choice

        case "$choice" in
            "m" | "M" )
                if [[ "$current_remote_path" != "/" ]]; then
                    local parent_dir
                    parent_dir=$(dirname "${current_remote_path%/}")
                    if [[ "$parent_dir" != "/" ]]; then
                        current_remote_path="${parent_dir}/"
                    else
                        current_remote_path="/"
                    fi
                fi
                ;;
            [0-9]* )
                if [ "$choice" -ge 1 ] && [ "$choice" -le ${#remote_contents_array[@]} ]; then
                    local chosen_item="${remote_contents_array[$((choice-1))]}"
                    if echo "$chosen_item" | grep -q " (文件夹)$"; then
                        local chosen_folder
                        chosen_folder=$(echo "$chosen_item" | sed 's/\ (文件夹)$//')
                        if [[ "$current_remote_path" == "/" ]]; then
                            current_remote_path="/${chosen_folder}/"
                        else
                            current_remote_path="${current_remote_path%/}/${chosen_folder}/"
                        fi
                    else
                        log_warn "不能进入文件。"; press_enter_to_continue
                    fi
                else
                    log_error "无效序号。"; press_enter_to_continue
                fi
                ;;
            [kK] )
                final_selected_path="$current_remote_path"
                break
                ;;
            [aA] )
                read -rp "请输入新的目标路径 (e.g., /backups/path/): " new_path_input
                local new_path="$new_path_input"
                if [[ "${new_path:0:1}" != "/" ]]; then
                    new_path="/${new_path}"
                fi
                new_path=$(echo "$new_path" | sed 's#//#/#g')
                final_selected_path="$new_path"
                break
                ;;
            [xX] ) return 1 ;;
            * ) log_error "无效输入。"; press_enter_to_continue ;;
        esac
    done

    CHOSEN_RCLONE_PATH="$final_selected_path"
    return 0
}

view_and_manage_rclone_targets() {
    local needs_saving="false"
    while true; do
        display_header
        echo -e "${BLUE}=== 查看、管理和启用备份目标 ===${NC}"

        if [ ${#RCLONE_TARGETS_ARRAY[@]} -eq 0 ]; then
            log_warn "当前没有配置任何 Rclone 目标。"
        else
            echo "已配置的 Rclone 目标列表:"
            for i in "${!RCLONE_TARGETS_ARRAY[@]}"; do
                local is_enabled="false"
                for enabled_idx in "${ENABLED_RCLONE_TARGET_INDICES_ARRAY[@]}"; do
                    if [[ "$i" -eq "$enabled_idx" ]]; then
                        is_enabled="true"; break;
                    fi
                done

                local metadata="${RCLONE_TARGETS_METADATA_ARRAY[$i]}"
                echo -n "$((i+1)). ${RCLONE_TARGETS_ARRAY[$i]} "
                if [[ -n "$metadata" ]]; then
                    echo -n "(${metadata}) "
                fi

                if [[ "$is_enabled" == "true" ]]; then
                    echo -e "[${GREEN}已启用${NC}]"
                else
                    echo "[已禁用]"
                fi
            done
        fi

        echo ""
        echo -e "${BLUE}━━━━━━━━━━━━━━━━━━ 操作选项 ━━━━━━━━━━━━━━━━━━${NC}"
        echo "  a - 添加新目标"
        echo "  d - 删除目标"
        echo "  m - 修改目标路径"
        echo "  t - 切换启用/禁用状态"
        echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
        echo -e "  0 - ${RED}保存并返回${NC}"
        read -rp "请输入选项: " choice

        case "$choice" in
            a|A)
                read -rp "请输入您已通过 'rclone config' 或助手配置好的远程端名称: " remote_name
                if ! check_rclone_remote_exists "$remote_name"; then
                    log_error "错误: Rclone 远程端 '${remote_name}' 不存在！"
                elif choose_rclone_path "$remote_name"; then
                    local remote_path="$CHOSEN_RCLONE_PATH"
                    RCLONE_TARGETS_ARRAY+=("${remote_name}:${remote_path}")
                    RCLONE_TARGETS_METADATA_ARRAY+=("手动添加")
                    needs_saving="true"
                    log_info "已成功添加目标: ${remote_name}:${remote_path}"
                else
                    log_warn "已取消添加目标。"
                fi
                press_enter_to_continue
                ;;

            d|D)
                if [ ${#RCLONE_TARGETS_ARRAY[@]} -eq 0 ]; then log_warn "没有可删除的目标。"; press_enter_to_continue; continue; fi
                read -rp "请输入要删除的目标序号: " index
                if [[ "$index" =~ ^[0-9]+$ ]] && [ "$index" -ge 1 ] && [ "$index" -le ${#RCLONE_TARGETS_ARRAY[@]} ]; then
                    local deleted_index=$((index - 1))
                    read -rp "确定要删除目标 '${RCLONE_TARGETS_ARRAY[$deleted_index]}' 吗? (y/N): " confirm
                    if [[ "$confirm" =~ ^[Yy]$ ]]; then
                        unset 'RCLONE_TARGETS_ARRAY[$deleted_index]'
                        unset 'RCLONE_TARGETS_METADATA_ARRAY[$deleted_index]'
                        RCLONE_TARGETS_ARRAY=("${RCLONE_TARGETS_ARRAY[@]}")
                        RCLONE_TARGETS_METADATA_ARRAY=("${RCLONE_TARGETS_METADATA_ARRAY[@]}")

                        local new_enabled_indices=()
                        for enabled_idx in "${ENABLED_RCLONE_TARGET_INDICES_ARRAY[@]}"; do
                            if (( enabled_idx < deleted_index )); then new_enabled_indices+=("$enabled_idx");
                            elif (( enabled_idx > deleted_index )); then new_enabled_indices+=("$((enabled_idx - 1))");
                            fi
                        done
                        ENABLED_RCLONE_TARGET_INDICES_ARRAY=("${new_enabled_indices[@]}")
                        needs_saving="true"
                        log_info "目标已删除。"
                    fi
                else
                    log_error "无效序号。"
                fi
                press_enter_to_continue
                ;;

            m|M)
                if [ ${#RCLONE_TARGETS_ARRAY[@]} -eq 0 ]; then log_warn "没有可修改的目标。"; press_enter_to_continue; continue; fi
                read -rp "请输入要修改路径的目标序号: " index
                if [[ "$index" =~ ^[0-9]+$ ]] && [ "$index" -ge 1 ] && [ "$index" -le ${#RCLONE_TARGETS_ARRAY[@]} ]; then
                    local mod_index=$((index - 1))
                    local target_to_modify="${RCLONE_TARGETS_ARRAY[$mod_index]}"
                    local remote_name="${target_to_modify%%:*}"

                    log_info "正在为远程端 '${remote_name}' 重新选择路径..."
                    if choose_rclone_path "$remote_name"; then
                        local new_path="$CHOSEN_RCLONE_PATH"
                        RCLONE_TARGETS_ARRAY[$mod_index]="${remote_name}:${new_path}"
                        needs_saving="true"
                        log_info "目标已修改为: ${remote_name}:${new_path}"
                    else
                        log_warn "已取消修改。"
                    fi
                else
                    log_error "无效序号。"
                fi
                press_enter_to_continue
                ;;

            t|T)
                if [ ${#RCLONE_TARGETS_ARRAY[@]} -eq 0 ]; then log_warn "没有可切换的目标。"; press_enter_to_continue; continue; fi
                read -rp "请输入要切换状态的目标序号: " index
                if [[ "$index" =~ ^[0-9]+$ ]] && [ "$index" -ge 1 ] && [ "$index" -le ${#RCLONE_TARGETS_ARRAY[@]} ]; then
                    local choice_idx=$((index - 1))
                    local found_in_enabled=-1; local index_in_enabled_array=-1
                    for i in "${!ENABLED_RCLONE_TARGET_INDICES_ARRAY[@]}"; do
                        if [[ "${ENABLED_RCLONE_TARGET_INDICES_ARRAY[$i]}" -eq "$choice_idx" ]]; then
                            found_in_enabled=1; index_in_enabled_array=$i; break
                        fi
                    done
                    if [[ "$found_in_enabled" -eq 1 ]]; then
                        unset 'ENABLED_RCLONE_TARGET_INDICES_ARRAY[$index_in_enabled_array]'
                        ENABLED_RCLONE_TARGET_INDICES_ARRAY=("${ENABLED_RCLONE_TARGET_INDICES_ARRAY[@]}")
                        log_warn "目标已 禁用。"
                    else
                        ENABLED_RCLONE_TARGET_INDICES_ARRAY+=("$choice_idx")
                        log_info "目标已 启用。"
                    fi
                    needs_saving="true"
                else
                    log_error "无效序号。"
                fi
                press_enter_to_continue
                ;;

            0)
                if [[ "$needs_saving" == "true" ]]; then
                    save_config
                fi
                break
                ;;
            *) log_error "无效选项。"; press_enter_to_continue ;;
        esac
    done
}

test_rclone_remotes() {
    while true; do
        display_header
        echo -e "${BLUE}=== 测试 Rclone 远程端连接 ===${NC}"

        local remotes_list=()
        mapfile -t remotes_list < <(rclone listremotes | sed 's/://' || true)

        if [ ${#remotes_list[@]} -eq 0 ]; then
            log_warn "未发现任何已配置的 Rclone 远程端。"
            log_info "请先使用 '创建新的 Rclone 远程端' 或 'rclone config' 进行配置。"
            press_enter_to_continue
            break
        fi

        echo "发现以下 Rclone 远程端:"
        for i in "${!remotes_list[@]}"; do
            echo " $((i+1)). ${remotes_list[$i]}"
        done
        echo ""
        echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
        echo -e "  0. ${RED}返回${NC}"
        read -rp "请选择要测试连接的远程端序号 (0 返回): " choice

        if [[ "$choice" -eq 0 ]]; then break; fi

        if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le ${#remotes_list[@]} ]; then
            local remote_to_test="${remotes_list[$((choice-1))]}"
            log_warn "正在测试 '${remote_to_test}'..."

            if rclone lsjson --max-depth 1 "${remote_to_test}:" >/dev/null 2>&1; then
                log_info "连接测试成功！ '${remote_to_test}' 可用。"
                
                echo -e "${GREEN}--- 详细信息 (部分后端可能不支持) ---${NC}"
                if ! rclone about "${remote_to_test}:"; then
                    echo "无法获取详细的存储空间信息。"
                fi
                echo -e "${GREEN}-------------------------------------------${NC}"

            else
                log_error "连接测试失败！"
                log_warn "请检查远程端配置 ('rclone config') 或网络连接。"
            fi
        else
            log_error "无效序号。"
        fi
        press_enter_to_continue
    done
}


# --- 脚本入口点调用 ---
main "$@"

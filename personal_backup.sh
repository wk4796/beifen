#!/bin/bash

# Script global configuration
SCRIPT_NAME="个人自用数据备份"
CONFIG_FILE="$HOME/.personal_backup_config"
LOG_FILE="$HOME/.personal_backup_log.txt"

# Default values (if config file not found)
BACKUP_SOURCE_PATH=""
AUTO_BACKUP_INTERVAL_DAYS=7 # Default auto backup interval in days (e.g., 7 days = 1 week)
LAST_AUTO_BACKUP_TIMESTAMP=0 # Unix timestamp of last automatic backup

# New: Backup Retention Policy Defaults
RETENTION_POLICY_TYPE="none" # "none", "count", "days"
RETENTION_VALUE=0           # Number of backups to keep or days to keep

# Cloud storage credentials variables (NOW loaded/saved from config file for convenience)
S3_ACCESS_KEY=""
S3_SECRET_KEY=""
S3_ENDPOINT="" # Cloudflare R2 Endpoint, e.g., "https://<ACCOUNT_ID>.r2.cloudflarestorage.com"
S3_BUCKET_NAME=""

WEBDAV_URL=""
WEBDAV_USERNAME=""
WEBDAV_PASSWORD=""

# New: Telegram Notification Variables (NOW loaded/saved from config file for convenience)
TELEGRAM_BOT_TOKEN=""
TELEGRAM_CHAT_ID=""

# Color definitions
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color - Reset to default terminal color

# --- Helper functions ---

# Clear screen
clear_screen() {
    clear
}

# Display script header
display_header() {
    clear_screen
    echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${GREEN}          $SCRIPT_NAME          ${NC}"
    echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
}

# Display message and log it
log_and_display() {
    local message="$1"
    local color="$2"
    echo -e "$(date '+%Y-%m-%d %H:%M:%S') - $message" | tee -a "$LOG_FILE"
    if [[ -n "$color" ]]; then
        echo -e "$color$message$NC"
    else
        echo -e "$message"
    fi
}

# Wait for user to press Enter to continue
press_enter_to_continue() {
    echo ""
    log_and_display "${BLUE}按 Enter 键继续...${NC}" ""
    read -r
    clear_screen
}

# --- Configuration save and load (Modified) ---

# Save configuration to file
save_config() {
    echo "BACKUP_SOURCE_PATH=\"$BACKUP_SOURCE_PATH\"" > "$CONFIG_FILE"
    echo "AUTO_BACKUP_INTERVAL_DAYS=$AUTO_BACKUP_INTERVAL_DAYS" >> "$CONFIG_FILE"
    echo "LAST_AUTO_BACKUP_TIMESTAMP=$LAST_AUTO_BACKUP_TIMESTAMP" >> "$CONFIG_FILE" # Save last backup timestamp
    echo "RETENTION_POLICY_TYPE=\"$RETENTION_POLICY_TYPE\"" >> "$CONFIG_FILE"     # Save retention policy type
    echo "RETENTION_VALUE=$RETENTION_VALUE" >> "$CONFIG_FILE"                   # Save retention value

    # NEW: Save sensitive credentials to config file for automated backups
    echo "S3_ACCESS_KEY=\"$S3_ACCESS_KEY\"" >> "$CONFIG_FILE"
    echo "S3_SECRET_KEY=\"$S3_SECRET_KEY\"" >> "$CONFIG_FILE"
    echo "S3_ENDPOINT=\"$S3_ENDPOINT\"" >> "$CONFIG_FILE"
    echo "S3_BUCKET_NAME=\"$S3_BUCKET_NAME\"" >> "$CONFIG_FILE"

    echo "WEBDAV_URL=\"$WEBDAV_URL\"" >> "$CONFIG_FILE"
    echo "WEBDAV_USERNAME=\"$WEBDAV_USERNAME\"" >> "$CONFIG_FILE"
    echo "WEBDAV_PASSWORD=\"$WEBDAV_PASSWORD\"" >> "$CONFIG_FILE"

    echo "TELEGRAM_BOT_TOKEN=\"$TELEGRAM_BOT_TOKEN\"" >> "$CONFIG_FILE"
    echo "TELEGRAM_CHAT_ID=\"$TELEGRAM_CHAT_ID\"" >> "$CONFIG_FILE"

    log_and_display "配置已保存到 $CONFIG_FILE"
    # IMPORTANT: Immediately set secure permissions for the config file
    chmod 600 "$CONFIG_FILE" 2>/dev/null # Suppress error if chmod fails (e.g., on read-only fs)
    log_and_display "${YELLOW}已将配置文件 $CONFIG_FILE 权限设置为 600 (只有所有者可读写)，请确保您的系统安全。${NC}"
}

# Load configuration from file
load_config() {
    if [[ -f "$CONFIG_FILE" ]]; then
        # Ensure config file has secure permissions before sourcing (warn if not 600)
        if [[ "$(stat -c "%a" "$CONFIG_FILE" 2>/dev/null)" != "600" ]]; then
            log_and_display "${YELLOW}警告：配置文件 $CONFIG_FILE 权限不安全 ($(stat -c "%a" "$CONFIG_FILE" 2>/dev/null))，建议设置为 600。${NC}"
        fi
        source "$CONFIG_FILE"
        log_and_display "配置已从 $CONFIG_FILE 加载。" "${BLUE}"
    else
        log_and_display "未找到配置文件 $CONFIG_FILE，将使用默认配置。" "${YELLOW}"
    fi
}

# --- Core functions ---

# Check required dependencies (Modified)
check_dependencies() {
    local missing_deps=()
    command -v zip &> /dev/null || missing_deps+=("zip")

    # Check S3/R2 dependencies only if S3/R2 credentials are set in config
    if [[ -n "$S3_ACCESS_KEY" && -n "$S3_SECRET_KEY" && -n "$S3_ENDPOINT" && -n "$S3_BUCKET_NAME" ]]; then
        command -v aws &> /dev/null || command -v s3cmd &> /dev/null || missing_deps+=("awscli 或 s3cmd (用于S3/R2)")
    fi
    # Check WebDAV dependencies only if WebDAV credentials are set in config
    if [[ -n "$WEBDAV_URL" && -n "$WEBDAV_USERNAME" && -n "$WEBDAV_PASSWORD" ]]; then
        command -v curl &> /dev/null || missing_deps+=("curl (用于WebDAV)")
    fi
    # Check curl for Telegram notifications only if Telegram credentials are set in config
    if [[ -n "$TELEGRAM_BOT_TOKEN" && -n "$TELEGRAM_CHAT_ID" ]]; then
        command -v curl &> /dev/null || missing_deps+=("curl (用于Telegram)")
    fi

    if [ ${#missing_deps[@]} -gt 0 ]; then
        log_and_display "${RED}检测到以下依赖项缺失，请安装后重试：${missing_deps[*]}${NC}"
        log_and_display "例如 (Debian/Ubuntu): sudo apt update && sudo apt install zip awscli curl" "${YELLOW}"
        log_and_display "例如 (CentOS/RHEL): sudo yum install zip awscli curl" "${YELLOW}"
        press_enter_to_continue
        return 1
    fi
    return 0
}

# New: Function to send message to Telegram
# Param 1: Message content
send_telegram_message() {
    local message_content="$1"
    if [[ -z "$TELEGRAM_BOT_TOKEN" || -z "$TELEGRAM_CHAT_ID" ]]; then
        log_and_display "${YELLOW}Telegram 通知未配置，跳过发送消息。${NC}" ""
        return 1
    fi

    log_and_display "正在发送 Telegram 消息..." ""
    # Use -s for silent, -X POST for POST request, -d for data, --data-urlencode to encode message
    # Ensure message content is URL-encoded for safety
    local encoded_message=$(printf %s "$message_content" | jq -sRr @uri) # Requires jq for robust URL encoding
    if [ $? -ne 0 ]; then
        log_and_display "${RED}警告：无法进行 URL 编码，请安装 'jq' (sudo apt install jq) 或手动检查消息内容。尝试发送未编码消息。${NC}"
        encoded_message=$(printf %s "$message_content" | sed 's/\([&/?= ]\)/%\1/g') # Fallback simple encoding
    fi

    if curl -s -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
        -d "chat_id=${TELEGRAM_CHAT_ID}" \
        -d "text=${encoded_message}" \
        -d "parse_mode=Markdown" > /dev/null; then
        log_and_display "${GREEN}Telegram 消息发送成功。${NC}" ""
    else
        log_and_display "${RED}Telegram 消息发送失败，请检查 Bot Token 和 Chat ID。${NC}" ""
    fi
}


# 1. Set auto backup interval
set_auto_backup_interval() {
    display_header
    echo -e "${BLUE}=== 1. 自动备份设定 ===${NC}"
    echo "当前自动备份间隔: ${AUTO_BACKUP_INTERVAL_DAYS} 天"
    echo ""
    read -rp "请输入新的自动备份间隔时间（天数，最小1天，例如 7 为 1 周）: " interval_input

    if [[ "$interval_input" =~ ^[0-9]+$ ]] && [ "$interval_input" -ge 1 ]; then
        AUTO_BACKUP_INTERVAL_DAYS="$interval_input"
        save_config
        log_and_display "${GREEN}自动备份间隔已成功设置为：${AUTO_BACKUP_INTERVAL_DAYS} 天。${NC}"
        log_and_display "${YELLOW}提示：现在您只需确保 Cron Job 每天运行此脚本一次。脚本会根据您设置的间隔自动判断是否执行备份。${NC}"
        log_and_display "${YELLOW}Cron Job 条目示例 (请将 /path/to/your_script.sh 替换为实际路径):${NC}"
        log_and_display "${YELLOW}0 0 * * * bash /path/to/your_script.sh check_auto_backup > /dev/null 2>&1${NC}" # Run daily at midnight
    else
        log_and_display "${RED}输入无效，请输入一个大于等于 1 的整数。${NC}"
    fi
    press_enter_to_continue
}

# 2. Manual backup
manual_backup() {
    display_header
    echo -e "${BLUE}=== 2. 手动备份 ===${NC}"
    log_and_display "您选择了手动备份，立即执行备份上传。" "${GREEN}"
    perform_backup "手动备份"
    press_enter_to_continue
}

# 3. Custom backup path
set_backup_path() {
    display_header
    echo -e "${BLUE}=== 3. 自定义备份路径 ===${NC}"
    echo "当前备份路径: ${BACKUP_SOURCE_PATH:-未设置}"
    echo ""
    read -rp "请输入要备份的文件或文件夹的绝对路径（例如 /home/user/mydata 或 /etc/nginx/nginx.conf）: " path_input

    # Remove trailing slash for consistency when zipping directories, but only if it's a directory
    if [[ -d "$path_input" ]]; then
        path_input="${path_input%/}" # Remove trailing slash
    fi

    if [[ -d "$path_input" || -f "$path_input" ]]; then
        BACKUP_SOURCE_PATH="$path_input"
        save_config
        log_and_display "${GREEN}备份路径已成功设置为：${BACKUP_SOURCE_PATH}${NC}"
    else
        log_and_display "${RED}错误：输入的路径无效或不存在。${NC}"
    fi
    press_enter_to_continue
}

# 4. Compression format info
display_compression_info() {
    display_header
    echo -e "${BLUE}=== 4. 压缩包格式 ===${NC}"
    log_and_display "本脚本当前支持的压缩格式为：${GREEN}ZIP${NC}。" ""
    log_and_display "如果您需要其他格式（如 .tar.gz），请修改脚本中 'perform_backup' 函数的压缩命令。" "${YELLOW}"
    press_enter_to_continue
}

# 5. Cloud storage settings (Modified)
set_cloud_storage() {
    while true; do
        display_header
        echo -e "${BLUE}=== 5. 云存储设定 ===${NC}"
        echo "1. 配置 S3/R2 存储"
        echo "2. 配置 WebDAV 存储"
        echo "0. 返回主菜单"
        echo -e "${BLUE}------------------------------------------------${NC}"
        read -rp "请输入选项: " sub_choice

        case $sub_choice in
            1)
                log_and_display "--- 配置 S3/R2 存储 ---"
                log_and_display "${YELLOW}凭证将保存到本地配置文件，请确保配置文件安全！${NC}"
                read -rp "请输入 S3/R2 Access Key ID: " S3_ACCESS_KEY
                read -rp "请输入 S3/R2 Secret Access Key: " S3_SECRET_KEY
                read -rp "请输入 S3/R2 Endpoint URL (例如 Cloudflare R2 的 https://<ACCOUNT_ID>.r2.cloudflarestorage.com): " S3_ENDPOINT
                read -rp "请输入 S3/R2 Bucket 名称: " S3_BUCKET_NAME
                save_config # Save credentials to config file
                log_and_display "${GREEN}S3/R2 配置已更新并保存。${NC}"
                press_enter_to_continue
                ;;
            2)
                log_and_display "--- 配置 WebDAV 存储 ---"
                log_and_display "${YELLOW}凭证将保存到本地配置文件，请确保配置文件安全！${NC}"
                read -rp "请输入 WebDAV URL (例如 http://your.webdav.server/path/): " WEBDAV_URL
                read -rp "请输入 WebDAV 用户名: " WEBDAV_USERNAME
                read -rp "请输入 WebDAV 密码: " -s WEBDAV_PASSWORD # -s hides input
                echo "" # New line
                save_config # Save credentials to config file
                log_and_display "${GREEN}WebDAV 配置已更新并保存。${NC}"
                press_enter_to_continue
                ;;
            0)
                log_and_display "返回主菜单。" "${BLUE}"
                break
                ;;
            *)
                log_and_display "${RED}无效的选项，请重新输入。${NC}"
                press_enter_to_continue
                ;;
        esac
    done
}

# New: 6. Set Telegram Notification Settings (Modified)
set_telegram_notification() {
    display_header
    echo -e "${BLUE}=== 6. 消息通知设定 (Telegram) ===${NC}"
    log_and_display "${YELLOW}Telegram Bot Token 和 Chat ID 将保存到本地配置文件，请确保配置文件安全！${NC}"
    read -rp "请输入 Telegram Bot Token (例如 123456:ABC-DEF1234ghIkl-79f): " TELEGRAM_BOT_TOKEN
    read -rp "请输入 Telegram Chat ID (例如 -123456789 或 123456789): " TELEGRAM_CHAT_ID
    save_config # Save credentials to config file
    log_and_display "${GREEN}Telegram 通知配置已更新并保存。${NC}"
    log_and_display "${YELLOW}提示：您可以向 @BotFather 获取 Bot Token，然后向您的 Bot 发送消息，再访问 https://api.telegram.org/bot<YOUR_BOT_TOKEN>/getUpdates 获取 Chat ID。${NC}"
    press_enter_to_continue
}

# 7. Set Backup Retention Policy
set_retention_policy() {
    while true; do
        display_header
        echo -e "${BLUE}=== 7. 设置备份保留策略 (云端) ===${NC}"
        echo "当前策略: "
        case "$RETENTION_POLICY_TYPE" in
            "none") echo -e "  ${YELLOW}无保留策略（所有备份将保留）${NC}" ;;
            "count") echo -e "  ${YELLOW}保留最新 ${RETENTION_VALUE} 个备份${NC}" ;;
            "days")  echo -e "  ${YELLOW}保留最近 ${RETENTION_VALUE} 天内的备份${NC}" ;;
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
                log_and_display "返回主菜单。" "${BLUE}"
                break
                ;;
            *)
                log_and_display "${RED}无效的选项，请重新输入。${NC}"
                press_enter_to_continue
                ;;
        esac
    done
}


# Function to apply retention policy (Modified)
# This function will check S3/R2 and WebDAV for old backups and delete them
apply_retention_policy() {
    log_and_display "${BLUE}--- 正在应用备份保留策略 ---${NC}"

    if [[ "$RETENTION_POLICY_TYPE" == "none" ]]; then
        log_and_display "未设置保留策略，跳过清理。" "${YELLOW}"
        return 0
    fi

    local current_timestamp=$(date +%s)
    local deleted_s3_count=0
    local deleted_webdav_count=0
    local total_s3_backups_found=0
    local total_webdav_backups_found=0

    # --- S3/R2 Cleanup ---
    # Only attempt S3/R2 cleanup if configuration is complete
    if [[ -n "$S3_ACCESS_KEY" && -n "$S3_SECRET_KEY" && -n "$S3_ENDPOINT" && -n "$S3_BUCKET_NAME" ]]; then
        log_and_display "正在检查 S3/R2 存储桶中的旧备份：${S3_BUCKET_NAME}..."
        local s3_backups=()
        if command -v aws &> /dev/null; then
            # Using globally loaded S3_ACCESS_KEY and S3_SECRET_KEY
            AWS_ACCESS_KEY_ID="$S3_ACCESS_KEY" \
            AWS_SECRET_ACCESS_KEY="$S3_SECRET_KEY" \
            s3_backups=($(aws s3 ls "s3://${S3_BUCKET_NAME}/" --endpoint-url "$S3_ENDPOINT" | awk '{print $4}' | grep '^backup_[0-9]\{14\}\.zip$'))
        elif command -v s3cmd &> /dev/null; then
            # s3cmd typically reads from ~/.s3cfg, but direct key passing might also be possible depending on version
            # For simplicity, relying on pre-configured s3cmd here
            s3_backups=($(s3cmd ls "s3://${S3_BUCKET_NAME}/" | awk '{print $4}' | sed 's/s3:\/\/'"${S3_BUCKET_NAME//./\\.}"'\///' | grep '^backup_[0-9]\{14\}\.zip$'))
        fi
        total_s3_backups_found=${#s3_backups[@]}

        if [ ${#s3_backups[@]} -eq 0 ]; then
            log_and_display "S3/R2 存储桶中未找到备份文件。" "${YELLOW}"
        else
            # Sort backups by timestamp (newest first)
            IFS=$'\n' s3_backups=($(sort -r <<<"${s3_backups[*]}"))
            unset IFS

            if [[ "$RETENTION_POLICY_TYPE" == "count" ]]; then
                log_and_display "S3/R2 保留策略: 保留最新 ${RETENTION_VALUE} 个备份。"
                local num_to_delete=$(( ${#s3_backups[@]} - RETENTION_VALUE ))
                if [ "$num_to_delete" -gt 0 ]; then
                    for (( i=RETENTION_VALUE; i<${#s3_backups[@]}; i++ )); do
                        local file_to_delete="${s3_backups[$i]}"
                        log_and_display "S3/R2: 正在删除旧备份: ${file_to_delete}" "${YELLOW}"
                        if command -v aws &> /dev/null; then
                            AWS_ACCESS_KEY_ID="$S3_ACCESS_KEY" \
                            AWS_SECRET_ACCESS_KEY="$S3_SECRET_KEY" \
                            aws s3 rm "s3://${S3_BUCKET_NAME}/${file_to_delete}" --endpoint-url "$S3_ENDPOINT" &> /dev/null
                            if [ $? -eq 0 ]; then deleted_s3_count=$((deleted_s3_count + 1)); fi
                        elif command -v s3cmd &> /dev/null; then
                            s3cmd del "s3://${S3_BUCKET_NAME}/${file_to_delete}" &> /dev/null
                            if [ $? -eq 0 ]; then deleted_s3_count=$((deleted_s3_count + 1)); fi
                        fi
                    done
                    log_and_display "${GREEN}S3/R2 旧备份清理完成。已删除 ${deleted_s3_count} 个文件。${NC}"
                else
                    log_and_display "S3/R2 中备份数量未超过保留限制，无需清理。" "${BLUE}"
                fi
            elif [[ "$RETENTION_POLICY_TYPE" == "days" ]]; then
                log_and_display "S3/R2 保留策略: 保留最近 ${RETENTION_VALUE} 天内的备份。"
                local cutoff_timestamp=$(( current_timestamp - RETENTION_VALUE * 24 * 3600 ))
                for backup_file in "${s3_backups[@]}"; do
                    # Extract timestamp from filename (backup_YYYYMMDDHHMMSS.zip)
                    local backup_date_str=$(echo "$backup_file" | sed -E 's/backup_([0-9]{14})\.zip/\1/')
                    local backup_timestamp=$(date -d "${backup_date_str:0:8} ${backup_date_str:8:2}:${backup_date_str:10:2}:${backup_date_str:12:2}" +%s 2>/dev/null)

                    if [[ "$backup_timestamp" -ne 0 && "$backup_timestamp" -lt "$cutoff_timestamp" ]]; then
                        log_and_display "S3/R2: 正在删除旧备份: ${backup_file} (创建于 $(date -d @$backup_timestamp '+%Y-%m-%d %H:%M:%S'))" "${YELLOW}"
                        if command -v aws &> /dev/null; then
                            AWS_ACCESS_KEY_ID="$S3_ACCESS_KEY" \
                            AWS_SECRET_ACCESS_KEY="$S3_SECRET_KEY" \
                            aws s3 rm "s3://${S3_BUCKET_NAME}/${backup_file}" --endpoint-url "$S3_ENDPOINT" &> /dev/null
                            if [ $? -eq 0 ]; then deleted_s3_count=$((deleted_s3_count + 1)); fi
                        elif command -v s3cmd &> /dev/null; then
                            s3cmd del "s3://${S3_BUCKET_NAME}/${backup_file}" &> /dev/null
                            if [ $? -eq 0 ]; then deleted_s3_count=$((deleted_s3_count + 1)); fi
                        fi
                    fi
                done
                log_and_display "${GREEN}S3/R2 旧备份清理完成。已删除 ${deleted_s3_count} 个文件。${NC}"
            fi
        fi
    else
        log_and_display "${YELLOW}S3/R2 配置不完整或未设置，跳过 S3/R2 备份清理。${NC}"
    fi

    # --- WebDAV Cleanup ---
    # Only attempt WebDAV cleanup if configuration is complete
    if [[ -n "$WEBDAV_URL" && -n "$WEBDAV_USERNAME" && -n "$WEBDAV_PASSWORD" ]]; then
        log_and_display "正在检查 WebDAV 服务器中的旧备份：${WEBDAV_URL}..."
        local webdav_backups=()
        if command -v curl &> /dev/null; then
            # List files, filter for backup_YYYYMMDDHHMMSS.zip and parse names
            # Note: This is a basic listing, might need adjustment based on WebDAV server's 'ls' output
            # Assumes the URL ends with a slash to list contents of a directory.
            # Using -L to follow redirects, --list-only to get directory listing, --fail-with-body for better error details
            # Added pipe to tr -d '\r' to handle potential Windows-style line endings
            local curl_output=$(curl -s -L -k --user "$WEBDAV_USERNAME:$WEBDAV_PASSWORD" --request PROPFIND --header "Depth: 1" "${WEBDAV_URL%/}/" | tr -d '\r' | grep -oP '<D:href>\K[^<]*backup_[0-9]{14}\.zip(?=</D:href>)')
            IFS=$'\n' read -r -d '' -a webdav_backups <<< "$curl_output"
            unset IFS
        fi
        total_webdav_backups_found=${#webdav_backups[@]}

        if [ ${#webdav_backups[@]} -eq 0 ]; then
            log_and_display "WebDAV 服务器中未找到备份文件。" "${YELLOW}"
        else
            # Sort backups by timestamp (newest first)
            IFS=$'\n' webdav_backups=($(sort -r <<<"${webdav_backups[*]}"))
            unset IFS

            if [[ "$RETENTION_POLICY_TYPE" == "count" ]]; then
                log_and_display "WebDAV 保留策略: 保留最新 ${RETENTION_VALUE} 个备份。"
                local num_to_delete=$(( ${#webdav_backups[@]} - RETENTION_VALUE ))
                if [ "$num_to_delete" -gt 0 ]; then
                    for (( i=RETENTION_VALUE; i<${#webdav_backups[@]}; i++ )); do
                        local file_to_delete="${webdav_backups[$i]}"
                        log_and_display "WebDAV: 正在删除旧备份: ${file_to_delete}" "${YELLOW}"
                        # curl DELETE method
                        curl -s -k --user "$WEBDAV_USERNAME:$WEBDAV_PASSWORD" -X DELETE "${WEBDAV_URL%/}/$file_to_delete" > /dev/null
                        if [ $? -eq 0 ]; then deleted_webdav_count=$((deleted_webdav_count + 1)); fi
                    done
                    log_and_display "${GREEN}WebDAV 旧备份清理完成。已删除 ${deleted_webdav_count} 个文件。${NC}"
                else
                    log_and_display "WebDAV 中备份数量未超过保留限制，无需清理。" "${BLUE}"
                fi
            elif [[ "$RETENTION_POLICY_TYPE" == "days" ]]; then
                log_and_display "WebDAV 保留策略: 保留最近 ${RETENTION_VALUE} 天内的备份。"
                local cutoff_timestamp=$(( current_timestamp - RETENTION_VALUE * 24 * 3600 ))
                for backup_file in "${webdav_backups[@]}"; do
                    # Extract timestamp from filename (backup_YYYYMMDDHHMMSS.zip)
                    local backup_date_str=$(echo "$backup_file" | sed -E 's/backup_([0-9]{14})\.zip/\1/')
                    local backup_timestamp=$(date -d "${backup_date_str:0:8} ${backup_date_str:8:2}:${backup_date_str:10:2}:${backup_date_str:12:2}" +%s 2>/dev/null)

                    if [[ "$backup_timestamp" -ne 0 && "$backup_timestamp" -lt "$cutoff_timestamp" ]]; then
                        log_and_display "WebDAV: 正在删除旧备份: ${backup_file} (创建于 $(date -d @$backup_timestamp '+%Y-%m-%d %H:%M:%S'))" "${YELLOW}"
                        # curl DELETE method
                        curl -s -k --user "$WEBDAV_USERNAME:$WEBDAV_PASSWORD" -X DELETE "${WEBDAV_URL%/}/$backup_file" > /dev/null
                        if [ $? -eq 0 ]; then deleted_webdav_count=$((deleted_webdav_count + 1)); fi
                    fi
                done
                log_and_display "${GREEN}WebDAV 旧备份清理完成。已删除 ${deleted_webdav_count} 个文件。${NC}"
            fi
        fi
    else
        log_and_display "${YELLOW}WebDAV 配置不完整或未设置，跳过 WebDAV 备份清理。${NC}"
    fi

    local retention_summary="保留策略执行完毕。S3/R2 找到 ${total_s3_backups_found} 个，删除了 ${deleted_s3_count} 个。WebDAV 找到 ${total_webdav_backups_found} 个，删除了 ${deleted_webdav_count} 个。"
    send_telegram_message "*个人自用数据备份：保留策略完成*\n${retention_summary}"
    log_and_display "${BLUE}--- 备份保留策略应用结束 ---${NC}"
}


# Core logic to perform backup upload (Modified)
# Param 1: backup type (e.g., "手动备份", "自动备份")
perform_backup() {
    local backup_type="$1"
    local timestamp=$(date +%Y%m%d%H%M%S)
    local readable_time=$(date '+%Y-%m-%d %H:%M:%S')
    local archive_name="backup_${timestamp}.zip"
    local temp_archive_path="/tmp/$archive_name"
    local backup_file_size="未知"
    local overall_status="失败"
    local s3_upload_status="未尝试"
    local webdav_upload_status="未尝试"
    local backup_destinations=""

    log_and_display "${BLUE}--- ${backup_type} 过程开始 ---${NC}"

    local initial_message="*个人自用数据备份：开始 (${backup_type})*\n时间: ${readable_time}\n源路径: \`${BACKUP_SOURCE_PATH}\`"
    send_telegram_message "${initial_message}"

    if [[ -z "$BACKUP_SOURCE_PATH" ]]; then
        log_and_display "${RED}错误：备份源路径未设置。请先设置备份路径。${NC}"
        send_telegram_message "${initial_message}\n状态: 失败\n原因: 备份源路径未设置。"
        return 1
    fi

    log_and_display "源路径: '$BACKUP_SOURCE_PATH'"
    log_and_display "目标压缩文件: '$temp_archive_path'"

    # --- Compress files ---
    log_and_display "正在压缩文件..."
    # If BACKUP_SOURCE_PATH is a directory, zip its content, not the directory itself
    # Adjusted zip command to handle both files and directories more consistently
    if [[ -d "$BACKUP_SOURCE_PATH" ]]; then
        # For directories, zip the contents (e.g., /home/user/mydata -> mydata/*)
        # Use a subshell to change directory, so it doesn't affect the main script's CWD
        (cd "$(dirname "$BACKUP_SOURCE_PATH")" && zip -r "$temp_archive_path" "$(basename "$BACKUP_SOURCE_PATH")") &> /dev/null
    elif [[ -f "$BACKUP_SOURCE_PATH" ]]; then
        # For files, just zip the file
        zip "$temp_archive_path" "$BACKUP_SOURCE_PATH" &> /dev/null
    else
        log_and_display "${RED}文件压缩失败！备份源路径 '$BACKUP_SOURCE_PATH' 无效或不存在。${NC}"
        send_telegram_message "*个人自用数据备份：压缩失败*\n时间: ${readable_time}\n源路径: \`${BACKUP_SOURCE_PATH}\`\n原因: 备份源路径无效或不存在。"
        rm -f "$temp_archive_path" 2>/dev/null
        return 1
    fi


    if [ $? -eq 0 ]; then
        log_and_display "${GREEN}文件压缩成功！${NC}"
        backup_file_size=$(du -h "$temp_archive_path" | awk '{print $1}')
        local compress_message="*个人自用数据备份：压缩成功*\n文件: \`${archive_name}\`\n大小: ${backup_file_size}"
        send_telegram_message "${compress_message}"
    else
        log_and_display "${RED}文件压缩失败！请检查备份源路径或权限。${NC}"
        send_telegram_message "*个人自用数据备份：压缩失败*\n时间: ${readable_time}\n源路径: \`${BACKUP_SOURCE_PATH}\`\n原因: 文件压缩失败。"
        rm -f "$temp_archive_path" 2>/dev/null
        return 1
    fi

    # --- Upload to S3/R2 ---
    # Now using globally loaded S3_ACCESS_KEY, S3_SECRET_KEY
    if [[ -n "$S3_ACCESS_KEY" && -n "$S3_SECRET_KEY" && -n "$S3_ENDPOINT" && -n "$S3_BUCKET_NAME" ]]; then
        log_and_display "正在尝试上传到 S3/R2 存储桶：${S3_BUCKET_NAME}..."
        backup_destinations+="S3/R2 (${S3_BUCKET_NAME})\n"
        local s3_command_output=""
        local s3_success=0

        if command -v aws &> /dev/null; then
            # Using globally loaded AWS_ACCESS_KEY_ID and AWS_SECRET_ACCESS_KEY
            # Temporarily set them for the command execution if not already in env
            AWS_ACCESS_KEY_ID="$S3_ACCESS_KEY" \
            AWS_SECRET_ACCESS_KEY="$S3_SECRET_KEY" \
            s3_command_output=$(aws s3 cp "$temp_archive_path" "s3://${S3_BUCKET_NAME}/${archive_name}" --endpoint-url "$S3_ENDPOINT" 2>&1)
            if [ $? -eq 0 ]; then s3_success=1; fi
        elif command -v s3cmd &> /dev/null; then
            log_and_display "${YELLOW}正在使用 s3cmd。请确保 ~/.s3cfg 已正确配置 Cloudflare R2。${NC}"
            s3_command_output=$(s3cmd put "$temp_archive_path" "s3://${S3_BUCKET_NAME}/${archive_name}" 2>&1)
            if [ $? -eq 0 ]; then s3_success=1; fi
        else
            log_and_display "${RED}未找到 'awscli' 或 's3cmd' 命令，无法上传到 S3/R2。${NC}"
        fi

        if [ "$s3_success" -eq 1 ]; then
            log_and_display "${GREEN}S3/R2 上传成功！${NC}"
            s3_upload_status="成功"
        else
            log_and_display "${RED}S3/R2 上传失败！请检查配置、凭证和网络连接。${NC}"
            s3_upload_status="失败"
            log_and_display "S3/R2 错误信息: ${s3_command_output}"
        fi
    else
        log_and_display "${YELLOW}S3/R2 配置不完整或未设置，跳过 S3/R2 上传。${NC}"
        s3_upload_status="跳过"
    fi

    # --- Upload to WebDAV ---
    # Now using globally loaded WEBDAV_URL, WEBDAV_USERNAME, WEBDAV_PASSWORD
    if [[ -n "$WEBDAV_URL" && -n "$WEBDAV_USERNAME" && -n "$WEBDAV_PASSWORD" ]]; then
        log_and_display "正在尝试上传到 WebDAV 服务器：${WEBDAV_URL}..."
        backup_destinations+="WebDAV (${WEBDAV_URL})\n"
        local webdav_command_output=""
        local webdav_success=0

        if command -v curl &> /dev/null; then
            webdav_command_output=$(curl -k --user "$WEBDAV_USERNAME:$WEBDAV_PASSWORD" --upload-file "$temp_archive_path" "${WEBDAV_URL%/}/$archive_name" 2>&1)
            if [ $? -eq 0 ]; then webdav_success=1; fi
        else
            log_and_display "${RED}未找到 'curl' 命令，无法上传到 WebDAV。${NC}"
        fi

        if [ "$webdav_success" -eq 1 ]; then
            log_and_display "${GREEN}WebDAV 上传成功！${NC}"
            webdav_upload_status="成功"
        else
            log_and_display "${RED}WebDAV 上传失败！请检查 WebDAV 配置、凭证和网络连接。${NC}"
            webdav_upload_status="失败"
            log_and_display "WebDAV 错误信息: ${webdav_command_output}"
        fi
    else
        log_and_display "${YELLOW}WebDAV 配置不完整或未设置，跳过 WebDAV 上传。${NC}"
        webdav_upload_status="跳过"
    fi

    # Determine overall status
    if [[ "$s3_upload_status" == "成功" || "$webdav_upload_status" == "成功" ]]; then
        overall_status="成功"
    elif [[ "$s3_upload_status" == "跳过" && "$webdav_upload_status" == "跳过" ]]; then
        overall_status="失败 (未配置任何上传目标)"
    else
        overall_status="部分失败或完全失败"
    fi

    # --- Clean up temporary file ---
    log_and_display "正在清理临时压缩文件：$temp_archive_path"
    rm -f "$temp_archive_path"
    if [ $? -eq 0 ]; then
        log_and_display "${GREEN}临时文件清理完成。${NC}"
    else
        log_and_display "${RED}临时文件清理失败。${NC}"
    fi

    log_and_display "${BLUE}--- ${backup_type} 过程结束 ---${NC}"

    # Update last auto backup timestamp if this was an automatic backup
    if [[ "$backup_type" == "自动备份" || "$backup_type" == "自动备份 (Cron)" ]]; then
        LAST_AUTO_BACKUP_TIMESTAMP=$(date +%s) # Get current Unix timestamp
        save_config # Save updated timestamp (this will also save current credentials)
        log_and_display "已更新上次自动备份时间戳：$(date -d @$LAST_AUTO_BACKUP_TIMESTAMP '+%Y-%m-%d %H:%M:%S')" "${BLUE}"
    fi

    # Send final detailed Telegram notification
    local final_message="*个人自用数据备份：${overall_status}*\n"
    final_message+="时间: ${readable_time}\n"
    final_message+="类型: ${backup_type}\n"
    final_message+="备份文件: \`${archive_name}\`\n"
    final_message+="文件大小: ${backup_file_size}\n"
    final_message+="--- 上传详情 ---\n"
    final_message+="S3/R2 上传: ${s3_upload_status}"
    if [[ -n "$S3_BUCKET_NAME" && "$s3_upload_status" != "跳过" ]]; then final_message+=" (Bucket: \`${S3_BUCKET_NAME}\`)"; fi # Check if S3_BUCKET_NAME is set
    final_message+="\n"
    final_message+="WebDAV 上传: ${webdav_upload_status}"
    if [[ -n "$WEBDAV_URL" && "$webdav_upload_status" != "跳过" ]]; then final_message+=" (URL: \`${WEBDAV_URL}\`)"; fi # Check if WEBDAV_URL is set
    final_message+="\n"
    final_message+="备份源路径: \`${BACKUP_SOURCE_PATH}\`"

    send_telegram_message "${final_message}"

    # New: Apply retention policy after each backup
    apply_retention_policy
}

# 99. Uninstall script
uninstall_script() { # Function name remains the same
    display_header
    echo -e "${RED}=== 99. 卸载脚本 ===${NC}" # Changed header
    log_and_display "${RED}警告：您确定要卸载脚本吗？这将删除所有脚本文件、配置文件和日志文件。（y/N）${NC}"
    read -rp "请确认 (y/N): " confirm

    if [[ "$confirm" =~ ^[Yy]$ ]]; then
        log_and_display "${RED}开始卸载脚本...${NC}"
        local script_path="$(readlink -f "$0")" # Get the real path of the script

        log_and_display "删除脚本文件：$script_path"
        rm -f "$script_path" 2>/dev/null

        if [[ -f "$CONFIG_FILE" ]]; then
            log_and_display "删除配置文件：$CONFIG_FILE"
            rm -f "$CONFIG_FILE" 2>/dev/null
        fi

        if [[ -f "$LOG_FILE" ]]; then
            log_and_display "删除日志文件：$LOG_FILE"
            rm -f "$LOG_FILE" 2>/dev/null
        fi

        # Attempt to remove possible aliases or startup files in PATH
        log_and_display "${YELLOW}提示：如果此脚本是通过别名或放置在 PATH 中的文件启动的，您可能需要手动删除它们。${NC}"

        log_and_display "${GREEN}脚本卸载完成。${NC}"
        exit 0
    else
        log_and_display "取消卸载。" "${BLUE}"
    fi
    press_enter_to_continue
}

# --- Main menu ---
show_main_menu() {
    display_header
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━ 功能选项 ━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "  1. ${YELLOW}自动备份设定${NC} (当前间隔: ${AUTO_BACKUP_INTERVAL_DAYS} 天)${NC}"
    echo -e "  2. ${YELLOW}手动备份${NC}"
    echo -e "  3. ${YELLOW}自定义备份路径${NC} (当前路径: ${BACKUP_SOURCE_PATH:-未设置})${NC}"
    echo -e "  4. ${YELLOW}压缩包格式${NC} (当前支持: ZIP)${NC}"
    echo -e "  5. ${YELLOW}云存储设定${NC} (支持: S3/R2, WebDAV)${NC}"
    echo -e "  6. ${YELLOW}消息通知设定${NC} (Telegram)${NC}"
    echo -e "  7. ${YELLOW}设置备份保留策略${NC} (云端)${NC}"
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "  0. ${RED}退出脚本${NC}"
    echo -e "  99. ${RED}卸载脚本${NC}"
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
}

# Process menu choice
process_menu_choice() {
    local choice
    read -rp "请输入选项: " choice
    log_and_display "用户选择: $choice"

    case $choice in
        1) set_auto_backup_interval ;;
        2) manual_backup ;;
        3) set_backup_path ;;
        4) display_compression_info ;;
        5) set_cloud_storage ;;
        6) set_telegram_notification ;;
        7) set_retention_policy ;;
        0)
            log_and_display "${GREEN}感谢使用，再见！${NC}"
            exit 0
            ;;
        99) uninstall_script ;;
        *)
            log_and_display "${RED}无效的选项，请重新输入。${NC}"
            press_enter_to_continue
            ;;
    esac
}

# Check if automatic backup should run based on interval
check_auto_backup() {
    load_config # Ensure latest config is loaded

    local current_timestamp=$(date +%s)
    local interval_seconds=$(( AUTO_BACKUP_INTERVAL_DAYS * 24 * 3600 )) # Convert days to seconds

    if [[ "$LAST_AUTO_BACKUP_TIMESTAMP" -eq 0 ]]; then
        log_and_display "首次自动备份，或上次自动备份时间未记录，立即执行。" "${YELLOW}"
        perform_backup "自动备份 (Cron)"
    elif (( current_timestamp - LAST_AUTO_BACKUP_TIMESTAMP >= interval_seconds )); then
        log_and_display "距离上次自动备份已超过 ${AUTO_BACKUP_INTERVAL_DAYS} 天，执行自动备份。" "${BLUE}"
        perform_backup "自动备份 (Cron)"
    else
        local next_backup_time=$(( LAST_AUTO_BACKUP_TIMESTAMP + interval_seconds ))
        local remaining_seconds=$(( next_backup_time - current_timestamp ))
        local remaining_days=$(( remaining_seconds / 86400 ))
        log_and_display "未到自动备份时间。距离下次备份还有约 ${remaining_days} 天。" "${YELLOW}"
    fi
}

# --- Script entry point ---
main() {
    load_config # Load configuration on startup

    # If called directly from cron job with specific argument
    if [[ "$1" == "check_auto_backup" ]]; then # New argument for cron triggered check
        log_and_display "由 Cron 任务触发自动备份检查。" "${BLUE}"
        check_auto_backup
        exit 0
    fi

    # Check dependencies for interactive mode
    if ! check_dependencies; then
        log_and_display "${RED}脚本无法运行，因为缺少必要的依赖项。请按照提示安装。${NC}"
        exit 1
    fi

    while true; do
        show_main_menu
        process_menu_choice
    done
}

# Execute main function
main "$@"

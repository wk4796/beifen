#!/bin/bash

# Script global configuration
SCRIPT_NAME="个人自用数据备份"
CONFIG_FILE="$HOME/.personal_backup_config"
LOG_FILE="$HOME/.personal_backup_log.txt"

# Default values (if config file not found)
BACKUP_SOURCE_PATH=""
AUTO_BACKUP_INTERVAL_SEC=3600 # Default auto backup interval in seconds (e.g., 3600s = 1 hour)

# Cloud storage credentials variables (do NOT hardcode here, enter at runtime or via env/awscli config)
S3_ACCESS_KEY=""
S3_SECRET_KEY=""
S3_ENDPOINT="" # Cloudflare R2 Endpoint, e.g., "https://<ACCOUNT_ID>.r2.cloudflarestorage.com"
S3_BUCKET_NAME=""

WEBDAV_URL=""
WEBDAV_USERNAME=""
WEBDAV_PASSWORD=""

# Color definitions
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

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

# --- Configuration save and load ---

# Save configuration to file
save_config() {
    echo "BACKUP_SOURCE_PATH=\"$BACKUP_SOURCE_PATH\"" > "$CONFIG_FILE"
    echo "AUTO_BACKUP_INTERVAL_SEC=$AUTO_BACKUP_INTERVAL_SEC" >> "$CONFIG_FILE"
    # Do NOT save sensitive credentials to config file
    log_and_display "配置已保存到 $CONFIG_FILE"
}

# Load configuration from file
load_config() {
    if [[ -f "$CONFIG_FILE" ]]; then
        source "$CONFIG_FILE"
        log_and_display "配置已从 $CONFIG_FILE 加载。" "${BLUE}"
    else
        log_and_display "未找到配置文件 $CONFIG_FILE，将使用默认配置。" "${YELLOW}"
    fi
}

# --- Core functions ---

# Check required dependencies
check_dependencies() {
    local missing_deps=()
    command -v zip &> /dev/null || missing_deps+=("zip")
    command -v aws &> /dev/null || command -v s3cmd &> /dev/null || missing_deps+=("awscli 或 s3cmd (用于S3/R2)")
    command -v curl &> /dev/null || missing_deps+=("curl (用于WebDAV)")

    if [ ${#missing_deps[@]} -gt 0 ]; then
        log_and_display "${RED}检测到以下依赖项缺失，请安装后重试：${missing_deps[*]}${NC}"
        log_and_display "例如 (Debian/Ubuntu): sudo apt update && sudo apt install zip awscli curl" "${YELLOW}"
        log_and_display "例如 (CentOS/RHEL): sudo yum install zip awscli curl" "${YELLOW}"
        press_enter_to_continue
        return 1
    fi
    return 0
}

# 1. Set auto backup interval
set_auto_backup_interval() {
    display_header
    echo -e "${BLUE}=== 1. 自动备份设定 ===${NC}"
    echo "当前自动备份间隔: ${AUTO_BACKUP_INTERVAL_SEC} 秒"
    echo ""
    read -rp "请输入新的自动备份间隔时间（秒，最小60秒，例如 3600 为 1 小时）: " interval_input

    if [[ "$interval_input" =~ ^[0-9]+$ ]] && [ "$interval_input" -ge 60 ]; then
        AUTO_BACKUP_INTERVAL_SEC="$interval_input"
        save_config
        log_and_display "${GREEN}自动备份间隔已成功设置为：${AUTO_BACKUP_INTERVAL_SEC} 秒。${NC}"
        log_and_display "${YELLOW}提示：要使自动备份真正生效，您需要配置 Cron Job 或 Systemd Service 来定期调用此脚本的备份功能。${NC}"
        log_and_display "${YELLOW}例如，每小时执行一次备份的 Cron Job 条目 (请将 /path/to/your_script.sh 替换为实际路径):${NC}"
        log_and_display "${YELLOW}0 * * * * bash /path/to/your_script.sh manual_backup_from_cron > /dev/null 2>&1${NC}"
    else
        log_and_display "${RED}输入无效，请输入一个大于等于 60 的整数。${NC}"
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

    if [[ -d "$path_input" || -f "$path_input" ]]; then
        BACKUP_SOURCE_PATH="$path_input"
        save_config
        log_and_display "${GREEN}备份路径已成功设置为：${BACKUP_SOURCE_PATH}${NC}"
    else
        log_and_display "${RED}错误：输入的路径无效或不存在。${NC}"
    fi # Corrected from 'F' to 'fi'
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

# 5. Cloud storage settings
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
                log_and_display "${YELLOW}注意：S3/R2 凭证不会保存到配置文件，每次脚本启动需要重新输入或依赖 AWS CLI 配置。${NC}"
                read -rp "请输入 S3/R2 Access Key ID: " S3_ACCESS_KEY
                read -rp "请输入 S3/R2 Secret Access Key: " S3_SECRET_KEY
                read -rp "请输入 S3/R2 Endpoint URL (例如 Cloudflare R2 的 https://<ACCOUNT_ID>.r2.cloudflarestorage.com): " S3_ENDPOINT
                read -rp "请输入 S3/R2 Bucket 名称: " S3_BUCKET_NAME
                log_and_display "${GREEN}S3/R2 配置已更新 (仅本次运行生效，或通过 AWS CLI 持久化)。${NC}"
                log_and_display "${YELLOW}建议您通过 'aws configure' 或设置环境变量来管理 AWS CLI 凭证，以增强安全性。${NC}"
                press_enter_to_continue
                ;;
            2)
                log_and_display "--- 配置 WebDAV 存储 ---"
                log_and_display "${YELLOW}注意：WebDAV 凭证不会保存到配置文件，每次脚本启动需要重新输入。${NC}"
                read -rp "请输入 WebDAV URL (例如 http://your.webdav.server/path/): " WEBDAV_URL
                read -rp "请输入 WebDAV 用户名: " WEBDAV_USERNAME
                read -rp "请输入 WebDAV 密码: " -s WEBDAV_PASSWORD # -s hides input
                echo "" # New line
                log_and_display "${GREEN}WebDAV 配置已更新 (仅本次运行生效)。${NC}"
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

# Core logic to perform backup upload
# Param 1: backup type (e.g., "手动备份", "自动备份")
perform_backup() {
    local backup_type="$1"
    local timestamp=$(date +%Y%m%d%H%M%S)
    local archive_name="backup_${timestamp}.zip"
    local temp_archive_path="/tmp/$archive_name"

    log_and_display "${BLUE}--- ${backup_type} 过程开始 ---${NC}"

    if [[ -z "$BACKUP_SOURCE_PATH" ]]; then
        log_and_display "${RED}错误：备份源路径未设置。请先设置备份路径。${NC}"
        return 1
    fi

    log_and_display "源路径: '$BACKUP_SOURCE_PATH'"
    log_and_display "目标压缩文件: '$temp_archive_path'"

    # --- Compress files ---
    log_and_display "正在压缩文件..."
    if zip -r "$temp_archive_path" "$BACKUP_SOURCE_PATH" &> /dev/null; then
        log_and_display "${GREEN}文件压缩成功！${NC}"
    else
        log_and_display "${RED}文件压缩失败！请检查备份源路径或权限。${NC}"
        rm -f "$temp_archive_path" 2>/dev/null
        return 1
    fi

    # --- Upload to S3/R2 ---
    if [[ -n "$S3_ACCESS_KEY" && -n "$S3_SECRET_KEY" && -n "$S3_ENDPOINT" && -n "$S3_BUCKET_NAME" ]]; then
        log_and_display "正在尝试上传到 S3/R2 存储桶：${S3_BUCKET_NAME}..."
        # Prefer awscli
        if command -v aws &> /dev/null; then
            # Temporarily set AWS credentials for this command, does not affect global config
            AWS_ACCESS_KEY_ID="$S3_ACCESS_KEY" \
            AWS_SECRET_ACCESS_KEY="$S3_SECRET_KEY" \
            aws s3 cp "$temp_archive_path" "s3://${S3_BUCKET_NAME}/${archive_name}" --endpoint-url "$S3_ENDPOINT" > >(tee -a "$LOG_FILE") 2> >(tee -a "$LOG_FILE" >&2)
            if [ $? -eq 0 ]; then
                log_and_display "${GREEN}S3/R2 上传成功！${NC}"
            else
                log_and_display "${RED}S3/R2 上传失败！请检查配置、凭证和网络连接。${NC}"
            fi
        elif command -v s3cmd &> /dev/null; then
            log_and_display "${YELLOW}正在使用 s3cmd。请确保 ~/.s3cfg 已正确配置 Cloudflare R2。${NC}"
            s3cmd put "$temp_archive_path" "s3://${S3_BUCKET_NAME}/${archive_name}" > >(tee -a "$LOG_FILE") 2> >(tee -a "$LOG_FILE" >&2)
            if [ $? -eq 0 ]; then
                log_and_display "${GREEN}S3/R2 上传成功！${NC}"
            else
                log_and_display "${RED}S3/R2 上传失败！请检查 ~/.s3cfg 配置和网络连接。${NC}"
            fi
        else
            log_and_display "${RED}未找到 'awscli' 或 's3cmd' 命令，无法上传到 S3/R2。${NC}"
        fi
    else
        log_and_display "${YELLOW}S3/R2 配置不完整或未设置，跳过 S3/R2 上传。${NC}"
    fi

    # --- Upload to WebDAV ---
    if [[ -n "$WEBDAV_URL" && -n "$WEBDAV_USERNAME" && -n "$WEBDAV_PASSWORD" ]]; then
        log_and_display "正在尝试上传到 WebDAV 服务器：${WEBDAV_URL}..."
        if command -v curl &> /dev/null; then
            # curl PUT method to upload file
            if curl -k --user "$WEBDAV_USERNAME:$WEBDAV_PASSWORD" --upload-file "$temp_archive_path" "${WEBDAV_URL%/}/$archive_name" > >(tee -a "$LOG_FILE") 2> >(tee -a "$LOG_FILE" >&2); then
                log_and_display "${GREEN}WebDAV 上传成功！${NC}"
            else
                log_and_display "${RED}WebDAV 上传失败！请检查 WebDAV 配置、凭证和网络连接。${NC}"
            fi # Corrected from 'F' to 'fi'
        else
            log_and_display "${RED}未找到 'curl' 命令，无法上传到 WebDAV。${NC}"
        fi
    else
        log_and_display "${YELLOW}WebDAV 配置不完整或未设置，跳过 WebDAV 上传。${NC}"
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
}

# 999. Uninstall script
uninstall_script() {
    display_header
    echo -e "${RED}=== 999. 卸载脚本 ===${NC}"
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
    echo -e "  1. ${YELLOW}自动备份设定${NC} (当前间隔: ${AUTO_BACKUP_INTERVAL_SEC} 秒)"
    echo -e "  2. ${YELLOW}手动备份${NC}"
    echo -e "  3. ${YELLOW}自定义备份路径${NC} (当前路径: ${BACKUP_SOURCE_PATH:-未设置})"
    echo -e "  4. ${YELLOW}压缩包格式${NC} (当前支持: ZIP)"
    echo -e "  5. ${YELLOW}云存储设定${NC}"
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "  0. ${RED}退出脚本${NC}"
    echo -e "  999. ${RED}卸载脚本${NC}"
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
        0)
            log_and_display "${GREEN}感谢使用，再见！${NC}"
            exit 0
            ;;
        999) uninstall_script ;;
        *)
            log_and_display "${RED}无效的选项，请重新输入。${NC}"
            press_enter_to_continue
            ;;
    esac
}

# --- Script entry point ---
main() {
    load_config # Load configuration on startup

    # If called directly from cron job, perform manual backup and exit
    if [[ "$1" == "manual_backup_from_cron" ]]; then
        log_and_display "由 Cron 任务触发自动备份。" "${BLUE}"
        perform_backup "自动备份 (Cron)"
        exit 0
    fi

    # Check dependencies
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

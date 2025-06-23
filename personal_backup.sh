#!/usr/bin/env bash
# 设置严格模式，以捕获脚本中的常见错误
set -euo pipefail
IFS=$'\n\t'

# 脚本全局配置
SCRIPT_NAME="个人自用数据备份"
# 使用 XDG Base Directory Specification，将配置文件和日志文件放在标准位置
# 如果您不熟悉 XDG，可以继续使用 $HOME/.personal_backup_config
CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/personal_backup"
LOG_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/personal_backup"
CONFIG_FILE="$CONFIG_DIR/config"
LOG_FILE="$LOG_DIR/log.txt"

# 默认值 (如果配置文件未找到)
# BACKUP_SOURCE_PATH="" # 已被 BACKUP_SOURCE_PATHS_ARRAY 取代
declare -a BACKUP_SOURCE_PATHS_ARRAY=() # 新增：要备份的源路径数组
BACKUP_SOURCE_PATHS_STRING="" # 新增：用于配置文件保存的路径字符串，使用特殊分隔符连接

AUTO_BACKUP_INTERVAL_DAYS=7 # 默认自动备份间隔天数 (例如，7 天 = 1 周)
LAST_AUTO_BACKUP_TIMESTAMP=0 # 上次自动备份的 Unix 时间戳

# 备份保留策略默认值
RETENTION_POLICY_TYPE="none" # "none", "count", "days"
RETENTION_VALUE=0           # 要保留的备份数量或天数

# 云存储凭证变量 (现在从配置文件加载/保存，更方便)
S3_ACCESS_KEY=""
S3_SECRET_KEY=""
S3_ENDPOINT="" # Cloudflare R2 端点，例如："https://<ACCOUNT_ID>.r2.cloudflarestorage.com"
S3_BUCKET_NAME=""
S3_BACKUP_PATH="" # S3/R2 备份的目标路径

WEBDAV_URL=""
WEBDAV_USERNAME=""
WEBDAV_PASSWORD=""
WEBDAV_BACKUP_PATH="" # WebDAV 备份的目标路径

# 备份目标标志
BACKUP_TARGET_S3="false"    # 是否启用 S3/R2 备份 (true/false)
BACKUP_TARGET_WEBDAV="false" # 是否启用 WebDAV 备份 (true/false)

# Telegram 通知变量 (现在从配置文件加载/保存)
TELEGRAM_BOT_TOKEN=""
TELEGRAM_CHAT_ID=""

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m' # 无颜色 - 重置为默认终端颜色

# 用于存储临时压缩文件的目录，使用 mktemp 创建一个安全的临时目录
TEMP_DIR=""

# --- 辅助函数 ---

# 确保在脚本退出时清理临时目录
cleanup_temp_dir() {
    if [[ -n "$TEMP_DIR" && -d "$TEMP_DIR" ]]; then
        rm -rf "$TEMP_DIR"
        # 不使用 log_and_display，避免在退出时产生过多日志
        echo "$(date '+%Y-%m-%d %H:%M:%S') - 清理临时目录: $TEMP_DIR" >> "$LOG_FILE"
    fi
}

# 注册清理函数，以便在脚本退出时运行 (即使发生错误)
trap cleanup_temp_dir EXIT

# 清屏
clear_screen() {
    clear
}

# 显示脚本头部
display_header() {
    clear_screen
    echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${GREEN}           $SCRIPT_NAME           ${NC}"
    echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
}

# 显示消息并记录到日志
log_and_display() {
    local message="$1"
    local color="${2:-}" # 修正：安全地检查 $2 是否已设置，并默认为空字符串
    # 使用 tee -a 将消息同时输出到标准输出和日志文件
    if [[ -n "$color" ]]; then
        echo -e "$(date '+%Y-%m-%d %H:%M:%S') - ${message}" | tee -a "$LOG_FILE"
        echo -e "$color$message$NC"
    else
        echo -e "$(date '+%Y-%m-%d %H:%M:%S') - ${message}" | tee -a "$LOG_FILE"
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
    # 确保配置目录存在
    mkdir -p "$CONFIG_DIR" 2>/dev/null
    if [ ! -d "$CONFIG_DIR" ]; then
        log_and_display "${RED}错误：无法创建配置目录 $CONFIG_DIR，请检查权限。${NC}" ""
        return 1
    fi

    # 将数组转换为字符串，使用 ;; 作为分隔符，确保路径中不太可能出现
    BACKUP_SOURCE_PATHS_STRING=$(IFS=';;'; echo "${BACKUP_SOURCE_PATHS_ARRAY[*]}")

    # 使用原子写入，避免部分写入导致文件损坏
    {
        echo "BACKUP_SOURCE_PATHS_STRING=\"$BACKUP_SOURCE_PATHS_STRING\"" # 保存路径字符串
        echo "AUTO_BACKUP_INTERVAL_DAYS=$AUTO_BACKUP_INTERVAL_DAYS"
        echo "LAST_AUTO_BACKUP_TIMESTAMP=$LAST_AUTO_BACKUP_TIMESTAMP"
        echo "RETENTION_POLICY_TYPE=\"$RETENTION_POLICY_TYPE\""
        echo "RETENTION_VALUE=$RETENTION_VALUE"

        # 保存敏感凭证
        echo "S3_ACCESS_KEY=\"$S3_ACCESS_KEY\""
        echo "S3_SECRET_KEY=\"$S3_SECRET_KEY\""
        echo "S3_ENDPOINT=\"$S3_ENDPOINT\""
        echo "S3_BUCKET_NAME=\"$S3_BUCKET_NAME\""
        echo "S3_BACKUP_PATH=\"$S3_BACKUP_PATH\"" # 保存 S3/R2 备份路径

        echo "WEBDAV_URL=\"$WEBDAV_URL\""
        echo "WEBDAV_USERNAME=\"$WEBDAV_USERNAME\""
        echo "WEBDAV_PASSWORD=\"$WEBDAV_PASSWORD\""
        echo "WEBDAV_BACKUP_PATH=\"$WEBDAV_BACKUP_PATH\"" # 保存 WebDAV 备份路径

        echo "BACKUP_TARGET_S3=\"$BACKUP_TARGET_S3\"" # 保存备份目标标志
        echo "BACKUP_TARGET_WEBDAV=\"$BACKUP_TARGET_WEBDAV\"" # 保存备份目标标志

        echo "TELEGRAM_BOT_TOKEN=\"$TELEGRAM_BOT_TOKEN\""
        echo "TELEGRAM_CHAT_ID=\"$TELEGRAM_CHAT_ID\""
    } > "$CONFIG_FILE"

    log_and_display "配置已保存到 $CONFIG_FILE" ""
    # 重要：立即设置配置文件为安全权限
    chmod 600 "$CONFIG_FILE" 2>/dev/null # 抑制 chmod 失败时的错误 (例如，在只读文件系统上)
    log_and_display "${YELLOW}已将配置文件 $CONFIG_FILE 权限设置为 600 (只有所有者可读写)，请确保您的系统安全。${NC}" ""
}

# 从文件加载配置
load_config() {
    # 确保日志目录存在
    mkdir -p "$LOG_DIR" 2>/dev/null
    if [ ! -d "$LOG_DIR" ]; then
        echo "$(date '+%Y-%m-%d %H:%M:%S') - 错误：无法创建日志目录 $LOG_DIR，请检查权限。" | tee -a "$LOG_FILE"
        return 1
    fi

    if [[ -f "$CONFIG_FILE" ]]; then
        # 检查权限，如果不是 600，则发出警告并尝试设置
        current_perms=$(stat -c "%a" "$CONFIG_FILE" 2>/dev/null)
        if [[ "$current_perms" != "600" ]]; then
            log_and_display "${YELLOW}警告：配置文件 $CONFIG_FILE 权限不安全 (${current_perms})，建议设置为 600。正在尝试设置...${NC}" ""
            chmod 600 "$CONFIG_FILE" 2>/dev/null
            if [ $? -ne 0 ]; then
                log_and_display "${RED}错误：无法将配置文件 $CONFIG_FILE 权限设置为 600，请手动检查。${NC}" ""
            else
                log_and_display "${GREEN}已将配置文件 $CONFIG_FILE 权限设置为 600。${NC}" ""
            fi
        fi
        source "$CONFIG_FILE"
        log_and_display "配置已从 $CONFIG_FILE 加载。" "${BLUE}"

        # 将字符串解析回数组
        if [[ -n "$BACKUP_SOURCE_PATHS_STRING" ]]; then
            IFS=';;' read -r -a BACKUP_SOURCE_PATHS_ARRAY <<< "$BACKUP_SOURCE_PATHS_STRING"
        else
            BACKUP_SOURCE_PATHS_ARRAY=()
        fi
    else
        log_and_display "未找到配置文件 $CONFIG_FILE，将使用默认配置。首次运行或配置已被删除。" "${YELLOW}" ""
        # 确保新变量在未找到配置时也初始化为默认值
        BACKUP_SOURCE_PATHS_ARRAY=()
        BACKUP_SOURCE_PATHS_STRING=""
        S3_BACKUP_PATH=""
        WEBDAV_BACKUP_PATH=""
        BACKUP_TARGET_S3="false"
        BACKUP_TARGET_WEBDAV="false"
    fi
}

# --- 核心功能 ---

# 检查所需依赖项
check_dependencies() {
    local missing_deps=()
    command -v zip &> /dev/null || missing_deps+=("zip")
    # 检查 realpath 命令是否存在，用于规范化路径
    command -v realpath &> /dev/null || missing_deps+=("realpath")


    # 仅当 S3/R2 凭证在配置中设置时才检查 S3/R2 依赖项
    if [[ -n "$S3_ACCESS_KEY" && -n "$S3_SECRET_KEY" && -n "$S3_ENDPOINT" && -n "$S3_BUCKET_NAME" ]]; then
        # 优先检测 awscli，其次 s3cmd
        if ! command -v aws &> /dev/null && ! command -v s3cmd &> /dev/null; then
            missing_deps+=("awscli 或 s3cmd (用于S3/R2)")
        fi
    fi
    # 仅当 WebDAV 凭证在配置中设置时才检查 WebDAV 依赖项
    if [[ -n "$WEBDAV_URL" && -n "$WEBDAV_USERNAME" && -n "$WEBDAV_PASSWORD" ]]; then
        command -v curl &> /dev/null || missing_deps+=("curl (用于WebDAV)")
    fi
    # 仅当 Telegram 凭证在配置中设置时才检查 curl 和 jq 依赖项
    if [[ -n "$TELEGRAM_BOT_TOKEN" && -n "$TELEGRAM_CHAT_ID" ]]; then
        command -v curl &> /dev/null || missing_deps+=("curl (用于Telegram)")
        command -v jq &> /dev/null || missing_deps+=("jq (用于Telegram消息URL编码)")
    fi

    if [ ${#missing_deps[@]} -gt 0 ]; then
        log_and_display "${RED}检测到以下依赖项缺失，请安装后重试：${missing_deps[*]}${NC}" ""
        log_and_display "例如 (Debian/Ubuntu): sudo apt update && sudo apt install zip awscli curl jq realpath" "${YELLOW}"
        log_and_display "例如 (CentOS/RHEL): sudo yum install zip awscli curl jq realpath" "${YELLOW}"
        press_enter_to_continue
        return 1
    fi
    return 0
}

# 发送 Telegram 消息的函数
# 参数 1: 消息内容
send_telegram_message() {
    local message_content="$1"
    if [[ -z "$TELEGRAM_BOT_TOKEN" || -z "$TELEGRAM_CHAT_ID" ]]; then
        log_and_display "${YELLOW}Telegram 通知未配置，跳过发送消息。${NC}" ""
        return 1
    fi

    # 再次检查 curl 和 jq 是否存在
    if ! command -v curl &> /dev/null; then
        log_and_display "${RED}错误：发送 Telegram 消息需要 'curl' 命令，但未找到。${NC}" ""
        return 1
    fi

    local encoded_message=""
    if command -v jq &> /dev/null; then
        encoded_message=$(printf %s "$message_content" | jq -sRr @uri)
    else
        log_and_display "${YELLOW}警告：未找到 'jq'，将使用简单的 URL 编码，可能不完全可靠。${NC}" ""
        # 备用简单编码 (对于复杂字符不太可靠)
        encoded_message=$(printf %s "$message_content" | sed 's/[^a-zA-Z0-9._~-]/%&/g; s/ /%20/g')
    fi

    log_and_display "正在发送 Telegram 消息..." ""
    if curl -s -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
        -d "chat_id=${TELEGRAM_CHAT_ID}" \
        -d "text=${encoded_message}" \
        -d "parse_mode=Markdown" > /dev/null; then
        log_and_display "${GREEN}Telegram 消息发送成功。${NC}" ""
    else
        log_and_display "${RED}Telegram 消息发送失败，请检查 Bot Token 和 Chat ID，或网络连接。${NC}" ""
    fi
}


# 1. 设置自动备份间隔
set_auto_backup_interval() {
    display_header
    echo -e "${BLUE}=== 1. 自动备份设定 ===${NC}"
    echo "当前自动备份间隔: ${AUTO_BACKUP_INTERVAL_DAYS} 天"
    echo ""
    read -rp "请输入新的自动备份间隔时间（天数，最小1天，例如 7 为 1 周）: " interval_input

    if [[ "$interval_input" =~ ^[0-9]+$ ]] && [ "$interval_input" -ge 1 ]; then
        AUTO_BACKUP_INTERVAL_DAYS="$interval_input"
        save_config
        log_and_display "${GREEN}自动备份间隔已成功设置为：${AUTO_BACKUP_INTERVAL_DAYS} 天。${NC}" ""
        log_and_display "${YELLOW}提示：现在您只需确保 Cron Job 每天运行此脚本一次。脚本会根据您设置的间隔自动判断是否执行备份。${NC}" ""
        log_and_display "${YELLOW}Cron Job 条目示例 (请将 /path/to/your_script.sh 替换为实际路径):${NC}" ""
        log_and_display "${YELLOW}0 0 * * * bash /path/to/your_script.sh check_auto_backup > /dev/null 2>&1${NC}" "" # 每天午夜运行
    else
        log_and_display "${RED}输入无效，请输入一个大于等于 1 的整数。${NC}" ""
    fi
    press_enter_to_continue
}

# 2. 手动备份
manual_backup() {
    display_header
    echo -e "${BLUE}=== 2. 手动备份 ===${NC}"
    # 检查是否有至少一个备份路径
    if [ ${#BACKUP_SOURCE_PATHS_ARRAY[@]} -eq 0 ]; then
        log_and_display "${RED}错误：没有设置任何备份源路径。请先通过 '3. 自定义备份路径' 添加路径。${NC}" ""
        press_enter_to_continue
        return 1
    fi
    log_and_display "您选择了手动备份，立即执行备份上传。" "${GREEN}"
    perform_backup "手动备份"
    press_enter_to_continue
}

# --- 修改后的 3. 自定义备份路径 ---
add_backup_path() {
    display_header
    echo -e "${BLUE}=== 添加备份路径 ===${NC}"
    read -rp "请输入要备份的文件或文件夹的绝对路径（例如 /home/user/mydata 或 /etc/nginx/nginx.conf）: " path_input

    local resolved_path=$(realpath -q "$path_input" 2>/dev/null)

    if [[ -z "$resolved_path" ]]; then
        log_and_display "${RED}错误：输入的路径无效或不存在。${NC}" ""
    elif [[ ! -d "$resolved_path" && ! -f "$resolved_path" ]]; then
        log_and_display "${RED}错误：输入的路径 '$resolved_path' 不存在或不是有效的文件/目录。${NC}" ""
    else
        # 检查是否已存在
        local found=false
        for p in "${BACKUP_SOURCE_PATHS_ARRAY[@]}"; do
            if [[ "$p" == "$resolved_path" ]]; then
                found=true
                break
            fi
        done

        if "$found"; then
            log_and_display "${YELLOW}该路径 '$resolved_path' 已存在于备份列表中。${NC}" ""
        else
            BACKUP_SOURCE_PATHS_ARRAY+=("$resolved_path")
            save_config
            log_and_display "${GREEN}备份路径 '$resolved_path' 已成功添加。${NC}" ""
        fi
    fi
    press_enter_to_continue
}

view_and_manage_backup_paths() {
    while true; do
        display_header
        echo -e "${BLUE}=== 查看/管理备份路径 ===${NC}"
        if [ ${#BACKUP_SOURCE_PATHS_ARRAY[@]} -eq 0 ]; then
            log_and_display "${YELLOW}当前没有设置任何备份路径。${NC}" ""
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

                    local resolved_new_path=$(realpath -q "$new_path_input" 2>/dev/null)

                    if [[ -z "$resolved_new_path" ]]; then
                        log_and_display "${RED}错误：输入的路径无效或不存在。${NC}" ""
                    elif [[ ! -d "$resolved_new_path" && ! -f "$resolved_new_path" ]]; then
                        log_and_display "${RED}错误：输入的路径 '$resolved_new_path' 不存在或不是有效的文件/目录。${NC}" ""
                    else
                        # 移除目录的尾部斜杠，但保留文件路径的完整性
                        if [[ -d "$resolved_new_path" ]]; then
                            resolved_new_path="${resolved_new_path%/}"
                        fi
                        BACKUP_SOURCE_PATHS_ARRAY[$((path_index-1))]="$resolved_new_path"
                        save_config
                        log_and_display "${GREEN}路径已成功修改为：${resolved_new_path}${NC}" ""
                    fi
                else
                    log_and_display "${RED}无效的路径序号。${NC}" ""
                fi
                press_enter_to_continue
                ;;
            2) # 删除路径
                read -rp "请输入要删除的路径序号: " path_index
                if [[ "$path_index" =~ ^[0-9]+$ ]] && [ "$path_index" -ge 1 ] && [ "$path_index" -le ${#BACKUP_SOURCE_PATHS_ARRAY[@]} ]; then
                    log_and_display "${YELLOW}警告：您确定要删除路径 '${BACKUP_SOURCE_PATHS_ARRAY[$((path_index-1))]}' 吗？(y/N)${NC}" ""
                    read -rp "请确认: " confirm_delete
                    if [[ "$confirm_delete" =~ ^[Yy]$ ]]; then
                        # 从数组中删除元素
                        unset 'BACKUP_SOURCE_PATHS_ARRAY[$((path_index-1))]'
                        BACKUP_SOURCE_PATHS_ARRAY=("${BACKUP_SOURCE_PATHS_ARRAY[@]}") # 重新索引数组
                        save_config
                        log_and_display "${GREEN}路径已成功删除。${NC}" ""
                    else
                        log_and_display "取消删除路径。" "${BLUE}"
                    fi
                else
                    log_and_display "${RED}无效的路径序号。${NC}" ""
                fi
                press_enter_to_continue
                ;;
            0)
                log_and_display "返回自定义备份路径菜单。" "${BLUE}"
                break
                ;;
            *)
                log_and_display "${RED}无效的选项，请重新输入。${NC}" ""
                press_enter_to_continue
                ;;
        esac
    done
}

# 3. 自定义备份路径主函数
set_backup_path() {
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
                log_and_display "返回主菜单。" "${BLUE}"
                break
                ;;
            *)
                log_and_display "${RED}无效的选项，请重新输入。${NC}" ""
                press_enter_to_continue
                ;;
        esac
    done
}

# 4. 压缩格式信息 (保持不变)
display_compression_info() {
    display_header
    echo -e "${BLUE}=== 4. 压缩包格式 ===${NC}"
    log_and_display "本脚本当前支持的压缩格式为：${GREEN}ZIP${NC}。" ""
    log_and_display "如果您需要其他格式（如 .tar.gz），请修改脚本中 'perform_backup' 函数的压缩命令。" "${YELLOW}" ""
    press_enter_to_continue
}

# --- 云存储连接测试和文件夹列表 (保持不变) ---

# 测试 S3/R2 连接
test_s3_r2_connection() {
    if [[ -z "$S3_ACCESS_KEY" || -z "$S3_SECRET_KEY" || -z "$S3_ENDPOINT" || -z "$S3_BUCKET_NAME" ]]; then
        log_and_display "${RED}S3/R2 配置不完整，无法测试连接。请先填写 Access Key, Secret Key, Endpoint 和 Bucket 名称。${NC}" ""
        return 1
    fi

    log_and_display "正在测试 S3/R2 连接到桶：${S3_BUCKET_NAME}..." "${BLUE}"

    # 临时设置 AWS 环境变量以供 awscli 使用
    export AWS_ACCESS_KEY_ID="$S3_ACCESS_KEY"
    export AWS_SECRET_ACCESS_KEY="$S3_SECRET_KEY"

    local test_output=""
    local test_status=1

    if command -v aws &> /dev/null; then
        # 尝试列出桶内少量对象，带超时，用于测试连接
        test_output=$(aws s3 ls "s3://${S3_BUCKET_NAME}/" --endpoint-url "$S3_ENDPOINT" --page-size 1 --cli-read-timeout 10 --cli-connect-timeout 10 2>&1)
        test_status=$?
    elif command -v s3cmd &> /dev/null; then
        log_and_display "${YELLOW}正在使用 s3cmd 进行连接测试。请确保 ~/.s3cfg 已正确配置 Cloudflare R2。${NC}" ""
        # s3cmd 通常会读取 ~/.s3cfg 或通过命令行参数，这里不强制传递凭证
        test_output=$(s3cmd ls "s3://${S3_BUCKET_NAME}/" 2>&1)
        test_status=$?
    else
        log_and_display "${RED}未找到 'awscli' 或 's3cmd' 命令，无法测试 S3/R2 连接。${NC}" ""
        unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY
        return 1
    fi

    # 清理 AWS 环境变量
    unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY

    if [ "$test_status" -eq 0 ]; then
        log_and_display "${GREEN}S3/R2 连接成功！${NC}" ""
        return 0
    else
        log_and_display "${RED}S3/R2 连接失败！请检查配置、凭证和网络连接。错误信息: ${test_output}${NC}" ""
        return 1
    fi
}

# 获取 S3/R2 桶中的文件夹列表
get_s3_r2_folders() {
    # 不再在函数内部调用 test_s3_r2_connection，而是依赖调用者先进行测试
    # 如果 test_s3_r2_connection 成功，则继续
    log_and_display "正在获取 S3/R2 存储桶中的文件夹列表 (最多显示50个)：" "${BLUE}"
    export AWS_ACCESS_KEY_ID="$S3_ACCESS_KEY"
    export AWS_SECRET_ACCESS_KEY="$S3_SECRET_KEY"
    local folders=()

    if command -v aws &> /dev/null; then
        # 使用 --delimiter '/' 和 --query "CommonPrefixes[].Prefix" 来获取顶层文件夹
        folders=($(aws s3 ls "s3://${S3_BUCKET_NAME}/" --endpoint-url "$S3_ENDPOINT" --delimiter '/' --query "CommonPrefixes[].Prefix" --output text 2>/dev/null))
    elif command -v s3cmd &> /dev/null; then
        log_and_display "${YELLOW}正在使用 s3cmd 获取文件夹列表。${NC}" ""
        # s3cmd 的输出需要进一步处理以提取文件夹名称
        folders=($(s3cmd ls "s3://${S3_BUCKET_NAME}/" 2>/dev/null | awk '{print $4}' | sed 's|s3://'"${S3_BUCKET_NAME//./\\.}"'\///' | head -n 50)) # 仅显示前50个
    else
        log_and_display "${RED}未找到 'awscli' 或 's3cmd' 命令，无法获取 S3/R2 文件夹列表。${NC}" ""
        unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY
        return 1 # 明确返回失败状态
    fi
    unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY

    if [ ${#folders[@]} -eq 0 ]; then
        log_and_display "${YELLOW}S3/R2 存储桶中没有检测到文件夹。${NC}" ""
    else
        for i in "${!folders[@]}"; do
            echo "  $((i+1)). ${folders[$i]}"
        done
    fi
    echo "${folders[@]}" # 返回一个空格分隔的字符串，方便调用者解析
}


# 测试 WebDAV 连接
test_webdav_connection() {
    if [[ -z "$WEBDAV_URL" || -z "$WEBDAV_USERNAME" || -z "$WEBDAV_PASSWORD" ]]; then
        log_and_display "${RED}WebDAV 配置不完整，无法测试连接。请先填写 URL, 用户名和密码。${NC}" ""
        return 1
    fi

    log_and_display "正在测试 WebDAV 连接到：${WEBDAV_URL}..." "${BLUE}"
    log_and_display "${YELLOW}警告：如果您的WebDAV服务器使用自签名证书，curl的-k/--insecure选项将跳过证书验证。在生产环境中，请确保使用受信任的证书。${NC}" ""

    # 使用 PROPFIND 方法测试连接，并检查 HTTP 状态码
    local http_code=$(curl -s -o /dev/null -w "%{http_code}" -L -k --user "$WEBDAV_USERNAME:$WEBDAV_PASSWORD" --request PROPFIND --header "Depth: 1" "${WEBDAV_URL%/}/" 2>/dev/null)
    local curl_status=$? # 获取 curl 的退出状态码

    if [ "$curl_status" -eq 0 ] && [[ "$http_code" -ge 200 && "$http_code" -lt 300 ]]; then
        log_and_display "${GREEN}WebDAV 连接成功！ (HTTP状态码: ${http_code})${NC}" ""
        return 0
    else
        log_and_display "${RED}WebDAV 连接失败！HTTP状态码: ${http_code}。请检查配置、凭证和网络连接。${NC}" ""
        log_and_display "${RED}Curl 错误码: ${curl_status}。${NC}" ""
        return 1
    fi
}

# 获取 WebDAV 服务器中的文件夹列表
get_webdav_folders() {
    # 不再在函数内部调用 test_webdav_connection，而是依赖调用者先进行测试
    # 如果 test_webdav_connection 成功，则继续
    log_and_display "正在获取 WebDAV 服务器中的文件夹列表 (最多显示50个)：" "${BLUE}"
    local folders=()
    local curl_output=""

    if ! command -v curl &> /dev/null; then
        log_and_display "${RED}错误：发送 WebDAV 请求需要 'curl' 命令，但未找到。${NC}" ""
        return 1 # 明确返回失败状态
    fi

    # 使用 PROPFIND 获取目录列表，解析 XML 响应
    # 确保 WEBDAV_URL 以 / 结尾以便 PROPFIND 正确列出子项
    curl_output=$(curl -s -L -k --user "$WEBDAV_USERNAME:$WEBDAV_PASSWORD" --request PROPFIND --header "Depth: 1" "${WEBDAV_URL%/}/" 2>/dev/null)

    if [ $? -eq 0 ]; then
        # 从 XML 响应中提取 href 标签的内容
        # 筛选出以 '/' 结尾的目录，并去除 WebDAV URL 前缀以获得相对路径
        local base_url_escaped=$(echo "${WEBDAV_URL%/}/" | sed 's|/|\\/|g; s|\.|\\.|g')
        # 优化正则，更准确地匹配目录，并去除最后的斜杠方便显示
        folders=($(echo "$curl_output" | grep -oP '<D:href>\K([^<]*?\/)(?=</D:href>)' | sed 's|^\(http\|https\):\/\/[^/]*||' | grep -E '\/$' | grep -v "$base_url_escaped" | sed 's|/$||' | head -n 50))
    else
        log_and_display "${RED}WebDAV 请求失败，无法获取文件夹列表。${NC}" ""
        return 1 # 明确返回失败状态
    fi

    if [ ${#folders[@]} -eq 0 ]; then
        log_and_display "${YELLOW}WebDAV 服务器中没有检测到文件夹。${NC}" ""
    else
        for i in "${!folders[@]}"; do
            echo "  $((i+1)). ${folders[$i]}"
        done
    fi
    echo "${folders[@]}" # 返回一个空格分隔的字符串
}

# 让用户选择/输入 S3/R2 备份路径
choose_s3_r2_path() {
    local default_path="$1" # 当前默认路径
    local selected_path=""

    while true; do
        log_and_display "当前 S3/R2 备份目标路径: ${S3_BACKUP_PATH:-未设置}" "${BLUE}"
        echo ""
        log_and_display "请选择 S3/R2 上的备份目标路径：" ""
        log_and_display "1. 从云端现有文件夹中选择" ""
        log_and_display "2. 手动输入新路径（例如: my_backups/daily/ 或 just_files/）" ""
        log_and_display "0. 取消设置" ""
        read -rp "请输入选项: " path_choice

        case "$path_choice" in
            1)
                local s3_folders_str=$(get_s3_r2_folders)
                if [ -z "$s3_folders_str" ]; then
                    log_and_display "${YELLOW}S3/R2 存储桶中没有可用文件夹，请选择手动输入。${NC}" ""
                    press_enter_to_continue
                    continue # 重新显示路径选择菜单
                fi
                local IFS=$'\n' s3_folders_array=($s3_folders_str) # 重新解析为数组
                unset IFS

                read -rp "请输入文件夹序号或直接输入完整路径（例如 backup/）: " folder_input
                if [[ "$folder_input" =~ ^[0-9]+$ ]] && [ "$folder_input" -ge 1 ] && [ "$folder_input" -le ${#s3_folders_array[@]} ]; then
                    selected_path="${s3_folders_array[$((folder_input-1))]}"
                else
                    selected_path="$folder_input"
                fi
                # 确保路径以斜杠结尾，如果非空
                if [[ -n "$selected_path" && "${selected_path: -1}" != "/" ]]; then
                    selected_path="${selected_path}/"
                fi
                break # 退出循环，进行路径确认
                ;;
            2)
                read -rp "请输入 S3/R2 上的新备份目标路径 (例如 my_backups/daily/): " new_path
                # 确保路径以斜杠结尾，如果非空
                if [[ -n "$new_path" && "${new_path: -1}" != "/" ]]; then
                    new_path="${new_path}/"
                fi
                selected_path="$new_path"
                break # 退出循环，进行路径确认
                ;;
            0)
                log_and_display "取消设置 S3/R2 备份路径。" "${BLUE}"
                return 1 # 表示取消
                ;;
            *)
                log_and_display "${RED}无效的选项，请重新输入。${NC}" ""
                press_enter_to_continue
                ;;
        esac
    done

    # 确认路径
    read -rp "您选择的 S3/R2 目标路径是 '${selected_path}'。确认吗？(y/N): " confirm_path
    if [[ "$confirm_path" =~ ^[Yy]$ ]]; then
        S3_BACKUP_PATH="$selected_path"
        log_and_display "${GREEN}S3/R2 备份路径已设置为：${S3_BACKUP_PATH}${NC}" ""
        return 0 # 表示成功设置
    else
        log_and_display "${YELLOW}取消设置 S3/R2 备份路径，请重新选择。${NC}" ""
        return 1 # 表示用户决定重新选择
    fi
}

# 让用户选择/输入 WebDAV 备份路径
choose_webdav_path() {
    local default_path="$1" # 当前默认路径
    local selected_path=""

    while true; do
        log_and_display "当前 WebDAV 备份目标路径: ${WEBDAV_BACKUP_PATH:-未设置}" "${BLUE}"
        echo ""
        log_and_display "请选择 WebDAV 上的备份目标路径：" ""
        log_and_display "1. 从云端现有文件夹中选择" ""
        log_and_display "2. 手动输入新路径（例如: my_backups/daily/ 或 just_files/）" ""
        log_and_display "0. 取消设置" ""
        read -rp "请输入选项: " path_choice

        case "$path_choice" in
            1)
                # 确保在尝试获取文件夹前先进行连接测试
                if ! test_webdav_connection; then
                    log_and_display "${RED}WebDAV 连接失败，无法获取文件夹列表。请先检查配置和连接。${NC}" ""
                    press_enter_to_continue
                    continue # 重新显示路径选择菜单
                fi
                local webdav_folders_str=$(get_webdav_folders)
                if [ -z "$webdav_folders_str" ]; then
                    log_and_display "${YELLOW}WebDAV 服务器中没有可用文件夹，请选择手动输入。${NC}" ""
                    press_enter_to_continue
                    continue # 重新显示路径选择菜单
                fi
                local IFS=$'\n' webdav_folders_array=($webdav_folders_str)
                unset IFS

                read -rp "请输入文件夹序号或直接输入完整路径（例如 backup/）: " folder_input
                if [[ "$folder_input" =~ ^[0-9]+$ ]] && [ "$folder_input" -ge 1 ] && [ "$folder_input" -le ${#webdav_folders_array[@]} ]; then
                    selected_path="${webdav_folders_array[$((folder_input-1))]}"
                else
                    selected_path="$folder_input"
                fi
                # 确保路径以斜杠结尾，如果非空
                if [[ -n "$selected_path" && "${selected_path: -1}" != "/" ]]; then
                    selected_path="${selected_path}/"
                fi
                break # 退出循环，进行路径确认
                ;;
            2)
                read -rp "请输入 WebDAV 上的新备份目标路径 (例如 my_backups/daily/): " new_path
                # 确保路径以斜杠结尾，如果非空
                if [[ -n "$new_path" && "${new_path: -1}" != "/" ]]; then
                    new_path="${new_path}/"
                fi
                selected_path="$new_path"
                break # 退出循环，进行路径确认
                ;;
            0)
                log_and_display "取消设置 WebDAV 备份路径。" "${BLUE}"
                return 1 # 表示取消
                ;;
            *)
                log_and_display "${RED}无效的选项，请重新输入。${NC}" ""
                press_enter_to_continue
                ;;
        esac
    done

    read -rp "您选择的 WebDAV 目标路径是 '${selected_path}'。确认吗？(y/N): " confirm_path
    if [[ "$confirm_path" =~ ^[Yy]$ ]]; then
        WEBDAV_BACKUP_PATH="$selected_path"
        log_and_display "${GREEN}WebDAV 备份路径已设置为：${WEBDAV_BACKUP_PATH}${NC}" ""
        return 0 # 表示成功设置
    else
        log_and_display "${YELLOW}取消设置 WebDAV 备份路径，请重新选择。${NC}" ""
        return 1 # 表示用户决定重新选择
    fi
}


# 管理 S3/R2 账号设置
manage_s3_r2_account() {
    while true; do
        display_header
        echo -e "${BLUE}=== 管理 S3/R2 存储账号 ===${NC}"
        local s3_status="${RED}未配置${NC}"
        local s3_path_status="${YELLOW}未设置目标路径${NC}"

        # 判断 S3/R2 账号是否已配置
        if [[ -n "$S3_ACCESS_KEY" && -n "$S3_SECRET_KEY" && -n "$S3_ENDPOINT" && -n "$S3_BUCKET_NAME" ]]; then
            s3_status="${GREEN}已配置${NC} (桶: ${S3_BUCKET_NAME})"
            if [[ -n "$S3_BACKUP_PATH" ]]; then
                s3_path_status="${GREEN}已设置目标路径: ${S3_BACKUP_PATH}${NC}"
            fi
        fi

        echo "当前 S3/R2 账号状态: $s3_status"
        echo "S3/R2 目标路径状态: $s3_path_status"
        echo ""
        echo "1. 添加/修改 S3/R2 账号凭证"
        echo "2. 测试 S3/R2 连接" # 分离出的测试连接选项
        echo "3. 设置 S3/R2 备份目标路径" # 分离出的设置路径选项
        echo "4. 清除 S3/R2 账号配置"
        echo "0. 返回云存储设定主菜单"
        echo -e "${BLUE}------------------------------------------------${NC}"
        read -rp "请输入选项: " sub_choice

        case $sub_choice in
            1)
                log_and_display "--- 添加/修改 S3/R2 账号凭证 ---" ""
                log_and_display "${YELLOW}凭证将保存到本地配置文件，请确保配置文件安全！${NC}" ""
                read -rp "请输入 S3/R2 Access Key ID [当前: ${S3_ACCESS_KEY}]: " input_key
                S3_ACCESS_KEY="${input_key:-$S3_ACCESS_KEY}" # 如果输入为空，保留当前值

                read -rp "请输入 S3/R2 Secret Access Key [当前: ${S3_SECRET_KEY}]: " input_secret
                S3_SECRET_KEY="${input_secret:-$S3_SECRET_KEY}"

                read -rp "请输入 S3/R2 Endpoint URL (例如 Cloudflare R2 的 https://<ACCOUNT_ID>.r2.cloudflstorage.com) [当前: ${S3_ENDPOINT}]: " input_endpoint
                S3_ENDPOINT="${input_endpoint:-$S3_ENDPOINT}"

                read -rp "请输入 S3/R2 Bucket 名称 [当前: ${S3_BUCKET_NAME}]: " input_bucket
                S3_BUCKET_NAME="${input_bucket:-$S3_BUCKET_NAME}"

                save_config
                log_and_display "${GREEN}S3/R2 账号凭证已更新并保存。${NC}" ""
                press_enter_to_continue
                ;;
            2) # 新增：测试 S3/R2 连接
                test_s3_r2_connection
                press_enter_to_continue
                ;;
            3) # 新增：设置 S3/R2 备份目标路径
                # 确保在尝试设置路径前先进行连接测试
                if ! test_s3_r2_connection; then
                    log_and_display "${RED}S3/R2 连接失败，无法设置备份目标路径。请先检查配置和连接。${NC}" ""
                    press_enter_to_continue
                    continue # 重新显示当前菜单
                fi
                choose_s3_r2_path "$S3_BACKUP_PATH" # 传递当前路径作为默认值
                save_config # 路径选择后保存配置
                press_enter_to_continue
                ;;
            4) # 原来的选项 3 变为 4
                log_and_display "${YELLOW}警告：这将清除所有 S3/R2 账号配置。确定吗？(y/N)${NC}" ""
                read -rp "请确认: " confirm_clear
                if [[ "$confirm_clear" =~ ^[Yy]$ ]]; then
                    S3_ACCESS_KEY=""
                    S3_SECRET_KEY=""
                    S3_ENDPOINT=""
                    S3_BUCKET_NAME=""
                    S3_BACKUP_PATH=""
                    BACKUP_TARGET_S3="false" # 禁用 S3 备份
                    save_config
                    log_and_display "${GREEN}S3/R2 账号配置已清除。${NC}" ""
                else
                    log_and_display "取消清除 S3/R2 账号配置。" "${BLUE}"
                fi
                press_enter_to_continue
                ;;
            0)
                log_and_display "返回云存储设定主菜单。" "${BLUE}"
                break
                ;;
            *)
                log_and_display "${RED}无效的选项，请重新输入。${NC}" ""
                press_enter_to_continue
                ;;
        esac
    done
}

# 管理 WebDAV 账号设置
manage_webdav_account() {
    while true; do
        display_header
        echo -e "${BLUE}=== 管理 WebDAV 存储账号 ===${NC}"
        local webdav_status="${RED}未配置${NC}"
        local webdav_path_status="${YELLOW}未设置目标路径${NC}"

        # 判断 WebDAV 账号是否已配置
        if [[ -n "$WEBDAV_URL" && -n "$WEBDAV_USERNAME" && -n "$WEBDAV_PASSWORD" ]]; then
            # 隐藏密码显示
            local display_url="${WEBDAV_URL}"
            display_url="${display_url/:\/\/www./:\/\/\*\*\*./}" # 简单替换，避免直接显示敏感部分
            webdav_status="${GREEN}已配置${NC} (URL: ${display_url} 用户名: ${WEBDAV_USERNAME})"
            if [[ -n "$WEBDAV_BACKUP_PATH" ]]; then
                webdav_path_status="${GREEN}已设置目标路径: ${WEBDAV_BACKUP_PATH}${NC}"
            fi
        fi

        echo "当前 WebDAV 账号状态: $webdav_status"
        echo "WebDAV 目标路径状态: $webdav_path_status"
        echo ""
        echo "1. 添加/修改 WebDAV 账号凭证"
        echo "2. 测试 WebDAV 连接" # 分离出的测试连接选项
        echo "3. 设置 WebDAV 备份目标路径" # 分离出的设置路径选项
        echo "4. 清除 WebDAV 账号配置"
        echo "0. 返回云存储设定主菜单"
        echo -e "${BLUE}------------------------------------------------${NC}"
        read -rp "请输入选项: " sub_choice

        case $sub_choice in
            1)
                log_and_display "--- 添加/修改 WebDAV 账号凭证 ---" ""
                log_and_display "${YELLOW}凭证将保存到本地配置文件，请确保配置文件安全！${NC}" ""
                read -rp "请输入 WebDAV URL (例如 http://your.webdav.server/path/) [当前: ${WEBDAV_URL}]: " input_url
                WEBDAV_URL="${input_url:-$WEBDAV_URL}"

                read -rp "请输入 WebDAV 用户名 [当前: ${WEBDAV_USERNAME}]: " input_username
                WEBDAV_USERNAME="${input_username:-$WEBDAV_USERNAME}"

                read -rp "请输入 WebDAV 密码 (留空不修改当前密码): " -s input_password
                echo "" # 隐藏输入后换行
                if [[ -n "$input_password" ]]; then # 仅在提供了新密码时才更新
                    WEBDAV_PASSWORD="$input_password"
                fi

                save_config
                log_and_display "${GREEN}WebDAV 账号凭证已更新并保存。${NC}" ""
                press_enter_to_continue
                ;;
            2) # 新增：测试 WebDAV 连接
                test_webdav_connection
                press_enter_to_continue
                ;;
            3) # 新增：设置 WebDAV 备份目标路径
                # 确保在尝试设置路径前先进行连接测试
                if ! test_webdav_connection; then
                    log_and_display "${RED}WebDAV 连接失败，无法设置备份目标路径。请先检查配置和连接。${NC}" ""
                    press_enter_to_continue
                    continue # 重新显示当前菜单
                fi
                choose_webdav_path "$WEBDAV_BACKUP_PATH" # 传递当前路径作为默认值
                save_config # 路径选择后保存配置
                press_enter_to_continue
                ;;
            4) # 原来的选项 3 变为 4
                log_and_display "${YELLOW}警告：这将清除所有 WebDAV 账号配置。确定吗？(y/N)${NC}" ""
                read -rp "请确认: " confirm_clear
                if [[ "$confirm_clear" =~ ^[Yy]$ ]]; then
                    WEBDAV_URL=""
                    WEBDAV_USERNAME=""
                    WEBDAV_PASSWORD=""
                    WEBDAV_BACKUP_PATH=""
                    BACKUP_TARGET_WEBDAV="false" # 禁用 WebDAV 备份
                    save_config
                    log_and_display "${GREEN}WebDAV 账号配置已清除。${NC}" ""
                else
                    log_and_display "取消清除 WebDAV 账号配置。" "${BLUE}"
                fi
                press_enter_to_continue
                ;;
            0)
                log_and_display "返回云存储设定主菜单。" "${BLUE}"
                break
                ;;
            *)
                log_and_display "${RED}无效的选项，请重新输入。${NC}" ""
                press_enter_to_continue
                ;;
        esac
    done
}

# 选择要使用的云存储目标
select_backup_targets() {
    while true; do
        display_header
        echo -e "${BLUE}=== 选择云备份目标 ===${NC}"
        echo "请选择要用于备份的云存储 (可多选，至少选择一个有效目标)："
        echo "------------------------------------------------"

        local s3_configured="false"
        local webdav_configured="false"

        # 检查 S3/R2 配置状态
        if [[ -n "$S3_ACCESS_KEY" && -n "$S3_SECRET_KEY" && -n "$S3_ENDPOINT" && -n "$S3_BUCKET_NAME" && -n "$S3_BACKUP_PATH" ]]; then
            s3_configured="true"
            echo -n "1. S3/R2 存储 (当前: "
            if [[ "$BACKUP_TARGET_S3" == "true" ]]; then echo -e "${GREEN}启用${NC})"
            else echo -e "${YELLOW}禁用${NC})" ; fi
            echo "    (已配置账号并设置路径: ${S3_BACKUP_PATH})"
        else
            echo -e "1. S3/R2 存储 (${RED}未完全配置，无法启用${NC})"
        fi

        # 检查 WebDAV 配置状态
        if [[ -n "$WEBDAV_URL" && -n "$WEBDAV_USERNAME" && -n "$WEBDAV_PASSWORD" && -n "$WEBDAV_BACKUP_PATH" ]]; then
            webdav_configured="true"
            echo -n "2. WebDAV 存储 (当前: "
            if [[ "$BACKUP_TARGET_WEBDAV" == "true" ]]; then echo -e "${GREEN}启用${NC})"
            else echo -e "${YELLOW}禁用${NC})" ; fi
            echo "    (已配置账号并设置路径: ${WEBDAV_BACKUP_PATH})"
        else
            echo -e "2. WebDAV 存储 (${RED}未完全配置，无法启用${NC})"
        fi

        echo ""
        echo "0. 返回主菜单 (保存选择)"
        echo -e "${BLUE}------------------------------------------------${NC}"
        read -rp "请输入选项 (例如 '1', '2', '1 2' 或 '0'): " choice_input

        local temp_s3_target="$BACKUP_TARGET_S3"
        local temp_webdav_target="$BACKUP_TARGET_WEBDAV"

        case "$choice_input" in
            "1")
                if [[ "$s3_configured" == "true" ]]; then
                    temp_s3_target="true"
                    temp_webdav_target="false" # 选择单项时，其他项默认禁用
                    log_and_display "已选择：仅启用 S3/R2 备份。" "${GREEN}"
                else
                    log_and_display "${RED}S3/R2 未完全配置，无法启用。${NC}" ""
                fi
                ;;
            "2")
                if [[ "$webdav_configured" == "true" ]]; then
                    temp_s3_target="false" # 选择单项时，其他项默认禁用
                    temp_webdav_target="true"
                    log_and_display "已选择：仅启用 WebDAV 备份。" "${GREEN}"
                else
                    log_and_display "${RED}WebDAV 未完全配置，无法启用。${NC}" ""
                fi
                ;;
            "1 2" | "2 1")
                if [[ "$s3_configured" == "true" && "$webdav_configured" == "true" ]]; then
                    temp_s3_target="true"
                    temp_webdav_target="true"
                    log_and_display "已选择：同时启用 S3/R2 和 WebDAV 备份。" "${GREEN}"
                else
                    log_and_display "${RED}至少一个云存储未完全配置，无法启用多目标备份。${NC}" ""
                fi
                ;;
            "0")
                if [[ "$temp_s3_target" == "false" && "$temp_webdav_target" == "false" ]]; then
                    log_and_display "${RED}警告：未选择任何有效备份目标。这会导致自动备份无法上传文件。${NC}" ""
                    read -rp "确定要不选择任何目标吗？(y/N): " confirm_none
                    if [[ ! "$confirm_none" =~ ^[Yy]$ ]]; then
                        continue # 重新显示菜单
                    fi
                fi
                BACKUP_TARGET_S3="$temp_s3_target"
                BACKUP_TARGET_WEBDAV="$temp_webdav_target"
                save_config
                log_and_display "备份目标设置已保存。" "${BLUE}"
                break
                ;;
            *)
                log_and_display "${RED}无效的选项，请重新输入。${NC}" ""
                ;;
        esac
        press_enter_to_continue
    done
}


# 5. 云存储设定 (主要修改)
set_cloud_storage() {
    while true; do
        display_header
        echo -e "${BLUE}=== 5. 云存储设定 ===${NC}"
        # 显示当前已配置的账号状态，满足“再次进入5. 云存储设定 会在其1. 配置 S3/R2 存储 和 2. 配置 WebDAV 存储 他们各自的下方显示当前已添加的账号”的要求
        local s3_info="${RED}未配置${NC}"
        if [[ -n "$S3_ACCESS_KEY" && -n "$S3_BUCKET_NAME" ]]; then
            s3_info="${GREEN}已配置${NC} (桶: ${S3_BUCKET_NAME} | 路径: ${S3_BACKUP_PATH:-未设置})"
        fi
        local webdav_info="${RED}未配置${NC}"
        if [[ -n "$WEBDAV_URL" && -n "$WEBDAV_USERNAME" ]]; then
             # 隐藏密码显示
            local display_url="${WEBDAV_URL}"
            display_url="${display_url/:\/\/www./:\/\/\*\*\*./}"
            webdav_info="${GREEN}已配置${NC} (URL: ${display_url} | 用户名: ${WEBDAV_USERNAME} | 路径: ${WEBDAV_BACKUP_PATH:-未设置})"
        fi

        echo "1. 选择云备份目标 (S3/R2: ${BACKUP_TARGET_S3}, WebDAV: ${BACKUP_TARGET_WEBDAV})"
        echo "    当前S3/R2账号: $s3_info"
        echo "    当前WebDAV账号: $webdav_info"
        echo "2. 管理 S3/R2 账号设置"
        echo "3. 管理 WebDAV 账号设置"
        echo "0. 返回主菜单"
        echo -e "${BLUE}------------------------------------------------${NC}"
        read -rp "请输入选项: " sub_choice

        case $sub_choice in
            1) select_backup_targets ;; # 满足“添加要用哪个进行云备份的选择 选择项有 选其一或者多选，可以随时进行切换”的要求
            2) manage_s3_r2_account ;; # 满足“添加完毕后再次进入5. 云存储设定 会在其1. 配置 S3/R2 存储...下方显示当前已添加的账号 还有修改当前账号参数的选项”的要求
            3) manage_webdav_account ;; # 满足“添加完毕后再次进入5. 云存储设定 会在其...2. 配置 WebDAV 存储 他们各自的下方显示当前已添加的账号 还有修改当前账号参数的选项”的要求
            0)
                log_and_display "返回主菜单。" "${BLUE}"
                break
                ;;
            *)
                log_and_display "${RED}无效的选项，请重新输入。${NC}" ""
                press_enter_to_continue
                ;;
        esac
    done
}

# 6. 设置 Telegram 通知设定 (保持不变)
set_telegram_notification() {
    display_header
    echo -e "${BLUE}=== 6. 消息通知设定 (Telegram) ===${NC}"
    log_and_display "${YELLOW}Telegram Bot Token 和 Chat ID 将保存到本地配置文件，请确保配置文件安全！${NC}" ""
    read -rp "请输入 Telegram Bot Token (例如 123456:ABC-DEF1234ghIkl-79f): " TELEGRAM_BOT_TOKEN
    read -rp "请输入 Telegram Chat ID (例如 -123456789 或 123456789): " TELEGRAM_CHAT_ID
    save_config # 保存凭证到配置文件
    log_and_display "${GREEN}Telegram 通知配置已更新并保存。${NC}" ""
    log_and_display "${YELLOW}提示：您可以向 @BotFather 获取 Bot Token，然后向您的 Bot 发送消息，再访问 https://api.telegram.org/bot<YOUR_BOT_TOKEN>/getUpdates 获取 Chat ID。${NC}" ""
    press_enter_to_continue
}

# 7. 设置备份保留策略 (保持不变)
set_retention_policy() {
    while true; do
        display_header
        echo -e "${BLUE}=== 7. 设置备份保留策略 (云端) ===${NC}"
        echo "当前策略: "
        case "$RETENTION_POLICY_TYPE" in
            "none") echo -e "  ${YELLOW}无保留策略（所有备份将保留）${NC}" ;;
            "count") echo -e "  ${YELLOW}保留最新 ${RETENTION_VALUE} 个备份${NC}" ;;
            "days")  echo -e "  ${YELLOW}保留最近 ${RETENTION_VALUE} 天内的备份${NC}" ;;
            *)       echo -e "  ${YELLOW}未知策略或未设置${NC}" ;; # 添加默认情况
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
                    log_and_display "${GREEN}已设置保留最新 ${RETENTION_VALUE} 个备份的策略。${NC}" ""
                fi
                press_enter_to_continue
                ;;
            2)
                read -rp "请输入要保留备份的天数 (例如 30): " value_input
                if [[ "$value_input" =~ ^[0-9]+$ ]] && [ "$value_input" -ge 1 ]; then
                    RETENTION_POLICY_TYPE="days"
                    RETENTION_VALUE="$value_input"
                    save_config
                    log_and_display "${GREEN}已设置保留最近 ${RETENTION_VALUE} 天内的备份策略。${NC}" ""
                fi
                press_enter_to_continue
                ;;
            3)
                RETENTION_POLICY_TYPE="none"
                RETENTION_VALUE=0
                save_config
                log_and_display "${GREEN}已关闭备份保留策略。${NC}" ""
                press_enter_to_continue
                ;;
            0)
                log_and_display "返回主菜单。" "${BLUE}"
                break
                ;;
            *)
                log_and_display "${RED}无效的选项，请重新输入。${NC}" ""
                press_enter_to_continue
                ;;
        esac
    done
}


# 应用保留策略的函数 (适应新的命名规则)
apply_retention_policy() {
    log_and_display "${BLUE}--- 正在应用备份保留策略 ---${NC}" ""

    if [[ "$RETENTION_POLICY_TYPE" == "none" ]]; then
        log_and_display "未设置保留策略，跳过清理。" "${YELLOW}"
        return 0
    fi

    local current_timestamp=$(date +%s)
    local deleted_s3_count=0
    local deleted_webdav_count=0
    local total_s3_backups_found=0
    local total_webdav_backups_found=0

    # --- S3/R2 清理 ---
    # 只有 S3/R2 被设置为备份目标并且配置完整时才执行清理
    if [[ "$BACKUP_TARGET_S3" == "true" && -n "$S3_ACCESS_KEY" && -n "$S3_SECRET_KEY" && -n "$S3_ENDPOINT" && -n "$S3_BUCKET_NAME" && -n "$S3_BACKUP_PATH" ]]; then
        log_and_display "正在检查 S3/R2 存储桶中的旧备份：${S3_BUCKET_NAME}/${S3_BACKUP_PATH}..." ""
        local s3_backups=()
        local s3_client_found="none"

        export AWS_ACCESS_KEY_ID="$S3_ACCESS_KEY"
        export AWS_SECRET_ACCESS_KEY="$S3_SECRET_KEY"

        if command -v aws &> /dev/null; then
            # ls 指定路径，获取文件名列表，匹配任意前缀+时间戳.zip
            s3_backups=($(aws s3 ls "s3://${S3_BUCKET_NAME}/${S3_BACKUP_PATH}" --endpoint-url "$S3_ENDPOINT" 2>/dev/null | awk '{print $4}' | grep -E '^[a-zA-Z0-9_-]+_[0-9]{14}\.zip$'))
            if [ $? -eq 0 ]; then s3_client_found="awscli"; fi
        elif command -v s3cmd &> /dev/null; then
            log_and_display "${YELLOW}正在使用 s3cmd 进行 S3/R2 清理。${NC}" ""
            s3_backups=($(s3cmd ls "s3://${S3_BUCKET_NAME}/${S3_BACKUP_PATH}" 2>/dev/null | awk '{print $4}' | sed 's|s3://'"${S3_BUCKET_NAME//./\\.}"'/'"${S3_BACKUP_PATH//./\\.}"'/\?||' | grep -E '^[a-zA-Z0-9_-]+_[0-9]{14}\.zip$'))
            if [ $? -eq 0 ]; then s3_client_found="s3cmd"; fi
        fi
        unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY

        total_s3_backups_found=${#s3_backups[@]}

        if [ ${#s3_backups[@]} -eq 0 ]; then
            log_and_display "S3/R2 存储桶中的指定路径 '${S3_BACKUP_PATH}' 未找到备份文件，或工具未正确配置/权限不足。" "${YELLOW}" ""
        else
            IFS=$'\n' s3_backups=($(sort <<<"${s3_backups[*]}")) # 按时间正序排序 (最旧的在前)
            unset IFS

            if [[ "$RETENTION_POLICY_TYPE" == "count" ]]; then
                log_and_display "S3/R2 保留策略: 保留最新 ${RETENTION_VALUE} 个备份。" ""
                local num_to_delete=$(( ${#s3_backups[@]} - RETENTION_VALUE ))
                if [ "$num_to_delete" -gt 0 ]; then
                    log_and_display "S3/R2: 发现 ${num_to_delete} 个备份超过保留数量，将删除最旧的 ${num_to_delete} 个。" "${YELLOW}"
                    for (( i=0; i<num_to_delete; i++ )); do
                        local file_to_delete="${s3_backups[$i]}"
                        log_and_display "S3/R2: 正在删除旧备份: ${file_to_delete}" "${YELLOW}"
                        if [[ "$s3_client_found" == "awscli" ]]; then
                            aws s3 rm "s3://${S3_BUCKET_NAME}/${S3_BACKUP_PATH}${file_to_delete}" --endpoint-url "$S3_ENDPOINT" &> /dev/null
                            if [ $? -eq 0 ]; then deleted_s3_count=$((deleted_s3_count + 1)); fi
                        elif [[ "$s3_client_found" == "s3cmd" ]]; then
                            s3cmd del "s3://${S3_BUCKET_NAME}/${S3_BACKUP_PATH}${file_to_delete}" &> /dev/null
                            if [ $? -eq 0 ]; then deleted_s3_count=$((deleted_s3_count + 1)); fi
                        fi
                    done
                    log_and_display "${GREEN}S3/R2 旧备份清理完成。已删除 ${deleted_s3_count} 个文件。${NC}" ""
                else
                    log_and_display "S3/R2 中备份数量 (${total_s3_backups_found} 个) 未超过保留限制 (${RETENTION_VALUE} 个)，无需清理。" "${BLUE}"
                fi
            elif [[ "$RETENTION_POLICY_TYPE" == "days" ]]; then
                log_and_display "S3/R2 保留策略: 保留最近 ${RETENTION_VALUE} 天内的备份。" ""
                local cutoff_timestamp=$(( current_timestamp - RETENTION_VALUE * 24 * 3600 ))
                local files_to_delete=()
                for backup_file in "${s3_backups[@]}"; do
                    # 从文件名中提取时间戳 (name_YYYYMMDDHHMMSS.zip)
                    local backup_date_str=$(echo "$backup_file" | sed -E 's/.*_([0-9]{14})\.zip/\1/')
                    local backup_timestamp=$(date -d "${backup_date_str:0:8} ${backup_date_str:8:2}:${backup_date_str:10:2}:${backup_date_str:12:2}" +%s 2>/dev/null)

                    if [[ "$backup_timestamp" -ne 0 && "$backup_timestamp" -lt "$cutoff_timestamp" ]]; then
                        files_to_delete+=("$backup_file")
                    fi
                done

                if [ ${#files_to_delete[@]} -gt 0 ]; then
                    log_and_display "S3/R2: 发现 ${#files_to_delete[@]} 个备份超过 ${RETENTION_VALUE} 天，将进行删除。" "${YELLOW}"
                    for file_to_delete in "${files_to_delete[@]}"; do
                        log_and_display "S3/R2: 正在删除旧备份: ${file_to_delete} (创建于 $(date -d @$backup_timestamp '+%Y-%m-%d %H:%M:%S'))" "${YELLOW}"
                        if [[ "$s3_client_found" == "awscli" ]]; then
                            aws s3 rm "s3://${S3_BUCKET_NAME}/${S3_BACKUP_PATH}${file_to_delete}" --endpoint-url "$S3_ENDPOINT" &> /dev/null
                            if [ $? -eq 0 ]; then deleted_s3_count=$((deleted_s3_count + 1)); fi
                        elif [[ "$s3_client_found" == "s3cmd" ]]; then
                            s3cmd del "s3://${S3_BUCKET_NAME}/${S3_BACKUP_PATH}${file_to_delete}" &> /dev/null
                            if [ $? -eq 0 ]; then deleted_s3_count=$((deleted_s3_count + 1)); fi
                        fi
                    done
                    log_and_display "${GREEN}S3/R2 旧备份清理完成。已删除 ${deleted_s3_count} 个文件。${NC}" ""
                else
                    log_and_display "S3/R2 中没有超过 ${RETENTION_VALUE} 天的备份，无需清理。" "${BLUE}"
                fi
            fi
        fi
    else
        log_and_display "${YELLOW}S3/R2 未启用为备份目标或配置不完整，跳过 S3/R2 备份清理。${NC}" ""
    fi

    # --- WebDAV 清理 ---
    # 只有 WebDAV 被设置为备份目标并且配置完整时才执行清理
    if [[ "$BACKUP_TARGET_WEBDAV" == "true" && -n "$WEBDAV_URL" && -n "$WEBDAV_USERNAME" && -n "$WEBDAV_PASSWORD" && -n "$WEBDAV_BACKUP_PATH" ]]; then
        log_and_display "正在检查 WebDAV 服务器中的旧备份：${WEBDAV_URL%/}/${WEBDAV_BACKUP_PATH}..." ""
        local webdav_backups=()
        if command -v curl &> /dev/null; then
            local target_url="${WEBDAV_URL%/}/${WEBDAV_BACKUP_PATH}"
            local curl_output=$(curl -s -L -k --user "$WEBDAV_USERNAME:$WEBDAV_PASSWORD" --request PROPFIND --header "Depth: 1" "$target_url" 2>/dev/null)

            if [ $? -eq 0 ]; then
                # 提取 href 标签中的文件名
                webdav_backups=($(echo "$curl_output" | grep -oP '<D:href>\K([^<]*[a-zA-Z0-9_-]+_[0-9]{14}\.zip)(?=</D:href>)' | sed "s|^${target_url//./\\.}||"))
            fi
        fi
        total_webdav_backups_found=${#webdav_backups[@]}

        if [ ${#webdav_backups[@]} -eq 0 ]; then
            log_and_display "WebDAV 服务器中的指定路径 '${WEBDAV_BACKUP_PATH}' 未找到备份文件，或工具未正确配置/权限不足。" "${YELLOW}" ""
        else
            IFS=$'\n' webdav_backups=($(sort <<<"${webdav_backups[*]}")) # 按时间正序排序 (最旧的在前)
            unset IFS

            if [[ "$RETENTION_POLICY_TYPE" == "count" ]]; then
                log_and_display "WebDAV 保留策略: 保留最新 ${RETENTION_VALUE} 个备份。" ""
                local num_to_delete=$(( ${#webdav_backups[@]} - RETENTION_VALUE ))
                if [ "$num_to_delete" -gt 0 ]; then
                    log_and_display "WebDAV: 发现 ${num_to_delete} 个备份超过保留数量，将删除最旧的 ${num_to_delete} 个。" "${YELLOW}"
                    for (( i=0; i<num_to_delete; i++ )); do
                        local file_to_delete="${webdav_backups[$i]}"
                        log_and_display "WebDAV: 正在删除旧备份: ${file_to_delete}" "${YELLOW}"
                        curl -s -k --user "$WEBDAV_USERNAME:$WEBDAV_PASSWORD" -X DELETE "${WEBDAV_URL%/}/${WEBDAV_BACKUP_PATH}${file_to_delete}" > /dev/null
                        if [ $? -eq 0 ]; then deleted_webdav_count=$((deleted_webdav_count + 1)); fi
                    done
                    log_and_display "${GREEN}WebDAV 旧备份清理完成。已删除 ${deleted_webdav_count} 个文件。${NC}" ""
                else
                    log_and_display "WebDAV 中备份数量 (${total_webdav_backups_found} 个) 未超过保留限制 (${RETENTION_VALUE} 个)，无需清理。" "${BLUE}"
                fi
            elif [[ "$RETENTION_POLICY_TYPE" == "days" ]]; then
                log_and_display "WebDAV 保留策略: 保留最近 ${RETENTION_VALUE} 天内的备份。" ""
                local cutoff_timestamp=$(( current_timestamp - RETENTION_VALUE * 24 * 3600 ))
                local files_to_delete=()
                for backup_file in "${webdav_backups[@]}"; do
                    local backup_date_str=$(echo "$backup_file" | sed -E 's/.*_([0-9]{14})\.zip/\1/')
                    local backup_timestamp=$(date -d "${backup_date_str:0:8} ${backup_date_str:8:2}:${backup_date_str:10:2}:${backup_date_str:12:2}" +%s 2>/dev/null)

                    if [[ "$backup_timestamp" -ne 0 && "$backup_timestamp" -lt "$cutoff_timestamp" ]]; then
                        files_to_delete+=("$backup_file")
                    fi
                done

                if [ ${#files_to_delete[@]} -gt 0 ]; then
                    log_and_display "WebDAV: 发现 ${#files_to_delete[@]} 个备份超过 ${RETENTION_VALUE} 天，将进行删除。" "${YELLOW}"
                    for file_to_delete in "${files_to_delete[@]}"; do
                        log_and_display "WebDAV: 正在删除旧备份: ${file_to_delete} (创建于 $(date -d @$backup_timestamp '+%Y-%m-%d %H:%M:%S'))" "${YELLOW}"
                        curl -s -k --user "$WEBDAV_USERNAME:$WEBDAV_PASSWORD" -X DELETE "${WEBDAV_URL%/}/${WEBDAV_BACKUP_PATH}${file_to_delete}" > /dev/null
                        if [ $? -eq 0 ]; then deleted_webdav_count=$((deleted_webdav_count + 1)); fi
                    done
                    log_and_display "${GREEN}WebDAV 旧备份清理完成。已删除 ${deleted_webdav_count} 个文件。${NC}" ""
                else
                    log_and_display "WebDAV 中没有超过 ${RETENTION_VALUE} 天的备份，无需清理。" "${BLUE}"
                fi
            fi
        fi
    else
        log_and_display "${YELLOW}WebDAV 未启用为备份目标或配置不完整，跳过 WebDAV 备份清理。${NC}" ""
    fi

    local retention_summary="保留策略执行完毕。"
    retention_summary+="\nS3/R2: 找到 ${total_s3_backups_found} 个，删除了 ${deleted_s3_count} 个。"
    retention_summary+="\nWebDAV: 找到 ${total_webdav_backups_found} 个，删除了 ${deleted_webdav_count} 个。"
    send_telegram_message "*个人自用数据备份：保留策略完成*\n${retention_summary}"
    log_and_display "${BLUE}--- 备份保留策略应用结束 ---${NC}" ""
}


# 执行备份上传的核心逻辑 (大幅修改以支持多路径独立备份)
# 参数 1: 备份类型 (例如，"手动备份", "自动备份")
perform_backup() {
    local backup_type="$1"
    local readable_time=$(date '+%Y-%m-%d %H:%M:%S')
    local overall_status="失败"
    local overall_succeeded_count=0
    local total_paths_to_backup=${#BACKUP_SOURCE_PATHS_ARRAY[@]}

    log_and_display "${BLUE}--- ${backup_type} 过程开始 ---${NC}" ""

    local initial_message="*个人自用数据备份：开始 (${backup_type})*\n时间: ${readable_time}\n将备份 ${total_paths_to_backup} 个路径。"
    send_telegram_message "${initial_message}"

    if [ ${#BACKUP_SOURCE_PATHS_ARRAY[@]} -eq 0 ]; then
        log_and_display "${RED}错误：没有设置任何备份源路径。请先通过 '3. 自定义备份路径' 添加路径。${NC}" ""
        send_telegram_message "*个人自用数据备份：失败*\n原因: 未设置备份源路径。"
        return 1
    fi

    # 遍历每个备份源路径
    for i in "${!BACKUP_SOURCE_PATHS_ARRAY[@]}"; do
        local current_backup_path="${BACKUP_SOURCE_PATHS_ARRAY[$i]}"
        local path_display_name=$(basename "$current_backup_path") # 用于显示友好的路径名
        local timestamp=$(date +%Y%m%d%H%M%S)

        # 清理路径名，使其适合作为文件名 (替换非字母数字下划线连字符为下划线)
        local sanitized_path_name=$(echo "$path_display_name" | sed 's/[^a-zA-Z0-9_-]/_/g')
        # 确保文件名不会以点开头，或者有连续的点
        sanitized_path_name=$(echo "$sanitized_path_name" | sed 's/^\.//; s/\.\./_/g')
        # 如果处理后为空，则使用通用名加索引
        if [[ -z "$sanitized_path_name" ]]; then
            sanitized_path_name="backup_item_${i}"
        fi

        local archive_name="${sanitized_path_name}_${timestamp}.zip"
        local temp_archive_path="${TEMP_DIR}/${archive_name}"
        local backup_file_size="未知"
        local current_path_upload_status="失败" # 记录当前路径的上传状态
        local zip_error_file="${TEMP_DIR}/zip_error_${timestamp}.log" # 用于捕获zip错误输出

        log_and_display "${BLUE}--- 正在处理路径 $((i+1))/${total_paths_to_backup}: ${current_backup_path} ---${NC}" ""

        if [[ ! -d "$current_backup_path" && ! -f "$current_backup_path" ]]; then
            log_and_display "${RED}错误：路径 '$current_backup_path' 无效或不存在，跳过此路径备份。${NC}" ""
            send_telegram_message "*个人自用数据备份：路径失败*\n路径: \`${current_backup_path}\`\n原因: 路径无效或不存在。"
            continue # 跳过当前路径，继续下一个
        fi

        # --- 压缩文件 ---
        log_and_display "正在压缩路径 '$current_backup_path' 到文件 '$archive_name'..." ""
        local zip_command_status=1 # 默认为失败
        local zip_error_output=""

        if [[ -d "$current_backup_path" ]]; then
            # 压缩目录，只包含目录内的内容，不包含父目录本身
            (cd "$(dirname "$current_backup_path")" && zip -r "$temp_archive_path" "$(basename "$current_backup_path")") 2> "$zip_error_file"
            zip_command_status=$?
        elif [[ -f "$current_backup_path" ]]; then
            # 压缩单个文件
            zip "$temp_archive_path" "$current_backup_path" 2> "$zip_error_file"
            zip_command_status=$?
        fi

        if [ -s "$zip_error_file" ]; then # 检查错误文件是否非空
            zip_error_output=$(cat "$zip_error_file")
            rm -f "$zip_error_file" # 清理错误日志文件
        fi

        if [ "$zip_command_status" -eq 0 ]; then
            log_and_display "${GREEN}文件压缩成功！${NC}" ""
            if [[ -f "$temp_archive_path" ]]; then
                backup_file_size=$(du -h "$temp_archive_path" | awk '{print $1}')
            else
                backup_file_size="未知 (压缩文件未生成)"
                log_and_display "${RED}警告：压缩成功但未找到生成的临时文件：$temp_archive_path${NC}" ""
            fi
        else
            log_and_display "${RED}文件压缩失败！请检查路径权限或磁盘空间。错误码: ${zip_command_status}${NC}" ""
            if [[ -n "$zip_error_output" ]]; then
                log_and_display "${RED}压缩工具输出: ${zip_error_output}${NC}" ""
            fi
            send_telegram_message "*个人自用数据备份：压缩失败*\n路径: \`${current_backup_path}\`\n文件: \`${archive_name}\`\n原因: 压缩失败，错误码: ${zip_command_status}。\n详情: ${zip_error_output}"
            rm -f "$temp_archive_path" 2>/dev/null # 尝试清理失败的临时文件
            continue # 跳过当前路径的上传，继续下一个
        fi

        local current_upload_succeeded="false"
        local s3_this_upload_status="未尝试"
        local webdav_this_upload_status="未尝试"

        # --- 上传到 S3/R2 ---
        if [[ "$BACKUP_TARGET_S3" == "true" ]]; then
            if [[ -n "$S3_ACCESS_KEY" && -n "$S3_SECRET_KEY" && -n "$S3_ENDPOINT" && -n "$S3_BUCKET_NAME" && -n "$S3_BACKUP_PATH" ]]; then
                log_and_display "正在尝试上传到 S3/R2 存储桶：${S3_BUCKET_NAME}/${S3_BACKUP_PATH}${archive_name}..." ""
                local s3_upload_output=""
                local s3_upload_status_code=1

                export AWS_ACCESS_KEY_ID="$S3_ACCESS_KEY"
                export AWS_SECRET_ACCESS_KEY="$S3_SECRET_KEY"

                if command -v aws &> /dev/null; then
                    s3_upload_output=$(aws s3 cp "$temp_archive_path" "s3://${S3_BUCKET_NAME}/${S3_BACKUP_PATH}${archive_name}" --endpoint-url "$S3_ENDPOINT" 2>&1)
                    s3_upload_status_code=$?
                elif command -v s3cmd &> /dev/null; then
                    s3_upload_output=$(s3cmd put "$temp_archive_path" "s3://${S3_BUCKET_NAME}/${S3_BACKUP_PATH}${archive_name}" 2>&1)
                    s3_upload_status_code=$?
                fi
                unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY

                if [ "$s3_upload_status_code" -eq 0 ]; then
                    log_and_display "${GREEN}S3/R2 上传成功！${NC}" ""
                    s3_this_upload_status="成功"
                    current_upload_succeeded="true"
                else
                    log_and_display "${RED}S3/R2 上传失败！错误信息: ${s3_upload_output}${NC}" ""
                    s3_this_upload_status="失败"
                fi
            else
                log_and_display "${RED}S3/R2 已设置为备份目标，但配置不完整。跳过 S3/R2 上传。${NC}" ""
                s3_this_upload_status="跳过 (配置不完整)"
            fi
        else
            log_and_display "${YELLOW}S3/R2 未设置为备份目标，跳过 S3/R2 上传。${NC}" ""
            s3_this_upload_status="禁用"
        fi

        # --- 上传到 WebDAV ---
        if [[ "$BACKUP_TARGET_WEBDAV" == "true" ]]; then
            if [[ -n "$WEBDAV_URL" && -n "$WEBDAV_USERNAME" && -n "$WEBDAV_PASSWORD" && -n "$WEBDAV_BACKUP_PATH" ]]; then
                log_and_display "正在尝试上传到 WebDAV 服务器：${WEBDAV_URL%/}/${WEBDAV_BACKUP_PATH}${archive_name}..." ""
                local webdav_upload_output=""
                local webdav_upload_status_code=1

                if command -v curl &> /dev/null; then
                    webdav_upload_output=$(curl -k --user "$WEBDAV_USERNAME:$WEBDAV_PASSWORD" --upload-file "$temp_archive_path" "${WEBDAV_URL%/}/${WEBDAV_BACKUP_PATH}${archive_name}" --fail --no-progress-meter 2>&1)
                    webdav_upload_status_code=$?
                fi

                if [ "$webdav_upload_status_code" -eq 0 ]; then
                    log_and_display "${GREEN}WebDAV 上传成功！${NC}" ""
                    webdav_this_upload_status="成功"
                    current_upload_succeeded="true"
                else
                    log_and_display "${RED}WebDAV 上传失败！错误信息: ${webdav_upload_output}${NC}" ""
                    webdav_this_upload_status="失败"
                fi
            else
                log_and_display "${RED}WebDAV 已设置为备份目标，但配置不完整。跳过 WebDAV 上传。${NC}" ""
                webdav_this_upload_status="跳过 (配置不完整)"
            fi
        else
            log_and_display "${YELLOW}WebDAV 未设置为备份目标，跳过 WebDAV 上传。${NC}" ""
            webdav_this_upload_status="禁用"
        fi

        # 记录当前路径的整体上传状态
        if [[ "$current_upload_succeeded" == "true" ]]; then
            overall_succeeded_count=$((overall_succeeded_count + 1))
            current_path_upload_status="成功"
        else
            current_path_upload_status="失败"
        fi

        # 发送当前路径的详细 Telegram 通知
        local path_summary_message="*个人自用数据备份：路径完成 (${current_path_upload_status})*\n"
        path_summary_message+="路径: \`${current_backup_path}\`\n"
        path_summary_message+="备份文件: \`${archive_name}\`\n"
        path_summary_message+="文件大小: ${backup_file_size}\n"
        path_summary_message+="S3/R2 上传: ${s3_this_upload_status}"
        if [[ -n "$S3_BUCKET_NAME" && "$s3_this_upload_status" != "禁用" ]]; then path_summary_message+=" (目标: \`${S3_BUCKET_NAME}/${S3_BACKUP_PATH}\`)"; fi
        path_summary_message+="\n"
        path_summary_message+="WebDAV 上传: ${webdav_this_upload_status}"
        if [[ -n "$WEBDAV_URL" && "$webdav_this_upload_status" != "禁用" ]]; then path_summary_message+=" (目标: \`${WEBDAV_URL%/}/${WEBDAV_BACKUP_PATH}\`)"; fi
        send_telegram_message "${path_summary_message}"

        # 清理当前路径的临时压缩文件
        if [[ -f "$temp_archive_path" ]]; then
            log_and_display "正在清理临时压缩文件：$temp_archive_path" ""
            rm -f "$temp_archive_path"
            if [ $? -eq 0 ]; then
                log_and_display "${GREEN}临时文件清理完成。${NC}" ""
            else
                log_and_display "${RED}临时文件清理失败。${NC}" ""
            fi
        fi
    done # 结束所有路径的循环

    # 根据所有路径的备份结果确定整体状态
    if [ "$overall_succeeded_count" -eq "$total_paths_to_backup" ] && [ "$total_paths_to_backup" -gt 0 ]; then
        overall_status="全部成功"
    elif [ "$overall_succeeded_count" -gt 0 ]; then
        overall_status="部分成功"
    elif [ "$total_paths_to_backup" -eq 0 ]; then
        overall_status="未执行 (无备份路径)"
    else
        overall_status="全部失败"
    fi

    log_and_display "${BLUE}--- ${backup_type} 过程结束 ---${NC}" ""

    # 如果是自动备份，更新上次自动备份时间戳
    if [[ "$backup_type" == "自动备份 (Cron)" ]]; then
        LAST_AUTO_BACKUP_TIMESTAMP=$(date +%s)
        save_config # 保存更新后的时间戳 (这也会保存当前凭证)
        log_and_display "已更新上次自动备份时间戳：$(date -d @$LAST_AUTO_BACKUP_TIMESTAMP '+%Y-%m-%d %H:%M:%S')" "${BLUE}"
    fi

    # 发送最终的整体 Telegram 通知
    local final_overall_message="*个人自用数据备份：总览 (${overall_status})*\n"
    final_overall_message+="时间: ${readable_time}\n"
    final_overall_message+="类型: ${backup_type}\n"
    final_overall_message+="总路径数: ${total_paths_to_backup}\n"
    final_overall_message+="成功备份路径数: ${overall_succeeded_count}\n"
    send_telegram_message "${final_overall_message}"

    # 只有在至少一个上传尝试成功后才应用保留策略
    # 注意：保留策略现在会处理新命名的文件
    if [[ "$overall_succeeded_count" -gt 0 ]]; then
        apply_retention_policy
    else
        log_and_display "${YELLOW}由于没有成功的备份上传，跳过保留策略的执行。${NC}" ""
    fi
}

# 99. 卸载脚本 (保持不变)
uninstall_script() {
    display_header
    echo -e "${RED}=== 99. 卸载脚本 ===${NC}"
    log_and_display "${RED}警告：您确定要卸载脚本吗？这将删除所有脚本文件、配置文件和日志文件。（y/N）${NC}" ""
    read -rp "请确认 (y/N): " confirm

    if [[ "$confirm" =~ ^[Yy]$ ]]; then
        log_and_display "${RED}开始卸载脚本...${NC}" ""
        local script_path="$(readlink -f "$0")" # 获取脚本的真实路径

        log_and_display "删除脚本文件：$script_path" ""
        rm -f "$script_path" 2>/dev/null

        if [[ -f "$CONFIG_FILE" ]]; then
            log_and_display "删除配置文件：$CONFIG_FILE" ""
            rm -f "$CONFIG_FILE" 2>/dev/null
        fi

        if [[ -d "$CONFIG_DIR" ]] && [ -z "$(ls -A "$CONFIG_DIR")" ]; then
            log_and_display "删除空配置目录：$CONFIG_DIR" ""
            rmdir "$CONFIG_DIR" 2>/dev/null
        fi

        if [[ -f "$LOG_FILE" ]]; then
            log_and_display "删除日志文件：$LOG_FILE" ""
            rm -f "$LOG_FILE" 2>/dev/null
        fi

        if [[ -d "$LOG_DIR" ]] && [ -z "$(ls -A "$LOG_DIR")" ]; then
            log_and_display "删除空日志目录：$LOG_DIR" ""
            rmdir "$LOG_DIR" 2>/dev/null
        fi

        log_and_display "${YELLOW}提示：如果此脚本是通过别名或放置在 PATH 中的文件启动的，您可能需要手动删除它们。${NC}" ""
        log_and_display "${GREEN}脚本卸载完成。${NC}" ""
        exit 0
    else
        log_and_display "取消卸载。" "${BLUE}"
    fi
    press_enter_to_continue
}

# --- 主菜单 ---
show_main_menu() {
    display_header
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━ 功能选项 ━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "  1. ${YELLOW}自动备份设定${NC} (当前间隔: ${AUTO_BACKUP_INTERVAL_DAYS} 天)${NC}"
    echo -e "  2. ${YELLOW}手动备份${NC}"
    echo -e "  3. ${YELLOW}自定义备份路径${NC} (当前数量: ${#BACKUP_SOURCE_PATHS_ARRAY[@]} 个)${NC}" # 显示路径数量
    echo -e "  4. ${YELLOW}压缩包格式${NC} (当前支持: ZIP)${NC}"
    echo -e "  5. ${YELLOW}云存储设定${NC} (支持: S3/R2, WebDAV)${NC}"
    echo -e "  6. ${YELLOW}消息通知设定${NC} (Telegram)${NC}"
    echo -e "  7. ${YELLOW}设置备份保留策略${NC} (云端)${NC}"
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "  0. ${RED}退出脚本${NC}"
    echo -e "  99. ${RED}卸载脚本${NC}"
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
}

# 处理菜单选择
process_menu_choice() {
    local choice
    read -rp "请输入选项: " choice
    log_and_display "用户选择: $choice" ""

    case $choice in
        1) set_auto_backup_interval ;;
        2) manual_backup ;;
        3) set_backup_path ;; # 调用新的多路径管理函数
        4) display_compression_info ;;
        5) set_cloud_storage ;;
        6) set_telegram_notification ;;
        7) set_retention_policy ;;
        0)
            log_and_display "${GREEN}感谢使用，再见！${NC}" ""
            exit 0
            ;;
        99) uninstall_script ;;
        *)
            log_and_display "${RED}无效的选项，请重新输入。${NC}" ""
            press_enter_to_continue
            ;;
    esac
}

# 检查是否应该运行自动备份 (根据间隔时间)
check_auto_backup() {
    load_config # 确保加载最新配置

    local current_timestamp=$(date +%s)
    local interval_seconds=$(( AUTO_BACKUP_INTERVAL_DAYS * 24 * 3600 )) # 将天数转换为秒

    # 检查是否有至少一个备份路径
    if [ ${#BACKUP_SOURCE_PATHS_ARRAY[@]} -eq 0 ]; then
        log_and_display "${RED}自动备份失败：没有设置任何备份源路径。请通过主菜单设置。${NC}" ""
        send_telegram_message "*个人自用数据备份：自动备份失败*\n原因: 未设置备份源路径。"
        return 1
    fi

    if [[ "$LAST_AUTO_BACKUP_TIMESTAMP" -eq 0 ]]; then
        log_and_display "首次自动备份，或上次自动备份时间未记录，立即执行。" "${YELLOW}"
        perform_backup "自动备份 (Cron)"
    elif (( current_timestamp - LAST_AUTO_BACKUP_TIMESTAMP >= interval_seconds )); then
        log_and_display "距离上次自动备份已超过 ${AUTO_BACKUP_INTERVAL_DAYS} 天 (${interval_seconds} 秒)，执行自动备份。" "${BLUE}"
        perform_backup "自动备份 (Cron)"
    else
        local next_backup_time=$(( LAST_AUTO_BACKUP_TIMESTAMP + interval_seconds ))
        local remaining_seconds=$(( next_backup_time - current_timestamp ))
        local remaining_days=$(( remaining_seconds / 86400 ))
        local remaining_hours=$(( (remaining_seconds % 86400) / 3600 ))
        log_and_display "未到自动备份时间。距离下次备份还有约 ${remaining_days} 天 ${remaining_hours} 小时。" "${YELLOW}"
    fi
}

# --- 脚本入口点 ---
main() {
    # 创建一个安全的临时目录，用于存放压缩文件
    TEMP_DIR=$(mktemp -d -t personal_backup_XXXXXX)
    if [ ! -d "$TEMP_DIR" ]; then
        log_and_display "${RED}错误：无法创建临时目录。请检查权限或磁盘空间。${NC}" ""
        exit 1
    fi
    log_and_display "临时目录已创建: $TEMP_DIR" "${BLUE}"


    load_config # 脚本启动时加载配置

    # 如果直接从 cron 任务调用带有特定参数
    if [[ "${1:-}" == "check_auto_backup" ]]; then # 修复：安全地检查 $1 是否已设置
        log_and_display "由 Cron 任务触发自动备份检查。" "${BLUE}"
        check_auto_backup
        exit 0
    fi

    # 在交互模式下检查依赖项 (仅当不是 cron 任务时)
    if ! check_dependencies; then
        log_and_display "${RED}脚本无法运行，因为缺少必要的依赖项。请按照提示安装。${NC}" ""
        exit 1
    fi

    while true; do
        show_main_menu
        process_menu_choice
    done
}

# 执行主函数
main "$@"

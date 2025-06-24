#!/bin/bash
set -e # Exit immediately if a command exits with a non-zero status.

# 脚本全局配置
SCRIPT_NAME="个人自用数据备份 (Rclone 最终版)"
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
RETENTION_VALUE=0           # 要保留的备份数量或天数

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
    echo -e "${GREEN}      $SCRIPT_NAME       ${NC}"
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

# 1. 设置自动备份间隔
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

# 2. 手动备份
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

# 3. 自定义备份路径
add_backup_path() {
    display_header
    echo -e "${BLUE}=== 添加备份路径 ===${NC}"
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
        echo "0. 返回"
        echo -e "${BLUE}------------------------------------------------${NC}"
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
            0) break ;;
            *) log_and_display "${RED}无效选项。${NC}"; press_enter_to_continue ;;
        esac
    done
}


# 4. 压缩格式信息
display_compression_info() {
    display_header
    echo -e "${BLUE}=== 4. 压缩包格式 ===${NC}"
    log_and_display "本脚本当前支持的压缩格式为：${GREEN}ZIP${NC}。"
    press_enter_to_continue
}

# ================================================================
# ===         在脚本内创建 Rclone 远程端 (增强版)              ===
# ================================================================

# 通用函数: 获取远程端名称
get_remote_name() {
    local prompt_message="$1"
    read -rp "为这个新的远程端起一个名字 (例如: ${prompt_message}): " remote_name
    if [[ -z "$remote_name" || "$remote_name" =~ [[:space:]] ]]; then
        log_and_display "${RED}错误: 远程端名称不能为空或包含空格。${NC}"
        return 1
    fi
    # 将结果存储在全局变量中以便调用者使用
    REPLY="$remote_name"
    return 0
}

# 创建 S3 兼容远程端的函数
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
        *) log_and_display "${RED}无效选项。${NC}"; press_enter_to_continue; return 1;
    esac

    read -rp "请输入 Access Key ID: " access_key_id
    read -s -rp "请输入 Secret Access Key: " secret_access_key
    echo ""

    log_and_display "正在创建 Rclone 远程端: ${remote_name}..." "${BLUE}"
    
    local rclone_create_cmd
    rclone_create_cmd=(rclone config create "$remote_name" s3 provider "$provider" access_key_id "$access_key_id" secret_access_key "$secret_access_key")
    if [[ -n "$endpoint" ]]; then
        rclone_create_cmd+=(endpoint "$endpoint")
    fi

    if "${rclone_create_cmd[@]}"; then
        log_and_display "${GREEN}远程端 '${remote_name}' 创建成功！${NC}"
        log_and_display "${YELLOW}Rclone 会自动将凭证存储在 $HOME/.config/rclone/rclone.conf 中。${NC}"
    else
        log_and_display "${RED}远程端创建失败！请检查您的输入或 Rclone 的错误提示。${NC}"
    fi
    press_enter_to_continue
}

# 创建 Backblaze B2 远程端的函数
create_rclone_b2_remote() {
    display_header
    echo -e "${BLUE}--- 创建 Backblaze B2 远程端 ---${NC}"
    get_remote_name "b2_backup" || { press_enter_to_continue; return 1; }
    local remote_name=$REPLY

    read -rp "请输入 B2 Account ID 或 Application Key ID: " account_id
    read -s -rp "请输入 B2 Application Key: " app_key
    echo ""

    log_and_display "正在创建 Rclone 远程端: ${remote_name}..." "${BLUE}"
    if rclone config create "$remote_name" b2 account "$account_id" key "$app_key"; then
        log_and_display "${GREEN}远程端 '${remote_name}' 创建成功！${NC}"
    else
        log_and_display "${RED}远程端创建失败！${NC}"
    fi
    press_enter_to_continue
}

# 创建 Azure Blob 远程端的函数
create_rclone_azureblob_remote() {
    display_header
    echo -e "${BLUE}--- 创建 Microsoft Azure Blob Storage 远程端 ---${NC}"
    get_remote_name "myazure" || { press_enter_to_continue; return 1; }
    local remote_name=$REPLY

    read -rp "请输入 Azure Storage Account Name: " account_name
    read -s -rp "请输入 Azure Storage Account Key: " account_key
    echo ""

    log_and_display "正在创建 Rclone 远程端: ${remote_name}..." "${BLUE}"
    if rclone config create "$remote_name" azureblob account "$account_name" key "$account_key"; then
        log_and_display "${GREEN}远程端 '${remote_name}' 创建成功！${NC}"
    else
        log_and_display "${RED}远程端创建失败！${NC}"
    fi
    press_enter_to_continue
}

# 创建 Mega 远程端的函数
create_rclone_mega_remote() {
    display_header
    echo -e "${BLUE}--- 创建 Mega.nz 远程端 ---${NC}"
    get_remote_name "mymega" || { press_enter_to_continue; return 1; }
    local remote_name=$REPLY

    read -rp "请输入 Mega 用户名 (邮箱): " user
    read -s -rp "请输入 Mega 密码: " password
    echo ""
    local obscured_pass=$(rclone obscure "$password")

    log_and_display "正在创建 Rclone 远程端: ${remote_name}..." "${BLUE}"
    if rclone config create "$remote_name" mega user "$user" pass "$obscured_pass"; then
        log_and_display "${GREEN}远程端 '${remote_name}' 创建成功！${NC}"
    else
        log_and_display "${RED}远程端创建失败！${NC}"
    fi
    press_enter_to_continue
}

# 创建 pCloud 远程端的函数
create_rclone_pcloud_remote() {
    display_header
    echo -e "${BLUE}--- 创建 pCloud 远程端 ---${NC}"
    get_remote_name "mypcloud" || { press_enter_to_continue; return 1; }
    local remote_name=$REPLY

    read -rp "请输入 pCloud 用户名 (邮箱): " user
    read -s -rp "请输入 pCloud 密码: " password
    echo ""
    local obscured_pass=$(rclone obscure "$password")

    log_and_display "正在创建 Rclone 远程端: ${remote_name}..." "${BLUE}"
    log_and_display "${YELLOW}Rclone 将尝试使用您的用户名和密码获取授权令牌...${NC}"

    if rclone config create "$remote_name" pcloud username "$user" password "$obscured_pass"; then
        log_and_display "${GREEN}远程端 '${remote_name}' 创建成功！${NC}"
    else
        log_and_display "${RED}远程端创建失败！可能是密码错误或需要双因素认证。${NC}"
    fi
    press_enter_to_continue
}

# 创建 WebDAV 远程端的函数
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

    log_and_display "正在创建 Rclone 远程端: ${remote_name}..." "${BLUE}"
    if rclone config create "$remote_name" webdav url "$url" user "$user" pass "$obscured_pass"; then
        log_and_display "${GREEN}远程端 '${remote_name}' 创建成功！${NC}"
    else
        log_and_display "${RED}远程端创建失败！${NC}"
    fi
    press_enter_to_continue
}

# 创建 SFTP 远程端的函数
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
            log_and_display "${RED}错误: 密钥文件不存在。${NC}"; press_enter_to_continue; return 1;
        fi
    else
        log_and_display "${RED}无效选项。${NC}"; press_enter_to_continue; return 1;
    fi
    
    log_and_display "正在创建 Rclone 远程端: ${remote_name}..." "${BLUE}"
    
    local rclone_create_cmd
    rclone_create_cmd=(rclone config create "$remote_name" sftp host "$host" user "$user" port "$port")
    if [[ -n "$pass_obscured" ]]; then
        rclone_create_cmd+=(pass "$pass_obscured")
    elif [[ -n "$key_file" ]]; then
        rclone_create_cmd+=(key_file "$key_file")
    fi
    
    if "${rclone_create_cmd[@]}"; then
        log_and_display "${GREEN}远程端 '${remote_name}' 创建成功！${NC}"
        log_and_display "${YELLOW}提示: 首次连接 SFTP 服务器时，Rclone 可能需要您确认主机的密钥指纹。${NC}"
    else
        log_and_display "${RED}远程端创建失败！${NC}"
    fi
    press_enter_to_continue
}

# 创建 FTP 远程端的函数
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

    log_and_display "正在创建 Rclone 远程端: ${remote_name}..." "${BLUE}"
    if rclone config create "$remote_name" ftp host "$host" user "$user" pass "$obscured_pass" port "$port"; then
        log_and_display "${GREEN}远程端 '${remote_name}' 创建成功！${NC}"
    else
        log_and_display "${RED}远程端创建失败！${NC}"
    fi
    press_enter_to_continue
}

# 创建 Crypt 远程端的函数
create_rclone_crypt_remote() {
    display_header
    echo -e "${BLUE}--- 创建 Crypt 加密远程端 ---${NC}"
    echo -e "${YELLOW}Crypt 会加密您上传到另一个远程端的文件名和内容。${NC}"
    get_remote_name "my_encrypted_remote" || { press_enter_to_continue; return 1; }
    local remote_name=$REPLY

    echo ""
    log_and_display "可用的远程端列表："
    rclone listremotes
    echo ""
    read -rp "请输入您要加密的目标远程端路径 (例如: myr2:my_encrypted_bucket): " target_remote

    echo -e "${YELLOW}您需要设置两个密码，第二个是盐值，用于进一步增强安全性。请务必牢记！${NC}"
    read -s -rp "请输入密码 (password): " pass1
    echo ""
    read -s -rp "请再次输入密码进行确认: " pass1_confirm
    echo ""
    if [[ "$pass1" != "$pass1_confirm" ]]; then
        log_and_display "${RED}两次输入的密码不匹配！${NC}"; press_enter_to_continue; return 1;
    fi

    read -s -rp "请输入盐值密码 (salt/password2)，可以与上一个不同: " pass2
    echo ""
    read -s -rp "请再次输入盐值密码进行确认: " pass2_confirm
    echo ""
    if [[ "$pass2" != "$pass2_confirm" ]]; then
        log_and_display "${RED}两次输入的盐值密码不匹配！${NC}"; press_enter_to_continue; return 1;
    fi

    local obscured_pass1=$(rclone obscure "$pass1")
    local obscured_pass2=$(rclone obscure "$pass2")

    log_and_display "正在创建 Rclone 远程端: ${remote_name}..." "${BLUE}"
    if rclone config create "$remote_name" crypt remote "$target_remote" password "$obscured_pass1" password2 "$obscured_pass2"; then
        log_and_display "${GREEN}加密远程端 '${remote_name}' 创建成功！${NC}"
        log_and_display "现在您可以像使用普通远程端一样使用 '${remote_name}:'，所有数据都会在后台自动加解密。"
    else
        log_and_display "${RED}远程端创建失败！${NC}"
    fi
    press_enter_to_continue
}

# 创建 Alias 远程端的函数
create_rclone_alias_remote() {
    display_header
    echo -e "${BLUE}--- 创建 Alias 别名远程端 ---${NC}"
    echo -e "${YELLOW}Alias 可以为另一个远程端的深层路径创建一个简短的别名。${NC}"
    get_remote_name "my_shortcut" || { press_enter_to_continue; return 1; }
    local remote_name=$REPLY

    echo ""
    log_and_display "可用的远程端列表："
    rclone listremotes
    echo ""
    read -rp "请输入您要为其创建别名的目标远程端路径 (例如: myr2:path/to/my/files): " target_remote

    log_and_display "正在创建 Rclone 远程端: ${remote_name}..." "${BLUE}"
    if rclone config create "$remote_name" alias remote "$target_remote"; then
        log_and_display "${GREEN}别名远程端 '${remote_name}' 创建成功！${NC}"
        log_and_display "现在 '${remote_name}:' 就等同于 '${target_remote}'。"
    else
        log_and_display "${RED}远程端创建失败！${NC}"
    fi
    press_enter_to_continue
}

# 创建远程端的总向导
create_rclone_remote_wizard() {
    while true; do
        display_header
        echo -e "${BLUE}=== [助手] 在脚本内创建新的 Rclone 远程端 ===${NC}"
        echo "请选择您要创建的云存储类型："
        echo ""
        echo -e "${GREEN}--- 对象存储/云盘 ---${NC}"
        echo " 1. S3 兼容存储 (如 Cloudflare R2, AWS S3, MinIO 等)"
        echo " 2. Backblaze B2"
        echo " 3. Microsoft Azure Blob Storage"
        echo " 4. Mega.nz"
        echo " 5. pCloud"
        echo ""
        echo -e "${GREEN}--- 传统协议 ---${NC}"
        echo " 6. WebDAV"
        echo " 7. SFTP"
        echo " 8. FTP"
        echo ""
        echo -e "${GREEN}--- 功能性远程端 (包装器) ---${NC}"
        echo " 9. Crypt (加密一个现有远程端)"
        echo " 10. Alias (为一个远程路径创建别名)"
        echo ""
        echo "对于 Google Drive, Dropbox 等需要浏览器授权的类型,"
        echo "请在终端中运行 'rclone config' 命令进行配置。"
        echo ""
        echo " 0. 返回上一级菜单"
        echo -e "${BLUE}---------------------------------------------------${NC}"
        read -rp "请输入选项: " choice

        case "$choice" in
            1) create_rclone_s3_remote ;;
            2) create_rclone_b2_remote ;;
            3) create_rclone_azureblob_remote ;;
            4) create_rclone_mega_remote ;;
            5) create_rclone_pcloud_remote ;;
            6) create_rclone_webdav_remote ;;
            7) create_rclone_sftp_remote ;;
            8) create_rclone_ftp_remote ;;
            9) create_rclone_crypt_remote ;;
            10) create_rclone_alias_remote ;;
            0) break ;;
            *) log_and_display "${RED}无效选项。${NC}"; press_enter_to_continue ;;
        esac
    done
}


# ================================================================
# ===         RCLONE 云存储管理函数 (优化版)                 ===
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

    # 使用一个已知不会冲突的变量名来返回路径
    CHOSEN_RCLONE_PATH="$final_selected_path"
    return 0
}

# [新] 查看、管理和启用备份目标
view_and_manage_rclone_targets() {
    local needs_saving="false"
    while true; do
        display_header
        echo -e "${BLUE}=== 查看、管理和启用备份目标 ===${NC}"
        
        if [ ${#RCLONE_TARGETS_ARRAY[@]} -eq 0 ]; then
            log_and_display "${YELLOW}当前没有配置任何 Rclone 目标。${NC}"
        else
            echo "已配置的 Rclone 目标列表:"
            for i in "${!RCLONE_TARGETS_ARRAY[@]}"; do
                local is_enabled="false"
                for enabled_idx in "${ENABLED_RCLONE_TARGET_INDICES_ARRAY[@]}"; do
                    if [[ "$i" -eq "$enabled_idx" ]]; then
                        is_enabled="true"; break;
                    fi
                done
                
                echo -n "$((i+1)). ${RCLONE_TARGETS_ARRAY[$i]} "
                if [[ "$is_enabled" == "true" ]]; then
                    echo -e "[${GREEN}已启用${NC}]"
                else
                    echo -e "[${YELLOW}已禁用${NC}]"
                fi
            done
        fi
        
        echo -e "${BLUE}------------------------------------------------${NC}"
        echo " a - 添加新目标      d - 删除目标      m - 修改目标路径"
        echo " t - 切换启用/禁用状态"
        echo " 0 - 保存并返回"
        echo -e "${BLUE}------------------------------------------------${NC}"
        read -rp "请输入选项: " choice

        case "$choice" in
            a|A) # 添加
                read -rp "请输入您已通过 'rclone config' 或助手配置好的远程端名称: " remote_name
                if ! check_rclone_remote_exists "$remote_name"; then
                    log_and_display "${RED}错误: Rclone 远程端 '${remote_name}' 不存在！${NC}"
                elif choose_rclone_path "$remote_name"; then
                    local remote_path="$CHOSEN_RCLONE_PATH"
                    RCLONE_TARGETS_ARRAY+=("${remote_name}:${remote_path}")
                    needs_saving="true"
                    log_and_display "${GREEN}已成功添加目标: ${remote_name}:${remote_path}${NC}"
                else
                    log_and_display "${YELLOW}已取消添加目标。${NC}"
                fi
                press_enter_to_continue
                ;;

            d|D) # 删除
                if [ ${#RCLONE_TARGETS_ARRAY[@]} -eq 0 ]; then log_and_display "${YELLOW}没有可删除的目标。${NC}"; press_enter_to_continue; continue; fi
                read -rp "请输入要删除的目标序号: " index
                if [[ "$index" =~ ^[0-9]+$ ]] && [ "$index" -ge 1 ] && [ "$index" -le ${#RCLONE_TARGETS_ARRAY[@]} ]; then
                    local deleted_index=$((index - 1))
                    read -rp "确定要删除目标 '${RCLONE_TARGETS_ARRAY[$deleted_index]}' 吗? (y/N): " confirm
                    if [[ "$confirm" =~ ^[Yy]$ ]]; then
                        unset 'RCLONE_TARGETS_ARRAY[$deleted_index]'
                        RCLONE_TARGETS_ARRAY=("${RCLONE_TARGETS_ARRAY[@]}")
                        
                        local new_enabled_indices=()
                        for enabled_idx in "${ENABLED_RCLONE_TARGET_INDICES_ARRAY[@]}"; do
                            if (( enabled_idx < deleted_index )); then new_enabled_indices+=("$enabled_idx");
                            elif (( enabled_idx > deleted_index )); then new_enabled_indices+=("$((enabled_idx - 1))");
                            fi
                        done
                        ENABLED_RCLONE_TARGET_INDICES_ARRAY=("${new_enabled_indices[@]}")
                        needs_saving="true"
                        log_and_display "${GREEN}目标已删除。${NC}"
                    fi
                else
                    log_and_display "${RED}无效序号。${NC}"
                fi
                press_enter_to_continue
                ;;
                
            m|M) # 修改
                if [ ${#RCLONE_TARGETS_ARRAY[@]} -eq 0 ]; then log_and_display "${YELLOW}没有可修改的目标。${NC}"; press_enter_to_continue; continue; fi
                read -rp "请输入要修改路径的目标序号: " index
                if [[ "$index" =~ ^[0-9]+$ ]] && [ "$index" -ge 1 ] && [ "$index" -le ${#RCLONE_TARGETS_ARRAY[@]} ]; then
                    local mod_index=$((index - 1))
                    local target_to_modify="${RCLONE_TARGETS_ARRAY[$mod_index]}"
                    local remote_name="${target_to_modify%%:*}"
                    
                    log_and_display "正在为远程端 '${remote_name}' 重新选择路径..."
                    if choose_rclone_path "$remote_name"; then
                        local new_path="$CHOSEN_RCLONE_PATH"
                        RCLONE_TARGETS_ARRAY[$mod_index]="${remote_name}:${new_path}"
                        needs_saving="true"
                        log_and_display "${GREEN}目标已修改为: ${remote_name}:${new_path}${NC}"
                    else
                         log_and_display "${YELLOW}已取消修改。${NC}"
                    fi
                else
                    log_and_display "${RED}无效序号。${NC}"
                fi
                press_enter_to_continue
                ;;

            t|T) # 切换状态
                if [ ${#RCLONE_TARGETS_ARRAY[@]} -eq 0 ]; then log_and_display "${YELLOW}没有可切换的目标。${NC}"; press_enter_to_continue; continue; fi
                read -rp "请输入要切换状态的目标序号: " index
                if [[ "$index" =~ ^[0-9]+$ ]] && [ "$index" -ge 1 ] && [ "$index" -le ${#RCLONE_TARGETS_ARRAY[@]} ]; then
                    local choice_idx=$((index - 1))
                    local found_in_enabled=-1; local index_in_enabled_array=-1
                    for i in "${!ENABLED_RCLONE_TARGET_INDICES_ARRAY[@]}"; do
                        if [[ "${ENABLED_RCLONE_TARGET_INDICES_ARRAY[$i]}" -eq "$choice_idx" ]]; then
                            found_in_enabled=1; index_in_enabled_array=$i; break
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
                    needs_saving="true"
                else
                    log_and_display "${RED}无效序号。${NC}"
                fi
                press_enter_to_continue
                ;;

            0)
                if [[ "$needs_saving" == "true" ]]; then
                    save_config
                    log_and_display "设置已保存。" "${BLUE}"
                fi
                break
                ;;
            *) log_and_display "${RED}无效选项。${NC}"; press_enter_to_continue ;;
        esac
    done
}

# [新] 测试 Rclone 远程端连接
test_rclone_remotes() {
    while true; do
        display_header
        echo -e "${BLUE}=== 测试 Rclone 远程端连接 ===${NC}"
        
        local remotes_list=()
        mapfile -t remotes_list < <(rclone listremotes | sed 's/://')

        if [ ${#remotes_list[@]} -eq 0 ]; then
            log_and_display "${YELLOW}未发现任何已配置的 Rclone 远程端。${NC}"
            log_and_display "请先使用 '创建新的 Rclone 远程端' 或 'rclone config' 进行配置。"
            press_enter_to_continue
            break
        fi

        echo "发现以下 Rclone 远程端:"
        for i in "${!remotes_list[@]}"; do
            echo " $((i+1)). ${remotes_list[$i]}"
        done
        echo ""
        echo " 0. 返回"
        echo -e "${BLUE}------------------------------------------------${NC}"
        read -rp "请选择要测试连接的远程端序号 (0 返回): " choice

        if [[ "$choice" -eq 0 ]]; then break; fi

        if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le ${#remotes_list[@]} ]; then
            local remote_to_test="${remotes_list[$((choice-1))]}"
            log_and_display "正在测试 '${remote_to_test}'..." "${YELLOW}"
            
            if rclone about "${remote_to_test}:" >/dev/null 2>&1; then
                log_and_display "连接测试成功！ '${remote_to_test}' 可用。" "${GREEN}"
                echo -e "${GREEN}--- Rclone About Info ---${NC}"
                rclone about "${remote_to_test}:"
                echo -e "${GREEN}-------------------------${NC}"
            else
                log_and_display "连接测试失败！" "${RED}"
                log_and_display "请检查远程端配置 ('rclone config') 或网络连接。"
            fi
        else
            log_and_display "${RED}无效序号。${NC}"
        fi
        press_enter_to_continue
    done
}

# 5. 云存储设定 (Rclone 主菜单 - 优化版)
set_cloud_storage() {
    while true; do
        display_header
        echo -e "${BLUE}=== 5. 云存储设定 (Rclone) ===${NC}"
        echo ""
        echo " 1. 查看、管理和启用备份目标"
        echo " 2. [助手] 创建新的 Rclone 远程端"
        echo " 3. 测试 Rclone 远程端连接"
        echo ""
        echo -e "${YELLOW}提示: '备份目标' 是 '远程端' 加上具体路径 (例如 mydrive:/backups)。${NC}"
        echo "      '远程端' 是您在 Rclone 中的云存储账户配置。"
        echo ""
        echo " 0. 返回主菜单"
        echo -e "${BLUE}------------------------------------------------${NC}"
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

# 6. 设置 Telegram 通知设定
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

# 7. 设置备份保留策略
set_retention_policy() {
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
        echo "1. 设置按数量保留 (例如：保留最新的 5 个)"
        echo "2. 设置按天数保留 (例如：保留最近 30 天)"
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


# 应用保留策略
apply_retention_policy() {
    log_and_display "${BLUE}--- 正在应用备份保留策略 (Rclone) ---${NC}"

    if [[ "$RETENTION_POLICY_TYPE" == "none" ]]; then
        log_and_display "未设置保留策略，跳过清理。" "${YELLOW}"
        return 0
    fi

    local retention_summary="*${SCRIPT_NAME}：保留策略完成*"
    retention_summary+=$'\n'"保留策略执行完毕。"

    for enabled_idx in "${ENABLED_RCLONE_TARGET_INDICES_ARRAY[@]}"; do
        local rclone_target="${RCLONE_TARGETS_ARRAY[$enabled_idx]}"
        log_and_display "正在为目标 ${rclone_target} 应用保留策略..."

        local backups_list
        backups_list=$(rclone lsf --format "p;T" "${rclone_target}" | grep -E '_[0-9]{14}\.zip;')
        if [[ -z "$backups_list" ]]; then
            log_and_display "在 ${rclone_target} 中未找到备份文件，跳过。" "${YELLOW}"
            continue
        fi
        
        local sorted_backups
        sorted_backups=$(echo "$backups_list" | sort -t ';' -k 2)

        local backups_to_process=()
        mapfile -t backups_to_process <<< "$sorted_backups"

        local deleted_count=0
        local total_found=${#backups_to_process[@]}
        
        if [[ "$RETENTION_POLICY_TYPE" == "count" ]]; then
            local num_to_delete=$(( total_found - RETENTION_VALUE ))
            if [ "$num_to_delete" -gt 0 ]; then
                log_and_display "发现 ${num_to_delete} 个旧备份，将删除..." "${YELLOW}"
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
                local file_path file_date file_timestamp
                file_path=$(echo "$item" | cut -d ';' -f 1)
                file_date=$(echo "$item" | cut -d ';' -f 2 | cut -d 'T' -f 1)
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
        retention_summary+=$'\n'"- ${rclone_target}: 找到 ${total_found} 个, 删除 ${deleted_count} 个。"
    done
    send_telegram_message "${retention_summary}"
}

# 执行备份上传的核心逻辑
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
        local path_summary_message="*${SCRIPT_NAME}：路径处理*\n路径: \`${current_backup_path}\`\n文件: \`${archive_name}\` (${backup_file_size})\n\n*上传状态:*"

        local upload_statuses=""
        for enabled_idx in "${ENABLED_RCLONE_TARGET_INDICES_ARRAY[@]}"; do
            local rclone_target="${RCLONE_TARGETS_ARRAY[$enabled_idx]}"
            log_and_display "正在上传到 Rclone 目标: ${rclone_target}"
            if rclone copyto "$temp_archive_path" "${rclone_target}${archive_name}" --progress; then
                log_and_display "${GREEN}上传到 ${rclone_target} 成功！${NC}"
                upload_statuses+="\n- \`${rclone_target}\`: 成功"
                any_upload_succeeded_for_path="true"
            else
                log_and_display "${RED}上传到 ${rclone_target} 失败！${NC}"
                upload_statuses+="\n- \`${rclone_target}\`: 失败"
            fi
        done
        
        if [[ "$any_upload_succeeded_for_path" == "true" ]]; then
            overall_succeeded_count=$((overall_succeeded_count + 1))
            path_summary_message=${path_summary_message/\*路径处理/\*路径处理 (成功)\*}
        else
            path_summary_message=${path_summary_message/\*路径处理/\*路径处理 (失败)\*}
        fi
        path_summary_message+="${upload_statuses}"
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
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━ 功能选项 ━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "  1. ${YELLOW}自动备份设定${NC} (间隔: ${AUTO_BACKUP_INTERVAL_DAYS} 天)"
    echo -e "  2. ${YELLOW}手动备份${NC}"
    echo -e "  3. ${YELLOW}自定义备份路径${NC} (数量: ${#BACKUP_SOURCE_PATHS_ARRAY[@]})"
    echo -e "  4. ${YELLOW}压缩包格式${NC} (ZIP)"
    echo -e "  5. ${YELLOW}云存储设定${NC} (Rclone)"
    echo -e "  6. ${YELLOW}消息通知设定${NC} (Telegram)"
    local retention_status_text="已禁用"
    if [[ "$RETENTION_POLICY_TYPE" == "count" ]]; then
        retention_status_text="保留 ${RETENTION_VALUE} 个"
    elif [[ "$RETENTION_POLICY_TYPE" == "days" ]]; then
        retention_status_text="保留 ${RETENTION_VALUE} 天"
    fi
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

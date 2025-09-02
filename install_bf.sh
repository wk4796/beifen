#!/bin/bash
# 注意：此脚本设计为通过 "source <(curl...)" 的方式来调用

# --- 配置 ---
SOURCE_URL="https://raw.githubusercontent.com/wk4796/beifen/main/bf.sh"
DEST_FILE="bf.sh"
DEST_PATH="$(pwd)/${DEST_FILE}"

# --- 颜色定义 ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
NC='\033[0m'

# --- 主函数 ---
main() {
    # 在脚本执行期间启用别名展开功能
    shopt -s expand_aliases
    
    # 检查是使用 curl 还是 wget
    if command -v curl >/dev/null 2>&1; then
        DOWNLOADER="curl -sL"
    elif command -v wget >/dev/null 2>&1; then
        DOWNLOADER="wget -qO-"
    else
        echo -e "${RED}错误：此脚本需要 curl 或 wget，但两者均未安装。${NC}"
        return 1
    fi

    echo -e "${GREEN}=== 开始安装个人备份脚本 (bf.sh) ===${NC}"

    # 1. 下载脚本到当前目录
    echo -e "${YELLOW}正在下载脚本到: ${CYAN}${DEST_PATH}${NC}"
    if ! ${DOWNLOADER} "${SOURCE_URL}" > "${DEST_PATH}"; then
        echo -e "${RED}下载失败！请检查您的网络连接或 URL 是否正确。${NC}"
        return 1
    fi
    echo "下载成功！"

    # 2. 设置执行权限
    echo -e "${YELLOW}正在设置执行权限...${NC}"
    chmod +x "${DEST_PATH}"
    echo "权限设置成功！"

    # 3. 自动配置 Shell 环境
    echo -e "${YELLOW}正在尝试自动配置 Shell 环境...${NC}"
    
    PROFILE_FILE=""
    SHELL_TYPE=""

    if [ -n "$ZSH_VERSION" ]; then
        PROFILE_FILE="$HOME/.zshrc"
        SHELL_TYPE="Zsh"
    elif [ -n "$BASH_VERSION" ]; then
        PROFILE_FILE="$HOME/.bashrc"
        SHELL_TYPE="Bash"
    else
        # Fallback for non-standard shells
        if [ -f "$HOME/.zshrc" ]; then
            PROFILE_FILE="$HOME/.zshrc"
            SHELL_TYPE="Zsh (Fallback)"
        elif [ -f "$HOME/.bashrc" ]; then
            PROFILE_FILE="$HOME/.bashrc"
            SHELL_TYPE="Bash (Fallback)"
        else
            echo -e "${RED}错误：无法检测到 .zshrc 或 .bashrc 文件。${NC}"
            return 1
        fi
    fi

    echo -e "检测到您正在使用 ${SHELL_TYPE}，将修改配置文件: ${CYAN}${PROFILE_FILE}${NC}"
    
    # 4. 创建别名命令
    ALIAS_CMD="alias bf='${DEST_PATH}'"
    
    if grep -qF -- "${ALIAS_CMD}" "${PROFILE_FILE}"; then
        echo -e "${GREEN}别名已存在于配置文件中，无需重复添加。${NC}"
    else
        echo "正在将别名写入配置文件..."
        echo "" >> "${PROFILE_FILE}"
        echo "# Personal Backup Script Alias" >> "${PROFILE_FILE}"
        echo "${ALIAS_CMD}" >> "${PROFILE_FILE}"
        echo "别名写入成功！"
    fi
    
    # 5. 在当前 Shell 会话中也定义这个别名，使其立即生效
    echo -e "${CYAN}--- 开始调试 ---${NC}"
    echo "将要执行的别名命令: ${ALIAS_CMD}"
    eval "${ALIAS_CMD}"
    echo "别名设置完毕。正在检查 'bf' 是否已定义..."
    
    # 检查别名是否真的被设置成功
    if alias bf >/dev/null 2>&1; then
        echo -e "${GREEN}调试成功: 'bf' 别名已在当前 Shell 中成功设置。${NC}"
        echo -e "${CYAN}--- 调试结束 ---${NC}"
    else
        echo -e "${RED}调试失败: 'bf' 别名未能在当前 Shell 中设置！请检查您的 Shell 配置。${NC}"
        echo -e "${CYAN}--- 调试结束 ---${NC}"
        return 1
    fi
    
    # 6. 最终提示并自动运行
    echo ""
    echo -e "${GREEN}================================================================${NC}"
    echo -e "${GREEN}🎉 恭喜！脚本已安装并激活！${NC}"
    echo ""
    echo -e "别名 'bf' 已在当前终端中生效，并已写入您的启动配置。"
    echo -e "现在将为您自动启动 ${YELLOW}bf.sh${NC} ..."
    echo -e "${GREEN}================================================================${NC}"
    echo ""
    
    # 7. 自动运行 bf.sh
    bf
}

# 执行主函数
main

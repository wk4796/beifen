#!/bin/bash
set -e # 如果任何命令失败，立即退出

# --- 配置 ---
# 脚本的源文件链接，已根据您的提供进行更新
SOURCE_URL="https://raw.githubusercontent.com/wk4796/beifen/refs/heads/main/bf.sh"

# 目标文件名
DEST_FILE="bf.sh"
# 使用 pwd 获取当前绝对路径
DEST_PATH="$(pwd)/${DEST_FILE}"

# --- 颜色定义 ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
NC='\033[0m'

# --- 主函数 ---
main() {
    # 检查是使用 curl 还是 wget
    if command -v curl >/dev/null 2>&1; then
        DOWNLOADER="curl -sL"
    elif command -v wget >/dev/null 2>&1;
        then DOWNLOADER="wget -qO-"
    else
        echo -e "${RED}错误：此脚本需要 curl 或 wget，但两者均未安装。${NC}"
        exit 1
    fi

    echo -e "${GREEN}=== 开始安装个人备份脚本 (bf.sh) ===${NC}"

    # 1. 下载脚本到当前目录
    echo -e "${YELLOW}正在下载脚本到: ${CYAN}${DEST_PATH}${NC}"
    if ! ${DOWNLOADER} "${SOURCE_URL}" > "${DEST_PATH}"; then
        echo -e "${RED}下载失败！请检查您的网络连接或 URL 是否正确: ${SOURCE_URL}${NC}"
        exit 1
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

    if [ -n "$ZSH_VERSION" ] || [ -f "$HOME/.zshrc" ]; then
        PROFILE_FILE="$HOME/.zshrc"
        SHELL_TYPE="Zsh"
    elif [ -n "$BASH_VERSION" ] || [ -f "$HOME/.bashrc" ]; then
        PROFILE_FILE="$HOME/.bashrc"
        SHELL_TYPE="Bash"
    else
        echo -e "${RED}错误：无法检测到 .zshrc 或 .bashrc 文件。${NC}"
        echo "请手动将以下命令添加到您的 Shell 配置文件中:"
        echo -e "  ${CYAN}alias bf='${DEST_PATH}'${NC}"
        exit 1
    fi

    echo "检测到您正在使用 ${SHELL_TYPE}，将修改配置文件: ${CYAN}${PROFILE_FILE}${NC}"
    
    # 4. 创建别名命令，并检查是否已存在
    ALIAS_CMD="alias bf='${DEST_PATH}'"
    
    if grep -qF -- "${ALIAS_CMD}" "${PROFILE_FILE}"; then
        echo -e "${GREEN}别名已经存在，无需重复添加。${NC}"
    else
        echo "正在将别名添加到文件末尾..."
        echo "" >> "${PROFILE_FILE}" # 添加一个空行以作分隔
        echo "# Personal Backup Script Alias" >> "${PROFILE_FILE}"
        echo "${ALIAS_CMD}" >> "${PROFILE_FILE}"
        echo "别名添加成功！"
    fi
    
    # 5. 最终提示
    echo ""
    echo -e "${GREEN}================================================================${NC}"
    echo -e "${GREEN}🎉 恭喜！脚本已成功安装并配置！${NC}"
    echo ""
    echo "要让 'bf' 命令立即生效，请选择以下一种方式:"
    echo "  1. 关闭当前终端窗口，然后打开一个新的。"
    echo -e "  2. 在当前终端中执行: ${YELLOW}source ${PROFILE_FILE}${NC}"
    echo ""
    echo "之后，您就可以在任何地方通过输入 ${YELLOW}bf${NC} 来运行脚本了。"
    echo -e "${GREEN}================================================================${NC}"
}

# 执行主函数
main

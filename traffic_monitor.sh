#!/bin/bash

# =========================================================
# Linux 流量监控与 Telegram 推送脚本
# Author: vlongx
# Repo: https://github.com/vlongx/traffic_monitor
# =========================================================

# --- 配置与存储路径 ---
CONFIG_FILE="/root/.traffic_monitor.conf"
STATE_FILE="/root/.traffic_monitor.state"
DATE_FILE="/root/.traffic_monitor.date"

# --- 颜色定义 ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
PLAIN='\033[0m'

# --- 1. 依赖检查 ---
check_dependencies() {
    if ! command -v bc &> /dev/null; then
        if [ -f /etc/debian_version ]; then
            apt-get update && apt-get install -y bc
        elif [ -f /etc/redhat-release ]; then
            yum install -y bc
        fi
    fi
    if ! command -v curl &> /dev/null; then
        if [ -f /etc/debian_version ]; then
            apt-get update && apt-get install -y curl
        elif [ -f /etc/redhat-release ]; then
            yum install -y curl
        fi
    fi
}

# --- 2. 核心工具函数 ---
get_interface() {
    local iface=$(ip route get 8.8.8.8 2>/dev/null | awk '{print $5; exit}')
    [ -z "$iface" ] && iface=$(ls /sys/class/net | grep -v lo | head -n 1)
    echo "$iface"
}

get_current_counters() {
    local iface=$1
    if [ ! -f "/sys/class/net/$iface/statistics/rx_bytes" ]; then
        echo "0 0"
        return
    fi
    local rx=$(cat /sys/class/net/$iface/statistics/rx_bytes)
    local tx=$(cat /sys/class/net/$iface/statistics/tx_bytes)
    echo "$rx $tx"
}

# --- 3. 安装配置向导 ---
install_script() {
    clear
    echo -e "${CYAN}=============================================${PLAIN}"
    echo -e "${CYAN}     Linux 流量监控与 TG 推送 - 安装向导      ${PLAIN}"
    echo -e "${CYAN}=============================================${PLAIN}"
    
    local auto_iface=$(get_interface)
    read -p "1. 请输入网卡名称 [默认: $auto_iface]: " input_iface
    INTERFACE=${input_iface:-$auto_iface}
    
    read -p "2. 每月总流量限制 (GB) [默认: 1000]: " input_total
    TOTAL_LIMIT_GB=${input_total:-1000}
    
    read -p "3. 当前已用流量 (GB) [默认: 0]: " input_used
    CURRENT_USED_GB=${input_used:-0}
    
    read -p "4. 每月重置日期 (1-31) [默认: 1]: " input_day
    RESET_DAY=${input_day:-1}
    
    echo -e "5. 流量计算方式:"
    echo "   1) 双向计费 (上传 + 下载)"
    echo "   2) 单向计费 (仅计算上传)"
    read -p "   请选择 [默认1]: " input_mode
    case "$input_mode" in
        2) CALC_MODE="TX_ONLY" ;;
        *) CALC_MODE="BIDIRECTIONAL" ;;
    esac

    local sys_hostname=$(hostname)
    read -p "6. 自定义服务器名称 [默认: $sys_hostname]: " input_name
    SERVER_NAME=${input_name:-$sys_hostname}

    echo -e "${YELLOW}--- Telegram 配置 (可选，回车跳过) ---${PLAIN}"
    read -p "Telegram Bot Token: " input_token
    TG_BOT_TOKEN=${input_token:-""}
    read -p "Telegram Chat ID: " input_chat_id
    TG_CHAT_ID=${input_chat_id:-""}

    # 写入配置
    cat > "$CONFIG_FILE" <<EOF
INTERFACE="$INTERFACE"
TOTAL_LIMIT_GB="$TOTAL_LIMIT_GB"
RESET_DAY="$RESET_DAY"
CALC_MODE="$CALC_MODE"
SERVER_NAME="$SERVER_NAME"
TG_BOT_TOKEN="$TG_BOT_TOKEN"
TG_CHAT_ID="$TG_CHAT_ID"
EOF

    # 初始化状态
    local counters=($(get_current_counters "$INTERFACE"))
    local used_bytes=$(echo "$CURRENT_USED_GB * 1073741824" | bc)
    local today=$(date +%F)
    
    echo "${counters[0]} ${counters[1]} 0 0 $used_bytes $today" > "$STATE_FILE"
    
    echo -e "\n${GREEN}✔ 配置已保存！${PLAIN}"
    echo -e "${YELLOW}请务必设置 Crontab 定时任务以保证数据准确。${PLAIN}"
    echo -e "例如: */5 * * * * bash $(pwd)/traffic_monitor.sh update"
}

# --- 4. 核心逻辑 ---
process_traffic() {
    local mode=$1  # "quiet" or "report"

    if [ ! -f "$CONFIG_FILE" ] || [ ! -f "$STATE_FILE" ]; then
        [ "$mode" == "report" ] && echo -e "${RED}未配置，请先运行 install${PLAIN}"
        return
    fi

    source "$CONFIG_FILE"
    if [ ! -f "$STATE_FILE" ]; then return; fi
    read last_rx last_tx daily_rx daily_tx month_used last_date < "$STATE_FILE"
    
    local counters=($(get_current_counters "$INTERFACE"))
    local curr_rx=${counters[0]}
    local curr_tx=${counters[1]}
    local curr_date=$(date +%F)
    local curr_day_num=$(date +%-d)
    local current_mon_str=$(date +%Y-%m)

    local diff_rx=0
    local diff_tx=0
    if (( $(echo "$curr_rx < $last_rx" | bc -l) )); then diff_rx=$curr_rx; else diff_rx=$(echo "$curr_rx - $last_rx" | bc); fi
    if (( $(echo "$curr_tx < $last_tx" | bc -l) )); then diff_tx=$curr_tx; else diff_tx=$(echo "$curr_tx - $last_tx" | bc); fi

    if [ "$curr_date" != "$last_date" ]; then daily_rx=0; daily_tx=0; fi
    daily_rx=$(echo "$daily_rx + $diff_rx" | bc)
    daily_tx=$(echo "$daily_tx + $diff_tx" | bc)

    local billable_increment=0
    if [ "$CALC_MODE" == "TX_ONLY" ]; then billable_increment=$diff_tx; else billable_increment=$(echo "$diff_rx + $diff_tx" | bc); fi

    local last_reset_mon=""; [ -f "$DATE_FILE" ] && last_reset_mon=$(cat "$DATE_FILE")
    if [ $curr_day_num -ge $RESET_DAY ] && [ "$last_reset_mon" != "$current_mon_str" ]; then
        month_used=0
        echo "$current_mon_str" > "$DATE_FILE"
    fi
    month_used=$(echo "$month_used + $billable_increment" | bc)

    echo "$curr_rx $curr_tx $daily_rx $daily_tx $month_used $curr_date" > "$STATE_FILE"

    [ "$mode" == "quiet" ] && return

    # Report Generation
    local rx_gib=$(echo "scale=2; $daily_rx / 1073741824" | bc)
    local tx_gib=$(echo "scale=2; $daily_tx / 1073741824" | bc)
    local daily_total_gib=$(echo "scale=2; ($daily_rx + $daily_tx) / 1073741824" | bc)
    local month_used_gib=$(echo "scale=2; $month_used / 1073741824" | bc)
    local total_bytes=$(echo "$TOTAL_LIMIT_GB * 1073741824" | bc)
    local remain_bytes=$(echo "$total_bytes - $month_used" | bc)
    if (( $(echo "$remain_bytes < 0" | bc -l) )); then remain_bytes=0; fi
    local remain_gib=$(echo "scale=2; $remain_bytes / 1073741824" | bc)
    
    local report_time=$(date "+%Y-%m-%d %H:%M:%S")

    if [ -z "$SERVER_NAME" ]; then SERVER_NAME=$(hostname); fi

    # 【修复重点1】改用真实换行符，不再使用 %0A，让 curl 自动处理编码
    MSG="📊 <b>流量日报</b> 📊

🖥 <b>服务器:</b> ${SERVER_NAME}
🕒 <b>时间:</b> ${report_time}

⬇️ <b>今日下载:</b> ${rx_gib} GiB
⬆️ <b>今日上传:</b> ${tx_gib} GiB
💰 <b>今日总计:</b> ${daily_total_gib} GiB

-------------------------
🔄 <b>重置日期:</b> 每月 ${RESET_DAY} 日
📦 <b>本月已用:</b> ${month_used_gib} GiB
🔋 <b>本月剩余:</b> ${remain_gib} GiB"

    # 终端输出保持不变
    echo -e "${CYAN}========================================${PLAIN}"
    echo -e " 📊  流量统计报表"
    echo -e " ----------------------------------------"
    echo -e " 🖥  服务器:   $SERVER_NAME"
    echo -e " ⬇️  今日下载: ${GREEN}${rx_gib} GiB${PLAIN}"
    echo -e " ⬆️  今日上传: ${GREEN}${tx_gib} GiB${PLAIN}"
    echo -e " 💰  今日总计: ${YELLOW}${daily_total_gib} GiB${PLAIN}"
    echo -e " 📦  本月已用: ${RED}${month_used_gib} GiB${PLAIN}"
    echo -e " 🔋  本月剩余: ${CYAN}${remain_gib} GiB${PLAIN}"
    echo -e "${CYAN}========================================${PLAIN}"
    
    if [ -n "$TG_BOT_TOKEN" ] && [ -n "$TG_CHAT_ID" ]; then
        # 【修复重点2】使用 --data-urlencode 处理空格和特殊符号，并捕获报错
        res=$(curl -s -X POST "https://api.telegram.org/bot${TG_BOT_TOKEN}/sendMessage" \
             -d "chat_id=${TG_CHAT_ID}" \
             --data-urlencode "text=${MSG}" \
             -d "parse_mode=HTML")
        
        # 检查返回值是否包含 ok:true
        if [[ "$res" == *'"ok":true'* ]]; then
            echo -e "${GREEN}>> 已推送到 Telegram${PLAIN}"
        else
            # 如果失败，打印红色错误信息
            echo -e "${RED}>> 推送失败! TG返回: $res${PLAIN}"
        fi
    fi
}

check_dependencies
case "$1" in
    install) install_script ;;
    reset) rm -f "$CONFIG_FILE" "$STATE_FILE" "$DATE_FILE"; echo "已重置"; ;;
    update) process_traffic "quiet" ;;
    report) process_traffic "report" ;;
    *) process_traffic "report" ;;
esac

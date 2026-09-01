#!/bin/bash
# ===================================================
# Boss 的 VPS 智囊管理腳本 v2.0
# GitHub 託管版 - 包含 SSH Key 精準管理與 Docker 冷/熱搬機
# ===================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m'

DOCKER_DATA_DIR="/docker-data"

if [ "$EUID" -ne 0 ]; then
  echo -e "${RED}錯誤：請使用 root 權限執行此腳本！${NC}"
  exit 1
fi

pause_prompt() {
    read -p "按下 Enter 鍵繼續..." temp
}

# 1. 基礎初始化
init_system() {
    echo -e "${BLUE}=== 1. 基礎系統初始化與 Docker 安裝 ===${NC}"
    apt-get update && apt-get install -y curl wget git ufw fail2ban jq tar openssh-client

    if [ ! -d "$DOCKER_DATA_DIR" ]; then
        mkdir -p "$DOCKER_DATA_DIR"
        echo -e "${GREEN}✓ 已建立主目錄：$DOCKER_DATA_DIR${NC}"
    else
        echo -e "${YELLOW}! 目錄 $DOCKER_DATA_DIR 已存在${NC}"
    fi

    if ! command -v docker &> /dev/null; then
        echo -e "${BLUE}正在安裝 Docker...${NC}"
        curl -fsSL https://get.docker.com | sh
        systemctl start docker
        systemctl enable docker
        echo -e "${GREEN}✓ Docker 安裝完成${NC}"
    else
        echo -e "${YELLOW}! Docker 已安裝${NC}"
    fi
    pause_prompt
}

# 2. SSH 安全 (雙 Port 防鎖死)
setup_ssh_security() {
    echo -e "${BLUE}=== 2. SSH Port 管理 (雙 Port 防鎖死) ===${NC}"
    current_port=$(ss -tulpn | grep sshd | awk '{print $5}' | awk -F: '{print $NF}' | head -n 1)
    echo -e "當前 SSH Port: ${YELLOW}${current_port:-22}${NC}"
    
    read -p "請輸入新的 SSH Port (留空不修改): " NEW_PORT

    if [ -n "$NEW_PORT" ]; then
        cp /etc/ssh/sshd_config /etc/ssh/sshd_config.bak
        sed -i '/^Port /d' /etc/ssh/sshd_config
        echo "Port 22" >> /etc/ssh/sshd_config
        echo "Port $NEW_PORT" >> /etc/ssh/sshd_config

        ufw allow $NEW_PORT/tcp > /dev/null 2>&1
        systemctl restart sshd
        echo -e "${GREEN}✓ 已開啟雙 Port (22 與 $NEW_PORT)${NC}"
        echo -e "${YELLOW}👉 請【開啟新 Terminal】測試是否能用 Port $NEW_PORT 成功登入！${NC}"
        read -p "測試成功？是否關閉舊 Port 22？(y/N): " close_22
        if [[ "$close_22" =~ ^[Yy]$ ]]; then
            sed -i '/^Port 22$/d' /etc/ssh/sshd_config
            ufw delete allow 22/tcp > /dev/null 2>&1
            systemctl restart sshd
            echo -e "${GREEN}✓ 已安全關閉 Port 22！${NC}"
        fi
    fi

    read -p "是否禁用 SSH 密碼登入？(y/N): " disable_pwd
    if [[ "$disable_pwd" =~ ^[Yy]$ ]]; then
        sed -i 's/^#*PasswordAuthentication.*/PasswordAuthentication no/' /etc/ssh/sshd_config
        systemctl restart sshd
        echo -e "${GREEN}✓ 已禁用密碼登入${NC}"
    fi
    pause_prompt
}

# 3. SSH Key 獨立管理 (增/刪/查/還原)
manage_ssh_keys() {
    while true; do
        clear
        echo -e "${BLUE}=== 3. SSH Key 獨立管理 ===${NC}"
        echo " [1] 查看現有 Keys (帶編號)"
        echo " [2] 追加新 Key (Append)"
        echo " [3] 刪除指定編號的 Key (Delete by Line)"
        echo " [4] 覆蓋所有 Key (Overwrite - 自動備份)"
        echo " [5] 從 .bak 檔案一鍵還原 Key"
        echo " [0] 返回主選單"
        read -p "請選擇 [0-5]: " key_choice

        mkdir -p ~/.ssh && touch ~/.ssh/authorized_keys
        chmod 700 ~/.ssh && chmod 600 ~/.ssh/authorized_keys

        case $key_choice in
            1)
                echo -e "${YELLOW}--- 當前 authorized_keys 列表 ---${NC}"
                nl -ba ~/.ssh/authorized_keys
                pause_prompt
                ;;
            2)
                read -p "請貼上新 Key: " NEW_KEY
                if [ -n "$NEW_KEY" ]; then
                    cp ~/.ssh/authorized_keys ~/.ssh/authorized_keys.bak
                    echo "$NEW_KEY" >> ~/.ssh/authorized_keys
                    echo -e "${GREEN}✓ 已追加 Key${NC}"
                fi
                pause_prompt
                ;;
            3)
                nl -ba ~/.ssh/authorized_keys
                read -p "請輸入要刪除的 Key 行號: " LINE_NUM
                if [ -n "$LINE_NUM" ]; then
                    cp ~/.ssh/authorized_keys ~/.ssh/authorized_keys.bak
                    sed -i "${LINE_NUM}d" ~/.ssh/authorized_keys
                    echo -e "${GREEN}✓ 已刪除第 $LINE_NUM 行 Key${NC}"
                fi
                pause_prompt
                ;;
            4)
                read -p "請貼上新 Key (這將覆蓋全部): " NEW_KEY
                if [ -n "$NEW_KEY" ]; then
                    cp ~/.ssh/authorized_keys ~/.ssh/authorized_keys.bak
                    echo "$NEW_KEY" > ~/.ssh/authorized_keys
                    echo -e "${GREEN}✓ 已覆蓋所有 Key (舊 Key 已備份至 .bak)${NC}"
                fi
                pause_prompt
                ;;
            5)
                if [ -f ~/.ssh/authorized_keys.bak ]; then
                    cp ~/.ssh/authorized_keys.bak ~/.ssh/authorized_keys
                    echo -e "${GREEN}✓ 已成功從 .bak 還原 Key 檔案！${NC}"
                else
                    echo -e "${RED}錯誤：找不到 authorized_keys.bak 備份檔！${NC}"
                fi
                pause_prompt
                ;;
            0) break ;;
        esac
    done
}

# 4. Fail2ban 設定
setup_fail2ban() {
    echo -e "${BLUE}=== 4. 配置 Fail2ban 防爆破 ===${NC}"
    read -p "請輸入 IP 白名單 (如 Tailscale IP，留空跳過): " MY_IP
    current_port=$(ss -tulpn | grep sshd | awk '{print $5}' | awk -F: '{print $NF}' | head -n 1)
    ssh_port=${current_port:-22}

    cat <<EOF > /etc/fail2ban/jail.local
[sshd]
enabled = true
port = $ssh_port
filter = sshd
logpath = /var/log/auth.log
maxretry = 5
findtime = 600
bantime = 86400
ignoreip = 127.0.0.1/8 ::1 $MY_IP
EOF

    systemctl restart fail2ban
    systemctl enable fail2ban
    echo -e "${GREEN}✓ Fail2ban 已配置 (監控 Port: $ssh_port)${NC}"
    pause_prompt
}

# 5. TG SSH Monitor
setup_tg_monitor() {
    echo -e "${BLUE}=== 5. 部署 Telegram SSH 登入監控 ===${NC}"
    read -p "請輸入 TG Bot Token: " TG_BOT_TOKEN
    read -p "請輸入 TG Chat ID: " TG_CHAT_ID

    if [ -n "$TG_BOT_TOKEN" ] && [ -n "$TG_CHAT_ID" ]; then
        MONITOR_SCRIPT="/usr/local/bin/ssh-monitor.sh"
        cat <<EOF > $MONITOR_SCRIPT
#!/bin/bash
IP=\$(echo \$PAM_RHOST)
USER=\$(echo \$PAM_USER)
HOSTNAME=\$(hostname)
DATE=\$(date "+%Y-%m-%d %H:%M:%S")

if [ "\$PAM_TYPE" = "open_session" ]; then
    TEXT="⚠️ <b>SSH 登入通知</b>%0A%0A<b>伺服器:</b> \$HOSTNAME%0A<b>使用者:</b> \$USER%0A<b>來源 IP:</b> \$IP%0A<b>時間:</b> \$DATE"
    curl -s -X POST "https://api.telegram.org/bot${TG_BOT_TOKEN}/sendMessage" \
        -d "chat_id=${TG_CHAT_ID}" \
        -d "parse_mode=HTML" \
        -d "text=\$TEXT" > /dev/null
fi
EOF
        chmod +x $MONITOR_SCRIPT
        if ! grep -q "ssh-monitor.sh" /etc/pam.d/sshd; then
            echo "session optional pam_exec.so seteuid $MONITOR_SCRIPT" >> /etc/pam.d/sshd
        fi
        echo -e "${GREEN}✓ TG SSH 監控部署完成${NC}"
    fi
    pause_prompt
}

# 6. Docker 冷/熱打包與搬機推送
backup_and_migrate() {
    echo -e "${BLUE}=== 6. Docker 服務搬機與備份 ===${NC}"
    echo "當前 $DOCKER_DATA_DIR 下的服務："
    ls -l $DOCKER_DATA_DIR | grep '^d' | awk '{print $9}'
    echo "---------------------------------------------------"
    read -p "請輸入要打包的服務資料夾名稱: " SERVICE_NAME

    TARGET_DIR="$DOCKER_DATA_DIR/$SERVICE_NAME"
    if [ ! -d "$TARGET_DIR" ]; then
        echo -e "${RED}錯誤：資料夾不存在！${NC}"
        pause_prompt
        return
    fi

    # 冷/熱備份選擇
    read -p "是否先停止該容器以確保數據一致 (冷備份)？(y/N): " stop_container
    if [[ "$stop_container" =~ ^[Yy]$ ]]; then
        if [ -f "$TARGET_DIR/docker-compose.yml" ] || [ -f "$TARGET_DIR/docker-compose.yaml" ]; then
            echo -e "${YELLOW}正在停止 Docker 容器...${NC}"
            (cd "$TARGET_DIR" && docker compose down)
        fi
    fi

    BACKUP_FILE="/tmp/${SERVICE_NAME}_backup_$(date +%Y%m%d_%H%M%S).tar.gz"
    tar -czvf "$BACKUP_FILE" -C "$DOCKER_DATA_DIR" "$SERVICE_NAME"
    echo -e "${GREEN}✓ 備份完成：$BACKUP_FILE${NC}"

    # 若剛才停止了容器，打包完自動重啟
    if [[ "$stop_container" =~ ^[Yy]$ ]]; then
        echo -e "${BLUE}正在重啟 Docker 容器...${NC}"
        (cd "$TARGET_DIR" && docker compose up -d)
    fi

    # 搬機推送
    read -p "是否直接傳輸至新 VPS？(y/N): " do_push
    if [[ "$do_push" =~ ^[Yy]$ ]]; then
        read -p "請輸入新 VPS IP (可填 Tailscale IP): " NEW_IP
        read -p "請輸入新 VPS SSH Port (預設 22): " NEW_SSH_PORT
        NEW_SSH_PORT=${NEW_SSH_PORT:-22}
        read -p "請輸入新 VPS 的 SSH 私鑰路徑 (預設 ~/.ssh/id_rsa，若無直接 Enter): " KEY_PATH

        SSH_CMD="scp -P $NEW_SSH_PORT"
        [ -n "$KEY_PATH" ] && SSH_CMD="scp -i $KEY_PATH -P $NEW_SSH_PORT"

        echo -e "${BLUE}正在傳輸至新 VPS /tmp 目錄...${NC}"
        $SSH_CMD "$BACKUP_FILE" "root@$NEW_IP:/tmp/"
        
        if [ $? -eq 0 ]; then
            echo -e "${GREEN}✓ 檔案已成功傳送至新 VPS 的 /tmp 目錄！${NC}"
            echo -e "${YELLOW}請在新 VPS 執行：tar -xzvf /tmp/$(basename $BACKUP_FILE) -C /docker-data/${NC}"
        else
            echo -e "${RED}傳輸失敗，請檢查網絡連線或 SSH Key 權限。${NC}"
        fi
    fi
    pause_prompt
}

# 主選單
main_menu() {
    while true; do
        clear
        echo -e "${GREEN}===================================================${NC}"
        echo -e "${GREEN}       Boss 的 VPS 智囊管理腳本 v2.0               ${NC}"
        echo -e "${GREEN}===================================================${NC}"
        echo " [1] 🚀 基礎初始化 (安裝 Docker / 建立 docker-data)"
        echo " [2] 🔒 SSH Port 管理 (雙 Port 防鎖死/關密碼)"
        echo " [3] 🔑 SSH Key 獨立管理 (增/刪/查/一鍵還原)"
        echo " [4] 🛡️ 配置 Fail2ban 防爆破 (帶 IP 白名單)"
        echo " [5] 📲 部署 Telegram SSH 登入監控"
        echo " [6] 📦 Docker 冷/熱打包備份與一鍵搬機"
        echo " [0] 🚪 退出 (Exit)"
        echo -e "${GREEN}===================================================${NC}"
        read -p "請選擇操作 [0-6]: " choice

        case $choice in
            1) init_system ;;
            2) setup_ssh_security ;;
            3) manage_ssh_keys ;;
            4) setup_fail2ban ;;
            5) setup_tg_monitor ;;
            6) backup_and_migrate ;;
            0) echo -e "${GREEN}已退出。${NC}"; exit 0 ;;
            *) echo -e "${RED}無效選項！${NC}"; sleep 1 ;;
        esac
    done
}

main_menu

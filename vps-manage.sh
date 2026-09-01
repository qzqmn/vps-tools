#!/bin/bash
# ===================================================
# Boss 的 VPS 智囊管理腳本 v2.8.0 (Full Security Checks & Mandatory Consent)
# 功能：全套系統初始化、SSH安全、Docker冷備份(帶卡死鎖)、雲端同步與選單管理
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
    echo ""
    read -p "按下 Enter 鍵繼續..." temp
}

# 檢查與安裝 Rclone (發現未安裝 -> 報告 -> 詢問授權)
check_and_install_rclone() {
    if ! command -v rclone &> /dev/null; then
        echo -e "${YELLOW}⚠️ 報告 Boss：偵測到系統尚未安裝 Rclone 雲端同步工具。${NC}"
        echo " [1] 安裝系統二進制版 (原生 CLI)"
        echo " [2] 使用 Docker 部署 Rclone 容器 (目錄: /docker-data/rclone)"
        echo " [0] 取消並返回"
        read -p "是否執行安裝？請選擇 [0-2]: " rc_install_choice

        case $rc_install_choice in
            1)
                echo -e "${BLUE}正在安裝 Rclone 系統二進制版...${NC}"
                curl https://rclone.org/install.sh | bash
                if command -v rclone &> /dev/null; then
                    echo -e "${GREEN}✓ Rclone 二進制版安裝完成！${NC}"
                    return 0
                else
                    echo -e "${RED}❌ 安裝失敗，請檢查網絡連線！${NC}"
                    return 1
                fi
                ;;
            2)
                echo -e "${BLUE}正在以 Docker 拉取 Rclone 映像檔...${NC}"
                mkdir -p /docker-data/rclone/config /docker-data/rclone/data
                docker pull rclone/rclone:latest
                
                cat << 'EOF' > /usr/local/bin/rclone
#!/bin/bash
docker run --rm -it \
  -v /docker-data/rclone/config:/config/rclone \
  -v /docker-data:/docker-data \
  -v /tmp:/tmp \
  rclone/rclone:latest "$@"
EOF
                chmod +x /usr/local/bin/rclone
                echo -e "${GREEN}✓ Rclone Docker 部署與 CLI 封裝完成！${NC}"
                return 0
                ;;
            *)
                echo -e "${YELLOW}已取消安裝。${NC}"
                return 1
                ;;
        esac
    fi
    return 0
}

# 檢查與安裝 UFW 防火牆 (發現未安裝 -> 報告 -> 詢問授權)
check_and_install_ufw() {
    if ! command -v ufw &> /dev/null; then
        echo -e "${YELLOW}⚠️ 報告 Boss：偵測到系統尚未安裝 UFW 防火牆。${NC}"
        read -p "是否現在為你安裝 UFW 防火牆？(y/N): " install_ufw
        if [[ "$install_ufw" =~ ^[Yy]$ ]]; then
            echo -e "${BLUE}正在安裝 UFW...${NC}"
            apt-get update && apt-get install -y ufw
            echo -e "${GREEN}✓ UFW 安裝完成！${NC}"
            return 0
        else
            echo -e "${YELLOW}已取消 UFW 安裝操作。${NC}"
            return 1
        fi
    fi
    return 0
}

# 檢查與安裝 Fail2ban (發現未安裝 -> 報告 -> 詢問授權)
check_and_install_fail2ban() {
    if ! command -v fail2ban-client &> /dev/null; then
        echo -e "${YELLOW}⚠️ 報告 Boss：偵測到系統尚未安裝 Fail2ban 防爆破工具。${NC}"
        read -p "是否現在為你安裝 Fail2ban？(y/N): " install_f2b
        if [[ "$install_f2b" =~ ^[Yy]$ ]]; then
            echo -e "${BLUE}正在安裝 Fail2ban...${NC}"
            apt-get update && apt-get install -y fail2ban
            echo -e "${GREEN}✓ Fail2ban 安裝完成！${NC}"
            return 0
        else
            echo -e "${YELLOW}已取消 Fail2ban 安裝操作。${NC}"
            return 1
        fi
    fi
    return 0
}

# 1. 基礎初始化
init_system() {
    echo -e "${BLUE}=== 1. 基礎系統初始化與 Docker 安裝 ===${NC}"
    echo -e "${YELLOW}此操作將為 VPS 安裝基礎工具 (curl, wget, git, jq, tar) 與 Docker。${NC}"
    read -p "確定要開始初始化嗎？(y/N): " confirm_init
    if [[ ! "$confirm_init" =~ ^[Yy]$ ]]; then
        echo -e "${YELLOW}已取消初始化。${NC}"
        pause_prompt
        return
    fi

    apt-get update && apt-get install -y curl wget git jq tar openssh-client sysbench

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

# 2. SSH Port 管理
setup_ssh_port() {
    echo -e "${BLUE}=== 2. SSH Port 管理 (雙 Port 防鎖死) ===${NC}"
    current_port=$(ss -tulpn | grep sshd | awk '{print $5}' | awk -F: '{print $NF}' | head -n 1)
    echo -e "當前 SSH Port: ${YELLOW}${current_port:-22}${NC}"
    
    read -p "請輸入新的 SSH Port (留空不修改): " NEW_PORT

    if [ -n "$NEW_PORT" ]; then
        cp /etc/ssh/sshd_config /etc/ssh/sshd_config.bak
        sed -i '/^Port /d' /etc/ssh/sshd_config
        echo "Port 22" >> /etc/ssh/sshd_config
        echo "Port $NEW_PORT" >> /etc/ssh/sshd_config

        if command -v ufw &> /dev/null; then
            ufw allow $NEW_PORT/tcp > /dev/null 2>&1
        fi
        systemctl restart sshd
        echo -e "${GREEN}✓ 已開啟雙 Port (22 與 $NEW_PORT)${NC}"
        echo -e "${YELLOW}👉 請【開啟新 Terminal】測試是否能用 Port $NEW_PORT 成功登入！${NC}"
        read -p "測試成功？是否關閉舊 Port 22？(y/N): " close_22
        if [[ "$close_22" =~ ^[Yy]$ ]]; then
            sed -i '/^Port 22$/d' /etc/ssh/sshd_config
            [ -x "$(command -v ufw)" ] && ufw delete allow 22/tcp > /dev/null 2>&1
            systemctl restart sshd
            echo -e "${GREEN}✓ 已安全關閉 Port 22！${NC}"
        fi
    fi
    pause_prompt
}

# 3. 關閉 SSH 密碼登入
disable_ssh_password() {
    echo -e "${BLUE}=== 3. 關閉 SSH 密碼登入 (安全控管) ===${NC}"
    
    if [ ! -s ~/.ssh/authorized_keys ]; then
        echo -e "${RED}❌ 嚴格警告：偵測到 ~/.ssh/authorized_keys 為空或不存在！${NC}"
        echo -e "${RED}若此時關閉密碼登入， Boss 將永遠無法登入此 VPS。請先到選項 [4] 注入 SSH Key！${NC}"
        pause_prompt
        return
    fi

    echo -e "${YELLOW}✓ 檢測到已存在 SSH Key，可以安全執行。${NC}"
    read -p "確定要禁用 SSH 密碼登入，僅允許 Key 登入嗎？(y/N): " confirm
    if [[ "$confirm" =~ ^[Yy]$ ]]; then
        sed -i 's/^#*PasswordAuthentication.*/PasswordAuthentication no/' /etc/ssh/sshd_config
        systemctl restart sshd
        echo -e "${GREEN}✓ 已成功禁用 SSH 密碼登入${NC}"
    fi
    pause_prompt
}

# 4. SSH Key 獨立管理
manage_ssh_keys() {
    while true; do
        clear
        echo -e "${BLUE}=== 4. SSH Key 獨立管理 ===${NC}"
        echo " [1] 查看現有 Keys (帶編號)"
        echo " [2] 追加新 Key (Append)"
        echo " [3] 刪除指定編號的 Key (Delete by Line)"
        echo " [4] 覆蓋所有 Key (Overwrite - 自動備份)"
        echo " [5] 從 .bak 檔案一鍵還原 Key"
        echo " [0] 返回主選單"
        read -p "請選擇 [0-5]: " key_choice

        mkdir -p ~/.ssh && chmod 700 ~/.ssh
        touch ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys

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

# 5. Fail2ban 設定 (含授權安裝機制)
setup_fail2ban() {
    echo -e "${BLUE}=== 5. 配置 Fail2ban 防爆破 ===${NC}"
    
    check_and_install_fail2ban
    if [ $? -ne 0 ]; then
        pause_prompt
        return
    fi

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
    echo -e "${GREEN}✓ Fail2ban 已配置並啟用 (監控 Port: $ssh_port，封禁時間: 24小時)${NC}"
    pause_prompt
}

# 6. 高級 TG SSH Monitor
setup_tg_monitor() {
    echo -e "${BLUE}=== 6. 部署 Telegram SSH 登入監控 (高級版) ===${NC}"
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
    if [ -n "\$IP" ] && [ "\$IP" != "127.0.0.1" ]; then
        GEO_INFO=\$(curl -s --connect-timeout 2 "http://ip-api.com/json/\$IP?lang=zh-TW")
        COUNTRY=\$(echo "\$GEO_INFO" | jq -r '.country // "未知"')
        CITY=\$(echo "\$GEO_INFO" | jq -r '.city // "未知"')
        LOCATION="\${COUNTRY}, \${CITY}"
    else
        LOCATION="Localhost / Tailscale"
    fi

    AUTH_TYPE="未知"
    LOG_ENTRY=\$(grep "Accepted " /var/log/auth.log | tail -n 1)
    if echo "\$LOG_ENTRY" | grep -q "publickey"; then
        AUTH_TYPE="🔑 Public Key"
    elif echo "\$LOG_ENTRY" | grep -q "password"; then
        AUTH_TYPE="🔐 Password"
    fi

    TEXT="⚠️ <b>SSH 登入通知</b>%0A%0A🖥️ <b>伺服器:</b> \$HOSTNAME%0A👤 <b>使用者:</b> \$USER%0A🛡️ <b>方式:</b> \$AUTH_TYPE%0A🌐 <b>來源 IP:</b> \$IP%0A📍 <b>歸屬地:</b> \$LOCATION%0A⏰ <b>時間:</b> \$DATE"
    
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
        echo -e "${GREEN}✓ 高級版 TG SSH 監控部署完成！${NC}"
    fi
    pause_prompt
}

# 7. Docker 服務冷備份 (帶卡死校驗鎖)、雲端同步與還原 (支援 空格多選 / 單選 / 全選)
backup_and_migrate() {
    while true; do
        clear
        echo -e "${BLUE}=== 7. Docker 服務搬機、雲端同步 (Rclone) 與還原 ===${NC}"
        echo " [1] 打包服務並同步至 雲端網盤 / 新 VPS (支援 多選/單選/ALL)"
        echo " [2] 從 Rclone 雲端 / 本機拉取備份檔並按需還原啟動"
        echo " [3] 配置 / 綁定 Rclone 雲端網盤 (rclone config)"
        echo " [0] 返回主選單"
        read -p "請選擇 [0-3]: " sub_choice

        case $sub_choice in
            1)
                echo -e "\n${BLUE}--- 當前 $DOCKER_DATA_DIR 下的服務清單 ---${NC}"
                
                SERVICES=()
                while IFS= read -r -d '' dir; do
                    SERVICES+=("$(basename "$dir")")
                done < <(find "$DOCKER_DATA_DIR" -maxdepth 1 -mindepth 1 -type d -print0 2>/dev/null)

                if [ ${#SERVICES[@]} -eq 0 ]; then
                    echo -e "${RED}❌ $DOCKER_DATA_DIR 下沒有找到任何服務資料夾！${NC}"
                    pause_prompt
                    continue
                fi

                for i in "${!SERVICES[@]}"; do
                    echo " [$((i+1))] ${SERVICES[$i]}"
                done
                echo "---------------------------------------------------"
                echo " [A] 打包全部服務 (ALL)"
                echo " [0] 取消並返回"
                echo "---------------------------------------------------"
                read -p "請選擇要打包的服務編號 (多選請用空格隔開，例如: 1 3 或 A): " input_choice

                if [ "$input_choice" = "0" ] || [ -z "$input_choice" ]; then
                    continue
                fi

                SELECTED_SERVICES=()
                IS_ALL=false

                if [[ "$input_choice" =~ ^[Aa]$ ]]; then
                    IS_ALL=true
                    SELECTED_SERVICES=("${SERVICES[@]}")
                else
                    for num in $input_choice; do
                        if [[ "$num" =~ ^[0-9]+$ ]] && [ "$num" -ge 1 ] && [ "$num" -le "${#SERVICES[@]}" ]; then
                            SELECTED_SERVICES+=("${SERVICES[$((num-1))]}")
                        fi
                    done
                fi

                # 剔除重複選擇
                SELECTED_SERVICES=($(echo "${SELECTED_SERVICES[@]}" | tr ' ' '\n' | sort -u | tr '\n' ' '))

                if [ ${#SELECTED_SERVICES[@]} -eq 0 ]; then
                    echo -e "${RED}❌ 無效選擇！${NC}"
                    pause_prompt
                    continue
                fi

                echo -e "${YELLOW}你已選擇打包以下服務: ${GREEN}${SELECTED_SERVICES[*]}${NC}"

                read -p "是否先停止相關 Docker 容器以進行【冷備份】(確保數據 100% 一致)？(Y/n): " do_cold
                do_cold=${do_cold:-Y}

                STOPPED_CONTAINERS=()
                STUCK_DETECTED=false

                if [[ "$do_cold" =~ ^[Yy]$ ]]; then
                    echo -e "${YELLOW}正在停止相關 Docker 容器以準備冷備份...${NC}"
                    if [ "$IS_ALL" = true ]; then
                        STOPPED_CONTAINERS=($(docker ps -q))
                        if [ ${#STOPPED_CONTAINERS[@]} -gt 0 ]; then
                            docker stop "${STOPPED_CONTAINERS[@]}" > /dev/null
                            REMAINING_RUNNING=$(docker ps -q)
                            if [ -n "$REMAINING_RUNNING" ]; then
                                STUCK_DETECTED=true
                            fi
                        fi
                    else
                        for s_name in "${SELECTED_SERVICES[@]}"; do
                            TARGET_DIR="$DOCKER_DATA_DIR/$s_name"
                            if [ -f "$TARGET_DIR/docker-compose.yml" ] || [ -f "$TARGET_DIR/docker-compose.yaml" ]; then
                                (cd "$TARGET_DIR" && docker compose down > /dev/null 2>&1)
                                IS_RUNNING=$(cd "$TARGET_DIR" && docker compose ps --services --filter "status=running" 2>/dev/null)
                                if [ -n "$IS_RUNNING" ]; then
                                    STUCK_DETECTED=true
                                fi
                            fi
                        done
                    fi

                    if [ "$STUCK_DETECTED" = true ]; then
                        echo -e "${RED}❌ 嚴重警告：機器反應過慢或容器卡死，仍有容器未完全關閉！${NC}"
                        echo -e "${RED}為避免備份損毀數據，腳本已強行中止備份程序！${NC}"
                        pause_prompt
                        continue
                    fi
                    echo -e "${GREEN}✓ 已停止並驗證選定容器完全關閉！${NC}"
                fi

                echo -e "${BLUE}正在打包中...${NC}"
                TIMESTAMP=$(date +%Y%m%d_%H%M%S)
                
                if [ "$IS_ALL" = true ]; then
                    BACKUP_FILE="/tmp/docker_data_ALL_${TIMESTAMP}.tar.gz"
                    tar -czvf "$BACKUP_FILE" -C "$DOCKER_DATA_DIR" . > /dev/null 2>&1
                elif [ ${#SELECTED_SERVICES[@]} -eq 1 ]; then
                    BACKUP_FILE="/tmp/${SELECTED_SERVICES[0]}_backup_${TIMESTAMP}.tar.gz"
                    tar -czvf "$BACKUP_FILE" -C "$DOCKER_DATA_DIR" "${SELECTED_SERVICES[0]}" > /dev/null 2>&1
                else
                    BACKUP_FILE="/tmp/docker_data_CUSTOM_${TIMESTAMP}.tar.gz"
                    TAR_PATHS=()
                    for s_name in "${SELECTED_SERVICES[@]}"; do
                        TAR_PATHS+=("$s_name")
                    done
                    tar -czvf "$BACKUP_FILE" -C "$DOCKER_DATA_DIR" "${TAR_PATHS[@]}" > /dev/null 2>&1
                fi

                if [ $? -eq 0 ] && [ -f "$BACKUP_FILE" ]; then
                    echo -e "${GREEN}✓ 備份成功：$BACKUP_FILE${NC}"
                else
                    echo -e "${RED}❌ 打包失敗！請檢查硬碟空間。${NC}"
                fi

                if [[ "$do_cold" =~ ^[Yy]$ ]]; then
                    echo -e "${BLUE}正在恢復 Docker 容器...${NC}"
                    if [ "$IS_ALL" = true ]; then
                        if [ ${#STOPPED_CONTAINERS[@]} -gt 0 ]; then
                            docker start "${STOPPED_CONTAINERS[@]}" > /dev/null
                            echo -e "${GREEN}✓ 所有 Docker 容器已重新啟動！${NC}"
                        fi
                    else
                        for s_name in "${SELECTED_SERVICES[@]}"; do
                            TARGET_DIR="$DOCKER_DATA_DIR/$s_name"
                            if [ -f "$TARGET_DIR/docker-compose.yml" ] || [ -f "$TARGET_DIR/docker-compose.yaml" ]; then
                                (cd "$TARGET_DIR" && docker compose up -d > /dev/null 2>&1)
                            fi
                        done
                        echo -e "${GREEN}✓ 已重啟選定的 Docker 服務！${NC}"
                    fi
                fi

                if check_and_install_rclone; then
                    read -p "是否同步備份檔至 Rclone 雲端網盤？(y/N): " do_rclone
                    if [[ "$do_rclone" =~ ^[Yy]$ ]]; then
                        echo -e "${YELLOW}現有 Rclone Remote 清單：${NC}"
                        rclone listremotes
                        read -p "請輸入 Remote 名稱與目標路徑 (例如 drive:/backup): " RCLONE_PATH
                        if [ -n "$RCLONE_PATH" ]; then
                            echo -e "${BLUE}正在上傳至雲端...${NC}"
                            rclone copy "$BACKUP_FILE" "$RCLONE_PATH"
                            if [ $? -eq 0 ]; then
                                echo -e "${GREEN}✓ 已成功同步上傳至 $RCLONE_PATH！${NC}"
                            else
                                echo -e "${RED}❌ Rclone 上傳失敗，請檢查路徑與配置。${NC}"
                            fi
                        fi
                    fi
                fi

                read -p "是否直接 SCP 傳輸至新 VPS？(y/N): " do_push
                if [[ "$do_push" =~ ^[Yy]$ ]]; then
                    read -p "請輸入新 VPS IP (可填 Tailscale IP): " NEW_IP
                    read -p "請輸入新 VPS SSH Port (預設 22): " NEW_SSH_PORT
                    NEW_SSH_PORT=${NEW_SSH_PORT:-22}
                    read -p "請輸入 SSH 私鑰路徑 (預設 ~/.ssh/id_rsa，若無直接 Enter): " KEY_PATH

                    SSH_CMD="scp -P $NEW_SSH_PORT"
                    [ -n "$KEY_PATH" ] && SSH_CMD="scp -i $KEY_PATH -P $NEW_SSH_PORT"

                    echo -e "${BLUE}正在傳輸至新 VPS /tmp 目錄...${NC}"
                    $SSH_CMD "$BACKUP_FILE" "root@$NEW_IP:/tmp/"
                    if [ $? -eq 0 ]; then
                        echo -e "${GREEN}✓ 檔案已成功傳送至新 VPS 的 /tmp 目錄！${NC}"
                    else
                        echo -e "${RED}傳輸失敗，請檢查網絡連線或 SSH Key 權限。${NC}"
                    fi
                fi

                read -p "備份與傳輸已完成，是否刪除本機 /tmp 暫存檔 ($BACKUP_FILE)？(y/N): " rm_tmp
                if [[ "$rm_tmp" =~ ^[Yy]$ ]]; then
                    rm -f "$BACKUP_FILE"
                    echo -e "${GREEN}✓ 已成功清除本機暫存檔！${NC}"
                fi
                pause_prompt
                ;;

            2)
                echo -e "\n${BLUE}--- 還原備份檔至本機 ---${NC}"
                SELECTED_FILE=""

                read -p "是否從 Rclone 雲端網盤下載備份檔？(y/N): " from_cloud
                if [[ "$from_cloud" =~ ^[Yy]$ ]]; then
                    if check_and_install_rclone; then
                        echo -e "${YELLOW}現有 Rclone Remote 清單：${NC}"
                        rclone listremotes
                        read -p "請輸入 Remote 路徑 (例如 drive:/backup): " CLOUD_PATH
                        if [ -n "$CLOUD_PATH" ]; then
                            echo -e "${YELLOW}遠端目錄中的檔案：${NC}"
                            rclone ls "$CLOUD_PATH"
                            read -p "請輸入要下載的檔案完整檔名 (例如 vaultwarden_backup.tar.gz): " CLOUD_FILE
                            
                            echo -e "${BLUE}正在從雲端拉取檔案...${NC}"
                            rclone copy "$CLOUD_PATH/$CLOUD_FILE" /tmp/
                            if [ $? -eq 0 ] && [ -f "/tmp/$CLOUD_FILE" ]; then
                                echo -e "${GREEN}✓ 下載成功！${NC}"
                                SELECTED_FILE="/tmp/$CLOUD_FILE"
                            else
                                echo -e "${RED}❌ 從雲端下載失敗！${NC}"
                                pause_prompt
                                continue
                            fi
                        fi
                    fi
                fi

                if [ -z "$SELECTED_FILE" ]; then
                    echo "掃描 /tmp/ 目錄下的備份檔："
                    BACKUP_LIST=($(ls /tmp/*.tar.gz 2>/dev/null))
                    
                    if [ ${#BACKUP_LIST[@]} -eq 0 ]; then
                        read -p "在 /tmp/ 找不到備份檔，請手動輸入備份檔完整路徑: " MANUAL_PATH
                        SELECTED_FILE="$MANUAL_PATH"
                    else
                        for i in "${!BACKUP_LIST[@]}"; do
                            echo " [$i] ${BACKUP_LIST[$i]}"
                        done
                        read -p "請選擇要還原的檔案編號 [0-$((${#BACKUP_LIST[@]}-1))]: " file_idx
                        SELECTED_FILE="${BACKUP_LIST[$file_idx]}"
                    fi
                fi

                if [ ! -f "$SELECTED_FILE" ]; then
                    echo -e "${RED}錯誤：檔案 $SELECTED_FILE 不存在！${NC}"
                    pause_prompt
                    continue
                fi

                # 讀取備份包內的服務清單
                INSIDE_SERVICES=($(tar -tzf "$SELECTED_FILE" | awk -F'/' '{print $1}' | grep -v '^\.' | grep -v '^$' | sort -u))

                if [ ${#INSIDE_SERVICES[@]} -eq 0 ]; then
                    # 嘗試備份時包含 -C 的結構解析
                    INSIDE_SERVICES=($(tar -tzf "$SELECTED_FILE" | awk -F'/' '{print $1}' | sort -u))
                fi

                echo -e "\n${BLUE}--- 檢測到備份包內含有以下 Docker 服務 ---${NC}"
                for i in "${!INSIDE_SERVICES[@]}"; do
                    echo " [$((i+1))] ${INSIDE_SERVICES[$i]}"
                done
                echo "---------------------------------------------------"
                echo " [A] 還原全部服務 (ALL)"
                echo "---------------------------------------------------"
                read -p "請選擇要還原的服務編號 (多選請用空格隔開，例如: 1 3 或 A): " r_choice

                TO_RESTORE=()
                if [[ "$r_choice" =~ ^[Aa]$ ]]; then
                    TO_RESTORE=("${INSIDE_SERVICES[@]}")
                else
                    for num in $r_choice; do
                        if [[ "$num" =~ ^[0-9]+$ ]] && [ "$num" -ge 1 ] && [ "$num" -le "${#INSIDE_SERVICES[@]}" ]; then
                            TO_RESTORE+=("${INSIDE_SERVICES[$((num-1))]}")
                        fi
                    done
                fi

                TO_RESTORE=($(echo "${TO_RESTORE[@]}" | tr ' ' '\n' | sort -u | tr '\n' ' '))

                if [ ${#TO_RESTORE[@]} -eq 0 ]; then
                    echo -e "${RED}❌ 未選擇任何服務，已取消還原。${NC}"
                    pause_prompt
                    continue
                fi

                FILE_SIZE=$(du -h "$SELECTED_FILE" | awk '{print $1}')
                echo -e "\n${YELLOW}=== 還原操作二次確認 ===${NC}"
                echo -e " 📦 備份來源檔: ${GREEN}$SELECTED_FILE${NC} ($FILE_SIZE)"
                echo -e " 🎯 準備還原服務: ${GREEN}${TO_RESTORE[*]}${NC}"
                echo -e " 📂 目標資料夾: ${GREEN}$DOCKER_DATA_DIR${NC}"
                echo -e "${RED}⚠️ 注意：若 $DOCKER_DATA_DIR 下存在同名資料夾，數據將會被覆蓋！${NC}"
                read -p "確定要開始解壓還原嗎？(y/N): " confirm_restore

                if [[ ! "$confirm_restore" =~ ^[Yy]$ ]]; then
                    echo -e "${YELLOW}已取消還原操作。${NC}"
                    pause_prompt
                    continue
                fi

                echo -e "${BLUE}正在精準解壓選定的服務到 $DOCKER_DATA_DIR ...${NC}"
                mkdir -p "$DOCKER_DATA_DIR"

                EXTRACT_ARGS=()
                for s in "${TO_RESTORE[@]}"; do
                    EXTRACT_ARGS+=("$s")
                done

                tar -xzvf "$SELECTED_FILE" -C "$DOCKER_DATA_DIR" "${EXTRACT_ARGS[@]}"
                
                if [ $? -eq 0 ]; then
                    echo -e "${GREEN}✓ 選定服務已成功解壓！${NC}"
                    
                    read -p "是否立即自動檢測並啟動已還原服務的 Compose？(Y/n): " start_restored
                    if [[ ! "$start_restored" =~ ^[Nn]$ ]]; then
                        echo -e "${BLUE}正在啟動服務...${NC}"
                        for s in "${TO_RESTORE[@]}"; do
                            R_DIR="$DOCKER_DATA_DIR/$s"
                            if [ -f "$R_DIR/docker-compose.yml" ] || [ -f "$R_DIR/docker-compose.yaml" ]; then
                                (cd "$R_DIR" && docker compose up -d)
                                echo -e "${GREEN}✓ $s 服務已啟動！${NC}"
                            fi
                        done
                    fi
                else
                    echo -e "${RED}❌ 解壓失敗，請檢查備份檔格式或資料夾名稱。${NC}"
                fi
                pause_prompt
                ;;

            3)
                if check_and_install_rclone; then
                    rclone config
                fi
                pause_prompt
                ;;

            0) break ;;
        esac
    done
}

# 8. 系統效能與網絡速測
test_performance() {
    while true; do
        clear
        echo -e "${BLUE}=== 8. 系統效能與網絡速測 ===${NC}"
        echo " [1] 測試硬碟 I/O 與 CPU 性能"
        echo " [2] 全球網絡下載速測"
        echo " [3] 執行 YABS 完整效能測試 (需時較長)"
        echo " [4] 🚀 一鍵執行全套測試 (1 + 2 + 3)"
        echo " [0] 返回主選單"
        read -p "請選擇 [0-4]: " test_choice

        case $test_choice in
            1)
                echo -e "${YELLOW}--- 硬碟 I/O 寫入測試 ---${NC}"
                dd if=/dev/zero of=/tmp/test.img bs=1M count=1000 conv=fdatasync status=progress
                rm -f /tmp/test.img
                echo -e "${YELLOW}--- CPU 單/多核效能測試 ---${NC}"
                sysbench cpu --threads=2 run
                pause_prompt
                ;;
            2)
                echo -e "${YELLOW}--- 網絡下載速測 (多節點) ---${NC}"
                curl -sL https://raw.githubusercontent.com/sivel/speedtest-cli/master/speedtest.py | python3 -
                pause_prompt
                ;;
            3)
                echo -e "${YELLOW}--- 正在啟動 YABS 測試 ---${NC}"
                curl -sL yabs.sh | bash
                pause_prompt
                ;;
            4)
                echo -e "${GREEN}=== 啟動一鍵全套測試 ===${NC}"
                echo -e "${YELLOW}[1/3] 測試硬碟 I/O 與 CPU...${NC}"
                dd if=/dev/zero of=/tmp/test.img bs=1M count=1000 conv=fdatasync status=progress
                rm -f /tmp/test.img
                sysbench cpu --threads=2 run
                echo -e "${YELLOW}[2/3] 測試網絡下載速度...${NC}"
                curl -sL https://raw.githubusercontent.com/sivel/speedtest-cli/master/speedtest.py | python3 -
                echo -e "${YELLOW}[3/3] 執行 YABS 測試...${NC}"
                curl -sL yabs.sh | bash
                echo -e "${GREEN}✓ 全套效能測試完畢！${NC}"
                pause_prompt
                ;;
            0) break ;;
        esac
    done
}

# 9. Docker 服務管理與系統垃圾清理
manage_docker_and_clean() {
    while true; do
        clear
        echo -e "${BLUE}=== 9. Docker 服務管理與系統垃圾清理 ===${NC}"
        echo " [1] 查看所有 Docker 容器運行狀態 (docker ps -a)"
        echo " [2] 查看指定 Docker 容器日誌 (Logs)"
        echo " [3] 重啟指定 Docker 容器"
        echo " [4] 清理 Docker 懸空映像檔、快取與廢棄數據卷"
        echo " [5] 清理 APT 套件快取與舊系統日誌 (/var/log)"
        echo " [6] 🧹 一鍵執行全套深度垃圾清理 (Docker + System)"
        echo " [0] 返回主選單"
        read -p "請選擇 [0-6]: " clean_choice

        case $clean_choice in
            1)
                docker ps -a
                pause_prompt
                ;;
            2)
                docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"
                read -p "請輸入容器名稱: " c_name
                [ -n "$c_name" ] && docker logs --tail 100 "$c_name"
                pause_prompt
                ;;
            3)
                docker ps --format "table {{.Names}}\t{{.Status}}"
                read -p "請輸入要重啟的容器名稱: " c_name
                [ -n "$c_name" ] && docker restart "$c_name" && echo -e "${GREEN}✓ 容器已重啟${NC}"
                pause_prompt
                ;;
            4)
                read -p "確定清理無用 Docker 快取與懸空 Image？(y/N): " confirm_dk
                if [[ "$confirm_dk" =~ ^[Yy]$ ]]; then
                    docker system prune -af --volumes
                    echo -e "${GREEN}✓ Docker 垃圾清理完成${NC}"
                fi
                pause_prompt
                ;;
            5)
                echo -e "${YELLOW}正在清理系統快取...${NC}"
                apt-get clean && apt-get autoclean && apt-get autoremove -y
                journalctl --vacuum-time=3d
                echo -e "${GREEN}✓ 系統日誌與快取清理完成${NC}"
                pause_prompt
                ;;
            6)
                read -p "確定執行全套深度清理？(y/N): " confirm_all
                if [[ "$confirm_all" =~ ^[Yy]$ ]]; then
                    apt-get clean && apt-get autoclean && apt-get autoremove -y
                    journalctl --vacuum-time=3d
                    docker system prune -af --volumes
                    echo -e "${GREEN}✓ 全套深度清理完成！${NC}"
                fi
                pause_prompt
                ;;
            0) break ;;
        esac
    done
}

# 10. SWAP 虛擬記憶體管理
manage_swap() {
    while true; do
        clear
        echo -e "${BLUE}=== 10. SWAP 虛擬記憶體動態管理 ===${NC}"
        echo " [1] 查看當前 SWAP 狀態"
        echo " [2] 設定/擴充 SWAP (1GB / 2GB / 4GB / 自訂)"
        echo " [3] 關閉並刪除 SWAP"
        echo " [0] 返回主選單"
        read -p "請選擇 [0-3]: " swap_choice

        case $swap_choice in
            1)
                free -h
                swapon --show
                pause_prompt
                ;;
            2)
                read -p "請選擇 SWAP 大小 (MB) [例如 1024 / 2048 / 4096]: " SWAP_SIZE
                if [ -n "$SWAP_SIZE" ]; then
                    swapoff -a
                    sed -i '/swapfile/d' /etc/fstab
                    rm -f /swapfile
                    
                    fallocate -l ${SWAP_SIZE}M /swapfile || dd if=/dev/zero of=/swapfile bs=1M count=$SWAP_SIZE
                    chmod 600 /swapfile
                    mkswap /swapfile
                    swapon /swapfile
                    echo '/swapfile none swap sw 0 0' >> /etc/fstab
                    echo -e "${GREEN}✓ 已成功創建並啟用 ${SWAP_SIZE}MB SWAP${NC}"
                fi
                pause_prompt
                ;;
            3)
                swapoff -a
                sed -i '/swapfile/d' /etc/fstab
                rm -f /swapfile
                echo -e "${GREEN}✓ SWAP 已關閉並完全刪除${NC}"
                pause_prompt
                ;;
            0) break ;;
        esac
    done
}

# 11. UFW 防火牆常用 Port 管理 (含授權安裝機制)
manage_ufw_ports() {
    check_and_install_ufw
    if [ $? -ne 0 ]; then
        pause_prompt
        return
    fi

    while true; do
        clear
        echo -e "${BLUE}=== 11. UFW 防火牆常用 Port 管理 ===${NC}"
        echo " [1] 查看當前防火牆狀態與開放 Port"
        echo " [2] 一鍵開放常用 Port (80, 443, 8080, 9000)"
        echo " [3] 手動開放指定 Port"
        echo " [4] 關閉指定 Port"
        echo " [5] 啟用 UFW 防火牆 (ufw enable)"
        echo " [6] 停用 UFW 防火牆 (ufw disable)"
        echo " [0] 返回主選單"
        read -p "請選擇 [0-6]: " ufw_choice

        case $ufw_choice in
            1)
                ufw status verbose
                pause_prompt
                ;;
            2)
                ufw allow 80/tcp && ufw allow 443/tcp && ufw allow 8080/tcp && ufw allow 9000/tcp
                ufw reload
                echo -e "${GREEN}✓ 常用 Port (80, 443, 8080, 9000) 已開放${NC}"
                pause_prompt
                ;;
            3)
                read -p "請輸入要開放的 Port (如 8080 或 8080/tcp): " p_open
                if [ -n "$p_open" ]; then
                    ufw allow $p_open
                    ufw reload
                    echo -e "${GREEN}✓ 已開放 Port $p_open${NC}"
                fi
                pause_prompt
                ;;
            4)
                read -p "請輸入要關閉的 Port: " p_close
                if [ -n "$p_close" ]; then
                    ufw delete allow $p_close
                    ufw reload
                    echo -e "${GREEN}✓ 已關閉 Port $p_close${NC}"
                fi
                pause_prompt
                ;;
            5)
                ufw enable
                pause_prompt
                ;;
            6)
                ufw disable
                pause_prompt
                ;;
            0) break ;;
        esac
    done
}

# 12. 系統時區選擇與 NTP 對時
manage_timezone() {
    while true; do
        clear
        NOW_TIME=$(date)
        echo -e "${BLUE}=== 12. 系統時區選擇與 NTP 對時 ===${NC}"
        echo -e "當前系統時間: ${YELLOW}${NOW_TIME}${NC}"
        echo "---------------------------------------------------"
        echo " [1] 切換至 香港/北京 時區 (Asia/Hong_Kong)"
        echo " [2] 切換至 新加坡 時區 (Asia/Singapore)"
        echo " [3] 切換至 美國東部 時區 (US/Eastern)"
        echo " [4] 切換至 美國西部 時區 (US/Pacific)"
        echo " [5] 切換至 UTC 標準時間"
        echo " [6] 強制重啟 NTP 服務進行對時"
        echo " [0] 返回主選單"
        read -p "請選擇 [0-6]: " tz_choice

        case $tz_choice in
            1) timedatectl set-timezone Asia/Hong_Kong ;;
            2) timedatectl set-timezone Asia/Singapore ;;
            3) timedatectl set-timezone US/Eastern ;;
            4) timedatectl set-timezone US/Pacific ;;
            5) timedatectl set-timezone UTC ;;
            6) 
                systemctl restart systemd-timesyncd
                echo -e "${GREEN}✓ 已強制與 NTP 伺服器對時${NC}"
                ;;
            0) break ;;
        esac
        if [ "$tz_choice" -ge 1 ] && [ "$tz_choice" -le 5 ]; then
            echo -e "${GREEN}✓ 當前時間已切換為：$(date)${NC}"
        fi
        pause_prompt
    done
}

# 13. BBR 網絡加速管理
setup_bbr() {
    while true; do
        clear
        CUR_KERNEL=$(uname -r)
        CUR_CC=$(sysctl net.ipv4.tcp_congestion_control 2>/dev/null | awk '{print $3}')
        CUR_QDISC=$(sysctl net.core.default_qdisc 2>/dev/null | awk '{print $3}')
        
        echo -e "${BLUE}=== 13. BBR 網絡加速管理 ===${NC}"
        echo -e "核心版本: ${YELLOW}${CUR_KERNEL:-未知}${NC}"
        echo -e "當前擁塞算法: ${YELLOW}${CUR_CC:-預設}${NC}"
        echo -e "當前隊列算法: ${YELLOW}${CUR_QDISC:-預設}${NC}"
        echo "---------------------------------------------------"
        echo " [1] 開啟 原版 BBR + fq"
        echo " [2] 恢復預設 擁塞算法 (cubic)"
        echo " [0] 返回主選單"
        read -p "請選擇 [0-2]: " bbr_choice

        case $bbr_choice in
            1)
                if echo "$CUR_CC" | grep -q "bbr"; then
                    echo -e "${GREEN}✓ BBR 已經在啟用狀態，無需重複開啟！${NC}"
                else
                    echo -e "${YELLOW}正在開啟 BBR + fq...${NC}"
                    sed -i '/net.core.default_qdisc/d' /etc/sysctl.conf
                    sed -i '/net.ipv4.tcp_congestion_control/d' /etc/sysctl.conf
                    echo "net.core.default_qdisc=fq" >> /etc/sysctl.conf
                    echo "net.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.conf
                    sysctl -p
                    echo -e "${GREEN}✓ BBR 網絡加速已成功開啟！${NC}"
                fi
                pause_prompt
                ;;
            2)
                echo -e "${YELLOW}正在恢復預設 cubic 算法...${NC}"
                sed -i '/net.core.default_qdisc/d' /etc/sysctl.conf
                sed -i '/net.ipv4.tcp_congestion_control/d' /etc/sysctl.conf
                echo "net.ipv4.tcp_congestion_control=cubic" >> /etc/sysctl.conf
                sysctl -p
                echo -e "${GREEN}✓ 已恢復預設 cubic 算法！${NC}"
                pause_prompt
                ;;
            0) break ;;
        esac
    done
}

# 主選單
main_menu() {
    while true; do
        clear
        echo -e "${GREEN}===================================================${NC}"
        echo -e "${GREEN}       Boss 的 VPS 智囊管理腳本 v2.8.0             ${NC}"
        echo -e "${GREEN}===================================================${NC}"
        echo " [1]  🚀 基礎初始化 (安裝 Docker / 建立 docker-data)"
        echo " [2]  🔒 SSH Port 管理 (獨立改 Port / 雙 Port 防鎖死)"
        echo " [3]  🚫 關閉 SSH 密碼登入 (帶 Key 強制防呆)"
        echo " [4]  🔑 SSH Key 獨立管理 (增/刪/查/一鍵還原)"
        echo " [5]  🛡️ 配置 Fail2ban 防爆破 (帶 IP 白名單)"
        echo " [6]  📲 部署 Telegram SSH 登入監控 (高級版)"
        echo " [7]  📦 Docker 服務搬機、雲端同步 (Rclone) 與還原"
        echo " [8]  🧪 系統效能與網絡速測 (支援一鍵全套)"
        echo " [9]  🐳 Docker 服務管理與系統垃圾清理"
        echo " [10] 🔄 SWAP 虛擬記憶體動態管理"
        echo " [11] 🧱 UFW 防火牆常用 Port 管理"
        echo " [12] ⏰ 系統時區選擇與 NTP 對時"
        echo " [13] 📜 BBR 網絡加速管理 (可檢測/切換)"
        echo " [0]  🚪 退出 (Exit)"
        echo -e "${GREEN}===================================================${NC}"
        read -p "請選擇操作 [0-13]: " choice

        case $choice in
            1) init_system ;;
            2) setup_ssh_port ;;
            3) disable_ssh_password ;;
            4) manage_ssh_keys ;;
            5) setup_fail2ban ;;
            6) setup_tg_monitor ;;
            7) backup_and_migrate ;;
            8) test_performance ;;
            9) manage_docker_and_clean ;;
            10) manage_swap ;;
            11) manage_ufw_ports ;;
            12) manage_timezone ;;
            13) setup_bbr ;;
            0) echo -e "${GREEN}已退出。${NC}"; exit 0 ;;
            *) echo -e "${RED}無效選項！${NC}"; sleep 1 ;;
        esac
    done
}

main_menu

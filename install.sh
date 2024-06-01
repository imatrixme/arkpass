#!/bin/bash

SERVICE_NAME=trojan-rust
CONFIG_FILE=./config/config.json
EXECUTABLE=./trojan-rust
PID_FILE=./${SERVICE_NAME}.pid
TLS_DIR=./config/tls
TOOLS_DIR=./tools
ACME_DIR=$TOOLS_DIR/acme
ACME_SH=$ACME_DIR/acme.sh
EMAIL=sslmatrix@gmail.com
REPO_URL=https://github.com/imatrixme/bypass.git

# 获取脚本的绝对路径
SCRIPT_DIR=$(cd $(dirname $0) && pwd)
TLS_DIR_ABS=$SCRIPT_DIR/$TLS_DIR

function install_cron_if_needed {
    if ! command -v crontab &> /dev/null; then
        echo "cron is not installed. Installing..."
        sudo apt-get update
        sudo apt-get install -y cron
        sudo systemctl enable cron
        sudo systemctl start cron
        echo "cron installed and started."
    fi
}

function install_git_if_needed {
    if ! command -v git &> /dev/null; then
        echo "git is not installed. Installing..."
        sudo apt-get update
        sudo apt-get install -y git
        echo "git installed."
    fi
}

function install_acme_sh {
    if [ ! -f "$ACME_SH" ]; then
        echo "Downloading acme.sh..."
        install_git_if_needed
        git clone https://github.com/acmesh-official/acme.sh.git $ACME_DIR
        cd $ACME_DIR
        ./acme.sh --install --home $ACME_DIR --accountemail $EMAIL
        cd -
    else
        echo "acme.sh already installed."
    fi
}

function download_trojan_rust {
    if [ ! -f "$EXECUTABLE" ]; then
        echo "$EXECUTABLE not found. Downloading from $REPO_URL..."
        install_git_if_needed
        git clone $REPO_URL
        cd bypass
        make
        mv trojan-rust ..
        cd ..
        rm -rf bypass
        echo "$EXECUTABLE downloaded and built."
    else
        echo "$EXECUTABLE already exists."
    fi
}

function generate_config {
    if [ ! -f "$CONFIG_FILE" ]; then
        echo "$CONFIG_FILE not found. Generating..."
        mkdir -p $(dirname "$CONFIG_FILE")
        cat > "$CONFIG_FILE" << EOL
{
    "inbound": {
        "mode": "TCP",
        "protocol": "TROJAN",
        "address": "0.0.0.0",
        "port": 9300,
        "secret": "79cfdefa-aa2f-4722-ab3f-c94c67c0d500",
        "tls": {
            "cert_path": "$TLS_DIR_ABS/domain.crt",
            "key_path": "$TLS_DIR_ABS/domain.key"
        }
    },
    "outbound": {
        "mode": "DIRECT",
        "protocol": "DIRECT"
    }
}
EOL
        echo "$CONFIG_FILE generated."
    else
        echo "$CONFIG_FILE already exists."
    fi
}

function setup_tls_dir {
    if [ ! -d "$TLS_DIR" ]; then
        echo "Creating $TLS_DIR directory..."
        mkdir -p "$TLS_DIR"
        echo "$TLS_DIR directory created."
    else
        echo "$TLS_DIR directory already exists."
    fi
}

function setup_autostart {
    install_cron_if_needed

    # Remove any existing cron job for this script
    crontab -l | grep -v "$(pwd)/$EXECUTABLE" | crontab -

    # Add new cron job for autostart
    (crontab -l ; echo "@reboot $(pwd)/$EXECUTABLE -c $(pwd)/$CONFIG_FILE > /dev/null 2>&1 &") | crontab -
    echo "Autostart configured."
}

function remove_autostart {
    # Remove any existing cron job for this script
    crontab -l | grep -v "$(pwd)/$EXECUTABLE" | crontab -
    echo "Autostart removed."
}

function start_service {
    if [ -f "$PID_FILE" ]; then
        PID=$(cat "$PID_FILE")
        if ps -p $PID > /dev/null; then
            echo "$SERVICE_NAME is already running."
            return
        else
            rm "$PID_FILE"
        fi
    fi
    echo "Starting $SERVICE_NAME..."
    nohup $(pwd)/$EXECUTABLE -c $(pwd)/$CONFIG_FILE > /dev/null 2>&1 &
    echo $! > "$PID_FILE"
    setup_autostart
    echo "$SERVICE_NAME started."
}

function stop_service {
    if [ -f "$PID_FILE" ]; then
        PID=$(cat "$PID_FILE")
        echo "Stopping $SERVICE_NAME..."
        kill $PID
        rm "$PID_FILE"
        remove_autostart
        echo "$SERVICE_NAME stopped."
    else
        echo "$SERVICE_NAME is not running."
    fi
}

function restart_service {
    stop_service
    start_service
}

function setup_scheduled_restart {
    read -p "请输入重启时间 (24小时制, 格式: HH:MM): " restart_time
    cron_time=$(date -d "$restart_time" +"%M %H * * *")
    
    install_cron_if_needed

    # Remove any existing cron job for scheduled restart
    crontab -l | grep -v "$(pwd)/$0 restart" | crontab -

    # Add new cron job for scheduled restart
    (crontab -l ; echo "$cron_time $(pwd)/$0 restart > /dev/null 2>&1") | crontab -
    echo "Scheduled restart configured at $restart_time."
}

function remove_scheduled_restart {
    # Remove any existing cron job for scheduled restart
    crontab -l | grep -v "$(pwd)/$0 restart" | crontab -
    echo "Scheduled restart removed."
}

function check_certificate {
    domain=$1
    crt_file="$TLS_DIR/$domain.crt"
    key_file="$TLS_DIR/$domain.key"

    if [ ! -f "$crt_file" ] || [ ! -f "$key_file" ]; then
        echo "证书文件不存在，开始申请新证书..."
        return 1
    fi

    openssl x509 -enddate -noout -in "$crt_file" | sed 's/notAfter=//g' | xargs -I {} date -d {} +%s > enddate.txt
    openssl x509 -startdate -noout -in "$crt_file" | sed 's/notBefore=//g' | xargs -I {} date -d {} +%s > startdate.txt

    end_date=$(cat enddate.txt)
    start_date=$(cat startdate.txt)
    current_date=$(date +%s)

    remaining_days=$(( (end_date - current_date) / 86400 ))
    valid_days=$(( (end_date - start_date) / 86400 ))

    if [ $current_date -lt $end_date ]; then
        echo "证书未过期。"
        echo "域名: $domain"
        echo "CA: Let's Encrypt"
        echo "申请日期: $(date -d @$start_date '+%Y-%m-%d %H:%M:%S')"
        echo "有效期: $valid_days 天"
        echo "过期时间: $(date -d @$end_date '+%Y-%m-%d %H:%M:%S')"
        echo "剩余时间: $remaining_days 天"
        read -p "是否继续申请新证书？ (y/n): " choice
        case "$choice" in
            y|Y )
                return 1
                ;;
            * )
                return 0
                ;;
        esac
    else
        echo "证书已过期，开始申请新证书..."
        return 1
    fi
}

function update_certificate {
    read -p "请输入域名: " domain
    check_certificate $domain
    if [ $? -eq 1 ]; then
        $ACME_SH --set-default-ca --server letsencrypt
        $ACME_SH --issue -d $domain --standalone --force
        if [ $? -eq 0 ]; then
            $ACME_SH --install-cert -d $domain \
                --cert-file $TLS_DIR_ABS/$domain.crt \
                --key-file $TLS_DIR_ABS/$domain.key
            echo "证书已更新并安装到 $TLS_DIR 目录下。"
            read -p "是否要替换配置文件中的证书路径？ (y/n): " replace_choice
            if [[ $replace_choice == "y" || $replace_choice == "Y" || -z $replace_choice ]]; then
                sed -i "s|\"cert_path\": \".*\"|\"cert_path\": \"$TLS_DIR_ABS/$domain.crt\"|" "$CONFIG_FILE"
                sed -i "s|\"key_path\": \".*\"|\"key_path\": \"$TLS_DIR_ABS/$domain.key\"|" "$CONFIG_FILE"
                echo "配置文件中的证书路径已更新。"
            else
                echo "配置文件中的证书路径未更新。"
            fi
        else
            echo "证书申请失败，请检查日志。"
        fi
    fi
}

function uninstall_reinstall {
    stop_service
    echo "Removing trojan-rust and config files..."
    rm -f "$EXECUTABLE"
    rm -f "$CONFIG_FILE"
    download_trojan_rust
    generate_config
    echo "Reinstallation completed."
}

function get_latest_domain {
    crt_files=($TLS_DIR/*.crt)
    if [ ${#crt_files[@]} -eq 0 ]; then
        echo "没有找到证书文件。"
        exit 1
    fi
    latest_crt=$(ls -t $TLS_DIR/*.crt | head -n 1)
    latest_domain=$(basename $latest_crt .crt)
    echo $latest_domain
}

function view_account {
    secret=$(jq -r '.inbound.secret' $CONFIG_FILE)
    domain=$(get_latest_domain)
    port=$(jq -r '.inbound.port' $CONFIG_FILE)
    echo "Account Information:"
    jq . $CONFIG_FILE
    echo ""
    echo "trojan://$secret@$domain:$port?peer=$domain&sni=$domain&tls-verification=1&cert=1&tls13=1&udp=1&tfo=1#TrojanRust"
    echo ""
}

function change_account {
    new_secret=$(cat /proc/sys/kernel/random/uuid)
    jq --arg new_secret "$new_secret" '.inbound.secret = $new_secret' $CONFIG_FILE > tmp.$$.json && mv tmp.$$.json $CONFIG_FILE
    echo "账号已更新为: $new_secret"
    restart_service
    view_account
}

function change_port {
    new_port=$(shuf -i 9000-9999 -n 1)
    jq --argjson new_port "$new_port" '.inbound.port = $new_port' $CONFIG_FILE > tmp.$$.json && mv tmp.$$.json $CONFIG_FILE
    echo "端口已更新为: $new_port"
    restart_service
    view_account
}

function show_menu {
    echo "1. 启动"
    echo "2. 停止"
    echo "3. 重启"
    echo "--------------------"
    echo "4. 配置开机自启动"
    echo "5. 取消开机自启动"
    echo "6. 配置定时重启"
    echo "7. 取消定时重启"
    echo "--------------------"
    echo "8. 更新证书"
    echo "--------------------"
    echo "9. 卸载重装"
    echo "--------------------"
    echo "10. 查看账号"
    echo "11. 变更账号"
    echo "12. 变更端口"
    echo "--------------------"
    echo "13. 退出"
}

install_acme_sh
setup_tls_dir
download_trojan_rust
generate_config

while true; do
    show_menu
    read -p "请选择一个选项: " choice
    case $choice in
        1)
            start_service
            ;;
        2)
            stop_service
            ;;
        3)
            restart_service
            ;;
        4)
            setup_autostart
            ;;
        5)
            remove_autostart
            ;;
        6)
            setup_scheduled_restart
            ;;
        7)
            remove_scheduled_restart
            ;;
        8)
            update_certificate
            ;;
        9)
            uninstall_reinstall
            ;;
        10)
            view_account
            ;;
        11)
            change_account
            ;;
        12)
            change_port
            ;;
        13)
            exit 0
            ;;
        *)
            echo "无效选项，请重新选择。"
            ;;
    esac
done

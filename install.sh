#!/bin/bash
# Универсальный установщик Xray VLESS+REALITY + AmneziaWG + SplitHTTP + Telegram-бот
# Запуск: sudo bash install.sh

set -e
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
echo -e "${GREEN}=== Установка VPN-сервера с тремя протоколами ===${NC}"

if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}Пожалуйста, запустите скрипт с правами root (sudo).${NC}"; exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ---------- 1. Системные пакеты ----------
echo -e "${YELLOW}[1/12] Установка системных пакетов...${NC}"
apt update
apt install -y curl wget unzip git jq python3 python3-pip python3-venv qrencode ufw openssl build-essential linux-headers-$(uname -r) wireguard-tools

# ---------- 2. Xray ----------
echo -e "${YELLOW}[2/12] Установка Xray...${NC}"
if ! command -v xray &>/dev/null; then
    bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install
else
    echo "Xray уже установлен."
fi

# ---------- 3. AmneziaWG ----------
echo -e "${YELLOW}[3/12] Установка AmneziaWG...${NC}"
AWG_INSTALLED=false

# Проверяем, есть ли модуль ядра amneziawg
if lsmod | grep -q amneziawg || modprobe amneziawg 2>/dev/null; then
    echo "Модуль ядра AmneziaWG уже загружен."
    AWG_INSTALLED=true
else
    # Пытаемся собрать модуль ядра из исходников
    echo "Попытка сборки модуля ядра AmneziaWG..."
    TMPDIR=$(mktemp -d)
    cd "$TMPDIR"
    git clone https://github.com/amnezia-vpn/amneziawg-linux-kernel-module.git
    cd amneziawg-linux-kernel-module
    if make && make install; then
        modprobe amneziawg
        AWG_INSTALLED=true
        echo -e "${GREEN}Модуль ядра AmneziaWG успешно установлен.${NC}"
    else
        echo -e "${YELLOW}Не удалось собрать модуль ядра. Переключаемся на userspace-демон...${NC}"
        cd "$TMPDIR"
        # Устанавливаем Go, если отсутствует
        if ! command -v go &>/dev/null; then
            wget -q https://go.dev/dl/go1.24.0.linux-amd64.tar.gz
            tar -C /usr/local -xzf go1.24.0.linux-amd64.tar.gz
            echo 'export PATH=$PATH:/usr/local/go/bin' >> ~/.bashrc
            export PATH=$PATH:/usr/local/go/bin
        fi
        git clone https://github.com/amnezia-vpn/amneziawg-go.git
        cd amneziawg-go
        make
        cp amneziawg-go /usr/bin/
        ln -sf /usr/bin/amneziawg-go /usr/bin/awg
        AWG_INSTALLED=true
    fi
    cd ~
    rm -rf "$TMPDIR"
fi

if ! $AWG_INSTALLED; then
    echo -e "${RED}Не удалось установить AmneziaWG. Продолжаем без него.${NC}"
fi

# ---------- 4. Настройка AmneziaWG (если установлен) ----------
if $AWG_INSTALLED; then
    echo -e "${YELLOW}[4/12] Настройка AmneziaWG...${NC}"
    # Генерируем ключи сервера
    SERVER_PRIVKEY=$(awg genkey)
    SERVER_PUBKEY=$(echo "$SERVER_PRIVKEY" | awg pubkey)
    LISTEN_PORT=51820
    SERVER_WG_IP="10.9.0.1"

    mkdir -p /etc/amnezia
    cat > /etc/amnezia/amneziawg.conf <<EOF
[Interface]
PrivateKey = $SERVER_PRIVKEY
Address = $SERVER_WG_IP/24
ListenPort = $LISTEN_PORT
PostUp = iptables -A FORWARD -i %i -j ACCEPT; iptables -t nat -A POSTROUTING -o ens3 -j MASQUERADE
PostDown = iptables -D FORWARD -i %i -j ACCEPT; iptables -t nat -D POSTROUTING -o ens3 -j MASQUERADE
EOF

    # Устанавливаем awg-quick и systemd-сервис
    cat > /usr/bin/awg-quick << 'EOF'
#!/bin/bash
INTERFACE="$1"; CONFIG="/etc/amnezia/${INTERFACE}.conf"
case "$2" in
    up)
        ip link add "$INTERFACE" type wireguard
        awg setconf "$INTERFACE" "$CONFIG"
        ip link set "$INTERFACE" up
        ;;
    down)
        ip link del "$INTERFACE"
        ;;
    *) echo "Usage: $0 <interface> [up|down]"; exit 1;;
esac
EOF
    chmod +x /usr/bin/awg-quick

    cat > /etc/systemd/system/awg-quick@.service <<EOF
[Unit]
Description=AmneziaWG Quick for %i
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/bin/awg-quick up %i
ExecStop=/usr/bin/awg-quick down %i

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable --now awg-quick@amneziawg
    echo -e "${GREEN}AmneziaWG запущен на порту $LISTEN_PORT.${NC}"
else
    SERVER_PUBKEY=""
    LISTEN_PORT=""
fi

# ---------- 5. Генерация ключей REALITY ----------
echo -e "${YELLOW}[5/12] Генерация ключей REALITY...${NC}"
XRAY_KEYS_OUTPUT=$(xray x25519)
PRIVATE_KEY=$(echo "$XRAY_KEYS_OUTPUT" | grep -E 'Private[ ]?Key:' | awk '{print $NF}')
PUBLIC_KEY=$(echo "$XRAY_KEYS_OUTPUT" | grep -E 'Public[ ]?Key:|Password[ ]?\(PublicKey\):' | awk '{print $NF}')
SHORT_ID=$(openssl rand -hex 8)

if [ -z "$PRIVATE_KEY" ] || [ -z "$PUBLIC_KEY" ]; then
    echo -e "${RED}Не удалось извлечь ключи REALITY.${NC}"; exit 1
fi

# ---------- 6. Создание конфигурации Xray ----------
echo -e "${YELLOW}[6/12] Создание config.json Xray...${NC}"
CONFIG_FILE="/usr/local/etc/xray/config.json"
cp "$SCRIPT_DIR/config.json.example" "$CONFIG_FILE"
sed -i "s/PRIVATE_KEY_PLACEHOLDER/$PRIVATE_KEY/g" "$CONFIG_FILE"
sed -i "s/SHORT_ID_PLACEHOLDER/$SHORT_ID/g" "$CONFIG_FILE"
chmod 644 "$CONFIG_FILE"

# ---------- 7. Запуск Xray ----------
echo -e "${YELLOW}[7/12] Проверка и запуск Xray...${NC}"
if ! xray -test -config "$CONFIG_FILE"; then
    echo -e "${RED}Ошибка в конфигурации Xray!${NC}"; exit 1
fi
systemctl restart xray
systemctl enable xray
sleep 2
if systemctl is-active --quiet xray; then
    echo -e "${GREEN}Xray запущен.${NC}"
else
    echo -e "${RED}Xray не запустился!${NC}"; exit 1
fi

# ---------- 8. NAT и IP forward ----------
echo -e "${YELLOW}[8/12] Настройка NAT...${NC}"
IFACE=$(ip route | grep default | awk '{print $5}')
iptables -t nat -A POSTROUTING -o "$IFACE" -j MASQUERADE
apt install -y iptables-persistent
netfilter-persistent save
sysctl -w net.ipv4.ip_forward=1

# ---------- 9. Python-окружение бота ----------
echo -e "${YELLOW}[9/12] Установка Python-окружения...${NC}"
BOT_DIR="/opt/xray-bot"
mkdir -p "$BOT_DIR"
cp "$SCRIPT_DIR/bot.py" "$BOT_DIR/"
cp "$SCRIPT_DIR/cleanup_expired.py" "$BOT_DIR/"
cp "$SCRIPT_DIR/config.py.example" "$BOT_DIR/config.py"
cp "$SCRIPT_DIR/requirements.txt" "$BOT_DIR/"

cd "$BOT_DIR"
python3 -m venv venv
source venv/bin/activate
pip install --upgrade pip
pip install -r requirements.txt

# Запрос данных пользователя
echo -e "${YELLOW}Введите данные для Telegram-бота:${NC}"
read -p "Токен бота: " BOT_TOKEN
read -p "Ваш Telegram ID: " ADMIN_ID
SERVER_IP=$(curl -s ifconfig.co)
read -p "Публичный IP сервера [$SERVER_IP]: " INPUT_IP
SERVER_IP=${INPUT_IP:-$SERVER_IP}

# Подстановка в config.py
sed -i "s/^TELEGRAM_BOT_TOKEN = .*/TELEGRAM_BOT_TOKEN = \"$BOT_TOKEN\"/" config.py
sed -i "s/^ALLOWED_USERS = .*/ALLOWED_USERS = {$ADMIN_ID}/" config.py
sed -i "s/^SERVER_IP = .*/SERVER_IP = \"$SERVER_IP\"/" config.py
sed -i "s/^PUBLIC_KEY = .*/PUBLIC_KEY = \"$PUBLIC_KEY\"/" config.py
sed -i "s/^SHORT_ID = .*/SHORT_ID = \"$SHORT_ID\"/" config.py
sed -i "s/^SPLIT_PORT = .*/SPLIT_PORT = 8081/" config.py
sed -i "s|^SPLIT_PATH = .*|SPLIT_PATH = \"/stream\"|" config.py
if $AWG_INSTALLED; then
    sed -i "s/^WG_SERVER_IP = .*/WG_SERVER_IP = \"$SERVER_IP\"/" config.py
    sed -i "s/^WG_PORT = .*/WG_PORT = $LISTEN_PORT/" config.py
    sed -i "s/^WG_SERVER_PUBKEY = .*/WG_SERVER_PUBKEY = \"$SERVER_PUBKEY\"/" config.py
    sed -i "s/^WG_SERVER_PRIVKEY = .*/WG_SERVER_PRIVKEY = \"$SERVER_PRIVKEY\"/" config.py
else
    # Закомментируем настройки WG, чтобы бот не пытался их использовать
    sed -i "s/^WG_/#WG_/" config.py
fi

# ---------- 10. Systemd-сервисы ----------
echo -e "${YELLOW}[10/12] Установка systemd-сервисов...${NC}"
cp "$SCRIPT_DIR/xray-bot.service" /etc/systemd/system/
cp "$SCRIPT_DIR/xray-cleanup.service" /etc/systemd/system/
cp "$SCRIPT_DIR/xray-cleanup.timer" /etc/systemd/system/

systemctl daemon-reload
systemctl enable xray-bot
systemctl restart xray-bot
systemctl enable xray-cleanup.timer
systemctl start xray-cleanup.timer

sleep 2
if systemctl is-active --quiet xray-bot; then
    echo -e "${GREEN}Бот запущен.${NC}"
else
    echo -e "${RED}Бот не запустился! Проверьте journalctl -u xray-bot${NC}"
fi

# ---------- 11. Тестирование ----------
echo -e "${YELLOW}[11/12] Автотестирование...${NC}"
echo "Проверка портов..."
ss -tulpn | grep -q ":443.*xray" && echo -e "${GREEN}✓ VLESS на 443${NC}" || echo -e "${RED}✗ порт 443${NC}"
ss -tulpn | grep -q ":8081.*xray" && echo -e "${GREEN}✓ SplitHTTP на 8081${NC}" || echo -e "${RED}✗ порт 8081${NC}"
if $AWG_INSTALLED; then
    ss -tulpn | grep -q ":51820" && echo -e "${GREEN}✓ AmneziaWG на 51820${NC}" || echo -e "${RED}✗ AmneziaWG${NC}"
fi

# ---------- 12. Итоговая информация ----------
echo -e "${GREEN}=== Установка завершена! ===${NC}"
echo "IP сервера: $SERVER_IP"
echo "Публичный ключ REALITY: $PUBLIC_KEY"
echo "ShortId: $SHORT_ID"
if $AWG_INSTALLED; then
    echo "AmneziaWG публичный ключ: $SERVER_PUBKEY"
    echo "Порт AmneziaWG: $LISTEN_PORT"
fi
echo "Конфиги Xray: $CONFIG_FILE"
echo "Каталог бота: $BOT_DIR"
echo "Для проверки: /menu в Telegram"

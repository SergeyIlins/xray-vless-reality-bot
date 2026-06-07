#!/bin/bash
# Xray VLESS+REALITY + AmneziaWG + SplitHTTP + Telegram Bot Installer
# Запуск: sudo bash install.sh

set -e
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo -e "${GREEN}=== Установка Xray, AmneziaWG и Telegram-бота ===${NC}"

if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}Пожалуйста, запустите скрипт с правами root (sudo).${NC}"
    exit 1
fi

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"

# --- 1. Установка системных зависимостей ---
echo -e "${YELLOW}[1/10] Установка пакетов...${NC}"
apt update
apt install -y curl wget unzip git jq python3 python3-pip python3-venv qrencode ufw openssl wireguard-tools

# --- 2. Установка Xray ---
echo -e "${YELLOW}[2/10] Установка Xray...${NC}"
if ! command -v xray &>/dev/null; then
    bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install
else
    echo "Xray уже установлен, пропускаем."
fi

# --- 3. Установка AmneziaWG ---
echo -e "${YELLOW}[3/10] Установка AmneziaWG...${NC}"
if ! command -v awg &>/dev/null; then
    # Добавляем репозиторий AmneziaWG
    curl -fsSL https://raw.githubusercontent.com/amnezia-vpn/amneziawg/master/install.sh | bash
else
    echo "AmneziaWG уже установлен."
fi

# --- 4. Генерация ключей REALITY ---
echo -e "${YELLOW}[4/10] Генерация ключей REALITY...${NC}"
XRAY_KEYS_OUTPUT=$(xray x25519)
PRIVATE_KEY=$(echo "$XRAY_KEYS_OUTPUT" | grep -E 'Private[ ]?Key:' | awk '{print $NF}')
PUBLIC_KEY=$(echo "$XRAY_KEYS_OUTPUT" | grep -E 'Public[ ]?Key:|Password[ ]?\(PublicKey\):' | awk '{print $NF}')
SHORT_ID=$(openssl rand -hex 8)

if [ -z "$PRIVATE_KEY" ] || [ -z "$PUBLIC_KEY" ]; then
    echo -e "${RED}Не удалось извлечь ключи REALITY.${NC}"
    exit 1
fi

echo "Приватный ключ REALITY: $PRIVATE_KEY"
echo "Публичный ключ REALITY: $PUBLIC_KEY"
echo "ShortId: $SHORT_ID"

# --- 5. Настройка AmneziaWG сервера ---
echo -e "${YELLOW}[5/10] Настройка AmneziaWG...${NC}"
# Генерируем ключи сервера
SERVER_PRIVATE_KEY=$(awg genkey)
SERVER_PUBLIC_KEY=$(echo "$SERVER_PRIVATE_KEY" | awg pubkey)
# Задаём внутреннюю сеть AmneziaWG
WG_SUBNET="10.9.0.0/24"
SERVER_WG_IP="10.9.0.1"
LISTEN_PORT="51820"

# Создаём конфигурационный файл
mkdir -p /etc/amnezia
cat > /etc/amnezia/amneziawg.conf <<EOF
[Interface]
PrivateKey = $SERVER_PRIVATE_KEY
Address = $SERVER_WG_IP/24
ListenPort = $LISTEN_PORT
PostUp = iptables -A FORWARD -i %i -j ACCEPT; iptables -t nat -A POSTROUTING -o ens3 -j MASQUERADE
PostDown = iptables -D FORWARD -i %i -j ACCEPT; iptables -t nat -D POSTROUTING -o ens3 -j MASQUERADE
EOF

systemctl enable awg-quick@amneziawg
systemctl start awg-quick@amneziawg

# --- 6. Создание конфига Xray ---
echo -e "${YELLOW}[6/10] Создание config.json для Xray...${NC}"
CONFIG_FILE="/usr/local/etc/xray/config.json"
cp "$CONFIG_FILE" "$CONFIG_FILE.bak" 2>/dev/null || true
cp "$SCRIPT_DIR/config.json.example" "$CONFIG_FILE"
sed -i "s/PRIVATE_KEY_PLACEHOLDER/$PRIVATE_KEY/g" "$CONFIG_FILE"
sed -i "s/SHORT_ID_PLACEHOLDER/$SHORT_ID/g" "$CONFIG_FILE"
chmod 644 "$CONFIG_FILE"

# --- 7. Проверка и запуск Xray ---
echo -e "${YELLOW}[7/10] Проверка конфигурации Xray...${NC}"
if ! xray -test -config "$CONFIG_FILE"; then
    echo -e "${RED}Ошибка в конфигурации Xray!${NC}"
    exit 1
fi

systemctl restart xray
systemctl enable xray
sleep 2
if systemctl is-active --quiet xray; then
    echo -e "${GREEN}Xray запущен.${NC}"
else
    echo -e "${RED}Xray не запустился!${NC}"
    exit 1
fi

# --- 8. Настройка NAT ---
echo -e "${YELLOW}[8/10] Настройка NAT...${NC}"
IFACE=$(ip route | grep default | awk '{print $5}')
iptables -t nat -A POSTROUTING -o "$IFACE" -j MASQUERADE
apt install -y iptables-persistent
netfilter-persistent save

# --- 9. Установка окружения бота ---
echo -e "${YELLOW}[9/10] Установка Python-окружения...${NC}"
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

# Запрос данных
echo -e "${YELLOW}Введите данные для Telegram-бота:${NC}"
read -p "Токен бота: " BOT_TOKEN
read -p "Ваш Telegram ID: " ADMIN_ID
SERVER_IP=$(curl -s ifconfig.co)
read -p "Публичный IP сервера [$SERVER_IP]: " INPUT_IP
SERVER_IP=${INPUT_IP:-$SERVER_IP}

# Замена в config.py
sed -i "s/^TELEGRAM_BOT_TOKEN = .*/TELEGRAM_BOT_TOKEN = \"$BOT_TOKEN\"/" config.py
sed -i "s/^ALLOWED_USERS = .*/ALLOWED_USERS = {$ADMIN_ID}/" config.py
sed -i "s/^SERVER_IP = .*/SERVER_IP = \"$SERVER_IP\"/" config.py
sed -i "s/^PUBLIC_KEY = .*/PUBLIC_KEY = \"$PUBLIC_KEY\"/" config.py
sed -i "s/^SHORT_ID = .*/SHORT_ID = \"$SHORT_ID\"/" config.py
sed -i "s/^SPLIT_PORT = .*/SPLIT_PORT = 8081/" config.py
sed -i "s|^SPLIT_PATH = .*|SPLIT_PATH = \"/stream\"|" config.py
sed -i "s/^WG_SERVER_IP = .*/WG_SERVER_IP = \"$SERVER_IP\"/" config.py
sed -i "s/^WG_PORT = .*/WG_PORT = $LISTEN_PORT/" config.py
sed -i "s/^WG_SERVER_PUBKEY = .*/WG_SERVER_PUBKEY = \"$SERVER_PUBLIC_KEY\"/" config.py
sed -i "s/^WG_SERVER_PRIVKEY = .*/WG_SERVER_PRIVKEY = \"$SERVER_PRIVATE_KEY\"/" config.py
sed -i "s|^WG_SUBNET = .*|WG_SUBNET = \"$WG_SUBNET\"|" config.py
sed -i "s/^SERVER_WG_IP = .*/SERVER_WG_IP = \"$SERVER_WG_IP\"/" config.py

# --- 10. Установка сервисов ---
echo -e "${YELLOW}[10/10] Установка systemd-сервисов...${NC}"
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

# --- Автотестирование ---
echo -e "${GREEN}=== Установка завершена! ===${NC}"
echo "Публичный ключ REALITY: $PUBLIC_KEY"
echo "ShortId: $SHORT_ID"
echo "AmneziaWG публичный ключ сервера: $SERVER_PUBLIC_KEY"
echo "Конфиг AmneziaWG: /etc/amnezia/amneziawg.conf"
echo "Каталог бота: $BOT_DIR"

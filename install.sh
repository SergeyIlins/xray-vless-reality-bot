#!/bin/bash
# Xray VLESS+REALITY + Telegram Bot Installer
# Запуск: sudo bash install.sh

set -e
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo -e "${GREEN}=== Установка Xray и Telegram-бота ===${NC}"

if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}Пожалуйста, запустите скрипт с правами root (sudo).${NC}"
    exit 1
fi

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"

# --- 1. Установка зависимостей ---
echo -e "${YELLOW}[1/10] Установка пакетов...${NC}"
apt update
apt install -y curl wget unzip git jq python3 python3-pip python3-venv qrencode ufw

# --- 2. Установка Xray ---
echo -e "${YELLOW}[2/10] Установка Xray...${NC}"
if ! command -v xray &>/dev/null; then
    bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install
else
    echo "Xray уже установлен, пропускаем."
fi

# --- 3. Генерация ключей ---
echo -e "${YELLOW}[3/10] Генерация ключей REALITY...${NC}"
# Сохраняем вывод в переменную
XRAY_KEYS_OUTPUT=$(xray x25519)
# Извлекаем ключи (учитываем разные форматы)
PRIVATE_KEY=$(echo "$XRAY_KEYS_OUTPUT" | grep -E 'Private[ ]?Key:' | awk '{print $NF}')
PUBLIC_KEY=$(echo "$XRAY_KEYS_OUTPUT" | grep -E 'Public[ ]?Key:|Password[ ]?\(PublicKey\):' | awk '{print $NF}')
SHORT_ID=$(openssl rand -hex 8)

if [ -z "$PRIVATE_KEY" ] || [ -z "$PUBLIC_KEY" ]; then
    echo -e "${RED}Не удалось извлечь ключи. Попробуйте выполнить 'xray x25519' вручную.${NC}"
    exit 1
fi

echo "Приватный ключ: $PRIVATE_KEY"
echo "Публичный ключ: $PUBLIC_KEY"
echo "ShortId: $SHORT_ID"

# --- 4. Создание конфига Xray ---
echo -e "${YELLOW}[4/10] Создание config.json...${NC}"
CONFIG_FILE="/usr/local/etc/xray/config.json"
cp "$CONFIG_FILE" "$CONFIG_FILE.bak" 2>/dev/null || true
cp "$SCRIPT_DIR/config.json.example" "$CONFIG_FILE"
sed -i "s/PRIVATE_KEY_PLACEHOLDER/$PRIVATE_KEY/g" "$CONFIG_FILE"
sed -i "s/SHORT_ID_PLACEHOLDER/$SHORT_ID/g" "$CONFIG_FILE"
chmod 644 "$CONFIG_FILE"

# --- 5. Проверка и запуск Xray ---
echo -e "${YELLOW}[5/10] Проверка конфигурации Xray...${NC}"
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

# --- 6. Настройка NAT ---
echo -e "${YELLOW}[6/10] Настройка NAT...${NC}"
IFACE=$(ip route | grep default | awk '{print $5}')
iptables -t nat -A POSTROUTING -o "$IFACE" -j MASQUERADE
apt install -y iptables-persistent
netfilter-persistent save

# --- 7. Окружение для бота ---
echo -e "${YELLOW}[7/10] Установка Python-окружения...${NC}"
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

# Замена в config.py
sed -i "s/^TELEGRAM_BOT_TOKEN = .*/TELEGRAM_BOT_TOKEN = \"$BOT_TOKEN\"/" config.py
sed -i "s/^ALLOWED_USERS = .*/ALLOWED_USERS = {$ADMIN_ID}/" config.py
sed -i "s/^SERVER_IP = .*/SERVER_IP = \"$SERVER_IP\"/" config.py
sed -i "s/^PUBLIC_KEY = .*/PUBLIC_KEY = \"$PUBLIC_KEY\"/" config.py
sed -i "s/^SHORT_ID = .*/SHORT_ID = \"$SHORT_ID\"/" config.py

# --- 8. Установка сервисов ---
echo -e "${YELLOW}[8/10] Установка systemd-сервисов...${NC}"
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

# --- 9. Автотестирование ---
echo -e "${YELLOW}[9/10] Тестирование...${NC}"
if ss -tulpn | grep -q ":443.*xray"; then
    echo -e "${GREEN}✓ Порт 443 слушается Xray${NC}"
else
    echo -e "${RED}✗ Порт 443 не слушается!${NC}"
fi

if ss -tulpn | grep -q ":8080.*xray"; then
    echo -e "${GREEN}✓ API порт 8080 слушается${NC}"
else
    echo -e "${RED}✗ API порт 8080 не слушается!${NC}"
fi

if iptables -t nat -L POSTROUTING | grep -q MASQUERADE; then
    echo -e "${GREEN}✓ NAT правило активно${NC}"
else
    echo -e "${RED}✗ NAT правило отсутствует!${NC}"
fi

echo -e "${YELLOW}Проверка добавления пользователя...${NC}"
TEST_UUID=$(xray uuid)
TEST_EMAIL="test_$(date +%s)"
TMP_CONFIG=$(mktemp)
jq --arg email "$TEST_EMAIL" --arg uuid "$TEST_UUID" \
   '.inbounds[] |= if .tag=="proxy" then .settings.clients += [{"email":$email, "id":$uuid, "flow":"xtls-rprx-vision", "level":0}] else . end' \
   "$CONFIG_FILE" > "$TMP_CONFIG"
mv "$TMP_CONFIG" "$CONFIG_FILE"
systemctl reload xray 2>/dev/null || systemctl restart xray
sleep 1
jq --arg email "$TEST_EMAIL" \
   '.inbounds[] |= if .tag=="proxy" then .settings.clients |= map(select(.email != $email)) else . end' \
   "$CONFIG_FILE" > "$TMP_CONFIG"
mv "$TMP_CONFIG" "$CONFIG_FILE"
systemctl reload xray 2>/dev/null || systemctl restart xray
echo -e "${GREEN}✓ Прямое редактирование конфига работает${NC}"

# --- 10. Завершение ---
echo -e "${GREEN}=== Установка завершена! ===${NC}"
echo "--------------------------------------------------"
echo "Публичный ключ сервера: $PUBLIC_KEY"
echo "ShortId: $SHORT_ID"
echo "IP сервера: $SERVER_IP"
echo "Конфиг Xray: $CONFIG_FILE"
echo "Каталог бота: $BOT_DIR"
echo ""
echo "Дальнейшие шаги:"
echo "1. Убедитесь, что бот работает: /menu в Telegram"
echo "2. При необходимости отредактируйте config.py: nano $BOT_DIR/config.py"
echo "3. Проверьте логи: journalctl -u xray-bot -f"
echo "--------------------------------------------------"

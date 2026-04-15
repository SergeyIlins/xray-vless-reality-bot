#!/bin/bash
# Xray VLESS+REALITY + Telegram Bot Installer
# Запуск: sudo bash install.sh

set -e
# Цвета для вывода
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo -e "${GREEN}=== Установка Xray и Telegram-бота ===${NC}"

# --- Проверка прав root ---
if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}Пожалуйста, запустите скрипт с правами root (sudo).${NC}"
    exit 1
fi

# Определяем директорию скрипта
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"

# --- 1. Установка системных зависимостей ---
echo -e "${YELLOW}[1/10] Установка пакетов...${NC}"
apt update
apt install -y curl wget unzip git jq python3 python3-pip python3-venv qrencode ufw

# --- 2. Установка Xray-core ---
echo -e "${YELLOW}[2/10] Установка Xray...${NC}"
if ! command -v xray &>/dev/null; then
    bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install
else
    echo "Xray уже установлен, пропускаем."
fi

# --- 3. Генерация ключей и shortId ---
echo -e "${YELLOW}[3/10] Генерация ключей REALITY...${NC}"
KEYS=$(xray x25519)
PRIVATE_KEY=$(echo "$KEYS" | grep "Private key" | awk '{print $3}')
PUBLIC_KEY=$(echo "$KEYS" | grep "Public key" | awk '{print $3}')
SHORT_ID=$(openssl rand -hex 8)

echo "Приватный ключ: $PRIVATE_KEY"
echo "Публичный ключ: $PUBLIC_KEY"
echo "ShortId: $SHORT_ID"

# --- 4. Создание конфигурации Xray из шаблона ---
echo -e "${YELLOW}[4/10] Создание config.json из шаблона...${NC}"
CONFIG_FILE="/usr/local/etc/xray/config.json"
cp "$CONFIG_FILE" "$CONFIG_FILE.bak" 2>/dev/null || true
cp "$SCRIPT_DIR/config.json.example" "$CONFIG_FILE"
sed -i "s/PRIVATE_KEY_PLACEHOLDER/$PRIVATE_KEY/g" "$CONFIG_FILE"
sed -i "s/SHORT_ID_PLACEHOLDER/$SHORT_ID/g" "$CONFIG_FILE"
echo -e "${GREEN}config.json создан.${NC}"

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

# --- 6. Настройка NAT (маскарадинг) ---
echo -e "${YELLOW}[6/10] Настройка NAT...${NC}"
IFACE=$(ip route | grep default | awk '{print $5}')
iptables -t nat -A POSTROUTING -o "$IFACE" -j MASQUERADE
apt install -y iptables-persistent
netfilter-persistent save

# --- 7. Создание окружения для бота ---
echo -e "${YELLOW}[7/10] Установка Python-окружения...${NC}"
BOT_DIR="/opt/xray-bot"
mkdir -p "$BOT_DIR"
cp "$SCRIPT_DIR/bot.py" "$BOT_DIR/"
cp "$SCRIPT_DIR/cleanup_expired.py" "$BOT_DIR/"
cp "$SCRIPT_DIR/.env.example" "$BOT_DIR/.env"
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

# Замена в .env
sed -i "s/^TELEGRAM_BOT_TOKEN=.*/TELEGRAM_BOT_TOKEN=$BOT_TOKEN/" .env
sed -i "s/^ALLOWED_USERS=.*/ALLOWED_USERS=$ADMIN_ID/" .env
sed -i "s/^SERVER_IP=.*/SERVER_IP=$SERVER_IP/" .env
sed -i "s/^PUBLIC_KEY=.*/PUBLIC_KEY=$PUBLIC_KEY/" .env
sed -i "s/^SHORT_ID=.*/SHORT_ID=$SHORT_ID/" .env
# SNI оставляем как есть

# --- 8. Установка systemd-сервисов ---
echo -e "${YELLOW}[8/10] Установка сервисов...${NC}"
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
echo -e "${YELLOW}[9/10] Тестирование компонентов...${NC}"

# Проверка портов
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

# Проверка NAT
if iptables -t nat -L POSTROUTING | grep -q MASQUERADE; then
    echo -e "${GREEN}✓ NAT правило активно${NC}"
else
    echo -e "${RED}✗ NAT правило отсутствует!${NC}"
fi

# Проверка файла конфигурации бота
if [ -f "$BOT_DIR/config.py" ]; then
    echo -e "${GREEN}✓ config.py создан${NC}"
else
    echo -e "${RED}✗ config.py не найден!${NC}"
fi

# Тест добавления пользователя (прямой метод, который используется ботом)
echo -e "${YELLOW}Проверка добавления пользователя через прямое редактирование конфига...${NC}"
TEST_UUID=$(xray uuid)
TEST_EMAIL="test_$(date +%s)"
# Добавляем временного пользователя в config.json (имитация действий бота)
TMP_CONFIG=$(mktemp)
jq --arg email "$TEST_EMAIL" --arg uuid "$TEST_UUID" \
   '.inbounds[] |= if .tag=="proxy" then .settings.clients += [{"email":$email, "id":$uuid, "flow":"xtls-rprx-vision", "level":0}] else . end' \
   "$CONFIG_FILE" > "$TMP_CONFIG"
mv "$TMP_CONFIG" "$CONFIG_FILE"
systemctl reload xray 2>/dev/null || systemctl restart xray
sleep 1
# Удаляем обратно
jq --arg email "$TEST_EMAIL" \
   '.inbounds[] |= if .tag=="proxy" then .settings.clients |= map(select(.email != $email)) else . end' \
   "$CONFIG_FILE" > "$TMP_CONFIG"
mv "$TMP_CONFIG" "$CONFIG_FILE"
systemctl reload xray 2>/dev/null || systemctl restart xray
echo -e "${GREEN}✓ Прямое редактирование конфига работает${NC}"

# --- 10. Финальное сообщение ---
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
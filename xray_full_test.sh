#!/bin/bash
# Полный скрипт диагностики подключения к Xray VLESS+REALITY
# Запуск: sudo bash xray_full_test.sh

set -e
OUTPUT_FILE="/tmp/xray_full_test_$(date +%Y%m%d_%H%M%S).log"
exec > >(tee -a "$OUTPUT_FILE") 2>&1

echo "=== ПОЛНЫЙ ТЕСТ XRAY И СЕТИ ==="
echo "Дата: $(date)"
echo "Сервер: $(hostname)"

# --- 1. Сбор информации о сервере ---
echo
echo "=== 1. ИНФОРМАЦИЯ О СЕРВЕРЕ ==="
SERVER_IP=$(curl -s ifconfig.co)
echo "Внешний IP: $SERVER_IP"
IFACE=$(ip route | grep default | awk '{print $5}')
echo "Сетевой интерфейс: $IFACE"
echo "IP forwarding: $(sysctl -n net.ipv4.ip_forward)"

# --- 2. Состояние Xray ---
echo
echo "=== 2. СТАТУС XRAY ==="
systemctl status xray --no-pager | head -15
echo
echo "Порты Xray:"
ss -tulpn | grep xray

# --- 3. Ключи и конфигурация ---
echo
echo "=== 3. КЛЮЧИ И КОНФИГ ==="
CONFIG_FILE="/usr/local/etc/xray/config.json"
PRIVATE_KEY=$(grep -o '"privateKey": *"[^"]*"' "$CONFIG_FILE" | cut -d'"' -f4)
SHORT_ID=$(grep -o '"shortIds": *\[ *"[^"]*"' "$CONFIG_FILE" | grep -o '"[^"]*"$' | tr -d '"')
echo "Приватный ключ в config.json: ${PRIVATE_KEY:0:10}... (первые 10 символов)"
echo "ShortId в config.json: $SHORT_ID"

PUBLIC_KEY_BOT=$(grep PUBLIC_KEY /opt/xray-bot/.env | cut -d= -f2)
SHORT_ID_BOT=$(grep SHORT_ID /opt/xray-bot/.env | cut -d= -f2)
echo "Публичный ключ бота: ${PUBLIC_KEY_BOT:0:10}..."
echo "ShortId бота: $SHORT_ID_BOT"

# --- 4. NAT и фаервол ---
echo
echo "=== 4. NAT И ФАЕРВОЛ ==="
echo "Правило MASQUERADE:"
iptables -t nat -L POSTROUTING -v | grep MASQUERADE || echo "Нет правила MASQUERADE!"
echo "Правила INPUT (первые 10):"
iptables -L INPUT -n -v | head -10

# --- 5. Доступность порта 443 снаружи ---
echo
echo "=== 5. ДОСТУПНОСТЬ ПОРТА 443 ==="
echo "Проверка локально:"
nc -zv 127.0.0.1 443 || echo "Порт 443 не отвечает локально"
echo "Проверка через внешний сервис (portchecker.co):"
curl -s "https://portchecker.co/check" -d "target=$SERVER_IP&port=443" | grep -o "Port 443 is open" || echo "Не удалось проверить порт извне"

# --- 6. Доступность dest сайта с сервера ---
echo
echo "=== 6. ДОСТУПНОСТЬ DEST САЙТА ==="
DEST=$(grep -o '"dest": *"[^"]*"' "$CONFIG_FILE" | cut -d'"' -f4)
echo "Dest: $DEST"
curl -I --connect-timeout 5 "https://${DEST}" 2>&1 | head -5 || echo "Ошибка соединения с $DEST"

# --- 7. Создание тестового пользователя и ссылки ---
echo
echo "=== 7. ТЕСТОВЫЙ ПОЛЬЗОВАТЕЛЬ ==="
TEST_UUID=$(xray uuid)
TEST_EMAIL="diag_$(date +%s)"
# Добавляем
TMP_CONFIG=$(mktemp)
jq --arg email "$TEST_EMAIL" --arg uuid "$TEST_UUID" \
   '.inbounds[] |= if .tag=="proxy" then .settings.clients += [{"email":$email, "id":$uuid, "flow":"xtls-rprx-vision", "level":0}] else . end' \
   "$CONFIG_FILE" > "$TMP_CONFIG"
mv "$TMP_CONFIG" "$CONFIG_FILE"
systemctl reload xray 2>/dev/null || systemctl restart xray
echo "Тестовый пользователь $TEST_EMAIL добавлен."

SNI=$(grep -o '"serverNames": *\[ *"[^"]*"' "$CONFIG_FILE" | head -1 | grep -o '"[^"]*"$' | tr -d '"')
[ -z "$SNI" ] && SNI="www.microsoft.com"
LINK="vless://${TEST_UUID}@${SERVER_IP}:443?security=reality&encryption=none&pbk=${PUBLIC_KEY_BOT}&sni=${SNI}&fp=chrome&type=tcp&flow=xtls-rprx-vision&sid=${SHORT_ID_BOT}#${TEST_EMAIL}"
echo "Ссылка для подключения:"
echo "$LINK"
echo
echo "QR-код (если установлен qrencode):"
if command -v qrencode &>/dev/null; then
    echo "$LINK" | qrencode -t ANSIUTF8
fi

# --- 8. Захват трафика (10 секунд) ---
echo
echo "=== 8. ЗАХВАТ ТРАФИКА НА ПОРТУ 443 (10 секунд) ==="
echo "В течение 10 секунд попробуйте подключиться клиентом."
timeout 10 tcpdump -i any port 443 -n -c 20 2>&1 || echo "Захват завершён (возможно, не было пакетов)."

# --- 9. Логи Xray (последние 30 строк) ---
echo
echo "=== 9. ПОСЛЕДНИЕ ЛОГИ XRAY ==="
journalctl -u xray -n 30 --no-pager

# --- 10. Удаление тестового пользователя ---
echo
echo "=== 10. ОЧИСТКА ==="
jq --arg email "$TEST_EMAIL" \
   '.inbounds[] |= if .tag=="proxy" then .settings.clients |= map(select(.email != $email)) else . end' \
   "$CONFIG_FILE" > "$TMP_CONFIG"
mv "$TMP_CONFIG" "$CONFIG_FILE"
systemctl reload xray 2>/dev/null || systemctl restart xray
echo "Тестовый пользователь удалён."

echo
echo "=== ДИАГНОСТИКА ЗАВЕРШЕНА ==="
echo "Лог сохранён в: $OUTPUT_FILE"
echo "Отправьте этот файл для анализа."

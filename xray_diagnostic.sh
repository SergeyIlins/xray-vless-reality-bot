#!/bin/bash
# Xray Advanced Diagnostic + Manual User Creation
# Usage: chmod +x xray_manual_test.sh && sudo ./xray_manual_test.sh

set -e
OUTPUT_FILE="/tmp/xray_manual_test_$(date +%Y%m%d_%H%M%S).log"
exec > >(tee -a "$OUTPUT_FILE") 2>&1

echo "=== XRAY MANUAL TEST ==="
echo "Date: $(date)"

# --- Проверка зависимостей ---
if ! command -v jq &>/dev/null; then
    echo "Installing jq..."
    apt update -qq && apt install -y jq
fi

# --- Параметры сервера ---
SERVER_IP=$(curl -s ifconfig.co)
PUBLIC_KEY="oPdUoKIfLo4esIc4FBp8zjslDDInMm1GwFPQrB7bmGg"
SHORT_ID="06c23db3e232e0b2"
SNI="www.microsoft.com"
CONFIG_FILE="/usr/local/etc/xray/config.json"

echo
echo "=== 1. XRAY STATUS ==="
systemctl status xray --no-pager | head -10

echo
echo "=== 2. CONFIG SYNTAX CHECK ==="
/usr/local/bin/xray -test -config "$CONFIG_FILE"

echo
echo "=== 3. CURRENT CLIENTS IN CONFIG ==="
jq '.inbounds[] | select(.tag=="proxy") | .settings.clients' "$CONFIG_FILE"

echo
echo "=== 4. CREATING TEST USER (direct config edit) ==="
NEW_UUID=$(/usr/local/bin/xray uuid)
echo "Generated UUID: $NEW_UUID"
TEST_EMAIL="testuser_$(date +%s)"

# Резервная копия
cp "$CONFIG_FILE" "$CONFIG_FILE.bak"

# Добавляем пользователя через jq
jq --arg email "$TEST_EMAIL" --arg uuid "$NEW_UUID" \
   '.inbounds[] |= if .tag=="proxy" then .settings.clients += [{"email":$email, "id":$uuid, "flow":"xtls-rprx-vision", "level":0}] else . end' \
   "$CONFIG_FILE" > "$CONFIG_FILE.tmp" && mv "$CONFIG_FILE.tmp" "$CONFIG_FILE"

echo "User $TEST_EMAIL added to config."

echo
echo "=== 5. RELOADING XRAY ==="
# Graceful reload через API (работает даже если добавление через API глючит)
/usr/local/bin/xray api restartlogger 2>/dev/null || true
systemctl reload xray 2>/dev/null || systemctl restart xray

sleep 2
systemctl status xray --no-pager | head -5

echo
echo "=== 6. GENERATING VLESS LINK ==="
LINK="vless://${NEW_UUID}@${SERVER_IP}:443?security=reality&encryption=none&pbk=${PUBLIC_KEY}&sni=${SNI}&fp=chrome&type=tcp&flow=xtls-rprx-vision&sid=${SHORT_ID}#${TEST_EMAIL}"
echo "$LINK"

# QR code в терминале (если есть qrencode)
if command -v qrencode &>/dev/null; then
    echo "QR Code:"
    echo "$LINK" | qrencode -t ANSIUTF8
else
    echo "Install qrencode to see QR in terminal."
fi

echo
echo "=== 7. VERIFY CLIENT IN CONFIG ==="
jq '.inbounds[] | select(.tag=="proxy") | .settings.clients' "$CONFIG_FILE"

echo
echo "=== 8. FIREWALL & NAT CHECK ==="
echo "MASQUERADE rule:"
iptables -t nat -L POSTROUTING -v | grep MASQUERADE || echo "WARNING: No MASQUERADE rule!"
echo "Port 443 listening:"
ss -tulpn | grep :443

echo
echo "=== 9. INSTRUCTIONS ==="
echo "Copy the link above and import into your VPN client (v2rayNG, Nekoray, etc.)."
echo "Then check logs with: journalctl -u xray -f"
echo "If connection fails, look for 'rejected' or 'invalid request user id'."
echo
echo "To remove test user, restore backup: cp $CONFIG_FILE.bak $CONFIG_FILE && systemctl reload xray"
echo
echo "Output saved to: $OUTPUT_FILE"
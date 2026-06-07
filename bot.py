#!/usr/bin/env python3
import logging
import subprocess
import json as json_lib
import re
import os
import shutil
import random
import ipaddress
from datetime import datetime, timedelta
from io import BytesIO
import qrcode
from telegram import Update, InlineKeyboardButton, InlineKeyboardMarkup, BotCommand
from telegram.ext import Application, CommandHandler, CallbackQueryHandler, MessageHandler, filters, ContextTypes

from config import (
    TELEGRAM_BOT_TOKEN, ALLOWED_USERS, SERVER_IP, PUBLIC_KEY, SHORT_ID, SNI,
    SPLIT_PORT, SPLIT_PATH,
    WG_SERVER_IP, WG_PORT, WG_SERVER_PUBKEY, WG_SERVER_PRIVKEY, WG_SUBNET, SERVER_WG_IP
)

logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)

INBOUND_VLESS = "proxy"
INBOUND_SPLIT = "split"
CONFIG_PATH = "/usr/local/etc/xray/config.json"
CONFIG_BACKUP = "/usr/local/etc/xray/config.json.bak"
CLIENTS_DB = "/opt/xray-bot/clients.json"
WG_CONFIG = "/etc/amnezia/amneziawg.conf"

DURATION_MAP = {
    "24 часа": 86400,
    "1 месяц": 2592000,
    "3 месяца": 7776000,
    "6 месяцев": 15552000,
    "12 месяцев": 31104000,
    "Постоянный": 0
}

def load_clients_db():
    if not os.path.exists(CLIENTS_DB):
        return {}
    with open(CLIENTS_DB, "r") as f:
        return json_lib.load(f)

def save_clients_db(db):
    with open(CLIENTS_DB, "w") as f:
        json_lib.dump(db, f, indent=2)

def is_allowed(update: Update) -> bool:
    user_id = update.effective_user.id
    return user_id in ALLOWED_USERS

def run_command(cmd_list):
    result = subprocess.run(cmd_list, capture_output=True, text=True)
    return result.stdout.strip(), result.stderr.strip(), result.returncode

def load_xray_config():
    with open(CONFIG_PATH, 'r') as f:
        return json_lib.load(f)

def save_xray_config(config):
    shutil.copy(CONFIG_PATH, CONFIG_BACKUP)
    with open(CONFIG_PATH, 'w') as f:
        json_lib.dump(config, f, indent=2)

def reload_xray():
    subprocess.run(["/usr/local/bin/xray", "api", "restartlogger"], capture_output=True)
    rc = subprocess.run(["/usr/bin/systemctl", "reload", "xray"], capture_output=True).returncode
    if rc != 0:
        subprocess.run(["/usr/bin/systemctl", "restart", "xray"], capture_output=True)

def generate_uuid():
    out, err, rc = run_command(["/usr/local/bin/xray", "uuid"])
    if rc != 0:
        raise Exception(f"Ошибка генерации UUID: {err}")
    return out

# ----- AmneziaWG helpers -----
def load_wg_config():
    with open(WG_CONFIG, 'r') as f:
        return f.read()

def save_wg_config(content):
    with open(WG_CONFIG, 'w') as f:
        f.write(content)

def reload_awg():
    subprocess.run(["systemctl", "restart", "awg-quick@amneziawg"], capture_output=True)

def add_peer_to_awg(public_key, allowed_ip):
    # Добавляем пир в конец файла
    with open(WG_CONFIG, "a") as f:
        f.write(f"\n[Peer]\nPublicKey = {public_key}\nAllowedIPs = {allowed_ip}\n")
    reload_awg()

def remove_peer_from_awg(public_key):
    # Удаляем блок пира
    lines = load_wg_config().splitlines()
    new_lines = []
    skip = False
    for line in lines:
        if line.startswith("[Peer]") and f"PublicKey = {public_key}" in lines[lines.index(line)+1]:
            skip = True
        elif line.startswith("[") and skip:
            skip = False
            new_lines.append(line)
        elif not skip:
            new_lines.append(line)
    save_wg_config("\n".join(new_lines))
    reload_awg()

def generate_awg_client_conf(name, client_privkey, client_ip):
    return f"""[Interface]
PrivateKey = {client_privkey}
Address = {client_ip}/32
DNS = 1.1.1.1

[Peer]
PublicKey = {WG_SERVER_PUBKEY}
Endpoint = {WG_SERVER_IP}:{WG_PORT}
AllowedIPs = 0.0.0.0/0
PersistentKeepalive = 25"""

# ----- Управление Xray клиентами -----
def add_client_to_xray(email, uuid, protocol='vless'):
    tag = INBOUND_VLESS if protocol == 'vless' else INBOUND_SPLIT
    config = load_xray_config()
    for inbound in config['inbounds']:
        if inbound.get('tag') == tag:
            clients = inbound['settings']['clients']
            for c in clients:
                if c.get('email') == email:
                    raise Exception(f"Клиент с email {email} уже существует")
            entry = {"email": email, "id": uuid, "level": 0}
            if protocol == 'vless':
                entry["flow"] = "xtls-rprx-vision"
            clients.append(entry)
            save_xray_config(config)
            reload_xray()
            return True
    raise Exception(f"Inbound с тегом {tag} не найден")

def remove_client_from_xray(email, protocol=None):
    config = load_xray_config()
    tags = [INBOUND_VLESS] if protocol == 'vless' else [INBOUND_SPLIT] if protocol == 'split' else [INBOUND_VLESS, INBOUND_SPLIT]
    deleted = False
    for tag in tags:
        for inbound in config['inbounds']:
            if inbound.get('tag') == tag:
                clients = inbound['settings']['clients']
                new_clients = [c for c in clients if c.get('email') != email]
                if len(new_clients) < len(clients):
                    inbound['settings']['clients'] = new_clients
                    deleted = True
    if not deleted:
        raise Exception(f"Клиент с email {email} не найден")
    save_xray_config(config)
    reload_xray()
    return True

# ----- Генерация ссылок и конфигов -----
def generate_vless_link(uuid, name):
    base = f"vless://{uuid}@{SERVER_IP}:443"
    params = f"security=reality&encryption=none&pbk={PUBLIC_KEY}&sni={SNI}&fp=chrome&type=tcp&flow=xtls-rprx-vision&sid={SHORT_ID}"
    return f"{base}?{params}#{name}"

def generate_split_link(uuid, name):
    return f"vless://{uuid}@{SERVER_IP}:{SPLIT_PORT}?type=xhttp&path={SPLIT_PATH}&security=none#sp-{name}"

def generate_client_conf(uuid_or_data, name, protocol='vless'):
    if protocol == 'vless':
        conf = {
            "outbounds": [{
                "protocol": "vless",
                "settings": {
                    "vnext": [{
                        "address": SERVER_IP, "port": 443,
                        "users": [{"id": uuid_or_data, "flow": "xtls-rprx-vision", "encryption": "none"}]
                    }]
                },
                "streamSettings": {
                    "network": "tcp", "security": "reality",
                    "realitySettings": {
                        "serverName": SNI, "fingerprint": "chrome",
                        "publicKey": PUBLIC_KEY, "shortId": SHORT_ID
                    }
                },
                "tag": "proxy"
            }]
        }
    elif protocol == 'split':
        conf = {
            "outbounds": [{
                "protocol": "vless",
                "settings": {
                    "vnext": [{
                        "address": SERVER_IP, "port": SPLIT_PORT,
                        "users": [{"id": uuid_or_data, "encryption": "none"}]
                    }]
                },
                "streamSettings": {"network": "xhttp", "xhttpSettings": {"mode": "auto", "path": SPLIT_PATH}},
                "tag": "split"
            }]
        }
    elif protocol == 'amneziawg':
        return generate_awg_client_conf(name, uuid_or_data[0], uuid_or_data[1])
    return json_lib.dumps(conf, indent=2)

def generate_qr_code(data):
    qr = qrcode.QRCode(version=1, box_size=10, border=4)
    qr.add_data(data)
    qr.make(fit=True)
    img = qr.make_image(fill_color="black", back_color="white")
    bio = BytesIO()
    img.save(bio, "PNG")
    bio.seek(0)
    return bio

def get_main_menu_keyboard():
    return InlineKeyboardMarkup([
        [InlineKeyboardButton("➕ Добавить клиента", callback_data="add_client")],
        [InlineKeyboardButton("❌ Удалить клиента", callback_data="del_client")],
        [InlineKeyboardButton("📋 Список клиентов", callback_data="list_clients")],
        [InlineKeyboardButton("📊 Статистика", callback_data="stats")],
        [InlineKeyboardButton("🆔 Мой ID", callback_data="my_id")]
    ])

# Обработчики команд
async def set_commands(app):
    await app.bot.set_my_commands([BotCommand("start", "Главное меню"), BotCommand("menu", "Показать меню")])

async def start(update: Update, context: ContextTypes.DEFAULT_TYPE):
    if not is_allowed(update): return
    await update.message.reply_text("Добро пожаловать! Выберите действие:", reply_markup=get_main_menu_keyboard())

async def menu(update: Update, context: ContextTypes.DEFAULT_TYPE):
    await start(update, context)

async def button_handler(update: Update, context: ContextTypes.DEFAULT_TYPE):
    query = update.callback_query
    await query.answer()
    data = query.data
    if not is_allowed(update): return

    if data == "add_client":
        keyboard = [
            [InlineKeyboardButton("🕒 24 часа", callback_data="dur_86400")],
            [InlineKeyboardButton("📅 1 месяц", callback_data="dur_2592000")],
            [InlineKeyboardButton("📅 3 месяца", callback_data="dur_7776000")],
            [InlineKeyboardButton("📅 6 месяцев", callback_data="dur_15552000")],
            [InlineKeyboardButton("📅 12 месяцев", callback_data="dur_31104000")],
            [InlineKeyboardButton("♾️ Постоянный", callback_data="dur_0")],
            [InlineKeyboardButton("◀️ Назад", callback_data="back_to_menu")]
        ]
        await query.edit_message_text("Выберите срок:", reply_markup=InlineKeyboardMarkup(keyboard))
    elif data.startswith("dur_"):
        seconds = int(data.split("_")[1])
        context.user_data['duration'] = seconds
        keyboard = [
            [InlineKeyboardButton("🚀 Стандарт (Xray REALITY)", callback_data="proto_vless")],
            [InlineKeyboardButton("⚡ АмнезияWG (обход DPI)", callback_data="proto_awg")],
            [InlineKeyboardButton("🛡️ Максимальная защита (Xray + SplitHTTP)", callback_data="proto_both_split")],
            [InlineKeyboardButton("◀️ Назад", callback_data="add_client")]
        ]
        duration_text = next((k for k, v in DURATION_MAP.items() if v == seconds), f"{seconds} сек")
        await query.edit_message_text(f"Вы выбрали срок: {duration_text}\nВыберите тип:", reply_markup=InlineKeyboardMarkup(keyboard))
        context.user_data['awaiting_protocol'] = True
    elif data.startswith("proto_"):
        proto = data.split("_", 1)[1]
        context.user_data['protocol'] = proto
        await query.edit_message_text("Введите имя клиента (латиница, 3-20 символов, можно - и _):")
        context.user_data['awaiting_name'] = True
    elif data == "del_client":
        context.user_data['awaiting_delete'] = True
        await query.edit_message_text("Введите имя клиента для удаления:")
    elif data == "list_clients":
        db = load_clients_db()
        if not db:
            await query.edit_message_text("Нет клиентов.")
            return
        msg = "📋 Список клиентов:\n\n"
        for email, info in db.items():
            name = info.get("name", email)
            expires = info.get("expires", 0)
            expire_str = "♾️ постоянный" if expires == 0 else datetime.fromtimestamp(expires).strftime('%Y-%m-%d %H:%M')
            msg += f"• {name} ({info.get('protocol','vless')}) — {expire_str}\n"
        await query.edit_message_text(msg, reply_markup=InlineKeyboardMarkup([[InlineKeyboardButton("◀️ Назад", callback_data="back_to_menu")]]))
    elif data == "stats":
        # можно добавить позже
        await query.edit_message_text("Статистика временно недоступна")
    elif data == "my_id":
        await query.edit_message_text(f"Ваш ID: {update.effective_user.id}", parse_mode="Markdown")
        await query.message.reply_text("Главное меню:", reply_markup=get_main_menu_keyboard())
    elif data == "back_to_menu":
        await query.edit_message_text("Главное меню:", reply_markup=get_main_menu_keyboard())

async def handle_message(update: Update, context: ContextTypes.DEFAULT_TYPE):
    if not is_allowed(update): return
    text = update.message.text.strip()
    if context.user_data.get('awaiting_name'):
        name = text
        if not re.match(r'^[a-zA-Z0-9_-]{3,20}$', name):
            await update.message.reply_text("Некорректное имя.")
            return
        duration = context.user_data.get('duration', 0)
        proto = context.user_data.get('protocol', 'vless')
        try:
            expire_ts = 0 if duration == 0 else int((datetime.now() + timedelta(seconds=duration)).timestamp())
            if proto == 'vless':
                uuid = generate_uuid()
                email = name
                add_client_to_xray(email, uuid, 'vless')
                db = load_clients_db()
                db[email] = {"name": name, "uuid": uuid, "expires": expire_ts, "protocol": "vless"}
                save_clients_db(db)
                link = generate_vless_link(uuid, name)
                qr = generate_qr_code(link)
                conf = generate_client_conf(uuid, name, 'vless')
                await update.message.reply_photo(photo=qr, caption=f"QR для {name}")
                await update.message.reply_document(document=BytesIO(conf.encode()), filename=f"{name}_vless.conf")
                await update.message.reply_text(f"✅ Клиент {name} (VLESS) добавлен.\n{link}")
            elif proto == 'awg':
                client_privkey = subprocess.run(["awg", "genkey"], capture_output=True, text=True).stdout.strip()
                client_pubkey = subprocess.run(["awg", "pubkey"], input=client_privkey, capture_output=True, text=True).stdout.strip()
                # Назначаем IP
                subnet = ipaddress.ip_network(WG_SUBNET)
                existing_ips = [int(ipaddress.IPv4Address(line.split('=')[1].strip().split('/')[0])) for line in load_wg_config().splitlines() if line.startswith("AllowedIPs")]
                used = set(existing_ips)
                for i in range(2, 254):
                    if int(subnet[i]) not in used:
                        client_ip = str(subnet[i])
                        break
                else:
                    raise Exception("Нет свободных IP в подсети")
                email = name
                add_peer_to_awg(client_pubkey, client_ip)
                db = load_clients_db()
                db[email] = {"name": name, "uuid": client_pubkey, "expires": expire_ts, "protocol": "awg", "privkey": client_privkey}
                save_clients_db(db)
                conf = generate_client_conf((client_privkey, client_ip), name, 'amneziawg')
                qr = generate_qr_code(conf)
                await update.message.reply_photo(photo=qr, caption=f"QR для {name} (AmneziaWG)")
                await update.message.reply_document(document=BytesIO(conf.encode()), filename=f"{name}_awg.conf")
                await update.message.reply_text(f"✅ Клиент {name} (AmneziaWG) добавлен.")
            elif proto == 'both_split':
                uuid = generate_uuid()
                email_v = f"{name}_v"
                add_client_to_xray(email_v, uuid, 'vless')
                uuid_s = generate_uuid()
                email_s = f"{name}_s"
                add_client_to_xray(email_s, uuid_s, 'split')
                db = load_clients_db()
                db[email_v] = {"name": f"{name} (VLESS)", "uuid": uuid, "expires": expire_ts, "protocol": "vless"}
                db[email_s] = {"name": f"{name} (Split)", "uuid": uuid_s, "expires": expire_ts, "protocol": "split"}
                save_clients_db(db)
                link_v = generate_vless_link(uuid, f"{name}_v")
                qr_v = generate_qr_code(link_v)
                conf_v = generate_client_conf(uuid, f"{name}_v", 'vless')
                await update.message.reply_photo(photo=qr_v, caption=f"QR VLESS {name}")
                await update.message.reply_document(document=BytesIO(conf_v.encode()), filename=f"{name}_vless.conf")
                link_s = generate_split_link(uuid_s, f"{name}_s")
                qr_s = generate_qr_code(link_s)
                conf_s = generate_client_conf(uuid_s, f"{name}_s", 'split')
                await update.message.reply_photo(photo=qr_s, caption=f"QR SplitHTTP {name}")
                await update.message.reply_document(document=BytesIO(conf_s.encode()), filename=f"{name}_split.conf")
                await update.message.reply_text(f"✅ Клиент {name} (VLESS+SplitHTTP) добавлен.")
        except Exception as e:
            logger.error(f"Error adding client: {e}")
            await update.message.reply_text(f"❌ Ошибка: {e}")
        finally:
            context.user_data.clear()
            await update.message.reply_text("Главное меню:", reply_markup=get_main_menu_keyboard())
    elif context.user_data.get('awaiting_delete'):
        email = text
        try:
            db = load_clients_db()
            if email in db:
                proto = db[email].get('protocol', 'vless')
                if proto == 'awg':
                    remove_peer_from_awg(db[email]['uuid'])
                else:
                    remove_client_from_xray(email, proto)
                del db[email]
                save_clients_db(db)
            await update.message.reply_text(f"🗑️ Клиент {email} удалён.")
        except Exception as e:
            await update.message.reply_text(f"❌ Ошибка: {e}")
        finally:
            context.user_data['awaiting_delete'] = False
            await update.message.reply_text("Главное меню:", reply_markup=get_main_menu_keyboard())
    else:
        await update.message.reply_text("Используйте /menu для управления.")

def main():
    app = Application.builder().token(TELEGRAM_BOT_TOKEN).build()
    app.add_handler(CommandHandler("start", start))
    app.add_handler(CommandHandler("menu", menu))
    app.add_handler(CallbackQueryHandler(button_handler))
    app.add_handler(MessageHandler(filters.TEXT & ~filters.COMMAND, handle_message))
    app.post_init = set_commands
    app.run_polling()

if __name__ == "__main__":
    main()

#!/usr/bin/env python3
import logging
import subprocess
import json as json_lib
import re
import os
import shutil
from datetime import datetime, timedelta
import qrcode
from io import BytesIO
from telegram import Update, InlineKeyboardButton, InlineKeyboardMarkup, BotCommand
from telegram.ext import Application, CommandHandler, CallbackQueryHandler, MessageHandler, filters, ContextTypes

from config import TELEGRAM_BOT_TOKEN, ALLOWED_USERS, SERVER_IP, PUBLIC_KEY, SHORT_ID, SNI

logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)

INBOUND_TAG = "proxy"
CONFIG_PATH = "/usr/local/etc/xray/config.json"
CONFIG_BACKUP = "/usr/local/etc/xray/config.json.bak"
CLIENTS_DB = "/opt/xray-bot/clients.json"

DURATION_MAP = {
    "24 часа": 86400,
    "1 месяц": 2592000,
    "3 месяца": 7776000,
    "6 месяцев": 15552000,
    "12 месяцев": 31104000,
    "Постоянный": 0
}

# ---------------------- Вспомогательные функции ----------------------
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

def run_command_with_stdin(cmd_list, input_data=None, timeout=10):
    try:
        result = subprocess.run(
            cmd_list,
            input=input_data,
            capture_output=True,
            text=True,
            timeout=timeout
        )
        return result.stdout.strip(), result.stderr.strip(), result.returncode
    except subprocess.TimeoutExpired:
        return "", "Command timed out", -1
    except Exception as e:
        return "", str(e), -1

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

def add_client_to_xray(email, uuid):
    config = load_xray_config()
    for inbound in config['inbounds']:
        if inbound.get('tag') == INBOUND_TAG:
            clients = inbound['settings']['clients']
            for c in clients:
                if c.get('email') == email:
                    raise Exception(f"Клиент с email {email} уже существует")
            clients.append({
                "email": email,
                "id": uuid,
                "flow": "xtls-rprx-vision",
                "level": 0
            })
            save_xray_config(config)
            reload_xray()
            return True
    raise Exception(f"Inbound '{INBOUND_TAG}' не найден в конфиге")

def remove_client_from_xray(email):
    config = load_xray_config()
    for inbound in config['inbounds']:
        if inbound.get('tag') == INBOUND_TAG:
            clients = inbound['settings']['clients']
            new_clients = [c for c in clients if c.get('email') != email]
            if len(new_clients) == len(clients):
                raise Exception(f"Клиент с email {email} не найден")
            inbound['settings']['clients'] = new_clients
            save_xray_config(config)
            reload_xray()
            return True
    raise Exception(f"Inbound '{INBOUND_TAG}' не найден")


def get_all_stats():
    """Получает все счётчики статистики одним запросом."""
    payload = json_lib.dumps({"reset": False})
    cmd = ["/usr/local/bin/xray", "api", "statsquery"]
    out, err, rc = run_command_with_stdin(cmd, input_data=payload, timeout=10)
    if rc != 0:
        logger.error(f"Failed to query all stats: {err}")
        return {}
    try:
        data = json_lib.loads(out)
        stats = {}
        for item in data.get("stat", []):
            name = item.get("name", "")
            value = int(item.get("value", 0))
            stats[name] = value
        return stats
    except Exception as e:
        logger.error(f"Failed to parse all stats: {e}")
        return {}

def get_client_stats(email):
    """Извлекает uplink/downlink для email из общего словаря статистики."""
    stats = get_all_stats()
    uplink = stats.get(f"user>>>{email}>>>traffic>>>uplink", 0)
    downlink = stats.get(f"user>>>{email}>>>traffic>>>downlink", 0)
    return uplink, downlink


def generate_vless_link(uuid, name):
    base = f"vless://{uuid}@{SERVER_IP}:443"
    params = f"security=reality&encryption=none&pbk={PUBLIC_KEY}&sni={SNI}&fp=chrome&type=tcp&flow=xtls-rprx-vision&sid={SHORT_ID}"
    return f"{base}?{params}#{name}"

def generate_client_conf(uuid, name):
    conf = {
        "outbounds": [{
            "protocol": "vless",
            "settings": {
                "vnext": [{
                    "address": SERVER_IP,
                    "port": 443,
                    "users": [{
                        "id": uuid,
                        "flow": "xtls-rprx-vision",
                        "encryption": "none"
                    }]
                }]
            },
            "streamSettings": {
                "network": "tcp",
                "security": "reality",
                "realitySettings": {
                    "serverName": SNI,
                    "fingerprint": "chrome",
                    "publicKey": PUBLIC_KEY,
                    "shortId": SHORT_ID
                }
            },
            "tag": "proxy"
        }]
    }
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

# ---------------------- Обработчики команд ----------------------
async def set_commands(app):
    await app.bot.set_my_commands([
        BotCommand("start", "Главное меню"),
        BotCommand("menu", "Показать меню")
    ])

async def start(update: Update, context: ContextTypes.DEFAULT_TYPE):
    if not is_allowed(update):
        await update.message.reply_text("⛔ У вас нет доступа к этому боту.")
        return
    await update.message.reply_text(
        "Добро пожаловать! Выберите действие:",
        reply_markup=get_main_menu_keyboard()
    )

async def menu(update: Update, context: ContextTypes.DEFAULT_TYPE):
    if not is_allowed(update):
        await update.message.reply_text("⛔ Нет доступа.")
        return
    await update.message.reply_text(
        "Главное меню:",
        reply_markup=get_main_menu_keyboard()
    )

async def show_my_id(update: Update, context: ContextTypes.DEFAULT_TYPE):
    query = update.callback_query
    await query.answer()
    user_id = update.effective_user.id
    await query.edit_message_text(
        f"Ваш Telegram ID: `{user_id}`",
        parse_mode="Markdown"
    )
    # Показываем главное меню новым сообщением
    await query.message.reply_text(
        "Главное меню:",
        reply_markup=get_main_menu_keyboard()
    )

# ---------------------- Обработчик инлайн-кнопок ----------------------
async def button_handler(update: Update, context: ContextTypes.DEFAULT_TYPE):
    if not is_allowed(update):
        await update.callback_query.answer("⛔ Нет доступа", show_alert=True)
        return
    query = update.callback_query
    await query.answer()
    data = query.data

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
        await query.edit_message_text("Выберите срок действия:", reply_markup=InlineKeyboardMarkup(keyboard))

    elif data.startswith("dur_"):
        seconds = int(data.split("_")[1])
        context.user_data['duration'] = seconds
        duration_text = next((k for k, v in DURATION_MAP.items() if v == seconds), f"{seconds} сек")
        await query.edit_message_text(
            f"Вы выбрали: {duration_text}\n"
            "Введите имя клиента (латиница, 3-20 символов, можно - и _):"
        )
        context.user_data['awaiting_name'] = True

    elif data == "del_client":
        await query.edit_message_text("Введите имя клиента (email) для удаления:")
        context.user_data['awaiting_delete'] = True

    elif data == "list_clients":
        db = load_clients_db()
        if not db:
            keyboard = [[InlineKeyboardButton("◀️ Назад", callback_data="back_to_menu")]]
            await query.edit_message_text("Нет клиентов.", reply_markup=InlineKeyboardMarkup(keyboard))
            return
        msg = "📋 *Список клиентов:*\n\n"
        for email, info in db.items():
            expires = info.get("expires", 0)
            name = info.get("name", email)
            expire_str = "♾️ постоянный" if expires == 0 else f"⏰ до {datetime.fromtimestamp(expires).strftime('%Y-%m-%d %H:%M')}"
            msg += f"• *{name}* — {expire_str}\n"
        keyboard = [[InlineKeyboardButton("◀️ Назад", callback_data="back_to_menu")]]
        await query.edit_message_text(msg, parse_mode="Markdown", reply_markup=InlineKeyboardMarkup(keyboard))

    elif data == "stats":
        db = load_clients_db()
        if not db:
            keyboard = [[InlineKeyboardButton("◀️ Назад", callback_data="back_to_menu")]]
            await query.edit_message_text("Нет клиентов.", reply_markup=InlineKeyboardMarkup(keyboard))
            return
        msg = "📊 *Статистика использования:*\n\n"
        for email, info in db.items():
            name = info.get("name", email)
            up, down = get_client_stats(email)
            total_mb = (up + down) / (1024 * 1024)
            msg += f"• *{name}*: {total_mb:.2f} МБ\n"
        keyboard = [[InlineKeyboardButton("◀️ Назад", callback_data="back_to_menu")]]
        await query.edit_message_text(msg, parse_mode="Markdown", reply_markup=InlineKeyboardMarkup(keyboard))

    elif data == "my_id":
        await show_my_id(update, context)

    elif data == "back_to_menu":
        await query.edit_message_text("Главное меню:", reply_markup=get_main_menu_keyboard())

# ---------------------- Обработчик текстовых сообщений ----------------------
async def handle_message(update: Update, context: ContextTypes.DEFAULT_TYPE):
    if not is_allowed(update):
        await update.message.reply_text("⛔ Нет доступа.")
        return
    text = update.message.text.strip()

    # Добавление клиента (ожидание имени)
    if context.user_data.get('awaiting_name'):
        name = text
        if not re.match(r'^[a-zA-Z0-9_-]{3,20}$', name):
            await update.message.reply_text(
                "Некорректное имя. Разрешены буквы, цифры, - и _. Длина 3-20. Попробуйте снова /menu"
            )
            context.user_data['awaiting_name'] = False
            return
        duration = context.user_data.get('duration', 0)
        try:
            uuid = generate_uuid()
            email = name
            add_client_to_xray(email, uuid)
            db = load_clients_db()
            expire_ts = 0 if duration == 0 else int((datetime.now() + timedelta(seconds=duration)).timestamp())
            db[email] = {
                "name": name,
                "uuid": uuid,
                "expires": expire_ts,
                "created": int(datetime.now().timestamp())
            }
            save_clients_db(db)
            link = generate_vless_link(uuid, name)
            qr_img = generate_qr_code(link)

            # Генерируем .conf файл
            conf_content = generate_client_conf(uuid, name)
            logger.info(f"Generated .conf file for {name}, size: {len(conf_content)} bytes")
            conf_bytes = BytesIO(conf_content.encode('utf-8'))
            conf_bytes.seek(0)

            # Отправка данных клиента
            await update.message.reply_photo(photo=qr_img, caption=f"QR-код для {name}")
            await update.message.reply_document(
                document=conf_bytes,
                filename=f"{name}.conf",
                caption=f"Конфигурация Xray для {name}"
            )
            await update.message.reply_text(
                f"✅ Клиент *{name}* добавлен.\n\n"
                f"*Ссылка для импорта:*\n`{link}`\n\n"
                f"*UUID:* `{uuid}`\n"
                f"*Срок действия:* {DURATION_MAP.get(duration, 'Постоянный') if duration == 0 else f'{duration} сек'}",
                parse_mode="Markdown"
            )
        except Exception as e:
            logger.error(f"Error adding client: {e}")
            await update.message.reply_text(f"❌ Ошибка: {e}")
        finally:
            context.user_data['awaiting_name'] = False
            context.user_data.pop('duration', None)
            # Показываем главное меню
            await update.message.reply_text("Главное меню:", reply_markup=get_main_menu_keyboard())

    # Удаление клиента (ожидание email)
    elif context.user_data.get('awaiting_delete'):
        email = text
        try:
            remove_client_from_xray(email)
            db = load_clients_db()
            if email in db:
                del db[email]
                save_clients_db(db)
            await update.message.reply_text(f"🗑️ Клиент {email} удалён.")
        except Exception as e:
            logger.error(f"Error removing client: {e}")
            await update.message.reply_text(f"❌ Ошибка: {e}")
        finally:
            context.user_data['awaiting_delete'] = False
            # Показываем главное меню
            await update.message.reply_text("Главное меню:", reply_markup=get_main_menu_keyboard())

    else:
        await update.message.reply_text("Используйте /menu для управления.")

# ---------------------- Точка входа ----------------------
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

# Xray VLESS+REALITY с Telegram-ботом

Полнофункциональный VPN-сервер на базе Xray (VLESS + XTLS-Vision + REALITY) с управлением через Telegram-бота.

## Возможности
- Автоматическая установка Xray и всех зависимостей
- Управление пользователями через Telegram (добавление, удаление, статистика)
- Автоматическое удаление истекших клиентов
- Генерация ссылки, QR-кода и `.conf` файла для импорта в клиенты
- Маскировка трафика под обычный HTTPS (обход DPI)

## Быстрый старт
```bash
git clone https://github.com/SergeyIlins/xray-vless-reality-bot
cd xray-vless-reality-bot
sudo bash install.sh

#!/usr/bin/env python3
import json
import subprocess
import shutil
from datetime import datetime

CLIENTS_DB = "/opt/xray-bot/clients.json"
CONFIG_PATH = "/usr/local/etc/xray/config.json"
CONFIG_BACKUP = "/usr/local/etc/xray/config.json.bak"

INBOUND_TAGS = ["proxy", "hysteria", "split"]

def remove_client(email):
    with open(CONFIG_PATH, 'r') as f:
        config = json.load(f)
    deleted = False
    for tag in INBOUND_TAGS:
        for inbound in config['inbounds']:
            if inbound.get('tag') == tag:
                clients = inbound['settings']['clients']
                new_clients = [c for c in clients if c.get('email') != email]
                if len(new_clients) < len(clients):
                    inbound['settings']['clients'] = new_clients
                    deleted = True
    if not deleted:
        return False
    shutil.copy(CONFIG_PATH, CONFIG_BACKUP)
    with open(CONFIG_PATH, 'w') as f:
        json.dump(config, f, indent=2)
    subprocess.run(["/usr/bin/systemctl", "reload", "xray"], capture_output=True)
    return True

def main():
    try:
        with open(CLIENTS_DB, "r") as f:
            db = json.load(f)
    except FileNotFoundError:
        return
    now = datetime.now().timestamp()
    changed = False
    for email, info in list(db.items()):
        expires = info.get("expires", 0)
        if expires != 0 and expires < now:
            if remove_client(email):
                del db[email]
                changed = True
                print(f"Removed expired client: {email}")
    if changed:
        with open(CLIENTS_DB, "w") as f:
            json.dump(db, f, indent=2)

if __name__ == "__main__":
    main()

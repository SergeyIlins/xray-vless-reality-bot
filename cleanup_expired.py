#!/usr/bin/env python3
import json, subprocess, shutil, os
from datetime import datetime

CLIENTS_DB = "/opt/xray-bot/clients.json"
CONFIG_PATH = "/usr/local/etc/xray/config.json"
CONFIG_BACKUP = "/usr/local/etc/xray/config.json.bak"
WG_CONFIG = "/etc/amnezia/amneziawg.conf"

def remove_client_xray(email, protocol=None):
    tags = ["proxy"] if protocol == "vless" else ["split"] if protocol == "split" else ["proxy", "split"]
    with open(CONFIG_PATH) as f:
        config = json.load(f)
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
        return False
    shutil.copy(CONFIG_PATH, CONFIG_BACKUP)
    with open(CONFIG_PATH, 'w') as f:
        json.dump(config, f, indent=2)
    subprocess.run(["/usr/bin/systemctl", "reload", "xray"])
    return True

def remove_peer_awg(pubkey):
    lines = open(WG_CONFIG).read().splitlines()
    new_lines, skip = [], False
    for line in lines:
        if line.startswith("[Peer]") and f"PublicKey = {pubkey}" in lines[lines.index(line)+1]:
            skip = True
        elif line.startswith("[") and skip:
            skip = False
            new_lines.append(line)
        elif not skip:
            new_lines.append(line)
    with open(WG_CONFIG, 'w') as f:
        f.write("\n".join(new_lines))
    subprocess.run(["systemctl", "restart", "awg-quick@amneziawg"])

def main():
    try:
        with open(CLIENTS_DB) as f:
            db = json.load(f)
    except FileNotFoundError:
        return
    now = datetime.now().timestamp()
    changed = False
    for email, info in list(db.items()):
        expires = info.get("expires", 0)
        if expires and expires < now:
            proto = info.get("protocol", "vless")
            if proto == "awg":
                remove_peer_awg(info["uuid"])
            else:
                remove_client_xray(email, proto)
            del db[email]
            changed = True
    if changed:
        with open(CLIENTS_DB, 'w') as f:
            json.dump(db, f, indent=2)

if __name__ == "__main__":
    main()

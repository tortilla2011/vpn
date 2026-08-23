#!/usr/bin/env python3
import json
import sys
import subprocess
import argparse
import os

CONFIG_PATH = '/usr/local/etc/xray/config.json'

def update_client(uuid, expiry):
    with open(CONFIG_PATH, 'r') as f:
        config = json.load(f)
    for inbound in config.get('inbounds', []):
        if inbound.get('tag') == 'vless-inbound':
            clients = inbound['settings'].get('clients', [])
            found = False
            for client in clients:
                if client.get('id') == uuid:
                    client['expiry'] = expiry
                    found = True
                    break
            if not found:
                clients.append({
                    'id': uuid,
                    'flow': 'xtls-rprx-vision',
                    'expiry': expiry
                })
            inbound['settings']['clients'] = clients
            break
    with open(CONFIG_PATH, 'w') as f:
        json.dump(config, f, indent=2)
    subprocess.run(['systemctl', 'reload', 'xray'], check=False)
    print(f"Client {uuid} updated with expiry {expiry}")

if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--uuid', required=True)
    parser.add_argument('--expiry', type=int, required=True)
    args = parser.parse_args()
    update_client(args.uuid, args.expiry)
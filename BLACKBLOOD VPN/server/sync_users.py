#!/usr/bin/env python3
import json
import subprocess
import psycopg2

DB_CONN = "postgresql://blackblood:пароль@central-db-host:5432/blackblood"

def fetch_users():
    conn = psycopg2.connect(DB_CONN)
    cur = conn.cursor()
    cur.execute("SELECT uuid, EXTRACT(epoch FROM subscription_end)::int FROM users WHERE subscription_end > NOW();")
    rows = cur.fetchall()
    cur.close()
    conn.close()
    return [{'uuid': r[0], 'expiry': r[1]} for r in rows if r[0]]

def update_local_config(users):
    with open('/usr/local/etc/xray/config.json', 'r') as f:
        config = json.load(f)
    for inbound in config.get('inbounds', []):
        if inbound.get('tag') == 'vless-inbound':
            clients = []
            for u in users:
                clients.append({
                    'id': u['uuid'],
                    'flow': 'xtls-rprx-vision',
                    'expiry': u['expiry']
                })
            inbound['settings']['clients'] = clients
            break
    with open('/usr/local/etc/xray/config.json', 'w') as f:
        json.dump(config, f, indent=2)
    subprocess.run(['systemctl', 'reload', 'xray'])

if __name__ == '__main__':
    users = fetch_users()
    update_local_config(users)
cat > /root/setup_vpn.sh << 'SETUP_EOF'
#!/bin/bash
set -e

# ========== Цвета ==========
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo -e "${GREEN}=== BlackBlood VPN Server Auto-Setup ===${NC}"

# ========== 1. Обновление системы ==========
echo -e "${YELLOW}[1/9] Обновление системы...${NC}"
export DEBIAN_FRONTEND=noninteractive
apt update -y
apt upgrade -y
apt install -y curl wget ufw fail2ban net-tools jq iptables-persistent python3

# ========== 2. Установка Xray ==========
echo -e "${YELLOW}[2/9] Установка Xray...${NC}"
bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install
systemctl enable xray

# ========== 3. Генерация ключей Reality ==========
echo -e "${YELLOW}[3/9] Генерация ключей Reality...${NC}"
KEYS=$(xray x25519)
PRIVATE_KEY=$(echo "$KEYS" | grep -i "private" | awk '{print $NF}')
PUBLIC_KEY=$(echo "$KEYS" | grep -i "public" | awk '{print $NF}')
SHORT_ID=$(openssl rand -hex 8)

if [ -z "$PRIVATE_KEY" ] || [ -z "$PUBLIC_KEY" ]; then
    echo "ОШИБКА: не удалось сгенерировать ключи"
    exit 1
fi

echo "  Private key: $PRIVATE_KEY"
echo "  Public key:  $PUBLIC_KEY"
echo "  Short ID:    $SHORT_ID"

# ========== 4. Создание конфига Xray ==========
echo -e "${YELLOW}[4/9] Создание конфига Xray...${NC}"
mkdir -p /usr/local/etc/xray

cat > /usr/local/etc/xray/config.json << XRAY_EOF
{
  "log": { "loglevel": "warning" },
  "api": {
    "services": ["HandlerService", "LoggerService", "StatsService"],
    "tag": "api"
  },
  "inbounds": [
    {
      "port": 443,
      "protocol": "vless",
      "tag": "vless-inbound",
      "settings": {
        "clients": [],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "xhttp",
        "xhttpSettings": {
          "mode": "auto",
          "path": "/api/v1/updates"
        },
        "security": "reality",
        "realitySettings": {
          "dest": "www.microsoft.com:443",
          "serverNames": ["www.microsoft.com", "www.google.com", "www.apple.com", "vk.com", "yandex.ru"],
          "privateKey": "$PRIVATE_KEY",
          "shortIds": ["$SHORT_ID"],
          "publicKey": "$PUBLIC_KEY"
        }
      }
    }
  ],
  "outbounds": [
    { "protocol": "freedom", "tag": "direct" },
    { "protocol": "blackhole", "tag": "block" }
  ],
  "policy": {
    "levels": {
      "0": {
        "handshake": 4,
        "connIdle": 300,
        "statsUserUplink": true,
        "statsUserDownlink": true
      }
    }
  },
  "stats": {},
  "routing": {
    "rules": [
      { "type": "field", "inboundTag": ["api"], "outboundTag": "api" }
    ]
  }
}
XRAY_EOF

# ========== 5. Скрипт update_client.py ==========
echo -e "${YELLOW}[5/9] Создание update_client.py...${NC}"
mkdir -p /opt/blackblood/server

cat > /opt/blackblood/server/update_client.py << 'PY_EOF'
#!/usr/bin/env python3
import json
import sys
import subprocess
import argparse
import os

CONFIG_PATH = '/usr/local/etc/xray/config.json'

def update_client(uuid, expiry):
    if not os.path.exists(CONFIG_PATH):
        print(f"ERROR: Config file not found: {CONFIG_PATH}", file=sys.stderr)
        sys.exit(1)

    with open(CONFIG_PATH, 'r') as f:
        config = json.load(f)

    found_inbound = False
    for inbound in config.get('inbounds', []):
        if inbound.get('tag') == 'vless-inbound':
            found_inbound = True
            clients = inbound['settings'].get('clients', [])
            found_client = False
            for client in clients:
                if client.get('id') == uuid:
                    client['expiry'] = expiry
                    found_client = True
                    break
            if not found_client:
                clients.append({
                    'id': uuid,
                    'flow': 'xtls-rprx-vision',
                    'expiry': expiry
                })
            inbound['settings']['clients'] = clients
            break

    if not found_inbound:
        print("ERROR: inbound 'vless-inbound' not found", file=sys.stderr)
        sys.exit(1)

    with open(CONFIG_PATH, 'w') as f:
        json.dump(config, f, indent=2, ensure_ascii=False)

    result = subprocess.run(['systemctl', 'restart', 'xray'], capture_output=True, text=True)
    if result.returncode != 0:
        print(f"WARNING: xray restart failed: {result.stderr}", file=sys.stderr)
    else:
        print(f"OK: Client {uuid} updated with expiry {expiry}")

if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--uuid', required=True)
    parser.add_argument('--expiry', type=int, required=True)
    args = parser.parse_args()
    update_client(args.uuid, args.expiry)
PY_EOF

chmod +x /opt/blackblood/server/update_client.py

# ========== 6. Firewall ==========
echo -e "${YELLOW}[6/9] Настройка firewall...${NC}"
ufw --force reset
ufw default deny incoming
ufw default allow outgoing
ufw allow 22/tcp
ufw allow 443/tcp
ufw --force enable

# ========== 7. iptables (SYN-flood, connlimit) ==========
echo -e "${YELLOW}[7/9] Настройка iptables...${NC}"
iptables -A INPUT -p tcp --syn -m limit --limit 1/s --limit-burst 3 -j ACCEPT || true
iptables -A INPUT -p tcp --syn -j DROP || true
iptables -A INPUT -p tcp --dport 443 -m connlimit --connlimit-above 100 -j DROP || true
iptables -A INPUT -m state --state INVALID -j DROP || true
netfilter-persistent save

# ========== 8. fail2ban ==========
echo -e "${YELLOW}[8/9] Настройка fail2ban...${NC}"
systemctl enable fail2ban
systemctl start fail2ban

# ========== 9. Запуск Xray ==========
echo -e "${YELLOW}[9/9] Запуск Xray...${NC}"
systemctl restart xray
sleep 2
systemctl status xray --no-pager | head -5

# ========== Финальный отчёт ==========
SERVER_IP=$(curl -s ifconfig.me)

echo ""
echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}  VPN-сервер успешно настроен!${NC}"
echo -e "${GREEN}========================================${NC}"
echo ""
echo "IP сервера: $SERVER_IP"
echo ""
echo "Скопируйте эти данные и добавьте на ГЛАВНЫЙ сервер в .env:"
echo ""
echo -e "${YELLOW}XRAY_SERVERS_JSON='[{\"host\":\"$SERVER_IP\",\"port\":443,\"public_key\":\"$PUBLIC_KEY\",\"short_id\":\"$SHORT_ID\"}]'${NC}"
echo ""
echo "Если у вас уже есть другие серверы — добавьте этот объект в существующий массив:"
echo -e "${YELLOW}{\"host\":\"$SERVER_IP\",\"port\":443,\"public_key\":\"$PUBLIC_KEY\",\"short_id\":\"$SHORT_ID\"}${NC}"
echo ""
echo "Готово. Xray работает на порту 443."
SETUP_EOF

chmod +x /root/setup_vpn.sh
bash /root/setup_vpn.sh

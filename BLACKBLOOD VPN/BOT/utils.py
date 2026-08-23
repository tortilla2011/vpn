import qrcode
import io
import uuid as uuid_lib
from datetime import datetime, timedelta
import json

def generate_referral_code(tg_id):
    return f"ref_{tg_id}"

def generate_uuid():
    return str(uuid_lib.uuid4())

def generate_vless_link(user_uuid, server_host, port, public_key, short_id, flow="xtls-rprx-vision"):
    params = f"encryption=none&security=reality&sni=www.microsoft.com&fp=chrome&pbk={public_key}&sid={short_id}&flow={flow}"
    link = f"vless://{user_uuid}@{server_host}:{port}?{params}#BlackBlood_{server_host}"
    return link

def generate_qr(data):
    qr = qrcode.QRCode(box_size=10, border=4)
    qr.add_data(data)
    qr.make(fit=True)
    img = qr.make_image(fill_color="black", back_color="white")
    bio = io.BytesIO()
    img.save(bio, format='PNG')
    bio.seek(0)
    return bio

def get_subscription_status(user):
    if user.subscription_end is None:
        return "Неактивна"
    now = datetime.utcnow()
    if user.subscription_end > now:
        days_left = (user.subscription_end - now).days
        return f"Активна, осталось {days_left} дн."
    else:
        return "Истекла"

def generate_client_config_with_balancer(user_uuid, servers):
    """
    Генерирует полный JSON-конфиг для клиента с балансировкой по всем серверам.
    """
    outbounds = []
    for idx, srv in enumerate(servers):
        tag = f"server-{idx}"
        outbound = {
            "tag": tag,
            "protocol": "vless",
            "settings": {
                "vnext": [{
                    "address": srv['host'],
                    "port": srv['port'],
                    "users": [{
                        "id": user_uuid,
                        "flow": "xtls-rprx-vision",
                        "encryption": "none"
                    }]
                }]
            },
            "streamSettings": {
                "network": "tcp",
                "security": "reality",
                "realitySettings": {
                    "serverName": "www.microsoft.com",
                    "fingerprint": "chrome",
                    "publicKey": srv['public_key'],
                    "shortId": srv['short_id']
                }
            }
        }
        outbounds.append(outbound)

    selector_tags = [f"server-{idx}" for idx in range(len(servers))]
    balancer = {
        "tag": "balancer",
        "protocol": "balancer",
        "settings": {
            "selector": selector_tags,
            "fallbackTag": selector_tags[0] if selector_tags else "",
            "strategy": "leastPing"
        }
    }
    outbounds.append(balancer)

    config = {
        "log": {"loglevel": "warning"},
        "inbounds": [
            {
                "port": 10808,
                "protocol": "socks",
                "settings": {"auth": "noauth", "udp": True}
            }
        ],
        "outbounds": outbounds,
        "routing": {
            "rules": [
                {
                    "type": "field",
                    "network": "tcp,udp",
                    "outboundTag": "balancer"
                }
            ]
        }
    }
    return json.dumps(config, indent=2)
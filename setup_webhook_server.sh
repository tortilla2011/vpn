cat > /root/setup_webhook.sh << 'SETUP_EOF'
#!/bin/bash
set -e

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

echo -e "${GREEN}=== BlackBlood Main Server Auto-Setup (Bot + Webhook) ===${NC}"
echo ""

# ========== Сбор данных ==========
read -p "Домен для вебхука (например, webhook.blackblood.ru): " WEBHOOK_DOMAIN
read -p "Email для SSL (Let's Encrypt): " LE_EMAIL
read -p "Токен Telegram-бота: " BOT_TOKEN
read -p "ЮKassa Shop ID: " YK_SHOP_ID
read -p "ЮKassa Secret Key: " YK_SECRET_KEY
read -p "Пароль для PostgreSQL (придумайте): " DB_PASSWORD
read -p "XRAY_SERVERS_JSON (вставьте JSON из VPN-скрипта): " XRAY_SERVERS

echo ""
echo -e "${YELLOW}Проверьте данные:${NC}"
echo "  Домен: $WEBHOOK_DOMAIN"
echo "  Email: $LE_EMAIL"
echo "  Bot token: ${BOT_TOKEN:0:10}..."
echo "  Shop ID: $YK_SHOP_ID"
echo "  Servers: $XRAY_SERVERS"
echo ""
read -p "Продолжить? (y/n): " CONFIRM
if [ "$CONFIRM" != "y" ]; then
    echo "Отменено."
    exit 1
fi

# ========== 1. Обновление и пакеты ==========
echo -e "${YELLOW}[1/9] Установка пакетов...${NC}"
export DEBIAN_FRONTEND=noninteractive
apt update -y
apt upgrade -y
apt install -y python3 python3-pip python3-venv postgresql postgresql-contrib nginx certbot python3-certbot-nginx curl wget git ufw

# ========== 2. PostgreSQL ==========
echo -e "${YELLOW}[2/9] Настройка PostgreSQL...${NC}"
sudo -u postgres psql << SQL_EOF
DROP DATABASE IF EXISTS blackblood;
DROP USER IF EXISTS blackblood;
CREATE DATABASE blackblood;
CREATE USER blackblood WITH PASSWORD '$DB_PASSWORD';
GRANT ALL PRIVILEGES ON DATABASE blackblood TO blackblood;
ALTER USER blackblood WITH SUPERUSER;
SQL_EOF

# ========== 3. Структура проекта ==========
echo -e "${YELLOW}[3/9] Создание структуры проекта...${NC}"
mkdir -p /opt/blackblood/{bot,server,systemd}
cd /opt/blackblood

# ========== 4. Файлы проекта ==========
echo -e "${YELLOW}[4/9] Создание файлов проекта...${NC}"

# .env
cat > /opt/blackblood/.env << ENV_EOF
BOT_TOKEN=$BOT_TOKEN
DB_HOST=localhost
DB_PORT=5432
DB_NAME=blackblood
DB_USER=blackblood
DB_PASSWORD=$DB_PASSWORD
PRICE_MONTH=160.0
TRIAL_DAYS=3
REFERRAL_BONUS_DAYS=3
XRAY_SERVERS_JSON='$XRAY_SERVERS'
YOOKASSA_SHOP_ID=$YK_SHOP_ID
YOOKASSA_SECRET_KEY=$YK_SECRET_KEY
YOOKASSA_RETURN_URL=https://t.me/blackblood_bot
ENV_EOF

chmod 600 /opt/blackblood/.env

# requirements.txt
cat > /opt/blackblood/requirements.txt << 'REQ_EOF'
python-telegram-bot==20.7
sqlalchemy==2.0.23
psycopg2-binary==2.9.9
python-dotenv==1.0.0
requests==2.31.0
cryptography==41.0.5
yookassa==3.1.0
fastapi==0.104.1
uvicorn[standard]==0.24.0
paramiko==3.4.0
REQ_EOF

# bot/__init__.py
touch /opt/blackblood/bot/__init__.py

# bot/config.py
cat > /opt/blackblood/bot/config.py << 'CONF_EOF'
import os
from dotenv import load_dotenv
import json

load_dotenv()

BOT_TOKEN = os.getenv('BOT_TOKEN')
DB_URL = f"postgresql://{os.getenv('DB_USER')}:{os.getenv('DB_PASSWORD')}@{os.getenv('DB_HOST')}:{os.getenv('DB_PORT')}/{os.getenv('DB_NAME')}"
PRICE_MONTH = float(os.getenv('PRICE_MONTH', 160.0))
TRIAL_DAYS = int(os.getenv('TRIAL_DAYS', 3))
REFERRAL_BONUS_DAYS = int(os.getenv('REFERRAL_BONUS_DAYS', 3))
XRAY_SERVERS = json.loads(os.getenv('XRAY_SERVERS_JSON', '[]'))
YOOKASSA_SHOP_ID = os.getenv('YOOKASSA_SHOP_ID')
YOOKASSA_SECRET_KEY = os.getenv('YOOKASSA_SECRET_KEY')
YOOKASSA_RETURN_URL = os.getenv('YOOKASSA_RETURN_URL', 'https://t.me/blackblood_bot')
CONF_EOF

# bot/models.py
cat > /opt/blackblood/bot/models.py << 'MOD_EOF'
from sqlalchemy import create_engine, Column, Integer, String, Float, DateTime, ForeignKey, BigInteger
from sqlalchemy.ext.declarative import declarative_base
from sqlalchemy.orm import sessionmaker, relationship
from datetime import datetime
from .config import DB_URL

Base = declarative_base()

class User(Base):
    __tablename__ = 'users'
    id = Column(Integer, primary_key=True)
    tg_id = Column(BigInteger, unique=True, nullable=False)
    username = Column(String(255))
    balance = Column(Float, default=0.0)
    subscription_end = Column(DateTime, nullable=True)
    referral_code = Column(String(50), unique=True, nullable=False)
    referrer_id = Column(Integer, ForeignKey('users.id'), nullable=True)
    uuid = Column(String(36), unique=True, nullable=True)
    created_at = Column(DateTime, default=datetime.utcnow)
    referrer = relationship('User', remote_side=[id], backref='referrals')

class Payment(Base):
    __tablename__ = 'payments'
    id = Column(Integer, primary_key=True)
    user_id = Column(Integer, ForeignKey('users.id'))
    amount = Column(Float)
    payment_system = Column(String(50))
    external_id = Column(String(100), unique=True)
    status = Column(String(20), default='pending')
    created_at = Column(DateTime, default=datetime.utcnow)

class ReferralBonus(Base):
    __tablename__ = 'referral_bonuses'
    id = Column(Integer, primary_key=True)
    referrer_id = Column(Integer, ForeignKey('users.id'))
    referred_id = Column(Integer, ForeignKey('users.id'))
    days_added = Column(Integer, default=3)
    created_at = Column(DateTime, default=datetime.utcnow)

def init_db():
    engine = create_engine(DB_URL)
    Base.metadata.create_all(engine)
MOD_EOF

# bot/texts.py
cat > /opt/blackblood/bot/texts.py << 'TXT_EOF'
LICENSE_AGREEMENT = """
**Лицензионное соглашение** (краткая версия)

1. Сервис BlackBlood VPN предоставляется «как есть».
2. Мы не гарантируем 100% доступность.
3. Пользователь обязуется не использовать VPN для незаконных действий.
4. Администрация вправе блокировать аккаунты при нарушении правил.
5. Срок подписки не продлевается при блокировке по вине пользователя.

Полный текст: https://blackblood-vpn.com/license
"""

PRIVACY_POLICY = """
**Политика конфиденциальности**

1. Мы собираем минимальные данные: Telegram ID, дату подписки, баланс.
2. Мы НЕ логируем ваш трафик, посещённые сайты, IP-адреса.
3. Ваши данные не передаются третьим лицам, кроме платёжных партнёров.
4. Вы можете удалить свои данные, написав в поддержку.

Полный текст: https://blackblood-vpn.com/privacy
"""

WELCOME_TEXT = "Добро пожаловать в BlackBlood VPN! 🖤\nВаш пробный период на 3 дня активирован."
MAIN_MENU = "Главное меню:"
TXT_EOF

# bot/utils.py
cat > /opt/blackblood/bot/utils.py << 'UTL_EOF'
import uuid as uuid_lib
from datetime import datetime
import json
import random

SNI_POOL = ["www.microsoft.com", "www.google.com", "www.apple.com", "vk.com", "yandex.ru"]

def generate_referral_code(tg_id):
    return f"ref_{tg_id}"

def generate_uuid():
    return str(uuid_lib.uuid4())

def generate_vless_link(user_uuid, server_host, port, public_key, short_id, flow="xtls-rprx-vision"):
    params = f"encryption=none&security=reality&sni=www.microsoft.com&fp=chrome&pbk={public_key}&sid={short_id}&flow={flow}"
    return f"vless://{user_uuid}@{server_host}:{port}?{params}#BlackBlood_{server_host}"

def get_subscription_status(user):
    if user.subscription_end is None:
        return "Неактивна"
    now = datetime.utcnow()
    if user.subscription_end > now:
        return f"Активна, осталось {(user.subscription_end - now).days} дн."
    return "Истекла"

def generate_client_config_with_balancer(user_uuid, servers):
    outbounds = []
    for idx, srv in enumerate(servers):
        sni = random.choice(SNI_POOL)
        outbounds.append({
            "tag": f"server-{idx}",
            "protocol": "vless",
            "settings": {"vnext": [{"address": srv['host'], "port": srv['port'], "users": [{"id": user_uuid, "flow": "xtls-rprx-vision", "encryption": "none"}]}]},
            "streamSettings": {
                "network": "xhttp",
                "xhttpSettings": {"mode": "auto", "path": "/api/v1/updates"},
                "security": "reality",
                "realitySettings": {"serverName": sni, "fingerprint": "chrome", "publicKey": srv['public_key'], "shortId": srv['short_id']}
            }
        })
    selector_tags = [f"server-{idx}" for idx in range(len(servers))]
    outbounds.append({
        "tag": "balancer",
        "protocol": "balancer",
        "settings": {"selector": selector_tags, "fallbackTag": selector_tags[0] if selector_tags else "", "strategy": "leastPing"}
    })
    return json.dumps({
        "log": {"loglevel": "warning"},
        "inbounds": [{"port": 10808, "protocol": "socks", "settings": {"auth": "noauth", "udp": True}}],
        "outbounds": outbounds,
        "routing": {"rules": [{"type": "field", "network": "tcp,udp", "outboundTag": "balancer"}]}
    }, indent=2)
UTL_EOF

# bot/payments.py
cat > /opt/blackblood/bot/payments.py << 'PAY_EOF'
import uuid
from yookassa import Configuration, Payment
from .config import YOOKASSA_SHOP_ID, YOOKASSA_SECRET_KEY, YOOKASSA_RETURN_URL
import logging

logger = logging.getLogger(__name__)
Configuration.account_id = YOOKASSA_SHOP_ID
Configuration.secret_key = YOOKASSA_SECRET_KEY

def create_yookassa_payment(user_id, amount, description="Пополнение баланса BlackBlood VPN"):
    try:
        payment = Payment.create({
            "amount": {"value": f"{amount:.2f}", "currency": "RUB"},
            "confirmation": {"type": "redirect", "return_url": YOOKASSA_RETURN_URL},
            "description": description,
            "metadata": {"user_id": str(user_id)}
        }, str(uuid.uuid4()))
        return {'payment_id': payment.id, 'confirmation_url': payment.confirmation.confirmation_url, 'status': payment.status}
    except Exception as e:
        logger.error(f"ЮKassa error: {e}")
        return None
PAY_EOF

# bot/xray_api.py
cat > /opt/blackblood/bot/xray_api.py << 'XAPI_EOF'
import subprocess
import logging

logger = logging.getLogger(__name__)
UPDATE_SCRIPT = '/opt/blackblood/server/update_client.py'

def update_client_on_server(uuid, expiry_timestamp):
    try:
        cmd = ['python3', UPDATE_SCRIPT, '--uuid', uuid, '--expiry', str(expiry_timestamp)]
        result = subprocess.run(cmd, capture_output=True, text=True, check=True)
        logger.info(f"Xray update: {result.stdout.strip()}")
        return True
    except subprocess.CalledProcessError as e:
        logger.error(f"Xray update failed: {e.stderr}")
        return False
XAPI_EOF

# bot/handlers.py
cat > /opt/blackblood/bot/handlers.py << 'HDL_EOF'
from telegram import Update, InlineKeyboardButton, InlineKeyboardMarkup, ReplyKeyboardMarkup
from telegram.ext import ContextTypes
from sqlalchemy import create_engine
from sqlalchemy.orm import sessionmaker
import datetime
import io

from .config import DB_URL, PRICE_MONTH, TRIAL_DAYS, REFERRAL_BONUS_DAYS, XRAY_SERVERS
from .models import User, ReferralBonus, Payment, init_db
from .texts import LICENSE_AGREEMENT, PRIVACY_POLICY, WELCOME_TEXT, MAIN_MENU
from .utils import generate_referral_code, generate_uuid, get_subscription_status, generate_client_config_with_balancer, generate_vless_link
from .xray_api import update_client_on_server
from .payments import create_yookassa_payment

init_db()
engine = create_engine(DB_URL)
SessionLocal = sessionmaker(bind=engine)

def main_menu_keyboard():
    return ReplyKeyboardMarkup([
        ["🛒 Купить VPN (160 руб)"],
        ["💳 Пополнить баланс"],
        ["👤 Мой профиль"],
        ["👥 Реферальная система"],
        ["❓ Помощь"]
    ], resize_keyboard=True)

async def start(update: Update, context: ContextTypes.DEFAULT_TYPE):
    tg_id = update.effective_user.id
    session = SessionLocal()
    db_user = session.query(User).filter_by(tg_id=tg_id).first()
    if db_user and db_user.subscription_end and db_user.subscription_end > datetime.datetime.utcnow():
        await update.message.reply_text("Вы уже активировали VPN. Используйте меню ниже.", reply_markup=main_menu_keyboard())
        session.close()
        return
    if context.user_data.get('agreed'):
        await register_user(update, context)
        return
    keyboard = [[InlineKeyboardButton("✅ Принять", callback_data='accept_agreement')], [InlineKeyboardButton("❌ Отклонить", callback_data='decline_agreement')]]
    await update.message.reply_text(f"{LICENSE_AGREEMENT}\n\n{PRIVACY_POLICY}", reply_markup=InlineKeyboardMarkup(keyboard))
    session.close()

async def accept_agreement(update: Update, context: ContextTypes.DEFAULT_TYPE):
    query = update.callback_query
    await query.answer()
    context.user_data['agreed'] = True
    await query.edit_message_text("Соглашение принято. Спасибо!")
    await register_user(update, context)

async def decline_agreement(update: Update, context: ContextTypes.DEFAULT_TYPE):
    query = update.callback_query
    await query.answer()
    await query.edit_message_text("Извините, для работы нашего VPN нужно принять пользовательское соглашение и политику конфиденциальности.")

async def register_user(update: Update, context: ContextTypes.DEFAULT_TYPE):
    user = update.effective_user
    session = SessionLocal()
    db_user = session.query(User).filter_by(tg_id=user.id).first()
    if not db_user:
        new_expiry = datetime.datetime.utcnow() + datetime.timedelta(days=TRIAL_DAYS)
        db_user = User(tg_id=user.id, username=user.username, referral_code=generate_referral_code(user.id), uuid=generate_uuid(), subscription_end=new_expiry)
        session.add(db_user)
        session.commit()
        update_client_on_server(db_user.uuid, int(new_expiry.timestamp()))
        start_param = context.args[0] if context.args else None
        if start_param and start_param.startswith('ref_'):
            referrer = session.query(User).filter_by(referral_code=start_param).first()
            if referrer and referrer.id != db_user.id:
                referrer.subscription_end += datetime.timedelta(days=REFERRAL_BONUS_DAYS)
                session.add(ReferralBonus(referrer_id=referrer.id, referred_id=db_user.id, days_added=REFERRAL_BONUS_DAYS))
                session.commit()
        await send_client_config(update, db_user.uuid)
        await update.effective_message.reply_text(WELCOME_TEXT, reply_markup=main_menu_keyboard())
    else:
        await update.effective_message.reply_text("Ваша подписка истекла. Пополните баланс и купите период.", reply_markup=main_menu_keyboard())
    session.close()

async def send_client_config(update, user_uuid):
    if not XRAY_SERVERS:
        await update.effective_message.reply_text("Серверы временно недоступны.")
        return
    config_json = generate_client_config_with_balancer(user_uuid, XRAY_SERVERS)
    file_obj = io.BytesIO(config_json.encode('utf-8'))
    file_obj.name = 'config.json'
    await update.effective_message.reply_document(document=file_obj, caption="Импортируйте этот файл в Happ / V2RayTun.")
    srv = XRAY_SERVERS[0]
    link = generate_vless_link(user_uuid, srv['host'], srv['port'], srv['public_key'], srv['short_id'])
    await update.effective_message.reply_text(f"Альтернативная ссылка:\n`{link}`", parse_mode='Markdown')

async def handle_menu(update: Update, context: ContextTypes.DEFAULT_TYPE):
    text = update.message.text
    if text == "🛒 Купить VPN (160 руб)": await buy_vpn(update, context)
    elif text == "💳 Пополнить баланс": await deposit(update, context)
    elif text == "👤 Мой профиль": await profile(update, context)
    elif text == "👥 Реферальная система": await referral(update, context)
    elif text == "❓ Помощь": await help_command(update, context)
    else: await update.message.reply_text("Используйте кнопки меню.", reply_markup=main_menu_keyboard())

async def profile(update, context):
    tg_id = update.effective_user.id
    session = SessionLocal()
    user = session.query(User).filter_by(tg_id=tg_id).first()
    if not user:
        await update.message.reply_text("Используйте /start")
        session.close()
        return
    ref_count = session.query(ReferralBonus).filter_by(referrer_id=user.id).count()
    text = f"👤 **Профиль**\n🆔 ID: {user.tg_id}\n💰 Баланс: {user.balance:.2f} руб.\n📅 Подписка: {get_subscription_status(user)}\n👥 Рефералов: {ref_count}\n🔗 Ссылка: `https://t.me/blackblood_bot?start={user.referral_code}`"
    await update.message.reply_text(text, parse_mode='Markdown', reply_markup=main_menu_keyboard())
    session.close()

async def referral(update, context):
    tg_id = update.effective_user.id
    session = SessionLocal()
    user = session.query(User).filter_by(tg_id=tg_id).first()
    if not user:
        await update.message.reply_text("Используйте /start")
        session.close()
        return
    ref_count = session.query(ReferralBonus).filter_by(referrer_id=user.id).count()
    text = f"👥 **Реферальная система**\nЗа каждого друга +{REFERRAL_BONUS_DAYS} дня.\n🔗 `https://t.me/blackblood_bot?start={user.referral_code}`\nПриглашено: {ref_count}"
    await update.message.reply_text(text, parse_mode='Markdown', reply_markup=main_menu_keyboard())
    session.close()

async def buy_vpn(update, context):
    tg_id = update.effective_user.id
    session = SessionLocal()
    user = session.query(User).filter_by(tg_id=tg_id).first()
    if not user:
        await update.message.reply_text("Используйте /start")
        session.close()
        return
    if user.balance < PRICE_MONTH:
        await update.message.reply_text(f"Недостаточно средств. Баланс: {user.balance:.2f} руб.", reply_markup=main_menu_keyboard())
        session.close()
        return
    user.balance -= PRICE_MONTH
    if not user.subscription_end or user.subscription_end < datetime.datetime.utcnow():
        user.subscription_end = datetime.datetime.utcnow() + datetime.timedelta(days=30)
    else:
        user.subscription_end += datetime.timedelta(days=30)
    session.commit()
    if user.uuid:
        update_client_on_server(user.uuid, int(user.subscription_end.timestamp()))
    session.close()
    await update.message.reply_text("✅ Подписка продлена на 30 дней.", reply_markup=main_menu_keyboard())

async def deposit(update, context):
    tg_id = update.effective_user.id
    session = SessionLocal()
    user = session.query(User).filter_by(tg_id=tg_id).first()
    if not user:
        await update.message.reply_text("Используйте /start")
        session.close()
        return
    result = create_yookassa_payment(user.id, PRICE_MONTH)
    if result:
        session.add(Payment(user_id=user.id, amount=PRICE_MONTH, payment_system='yookassa', external_id=result['payment_id'], status='pending'))
        session.commit()
        session.close()
        await update.message.reply_text(f"💳 **Оплата {PRICE_MONTH} руб.**\n\n{result['confirmation_url']}\n\nПосле оплаты баланс зачислится автоматически.", reply_markup=main_menu_keyboard())
    else:
        session.close()
        await update.message.reply_text("Ошибка создания счёта.", reply_markup=main_menu_keyboard())

async def help_command(update, context):
    await update.message.reply_text("""
❓ **Помощь**
1. Скачайте Happ или V2RayTun.
2. Импортируйте config.json.
3. Подключитесь.

Поддержка: @blackblood_support
    """, reply_markup=main_menu_keyboard())
HDL_EOF

# bot/main.py
cat > /opt/blackblood/bot/main.py << 'MAIN_EOF'
import logging
from telegram.ext import Application, CommandHandler, CallbackQueryHandler, MessageHandler, filters
from .config import BOT_TOKEN
from .handlers import start, accept_agreement, decline_agreement, handle_menu

logging.basicConfig(level=logging.INFO)

def main():
    app = Application.builder().token(BOT_TOKEN).build()
    app.add_handler(CommandHandler('start', start))
    app.add_handler(CallbackQueryHandler(accept_agreement, pattern='^accept_agreement$'))
    app.add_handler(CallbackQueryHandler(decline_agreement, pattern='^decline_agreement$'))
    app.add_handler(MessageHandler(filters.TEXT & ~filters.COMMAND, handle_menu))
    app.run_polling()

if __name__ == '__main__':
    main()
MAIN_EOF

# bot/webhook.py
cat > /opt/blackblood/bot/webhook.py << 'WH_EOF'
import json
import hmac
import hashlib
from fastapi import FastAPI, Request, HTTPException
from sqlalchemy import create_engine
from sqlalchemy.orm import sessionmaker
from datetime import datetime

from .config import DB_URL, YOOKASSA_SECRET_KEY
from .models import User, Payment

app = FastAPI()
engine = create_engine(DB_URL)
SessionLocal = sessionmaker(bind=engine)

@app.post("/webhook/yookassa")
async def yookassa_webhook(request: Request):
    body = await request.body()
    data = json.loads(body)

    signature = request.headers.get("X-Yandex-Signature")
    if not signature:
        raise HTTPException(status_code=400, detail="Missing signature")

    expected = hmac.new(YOOKASSA_SECRET_KEY.encode(), body, hashlib.sha256).hexdigest()
    if not hmac.compare_digest(signature, expected):
        raise HTTPException(status_code=403, detail="Invalid signature")

    if data.get("event") != "payment.succeeded":
        return {"status": "ignored"}

    payment_id = data["object"]["id"]
    amount = float(data["object"]["amount"]["value"])
    user_id = data["object"]["metadata"].get("user_id")
    if not user_id:
        raise HTTPException(status_code=400, detail="Missing user_id")

    session = SessionLocal()
    if session.query(Payment).filter_by(external_id=payment_id).first():
        session.close()
        return {"status": "already_processed"}

    user = session.query(User).filter_by(id=int(user_id)).first()
    if not user:
        session.close()
        raise HTTPException(status_code=404, detail="User not found")

    user.balance += amount
    session.add(Payment(user_id=user.id, amount=amount, payment_system="yookassa", external_id=payment_id, status="succeeded", created_at=datetime.utcnow()))
    session.commit()
    session.close()
    return {"status": "success"}
WH_EOF

# run_webhook.py
cat > /opt/blackblood/run_webhook.py << 'RUN_EOF'
import uvicorn
from bot.webhook import app

if __name__ == "__main__":
    uvicorn.run(app, host="127.0.0.1", port=8000)
RUN_EOF

# ========== 5. venv и зависимости ==========
echo -e "${YELLOW}[5/9] Установка Python-зависимостей...${NC}"
cd /opt/blackblood
python3 -m venv venv
source venv/bin/activate
pip install --upgrade pip
pip install -r requirements.txt

# ========== 6. Nginx ==========
echo -e "${YELLOW}[6/9] Настройка Nginx...${NC}"
cat > /etc/nginx/sites-available/blackblood << NGINX_EOF
server {
    listen 80;
    server_name $WEBHOOK_DOMAIN;
    location / {
        proxy_pass http://127.0.0.1:8000;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }
}
NGINX_EOF

ln -sf /etc/nginx/sites-available/blackblood /etc/nginx/sites-enabled/
rm -f /etc/nginx/sites-enabled/default
nginx -t
systemctl reload nginx

# ========== 7. Firewall ==========
echo -e "${YELLOW}[7/9] Настройка firewall...${NC}"
ufw --force reset
ufw default deny incoming
ufw default allow outgoing
ufw allow 22/tcp
ufw allow 80/tcp
ufw allow 443/tcp
ufw --force enable

# ========== 8. SSL Certbot ==========
echo -e "${YELLOW}[8/9] Получение SSL-сертификата...${NC}"
certbot --nginx -d "$WEBHOOK_DOMAIN" --non-interactive --agree-tos --email "$LE_EMAIL" --redirect || echo "SSL failed — проверьте DNS"

# ========== 9. systemd-сервисы ==========
echo -e "${YELLOW}[9/9] Создание systemd-сервисов...${NC}"

cat > /etc/systemd/system/blackblood-bot.service << 'BOT_SVC'
[Unit]
Description=BlackBlood VPN Bot
After=network.target postgresql.service

[Service]
Type=simple
User=root
WorkingDirectory=/opt/blackblood
ExecStart=/opt/blackblood/venv/bin/python -m bot.main
Restart=always
RestartSec=10
Environment="PYTHONUNBUFFERED=1"

[Install]
WantedBy=multi-user.target
BOT_SVC

cat > /etc/systemd/system/blackblood-webhook.service << 'WH_SVC'
[Unit]
Description=BlackBlood VPN Webhook
After=network.target postgresql.service

[Service]
Type=simple
User=root
WorkingDirectory=/opt/blackblood
ExecStart=/opt/blackblood/venv/bin/python run_webhook.py
Restart=always
RestartSec=10
Environment="PYTHONUNBUFFERED=1"

[Install]
WantedBy=multi-user.target
WH_SVC

systemctl daemon-reload
systemctl enable blackblood-bot blackblood-webhook
systemctl start blackblood-bot blackblood-webhook

sleep 3

echo ""
echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}  ГЛАВНЫЙ СЕРВЕР УСПЕШНО НАСТРОЕН!${NC}"
echo -e "${GREEN}========================================${NC}"
echo ""
echo "Вебхук: https://$WEBHOOK_DOMAIN/webhook/yookassa"
echo ""
echo "Проверьте статусы:"
echo "  systemctl status blackblood-bot"
echo "  systemctl status blackblood-webhook"
echo ""
echo "Проверка вебхука:"
echo "  curl -X POST https://$WEBHOOK_DOMAIN/webhook/yookassa"
echo "  (должен вернуть 400 или 403 — это правильно)"
echo ""
echo -e "${YELLOW}НЕ ЗАБУДЬТЕ: укажите в личном кабинете ЮKassa URL вебхука:${NC}"
echo "  https://$WEBHOOK_DOMAIN/webhook/yookassa"
echo ""
SETUP_EOF

chmod +x /root/setup_webhook.sh
bash /root/setup_webhook.sh

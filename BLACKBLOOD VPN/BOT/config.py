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

# ЮKassa
YOOKASSA_SHOP_ID = os.getenv('YOOKASSA_SHOP_ID')
YOOKASSA_SECRET_KEY = os.getenv('YOOKASSA_SECRET_KEY')
YOOKASSA_RETURN_URL = os.getenv('YOOKASSA_RETURN_URL', 'https://t.me/blackblood_bot')
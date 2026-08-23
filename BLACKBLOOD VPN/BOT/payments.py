import uuid
from yookassa import Configuration, Payment
from .config import YOOKASSA_SHOP_ID, YOOKASSA_SECRET_KEY, YOOKASSA_RETURN_URL
import logging

logger = logging.getLogger(__name__)

# Настройка ЮKassa
Configuration.account_id = YOOKASSA_SHOP_ID
Configuration.secret_key = YOOKASSA_SECRET_KEY

def create_yookassa_payment(user_id, amount, description="Пополнение баланса BlackBlood VPN"):
    """
    Создаёт платёж в ЮKassa и возвращает ссылку для оплаты.
    """
    try:
        idempotence_key = str(uuid.uuid4())
        payment = Payment.create({
            "amount": {
                "value": f"{amount:.2f}",
                "currency": "RUB"
            },
            "confirmation": {
                "type": "redirect",
                "return_url": YOOKASSA_RETURN_URL
            },
            "description": description,
            "metadata": {
                "user_id": str(user_id)
            }
        }, idempotence_key)
        
        return {
            'payment_id': payment.id,
            'confirmation_url': payment.confirmation.confirmation_url,
            'status': payment.status
        }
    except Exception as e:
        logger.error(f"Ошибка создания платежа ЮKassa: {e}")
        return None

def check_yookassa_payment(payment_id):
    """Проверяет статус платежа (используется редко, т.к. уведомления приходят через вебхук)."""
    try:
        payment = Payment.find_one(payment_id)
        return payment.status
    except Exception as e:
        logger.error(f"Ошибка проверки платежа: {e}")
        return 'unknown'
from telegram import Update, InlineKeyboardButton, InlineKeyboardMarkup
from telegram.ext import ContextTypes
from sqlalchemy import create_engine
from sqlalchemy.orm import sessionmaker
import datetime
import logging

from .config import DB_URL, PRICE_MONTH, TRIAL_DAYS, REFERRAL_BONUS_DAYS, XRAY_SERVERS
from .models import User, ReferralBonus, Payment, init_db
from .texts import LICENSE_AGREEMENT, PRIVACY_POLICY, WELCOME_TEXT, MAIN_MENU
from .utils import (
    generate_referral_code, generate_uuid, generate_qr,
    get_subscription_status, generate_client_config_with_balancer,
    generate_vless_link
)
from .xray_api import update_client_on_server
from .payments import create_yookassa_payment
import io

logger = logging.getLogger(__name__)

# Инициализация БД
init_db()
engine = create_engine(DB_URL)
SessionLocal = sessionmaker(bind=engine)

# ---------- Согласие ----------
async def start(update: Update, context: ContextTypes.DEFAULT_TYPE):
    user = update.effective_user
    tg_id = user.id
    session = SessionLocal()
    db_user = session.query(User).filter_by(tg_id=tg_id).first()
    
    if db_user and db_user.subscription_end is not None and db_user.subscription_end > datetime.datetime.utcnow():
        await show_main_menu(update, context)
        return

    if context.user_data.get('agreed'):
        await register_user(update, context)
        return

    keyboard = [
        [InlineKeyboardButton("✅ Принять", callback_data='accept_agreement')],
        [InlineKeyboardButton("❌ Отклонить", callback_data='decline_agreement')]
    ]
    reply_markup = InlineKeyboardMarkup(keyboard)
    text = f"{LICENSE_AGREEMENT}\n\n{PRIVACY_POLICY}"
    await update.message.reply_text(text, reply_markup=reply_markup)

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

# ---------- Регистрация и пробный период ----------
async def register_user(update: Update, context: ContextTypes.DEFAULT_TYPE):
    user = update.effective_user
    tg_id = user.id
    session = SessionLocal()
    db_user = session.query(User).filter_by(tg_id=tg_id).first()
    if not db_user:
        ref_code = generate_referral_code(tg_id)
        user_uuid = generate_uuid()
        new_expiry = datetime.datetime.utcnow() + datetime.timedelta(days=TRIAL_DAYS)
        db_user = User(
            tg_id=tg_id,
            username=user.username,
            referral_code=ref_code,
            uuid=user_uuid,
            subscription_end=new_expiry
        )
        session.add(db_user)
        session.commit()
        # Обновляем Xray
        expiry_ts = int(new_expiry.timestamp())
        update_client_on_server(user_uuid, expiry_ts)
        # Реферальная проверка
        start_param = context.args[0] if context.args else None
        if start_param and start_param.startswith('ref_'):
            referrer = session.query(User).filter_by(referral_code=start_param).first()
            if referrer and referrer.id != db_user.id:
                referrer.subscription_end += datetime.timedelta(days=REFERRAL_BONUS_DAYS)
                bonus = ReferralBonus(referrer_id=referrer.id, referred_id=db_user.id, days_added=REFERRAL_BONUS_DAYS)
                session.add(bonus)
                session.commit()
        # Отправляем конфиг
        await send_client_config(update, db_user.uuid)
        await update.effective_message.reply_text(WELCOME_TEXT)
    else:
        # Если пользователь уже есть, но подписка истекла – можно предложить продлить
        await update.effective_message.reply_text("Ваша подписка истекла. Пополните баланс и купите новый период.")
    session.close()
    await show_main_menu(update, context)

async def send_client_config(update, user_uuid):
    if not XRAY_SERVERS:
        await update.effective_message.reply_text("Серверы временно недоступны. Попробуйте позже.")
        return
    config_json = generate_client_config_with_balancer(user_uuid, XRAY_SERVERS)
    file_obj = io.BytesIO(config_json.encode('utf-8'))
    file_obj.name = 'config.json'
    await update.effective_message.reply_document(
        document=file_obj,
        caption="Сохраните этот файл и импортируйте в приложение Happ / V2RayTun."
    )
    # Отправляем также одну ссылку для быстрого импорта
    srv = XRAY_SERVERS[0]
    link = generate_vless_link(user_uuid, srv['host'], srv['port'], srv['public_key'], srv['short_id'])
    await update.effective_message.reply_text(f"Альтернативная ссылка (без балансировки):\n`{link}`", parse_mode='Markdown')
    qr = generate_qr(link)
    await update.effective_message.reply_photo(qr, caption="QR для быстрого импорта (только первый сервер)")

# ---------- Главное меню ----------
async def show_main_menu(update: Update, context: ContextTypes.DEFAULT_TYPE):
    keyboard = [
        [InlineKeyboardButton("🛒 Купить VPN (160 руб/мес)", callback_data='buy_vpn')],
        [InlineKeyboardButton("💳 Пополнить баланс", callback_data='deposit')],
        [InlineKeyboardButton("👤 Мой профиль", callback_data='profile')],
        [InlineKeyboardButton("👥 Реферальная система", callback_data='referral')],
        [InlineKeyboardButton("❓ Помощь", callback_data='help')]
    ]
    reply_markup = InlineKeyboardMarkup(keyboard)
    await update.message.reply_text(MAIN_MENU, reply_markup=reply_markup)

async def profile(update: Update, context: ContextTypes.DEFAULT_TYPE):
    query = update.callback_query
    await query.answer()
    tg_id = query.from_user.id
    session = SessionLocal()
    user = session.query(User).filter_by(tg_id=tg_id).first()
    if not user:
        await query.edit_message_text("Пользователь не найден. Используйте /start")
        return
    ref_count = session.query(ReferralBonus).filter_by(referrer_id=user.id).count()
    status = get_subscription_status(user)
    text = f"""
👤 **Ваш профиль**
🆔 ID: {user.tg_id}
💰 Баланс: {user.balance:.2f} руб.
📅 Подписка: {status}
👥 Рефералов: {ref_count}
🔗 Ваша реферальная ссылка: `https://t.me/blackblood_bot?start={user.referral_code}`
    """
    await query.edit_message_text(text, parse_mode='Markdown')
    await show_main_menu_callback(query)

async def referral(update: Update, context: ContextTypes.DEFAULT_TYPE):
    query = update.callback_query
    await query.answer()
    tg_id = query.from_user.id
    session = SessionLocal()
    user = session.query(User).filter_by(tg_id=tg_id).first()
    if not user:
        await query.edit_message_text("Ошибка.")
        return
    ref_count = session.query(ReferralBonus).filter_by(referrer_id=user.id).count()
    text = f"""
👥 **Реферальная система**
За каждого приглашённого друга, который активирует VPN, вы получаете +{REFERRAL_BONUS_DAYS} дня к подписке.
Ваша ссылка: `https://t.me/blackblood_bot?start={user.referral_code}`
Приглашено: {ref_count} чел.
    """
    await query.edit_message_text(text, parse_mode='Markdown')
    await show_main_menu_callback(query)

async def buy_vpn(update: Update, context: ContextTypes.DEFAULT_TYPE):
    query = update.callback_query
    await query.answer()
    tg_id = query.from_user.id
    session = SessionLocal()
    user = session.query(User).filter_by(tg_id=tg_id).first()
    if not user:
        await query.edit_message_text("Пожалуйста, запустите бота заново через /start")
        return
    if user.balance < PRICE_MONTH:
        await query.edit_message_text(f"Недостаточно средств. Ваш баланс: {user.balance:.2f} руб. Пополните баланс.")
        return
    # Списываем и продлеваем
    user.balance -= PRICE_MONTH
    if user.subscription_end is None or user.subscription_end < datetime.datetime.utcnow():
        user.subscription_end = datetime.datetime.utcnow() + datetime.timedelta(days=30)
    else:
        user.subscription_end += datetime.timedelta(days=30)
    session.commit()
    # Обновляем Xray
    expiry_ts = int(user.subscription_end.timestamp())
    if user.uuid:
        update_client_on_server(user.uuid, expiry_ts)
    session.close()
    await query.edit_message_text("✅ Подписка продлена на 30 дней! Конфигурация действует.")
    await show_main_menu_callback(query)

async def deposit(update: Update, context: ContextTypes.DEFAULT_TYPE):
    query = update.callback_query
    await query.answer()
    tg_id = query.from_user.id
    session = SessionLocal()
    user = session.query(User).filter_by(tg_id=tg_id).first()
    if not user:
        await query.edit_message_text("Ошибка.")
        return
    # Создаём платёж через ЮKassa
    result = create_yookassa_payment(user.id, PRICE_MONTH)
    if result:
        # Сохраняем external_id в БД (можно добавить отдельную запись в Payment)
        # Для простоты сохраним в отдельной таблице, но мы уже имеем Payment.
        # Создаём запись со статусом pending
        payment_record = Payment(
            user_id=user.id,
            amount=PRICE_MONTH,
            payment_system='yookassa',
            external_id=result['payment_id'],
            status='pending'
        )
        session.add(payment_record)
        session.commit()
        session.close()
        await query.edit_message_text(
            f"💳 **Оплата {PRICE_MONTH} руб.**\n\n"
            f"Перейдите по ссылке для оплаты:\n{result['confirmation_url']}\n\n"
            "После оплаты баланс будет зачислен автоматически."
        )
    else:
        await query.edit_message_text("Ошибка создания счёта. Попробуйте позже.")
    await show_main_menu_callback(query)

async def help_command(update: Update, context: ContextTypes.DEFAULT_TYPE):
    query = update.callback_query
    await query.answer()
    await query.edit_message_text("""
❓ **Помощь**
1. Скачайте приложение Happ (Android) или V2RayTun (iOS/Android).
2. Импортируйте файл config.json, который вы получили при активации.
3. Подключитесь. Балансировка между серверами происходит автоматически.

По вопросам: @blackblood_support
    """)
    await show_main_menu_callback(query)

async def show_main_menu_callback(query):
    keyboard = [
        [InlineKeyboardButton("🛒 Купить VPN", callback_data='buy_vpn')],
        [InlineKeyboardButton("💳 Пополнить баланс", callback_data='deposit')],
        [InlineKeyboardButton("👤 Мой профиль", callback_data='profile')],
        [InlineKeyboardButton("👥 Реферальная система", callback_data='referral')],
        [InlineKeyboardButton("❓ Помощь", callback_data='help')]
    ]
    reply_markup = InlineKeyboardMarkup(keyboard)
    await query.message.reply_text("Главное меню:", reply_markup=reply_markup)
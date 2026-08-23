import os
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

SECRET_KEY = YOOKASSA_SECRET_KEY

@app.post("/webhook/yookassa")
async def yookassa_webhook(request: Request):
    body = await request.body()
    data = json.loads(body)

    # Проверка подписи
    signature = request.headers.get("X-Yandex-Signature")
    if not signature:
        raise HTTPException(status_code=400, detail="Missing signature")
    
    expected_signature = hmac.new(
        SECRET_KEY.encode('utf-8'),
        body,
        hashlib.sha256
    ).hexdigest()
    
    if not hmac.compare_digest(signature, expected_signature):
        raise HTTPException(status_code=403, detail="Invalid signature")
    
    event = data.get("event")
    if event != "payment.succeeded":
        return {"status": "ignored"}
    
    payment_id = data["object"]["id"]
    amount = float(data["object"]["amount"]["value"])
    metadata = data["object"]["metadata"]
    user_id = metadata.get("user_id")
    if not user_id:
        raise HTTPException(status_code=400, detail="Missing user_id")
    
    session = SessionLocal()
    existing = session.query(Payment).filter_by(external_id=payment_id).first()
    if existing:
        session.close()
        return {"status": "already_processed"}
    
    user = session.query(User).filter_by(id=int(user_id)).first()
    if not user:
        session.close()
        raise HTTPException(status_code=404, detail="User not found")
    
    user.balance += amount
    new_payment = Payment(
        user_id=user.id,
        amount=amount,
        payment_system="yookassa",
        external_id=payment_id,
        status="succeeded",
        created_at=datetime.utcnow()
    )
    session.add(new_payment)
    session.commit()
    session.close()
    
    # (Опционально) уведомить пользователя в Telegram – можно через bot API
    # await bot.send_message(user.tg_id, f"Ваш баланс пополнен на {amount} руб.")
    return {"status": "success"}
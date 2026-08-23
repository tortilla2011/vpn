from sqlalchemy import create_engine, Column, Integer, String, Float, DateTime, ForeignKey, BigInteger, Text
from sqlalchemy.ext.declarative import declarative_base
from sqlalchemy.orm import sessionmaker, relationship
from datetime import datetime
import os
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
    uuid = Column(String(36), unique=True, nullable=True)  # UUID для Xray
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

# Создание таблиц (выполняется один раз при первом запуске)
def init_db():
    engine = create_engine(DB_URL)
    Base.metadata.create_all(engine)
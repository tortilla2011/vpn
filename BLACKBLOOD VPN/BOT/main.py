import logging
from telegram.ext import Application, CommandHandler, CallbackQueryHandler
from .config import BOT_TOKEN
from .handlers import (
    start, accept_agreement, decline_agreement,
    profile, referral, buy_vpn, deposit, help_command
)

logging.basicConfig(level=logging.INFO)

def main():
    app = Application.builder().token(BOT_TOKEN).build()
    
    app.add_handler(CommandHandler('start', start))
    app.add_handler(CallbackQueryHandler(accept_agreement, pattern='^accept_agreement$'))
    app.add_handler(CallbackQueryHandler(decline_agreement, pattern='^decline_agreement$'))
    app.add_handler(CallbackQueryHandler(profile, pattern='^profile$'))
    app.add_handler(CallbackQueryHandler(referral, pattern='^referral$'))
    app.add_handler(CallbackQueryHandler(buy_vpn, pattern='^buy_vpn$'))
    app.add_handler(CallbackQueryHandler(deposit, pattern='^deposit$'))
    app.add_handler(CallbackQueryHandler(help_command, pattern='^help$'))
    
    app.run_polling()

if __name__ == '__main__':
    main()
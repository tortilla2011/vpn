#!/bin/bash
set -e
echo "Установка Xray..."
bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install
systemctl enable xray
systemctl start xray
echo "Xray установлен."
echo "Для генерации ключей выполните: xray x25519"
import json
import subprocess
import logging
import os

logger = logging.getLogger(__name__)

# Путь к скрипту обновления на сервере
UPDATE_SCRIPT = '/opt/blackblood/server/update_client.py'

def update_client_on_server(uuid, expiry_timestamp):
    """
    Вызывает локальный скрипт update_client.py для обновления конфига Xray.
    Если несколько серверов, можно расширить через SSH.
    """
    try:
        cmd = ['python3', UPDATE_SCRIPT, '--uuid', uuid, '--expiry', str(expiry_timestamp)]
        result = subprocess.run(cmd, capture_output=True, text=True, check=True)
        logger.info(f"Xray update success: {result.stdout}")
        return True
    except subprocess.CalledProcessError as e:
        logger.error(f"Xray update failed: {e.stderr}")
        return False

# (Опционально) функция для обновления на всех серверах через SSH
def update_client_on_servers(uuid, expiry_timestamp, servers, ssh_key_path='/root/.ssh/id_rsa'):
    import paramiko
    for srv in servers:
        try:
            ssh = paramiko.SSHClient()
            ssh.set_missing_host_key_policy(paramiko.AutoAddPolicy())
            ssh.connect(srv['host'], username='root', key_filename=ssh_key_path)
            cmd = f"python3 /opt/blackblood/server/update_client.py --uuid {uuid} --expiry {expiry_timestamp}"
            stdin, stdout, stderr = ssh.exec_command(cmd)
            ssh.close()
            logger.info(f"Updated server {srv['host']}")
        except Exception as e:
            logger.error(f"SSH update failed for {srv['host']}: {e}")
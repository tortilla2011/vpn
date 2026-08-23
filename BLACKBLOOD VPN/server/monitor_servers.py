#!/usr/bin/env python3
import json
import socket
import os

def ping_server(host, port=443):
    try:
        sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        sock.settimeout(2)
        result = sock.connect_ex((host, port))
        sock.close()
        return result == 0
    except:
        return False

def main():
    # Загружаем список серверов из файла, который генерируется ботом или статичен
    servers_file = '/etc/blackblood/servers.json'
    if not os.path.exists(servers_file):
        print("No servers.json found")
        return
    with open(servers_file, 'r') as f:
        servers = json.load(f)
    
    alive = []
    for srv in servers:
        if ping_server(srv['host'], srv['port']):
            alive.append(srv)
        else:
            print(f"Сервер {srv['host']} недоступен!")
    
    with open('/etc/blackblood/alive_servers.json', 'w') as f:
        json.dump(alive, f)

if __name__ == '__main__':
    main()
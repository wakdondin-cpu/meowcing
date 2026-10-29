#!/usr/bin/env bash
set -euo pipefail
umask 077
WORKSPACE_DIR="${WORKSPACE_DIR:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)}"
STATE_DIR="$WORKSPACE_DIR/.rdp-generator"
mkdir -p "$STATE_DIR"
chmod 700 "$STATE_DIR"
LOG_FILE="$STATE_DIR/worker.log"
exec >> "$LOG_FILE" 2>&1
echo "=== [$(date -u '+%Y-%m-%dT%H:%M:%SZ')] Starting RDP Worker ==="

WIN_VERSION="${WIN_VERSION:-2022}"
WIN_RAM="${WIN_RAM:-8G}"
WIN_CPUS="${WIN_CPUS:-2}"
WIN_DISK="${WIN_DISK:-32G}"
STORAGE_PATH="/tmp/windows"
CREDS_FILE="$STATE_DIR/credentials"
STATUS_FILE="$STATE_DIR/status.json"
TS_STATE_DIR="$STATE_DIR/tailscale"

mkdir -p "$TS_STATE_DIR"
chmod 700 "$TS_STATE_DIR"
chmod 600 "$CREDS_FILE" "$STATUS_FILE" "$LOG_FILE" 2>/dev/null || true
sudo find "$TS_STATE_DIR" -type f -exec chmod 600 {} +
sudo mkdir -p "$STORAGE_PATH" /var/run/tailscale

RDP_MASTER_SECRET="${RDP_MASTER_SECRET:-}"
TS_AUTHKEY="${TS_AUTHKEY:-}"
if [ -f "/workspaces/.codespaces/shared/user-secrets-envs.json" ]; then
    TS_AUTHKEY_SECRET=$(python3 -c "import json; print(json.load(open('/workspaces/.codespaces/shared/user-secrets-envs.json')).get('TS_AUTHKEY', ''))" 2>/dev/null || true)
    WIN_VERSION_SECRET=$(python3 -c "import json; print(json.load(open('/workspaces/.codespaces/shared/user-secrets-envs.json')).get('WIN_VERSION', ''))" 2>/dev/null || true)
    MASTER_SECRET=$(python3 -c "import json; print(json.load(open('/workspaces/.codespaces/shared/user-secrets-envs.json')).get('RDP_MASTER_SECRET', ''))" 2>/dev/null || true)
    WIN_PASSWORD_SECRET=$(python3 -c "import json; print(json.load(open('/workspaces/.codespaces/shared/user-secrets-envs.json')).get('WIN_PASSWORD', ''))" 2>/dev/null || true)
    if [ -n "$TS_AUTHKEY_SECRET" ] && [ -z "$TS_AUTHKEY" ]; then
        TS_AUTHKEY="$TS_AUTHKEY_SECRET"
    fi
    if [ -n "$WIN_VERSION_SECRET" ]; then
        WIN_VERSION="$WIN_VERSION_SECRET"
    fi
    if [ -n "$MASTER_SECRET" ] && [ -z "$RDP_MASTER_SECRET" ]; then
        RDP_MASTER_SECRET="$MASTER_SECRET"
    fi
    if [ -n "$WIN_PASSWORD_SECRET" ] && [ -z "${WIN_PASSWORD:-}" ]; then
        WIN_PASSWORD="$WIN_PASSWORD_SECRET"
    fi
fi

if [ ! -f "$CREDS_FILE" ] && [ -f "/tmp/rdp-creds" ]; then
    cp /tmp/rdp-creds "$CREDS_FILE"
    chmod 600 "$CREDS_FILE"
fi

if [ ! -f "$CREDS_FILE" ]; then
    WIN_USER="${WIN_USER:-WinAdmin}"
    WIN_PASS=""
    if [ -n "$RDP_MASTER_SECRET" ]; then
        if [ -z "${CODESPACE_NAME:-}" ]; then
            echo "Error: CODESPACE_NAME missing with RDP_MASTER_SECRET" >&2
            exit 1
        fi
        export RDP_MASTER_SECRET CODESPACE_NAME
        WIN_PASS=$(python3 -c "import hmac,hashlib,os; ms=os.environ['RDP_MASTER_SECRET'].encode('utf-8'); cs=os.environ['CODESPACE_NAME'].encode('utf-8'); assert len(ms) >= 32, 'RDP_MASTER_SECRET must be at least 32 bytes'; print('Aa1!' + hmac.new(ms, cs, hashlib.sha256).hexdigest()[:24])")
    elif [ -n "${WIN_PASSWORD:-}" ]; then
        WIN_PASS="$WIN_PASSWORD"
    else
        WIN_PASS=$(python3 -c 'import secrets,string; chars=string.ascii_letters+string.digits+"!@#%_-"; print("".join(secrets.choice(chars) for _ in range(16)))')
    fi
    printf "%s\n%s\n" "$WIN_USER" "$WIN_PASS" > "$CREDS_FILE"
    chmod 600 "$CREDS_FILE"
fi

WIN_USER=$(sed -n 1p "$CREDS_FILE")
WIN_PASS=$(sed -n 2p "$CREDS_FILE")

sudo rm -f /etc/apt/sources.list.d/yarn.list 2>/dev/null || true

if ! command -v tailscale >/dev/null 2>&1; then
    curl -fsSL https://pkgs.tailscale.com/stable/tailscale_1.76.6_amd64.tgz -o /tmp/ts.tgz
    tar -C /tmp -xzf /tmp/ts.tgz
    sudo cp /tmp/tailscale_*/tailscale* /usr/local/bin/
    rm -rf /tmp/ts.tgz /tmp/tailscale_*
fi

if ! pgrep -x tailscaled >/dev/null 2>&1; then
    sudo nohup /usr/local/bin/tailscaled --state="$TS_STATE_DIR/tailscaled.state" --socket=/var/run/tailscale/tailscaled.sock > "$STATE_DIR/tailscaled.log" 2>&1 &
    sleep 3
fi

TS_IP=""
TS_HOST=""
if [ -n "$TS_AUTHKEY" ]; then
    NODE_ID="${CODESPACE_NAME:-$(cat /etc/hostname | tr -dc 'a-zA-Z0-9')}"
    TS_HOST="winlab-${NODE_ID}"
    if [ ${#TS_HOST} -gt 63 ]; then
        TS_HOST="${TS_HOST:0:63}"
        while [[ "$TS_HOST" == *- ]]; do TS_HOST="${TS_HOST%-}"; done
    fi
    sudo /usr/local/bin/tailscale up --auth-key="$TS_AUTHKEY" --hostname="$TS_HOST" --accept-dns=true --reset || true
    TS_IP=$(sudo /usr/local/bin/tailscale ip -4 || true)
fi

if ! docker ps -a --format '{{.Names}}' | grep -q '^windows$'; then
    docker run -d --name windows \
        --restart unless-stopped \
        --device=/dev/kvm --device=/dev/net/tun --cap-add NET_ADMIN \
        -e VERSION="$WIN_VERSION" -e RAM_SIZE="$WIN_RAM" -e CPU_CORES="$WIN_CPUS" -e DISK_SIZE="$WIN_DISK" \
        -e USERNAME="$WIN_USER" -e PASSWORD="$WIN_PASS" \
        -p 127.0.0.1:8006:8006 -p 127.0.0.1:3389:3389/tcp \
        -v "$STORAGE_PATH:/storage" --stop-timeout 120 ghcr.io/dockur/windows
else
    docker start windows || true
fi

if [ -n "$TS_IP" ]; then
    sudo pkill -f "start_server.*$TS_IP" 2>/dev/null || true
    sudo nohup python3 -c "
import socket, threading

def relay(client, target_host, target_port):
    try:
        server = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        server.connect((target_host, target_port))
        def forward(src, dst):
            try:
                while True:
                    data = src.recv(4096)
                    if not data: break
                    dst.sendall(data)
            except: pass
            finally:
                try: src.close()
                except: pass
                try: dst.close()
                except: pass
        threading.Thread(target=forward, args=(client, server), daemon=True).start()
        threading.Thread(target=forward, args=(server, client), daemon=True).start()
    except:
        client.close()

def start_server(bind_ip, bind_port, target_ip, target_port):
    s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    s.bind((bind_ip, bind_port))
    s.listen(50)
    while True:
        c, _ = s.accept()
        relay(c, target_ip, target_port)

threading.Thread(target=start_server, args=('$TS_IP', 3389, '127.0.0.1', 3389), daemon=True).start()
start_server('$TS_IP', 8006, '127.0.0.1', 8006)
" > "$STATE_DIR/pyrelay.log" 2>&1 &
fi

export STATE_DIR WIN_VERSION WIN_RAM WIN_CPUS WIN_DISK WIN_USER WIN_PASS TS_IP TS_HOST
python3 - <<'PY'
import datetime, json, os
state = os.environ['STATE_DIR']
config = {key: os.environ[key] for key in ('WIN_VERSION', 'WIN_RAM', 'WIN_CPUS', 'WIN_DISK')}
status = {
    'updated_at': datetime.datetime.now(datetime.timezone.utc).isoformat(),
    'status': 'running',
    'tailscale_ip': os.environ['TS_IP'],
    'tailscale_host': os.environ['TS_HOST'],
    'rdp_host': (os.environ['TS_IP'] or '127.0.0.1') + ':3389',
    'web_console': 'http://' + (os.environ['TS_IP'] or '127.0.0.1') + ':8006',
    'username': os.environ['WIN_USER'],
    'password': os.environ['WIN_PASS'],
    'windows_version': os.environ['WIN_VERSION'],
}
for name, data in (('config.json', config), ('status.json', status)):
    path = os.path.join(state, name)
    with open(path, 'w') as f:
        json.dump(data, f)
    os.chmod(path, 0o600)
PY

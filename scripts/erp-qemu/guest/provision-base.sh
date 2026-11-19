#!/usr/bin/env bash
# Guest provisioning (Debian 13, QEMU-TCG): system packages, MariaDB 11.8 (guest-local, private), Python 3.14
# (uv-managed python-build-standalone), Node.js 24 (official tarball, SHA-256 verified), yarn, frappe-bench.
# Idempotent; run as the 'erp' user with sudo. Mirrors .github/workflows/erp-integration.yml.
set -euo pipefail
NODE_VERSION="${NODE_VERSION:-24.22.3}"
UV_VERSION="${UV_VERSION:-0.13.9}"
log() { printf '%s %s\n' "$(date -u +%FT%TZ)" "$*"; }

log "apt packages"
sudo DEBIAN_FRONTEND=noninteractive apt-get update -q
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -q --no-install-recommends \
  mariadb-server mariadb-client libmariadb-dev pkg-config libcups2-dev redis-server cron git curl ca-certificates \
  build-essential xz-utils jq
# bench runs its own Redis instances (redis_cache, redis_queue) from the Procfile; the distro service is not used.
sudo systemctl disable --now redis-server

log "MariaDB settings (as in ERPNext CI, sized for a small guest)"
sudo tee /etc/mysql/mariadb.conf.d/99-erpnext.cnf >/dev/null <<'EOF'
[mysqld]
bind-address = 127.0.0.1
character-set-server = utf8mb4
collation-server = utf8mb4_unicode_ci
innodb_buffer_pool_size = 256M
innodb_log_file_size = 128M
innodb_flush_log_at_trx_commit = 2
performance_schema = OFF
max_connections = 60
skip-name-resolve
[client]
default-character-set = utf8mb4
EOF
sudo systemctl restart mariadb
sudo systemctl enable mariadb

log "uv ${UV_VERSION} and Python 3.14"
if ! command -v uv >/dev/null || [[ "$(uv --version | awk '{print $2}')" != "$UV_VERSION" ]]; then
  t=$(mktemp -d); base="https://github.com/astral-sh/uv/releases/download/${UV_VERSION}"
  curl -fsSL -o "$t/uv.tar.gz" "$base/uv-x86_64-unknown-linux-gnu.tar.gz"
  curl -fsSL -o "$t/uv.sha256" "$base/uv-x86_64-unknown-linux-gnu.tar.gz.sha256"
  (cd "$t" && echo "$(awk '{print $1}' uv.sha256)  uv.tar.gz" | sha256sum -c -)
  tar -xzf "$t/uv.tar.gz" -C "$t" && sudo install -m 0755 "$t"/uv-x86_64-unknown-linux-gnu/uv "$t"/uv-x86_64-unknown-linux-gnu/uvx /usr/local/bin/
  rm -rf "$t"
fi
uv python install 3.14
PY="$(uv python find 3.14)"
"$PY" --version

log "Node.js ${NODE_VERSION}"
if [[ "$(node --version 2>/dev/null)" != "v${NODE_VERSION}" ]]; then
  t=$(mktemp -d); base="https://nodejs.org/dist/v${NODE_VERSION}"; f="node-v${NODE_VERSION}-linux-x64.tar.xz"
  curl -fsSL -o "$t/$f" "$base/$f"; curl -fsSL -o "$t/SHASUMS256.txt" "$base/SHASUMS256.txt"
  (cd "$t" && grep " $f\$" SHASUMS256.txt | sha256sum -c -)
  sudo rm -rf /opt/node && sudo mkdir -p /opt/node && sudo tar -xJf "$t/$f" -C /opt/node --strip-components=1
  for b in node npm npx corepack; do sudo ln -sf "/opt/node/bin/$b" "/usr/local/bin/$b"; done
  rm -rf "$t"
fi
command -v yarn >/dev/null || { sudo npm install -g --silent yarn; sudo ln -sf /opt/node/bin/yarn /usr/local/bin/yarn; }

log "frappe-bench"
uv tool install --python 3.14 frappe-bench >/dev/null 2>&1 || uv tool upgrade frappe-bench
grep -q '.local/bin' ~/.profile || echo 'export PATH="$HOME/.local/bin:$PATH"' >> ~/.profile
export PATH="$HOME/.local/bin:$PATH"

log "versions"
"$PY" --version; node --version; yarn --version; bench --version; redis-server --version | awk '{print $1,$2,$3}'; mariadb --version

#!/usr/bin/env bash
#
# Modified from https://github.com/sleepymole/docker-corplink

# Keep this script reusable for both the container image and the Lima/macOS VM
# release bundle while preserving the existing docker guardrails.
if [ -z "${CONTAINER:-}" ] && [ "${CORPLINK_RUNTIME:-}" != "vm" ]; then
    echo "Neither CONTAINER=1 nor CORPLINK_RUNTIME=vm is set"
    exit 1
fi

set -euxo pipefail

readonly CORPLINK_DIR="/opt/Corplink"
readonly SUPERVISOR_CONF_DIR="/etc/supervisor/conf.d"
readonly SYSTEMD_UNIT_PATH="/etc/systemd/system/corplink-headless.service"
readonly RUNTIME_ENV_PATH="${CORPLINK_DIR}/runtime.env"
readonly STARTUP_TARGET="/startup.sh"

require_file() {
    local file="$1"
    if [ ! -f "${file}" ]; then
        echo "Required file not found: ${file}" >&2
        exit 1
    fi
}

shell_quote() {
    printf "%s" "$1" | sed "s/'/'\"'\"'/g"
}

ensure_hostname_resolution() {
    [ "${CORPLINK_RUNTIME:-}" = "vm" ] || return 0

    local host_name short_name
    host_name="$(hostname)"
    short_name="$(hostname -s)"
    if awk -v h1="${host_name}" -v h2="${short_name}" '
        {
            for (i = 2; i <= NF; i++) {
                if ($i == h1 || $i == h2) {
                    found = 1
                }
            }
        }
        END { exit found ? 0 : 1 }
    ' /etc/hosts; then
        return
    fi
    echo "127.0.1.1 ${host_name} ${short_name}" >>/etc/hosts
}

install_runtime_dependencies() {
    [ "${SKIP_APT_INSTALL:-0}" = "1" ] && return

    local packages=(
        supervisor
        privoxy
        jq
        iptables
        iproute2
        net-tools
        iputils-ping
        less
        ca-certificates
    )
    local missing_packages=()
    local package

    for package in "${packages[@]}"; do
        if ! dpkg -s "${package}" >/dev/null 2>&1; then
            missing_packages+=("${package}")
        fi
    done

    [ "${#missing_packages[@]}" -eq 0 ] && return

    export DEBIAN_FRONTEND=noninteractive
    apt-get update
    apt-get install -y --no-install-recommends "${missing_packages[@]}"
    rm -rf /var/lib/apt/lists/*
}

install_runtime_artifacts() {
    mkdir -p "${CORPLINK_DIR}"

    if [ -n "${CORPLINK_HEADLESS_BIN:-}" ]; then
        require_file "${CORPLINK_HEADLESS_BIN}"
        install -m 0755 "${CORPLINK_HEADLESS_BIN}" "${CORPLINK_DIR}/corplink-headless"
    fi

    if [ -n "${CORPLINK_SOCKS5_BIN:-}" ]; then
        require_file "${CORPLINK_SOCKS5_BIN}"
        install -m 0755 "${CORPLINK_SOCKS5_BIN}" /usr/local/bin/socks5
    fi

    if [ -n "${CORPLINK_PACKAGE_DEB:-}" ]; then
        require_file "${CORPLINK_PACKAGE_DEB}"
        # Follow Dockerfile behavior: extract files from the official package.
        dpkg-deb -x "${CORPLINK_PACKAGE_DEB}" /
    fi

    if [ "${CORPLINK_RUNTIME:-}" = "vm" ]; then
        [ -x "${CORPLINK_DIR}/corplink-headless" ] || {
            echo "corplink-headless is required for vm runtime" >&2
            exit 1
        }
        [ -x "/usr/local/bin/socks5" ] || {
            echo "socks5 is required for vm runtime" >&2
            exit 1
        }
        [ -x "${CORPLINK_DIR}/corplink-service" ] || {
            echo "corplink-service was not found after installing the official package" >&2
            exit 1
        }
    fi
}

install_startup_script() {
    [ "${CORPLINK_RUNTIME:-}" = "vm" ] || return 0

    if [ -n "${CORPLINK_STARTUP_SCRIPT:-}" ]; then
        require_file "${CORPLINK_STARTUP_SCRIPT}"
        install -m 0755 "${CORPLINK_STARTUP_SCRIPT}" "${STARTUP_TARGET}"
        return
    fi

    [ -x "${STARTUP_TARGET}" ] || {
        echo "CORPLINK_STARTUP_SCRIPT is required for vm runtime when ${STARTUP_TARGET} is absent" >&2
        exit 1
    }
}

disable_conflicting_systemd_units() {
    [ "${CORPLINK_RUNTIME:-}" = "vm" ] || return 0
    command -v systemctl >/dev/null 2>&1 || return

    local unit
    for unit in privoxy.service supervisor.service; do
        # Keep privoxy and supervisord lifecycle under startup.sh + supervisor.
        systemctl disable --now "${unit}" >/dev/null 2>&1 || true
        systemctl mask "${unit}" >/dev/null 2>&1 || true
    done
}

write_supervisor_programs() {
    # corplink-service
    mkdir -p /var/log/corplink/
    cat <<EOF >"${SUPERVISOR_CONF_DIR}/corplink.conf"
[program:corplink]
command=/opt/Corplink/corplink-service
autostart=true
autorestart=true
stderr_logfile=/var/log/corplink/stderr.log
stdout_logfile=/var/log/corplink/stdout.log
priority=1
startsecs=3
EOF

    # corplink-headless
    mkdir -p /var/log/corplink-headless/
    cat <<EOF >"${SUPERVISOR_CONF_DIR}/corplink-headless.conf"
[program:corplink-headless]
command=/opt/Corplink/corplink-headless
autostart=true
autorestart=true
stderr_logfile=/var/log/corplink-headless/stderr.log
stdout_logfile=/var/log/corplink-headless/stdout.log
priority=2
EOF

    # Privoxy
    mkdir -p /var/log/privoxy
    cat <<EOF >"${SUPERVISOR_CONF_DIR}/privoxy.conf"
[program:privoxy]
command=/usr/sbin/privoxy --no-daemon /etc/privoxy/config
autostart=true
autorestart=true
stderr_logfile=/var/log/privoxy/stderr.log
stdout_logfile=/var/log/privoxy/stdout.log
EOF
    sed -i '/^listen-address/d' /etc/privoxy/config
    echo 'listen-address 0.0.0.0:8118' >>/etc/privoxy/config

    # Socks5 server
    mkdir -p /var/log/socks5/
    cat <<EOF >"${SUPERVISOR_CONF_DIR}/socks5.conf"
[program:socks5]
command=/usr/local/bin/socks5
autostart=true
autorestart=true
stderr_logfile=/var/log/socks5/stderr.log
stdout_logfile=/var/log/socks5/stdout.log
EOF

    # Automatic fix dns
    cat <<EOF >/usr/local/bin/fixdns.sh
#!/bin/bash
set -x
tmp_file="/tmp/resolv.conf.corplink"
while true; do
  sleep 5
  dns=\$(jq -r '.DNS[0] // empty' /opt/Corplink/vpn.conf 2>/dev/null)
  {
    if [[ -n "\$dns" && "\$dns" != "114.114.114.114" && "\$dns" != "1.1.1.1" ]]; then
      echo "nameserver \${dns}"
    fi
    # Always keep deterministic fallback DNS entries regardless of Feilian state.
    echo "nameserver 114.114.114.114"
    echo "nameserver 1.1.1.1"
  } >"\${tmp_file}"
  cmp -s "\${tmp_file}" /etc/resolv.conf && continue
  cat "\${tmp_file}" >/etc/resolv.conf
done
EOF
    chmod +x /usr/local/bin/fixdns.sh
    mkdir -p /var/log/fixdns/
    cat <<EOF >"${SUPERVISOR_CONF_DIR}/fixdns.conf"
[program:fixdns]
command=/usr/local/bin/fixdns.sh
autostart=true
autorestart=true
stderr_logfile=/var/log/fixdns/stderr.log
stdout_logfile=/var/log/fixdns/stdout.log
EOF

    # Fix ssh stuck at debug1: expecting SSH2_MSG_KEX_DH_GEX_REPLY
    # See https://serverfault.com/a/670081
    cat <<EOF >/usr/local/bin/fixsshmtu.sh
#!/bin/bash
set -x
while true; do
  sleep 10
  mtu=\$(cat /sys/class/net/utun/mtu  2>/dev/null)
  [[ "\$mtu" -eq 1200 ]] && continue
  ifconfig utun mtu 1200
done
EOF
    chmod +x /usr/local/bin/fixsshmtu.sh
    mkdir -p /var/log/fixsshmtu/
    cat <<EOF >"${SUPERVISOR_CONF_DIR}/fixsshmtu.conf"
[program:fixsshmtu]
command=/usr/local/bin/fixsshmtu.sh
autostart=true
autorestart=true
stderr_logfile=/var/log/fixsshmtu/stderr.log
stdout_logfile=/var/log/fixsshmtu/stdout.log
EOF
}

write_vm_runtime_files() {
    [ "${CORPLINK_RUNTIME:-}" = "vm" ] || return 0

    local escaped_company_code
    escaped_company_code="$(shell_quote "${COMPANY_CODE:-}")"

    cat <<EOF >"${RUNTIME_ENV_PATH}"
COMPANY_CODE='${escaped_company_code}'
CONTAINER=1
CORPLINK_RUNTIME=vm
EOF
    chmod 0600 "${RUNTIME_ENV_PATH}"

    cat <<'EOF' >"${SYSTEMD_UNIT_PATH}"
[Unit]
Description=Corplink headless runtime stack
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
EnvironmentFile=-/opt/Corplink/runtime.env
WorkingDirectory=/opt/Corplink
ExecStart=/startup.sh
Restart=always
RestartSec=5
KillMode=control-group

[Install]
WantedBy=multi-user.target
EOF
}

enable_vm_runtime() {
    [ "${CORPLINK_RUNTIME:-}" = "vm" ] || return 0
    command -v systemctl >/dev/null 2>&1 || return

    systemctl daemon-reload
    systemctl enable corplink-headless.service >/dev/null
    systemctl restart corplink-headless.service
}

ensure_hostname_resolution
install_runtime_dependencies
install_runtime_artifacts
install_startup_script
disable_conflicting_systemd_units
write_supervisor_programs
write_vm_runtime_files
enable_vm_runtime

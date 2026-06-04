#!/usr/bin/env bash
set -euo pipefail

info() { echo "[INFO] $*"; }
ok() { echo "[OK] $*"; }

if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
  echo "[ERROR] Скрипт нужно запускать от root на узле Proxmox." >&2
  exit 1
fi

if ! command -v qm >/dev/null 2>&1; then
  echo "[ERROR] Утилита qm не найдена. Запустите скрипт на узле Proxmox." >&2
  exit 1
fi

info "Проверка зависимостей хоста Proxmox"
if command -v expect >/dev/null 2>&1; then
  ok "Пакет expect уже установлен."
else
  info "Устанавливаю expect..."
  apt-get install -y expect
fi

if command -v python3 >/dev/null 2>&1; then
  ok "Пакет python3 уже установлен."
else
  info "Устанавливаю python3..."
  apt-get install -y python3
fi

# === Настройки по умолчанию ===
VMID_DEF="107"
FQDN_DEF="br-rtr.au-team.irpo"
TZ_NAME_DEF="utc+5"

ADMIN_USER_DEF="net_admin"
ADMIN_PASS_DEF="P@ssword"

WAN_PORT_DEF="ge0"
LAN_PORT_DEF="ge1"

WAN_IP_DEF="172.16.60.2/28"
WAN_GW_DEF="172.16.60.1"
NAT_LOCAL_POOL_DEF="192.168.0.0-192.168.255.255"

LAN_HOSTS_DEF="16"
LAN_GW_DEF="192.168.0.1"

GRE_REMOTE_DEF="172.16.50.2"
GRE_INNER_DEF="172.16.0.2/30"
OSPF_PASS_DEF="P@ssword"

ask() {
  local text="$1" default="$2" value
  read -r -p "$text [$default]: " value
  echo "${value:-$default}"
}

calc_prefix() {
  python3 - "$1" <<'PY'
import math
import sys

try:
    addrs = int(sys.argv[1])
    if addrs < 1:
        addrs = 1
    p = 1
    while p < addrs:
        p *= 2
    print(32 - int(math.log2(p)))
except Exception:
    print("24")
PY
}

calc_netmask() {
  python3 - "$1" <<'PY'
import ipaddress
import sys

try:
    print(ipaddress.IPv4Network(f"0.0.0.0/{sys.argv[1]}").netmask)
except Exception:
    print("255.255.255.0")
PY
}

calc_network() {
  python3 - "$1" "$2" <<'PY'
import ipaddress
import sys

try:
    print(ipaddress.IPv4Network(f"{sys.argv[1]}/{sys.argv[2]}", strict=False))
except Exception:
    print("")
PY
}

calc_network_from_cidr() {
  python3 - "$1" <<'PY'
import ipaddress
import sys

try:
    print(ipaddress.IPv4Interface(sys.argv[1]).network)
except Exception:
    print("")
PY
}

echo "=== BR-RTR (EcoRouter Rose) Interactive Configurator ==="
VMID="$(ask "VMID устройства BR-RTR" "$VMID_DEF")"

echo
echo "--- Базовая настройка ---"
FQDN="$(ask "FQDN устройства" "$FQDN_DEF")"
TZ_NAME="$(ask "Часовой пояс (например, utc+5)" "$TZ_NAME_DEF")"
ADMIN_USER="$(ask "Имя администратора" "$ADMIN_USER_DEF")"
ADMIN_PASS="$(ask "Пароль администратора $ADMIN_USER" "$ADMIN_PASS_DEF")"

echo
echo "--- Порты ---"
WAN_PORT="$(ask "WAN-порт в сторону ISP" "$WAN_PORT_DEF")"
LAN_PORT="$(ask "LAN-порт в сторону BR-SRV" "$LAN_PORT_DEF")"

echo
echo "--- WAN / NAT ---"
WAN_IP="$(ask "WAN IP/CIDR" "$WAN_IP_DEF")"
WAN_GW="$(ask "Шлюз провайдера" "$WAN_GW_DEF")"
NAT_LOCAL_POOL="$(ask "NAT-пул локальных адресов" "$NAT_LOCAL_POOL_DEF")"

echo
echo "--- LAN BR-SRV ---"
LAN_HOSTS="$(ask "Количество адресов в локальной сети BR-SRV" "$LAN_HOSTS_DEF")"
LAN_PREF="$(calc_prefix "$LAN_HOSTS")"
LAN_GW="$(ask "IP шлюза LAN" "$LAN_GW_DEF")"
LAN_IP="$LAN_GW/$LAN_PREF"
LAN_MASK="$(calc_netmask "$LAN_PREF")"

echo
echo "--- GRE / OSPF ---"
GRE_REM_OUTER="$(ask "Внешний IP HQ-RTR для GRE" "$GRE_REMOTE_DEF")"
GRE_INNER="$(ask "Внутренний IP/CIDR GRE" "$GRE_INNER_DEF")"
OSPF_PASS="$(ask "Пароль OSPF (MD5)" "$OSPF_PASS_DEF")"

echo
echo "--- Авторизация EcoRouter ---"
read -r -p "Текущий логин EcoRouter: " RTR_USER
read -r -s -p "Текущий пароль EcoRouter: " RTR_PASS
echo

WAN_ONLY_IP="${WAN_IP%%/*}"
LAN_NET="$(calc_network "$LAN_GW" "$LAN_PREF")"
GRE_NET="$(calc_network_from_cidr "$GRE_INNER")"

if [[ -z "$LAN_NET" || -z "$GRE_NET" ]]; then
  echo "[ERROR] Не удалось вычислить сетевые параметры. Проверьте введённые значения." >&2
  exit 1
fi

info "Параметры рассчитаны. Запускаю настройку через qm terminal ${VMID}..."

export VMID FQDN TZ_NAME ADMIN_USER ADMIN_PASS
export WAN_PORT LAN_PORT WAN_IP WAN_GW NAT_LOCAL_POOL WAN_ONLY_IP
export LAN_IP LAN_MASK LAN_NET
export GRE_REM_OUTER GRE_INNER GRE_NET OSPF_PASS
export RTR_USER RTR_PASS

expect <<'EXPECT_BR'
set timeout 30
spawn qm terminal $env(VMID)
send "\r"

expect {
    "*login:"   { send "$env(RTR_USER)\r"; exp_continue }
    "*assword:" { send "$env(RTR_PASS)\r"; exp_continue }
    "*>"        { send "en\r"; exp_continue }
    "*#"        { }
    timeout      { send_user "\n[ERROR] Тайм-аут при входе в CLI EcoRouter\n"; exit 1 }
}

proc cmd {c} {
    send "$c\r"
    expect {
        "*#" { }
        "*(config)#" { }
        "*(config-if)#" { }
        "*(config-port)#" { }
        "*(config-service-instance)#" { }
        "*(config-router)#" { }
        "*(config-user)#" { }
        timeout {
            send_user "\n[TIMEOUT] Команда: $c\n"
            exit 1
        }
    }
}

cmd "conf t"
cmd "hostname $env(FQDN)"
cmd "ntp timezone $env(TZ_NAME)"

cmd "username $env(ADMIN_USER)"
cmd "password $env(ADMIN_PASS)"
cmd "role admin"
cmd "exit"

log_user 0
cmd "port $env(LAN_PORT)"
cmd "no service-instance 2"
cmd "exit"
cmd "port $env(WAN_PORT)"
cmd "no service-instance 1"
cmd "exit"
cmd "no interface eth.wan"
cmd "no interface eth.lan"
cmd "no interface tunnel.1"
cmd "no ip nat pool LOCAL_NETS"
log_user 1

cmd "interface eth.wan"
cmd "ip address $env(WAN_IP)"
cmd "ip nat outside"
cmd "exit"

cmd "interface eth.lan"
cmd "ip address $env(LAN_IP)"
cmd "ip nat inside"
cmd "exit"

cmd "port $env(WAN_PORT)"
cmd "no shutdown"
cmd "service-instance 1"
cmd "encapsulation untagged"
cmd "connect ip interface eth.wan"
cmd "exit"
cmd "exit"

cmd "port $env(LAN_PORT)"
cmd "no shutdown"
cmd "service-instance 2"
cmd "encapsulation untagged"
cmd "connect ip interface eth.lan"
cmd "exit"
cmd "exit"

cmd "ip route 0.0.0.0/0 $env(WAN_GW)"
cmd "ip nat pool LOCAL_NETS $env(NAT_LOCAL_POOL)"
cmd "ip nat source dynamic inside pool LOCAL_NETS overload interface eth.wan"

cmd "interface tunnel.1"
cmd "ip address $env(GRE_INNER)"
cmd "ip tunnel $env(WAN_ONLY_IP) $env(GRE_REM_OUTER) mode gre"
cmd "ip ospf message-digest-key 1 md5 $env(OSPF_PASS)"
cmd "exit"

cmd "router ospf 1"
cmd "ospf router-id $env(WAN_ONLY_IP)"
cmd "network $env(GRE_NET) area 0"
cmd "network $env(LAN_NET) area 0"
cmd "area 0 authentication message-digest"
cmd "exit"

cmd "end"
cmd "write memory"

send_user "\n[OK] Настройка BR-RTR завершена успешно.\n"
# Ctrl+O (0x0f) — штатный выход из qm terminal в Proxmox.
send "\x0f"
EXPECT_BR

echo "[OK] Конфигурация BR-RTR применена и сохранена (write memory)."

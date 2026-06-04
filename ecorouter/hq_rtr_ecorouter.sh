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
VMID_DEF="106"
FQDN_DEF="hq-rtr.au-team.irpo"
TZ_NAME_DEF="utc+5"

ADMIN_USER_DEF="net_admin"
ADMIN_PASS_DEF="P@ssword"

WAN_PORT_DEF="ge0"
LAN_PORT_DEF="ge1"

WAN_IP_DEF="172.16.50.2/28"
WAN_GW_DEF="172.16.50.1"
NAT_LOCAL_POOL_DEF="192.168.0.0-192.168.255.255"

V100_ID_DEF="100"
V100_HOSTS_DEF="32"
V100_GW_DEF="192.168.100.1"

V200_ID_DEF="200"
V200_HOSTS_DEF="18"
V200_GW_DEF="192.168.200.1"

V999_ID_DEF="999"
V999_HOSTS_DEF="8"
V999_GW_DEF="192.168.99.1"

DNS_SRV_DEF="192.168.100.10"
DNS_DOMAIN_DEF="au-team.irpo"

GRE_REMOTE_DEF="172.16.60.2"
GRE_INNER_DEF="172.16.0.1/30"
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

calc_dhcp_range() {
  python3 - "$1" "$2" <<'PY'
import ipaddress
import sys

try:
    gw = ipaddress.IPv4Address(sys.argv[1])
    prefix = int(sys.argv[2])
    net = ipaddress.IPv4Network(f"{gw}/{prefix}", strict=False)
    hosts = [h for h in net.hosts() if h != gw]
    if hosts:
        print(f"{hosts[0]}-{hosts[-1]}")
    else:
        print("")
except Exception:
    print("")
PY
}

calc_network() {
  python3 - "$1" "$2" <<'PY'
import ipaddress
import sys

try:
    ip = sys.argv[1]
    prefix = sys.argv[2]
    print(ipaddress.IPv4Network(f"{ip}/{prefix}", strict=False))
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

echo "=== HQ-RTR (EcoRouter Rose) Interactive Configurator ==="
VMID="$(ask "VMID устройства HQ-RTR" "$VMID_DEF")"

echo
echo "--- Базовая настройка ---"
FQDN="$(ask "FQDN устройства" "$FQDN_DEF")"
TZ_NAME="$(ask "Часовой пояс (например, utc+5)" "$TZ_NAME_DEF")"
ADMIN_USER="$(ask "Имя администратора" "$ADMIN_USER_DEF")"
ADMIN_PASS="$(ask "Пароль администратора $ADMIN_USER" "$ADMIN_PASS_DEF")"

echo
echo "--- Порты ---"
WAN_PORT="$(ask "WAN-порт в сторону ISP" "$WAN_PORT_DEF")"
LAN_PORT="$(ask "LAN-порт (trunk) в сторону HQ-SW" "$LAN_PORT_DEF")"

echo
echo "--- WAN / NAT ---"
WAN_IP="$(ask "WAN IP/CIDR" "$WAN_IP_DEF")"
WAN_GW="$(ask "Шлюз провайдера" "$WAN_GW_DEF")"
NAT_LOCAL_POOL="$(ask "NAT-пул локальных адресов" "$NAT_LOCAL_POOL_DEF")"

echo
echo "--- VLAN 100 (HQ-SRV) ---"
V100_ID="$(ask "VLAN ID для HQ-SRV" "$V100_ID_DEF")"
V100_HOSTS="$(ask "Количество адресов для VLAN $V100_ID" "$V100_HOSTS_DEF")"
V100_PREF="$(calc_prefix "$V100_HOSTS")"
V100_GW="$(ask "IP шлюза VLAN $V100_ID" "$V100_GW_DEF")"
V100_IP="$V100_GW/$V100_PREF"

echo
echo "--- VLAN 200 (HQ-CLI) ---"
V200_ID="$(ask "VLAN ID для HQ-CLI" "$V200_ID_DEF")"
V200_HOSTS="$(ask "Количество адресов для VLAN $V200_ID" "$V200_HOSTS_DEF")"
V200_PREF="$(calc_prefix "$V200_HOSTS")"
V200_GW="$(ask "IP шлюза VLAN $V200_ID" "$V200_GW_DEF")"
V200_IP="$V200_GW/$V200_PREF"
V200_MASK="$(calc_netmask "$V200_PREF")"
DHCP_RANGE="$(calc_dhcp_range "$V200_GW" "$V200_PREF")"

echo
echo "--- VLAN 999 (управление) ---"
V999_ID="$(ask "VLAN ID управления" "$V999_ID_DEF")"
V999_HOSTS="$(ask "Количество адресов для VLAN $V999_ID" "$V999_HOSTS_DEF")"
V999_PREF="$(calc_prefix "$V999_HOSTS")"
V999_GW="$(ask "IP шлюза VLAN $V999_ID" "$V999_GW_DEF")"
V999_IP="$V999_GW/$V999_PREF"

echo
echo "--- DNS ---"
DNS_SRV="$(ask "DNS-сервер для DHCP-клиентов" "$DNS_SRV_DEF")"
DNS_DOMAIN="$(ask "DNS-домен" "$DNS_DOMAIN_DEF")"

echo
echo "--- GRE / OSPF ---"
GRE_REM_OUTER="$(ask "Внешний IP BR-RTR для GRE" "$GRE_REMOTE_DEF")"
GRE_INNER="$(ask "Внутренний IP/CIDR GRE" "$GRE_INNER_DEF")"
OSPF_PASS="$(ask "Пароль OSPF (MD5)" "$OSPF_PASS_DEF")"

echo
echo "--- Авторизация EcoRouter ---"
read -r -p "Текущий логин EcoRouter: " RTR_USER
read -r -s -p "Текущий пароль EcoRouter: " RTR_PASS
echo

WAN_ONLY_IP="${WAN_IP%%/*}"
V100_NET="$(calc_network "$V100_GW" "$V100_PREF")"
V200_NET="$(calc_network "$V200_GW" "$V200_PREF")"
V999_NET="$(calc_network "$V999_GW" "$V999_PREF")"
GRE_NET="$(calc_network_from_cidr "$GRE_INNER")"

if [[ -z "$DHCP_RANGE" || -z "$V100_NET" || -z "$V200_NET" || -z "$V999_NET" || -z "$GRE_NET" ]]; then
  echo "[ERROR] Не удалось вычислить сетевые параметры. Проверьте введённые значения." >&2
  exit 1
fi

info "Параметры рассчитаны. Запускаю настройку через qm terminal ${VMID}..."

export VMID FQDN TZ_NAME ADMIN_USER ADMIN_PASS
export WAN_PORT LAN_PORT WAN_IP WAN_GW NAT_LOCAL_POOL WAN_ONLY_IP
export V100_ID V100_IP V100_NET
export V200_ID V200_IP V200_GW V200_MASK V200_NET DHCP_RANGE
export V999_ID V999_IP V999_NET
export DNS_SRV DNS_DOMAIN
export GRE_REM_OUTER GRE_INNER GRE_NET OSPF_PASS
export RTR_USER RTR_PASS

expect <<'EXPECT_HQ'
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
        "*(config-if-bmi)#" { }
        "*(config-port)#" { }
        "*(config-service-instance)#" { }
        "*(config-sub-map)#" { }
        "*(config-sub-policy)#" { }
        "*(config-sub-service)#" { }
        "*(config-filter-map-ipv4)#" { }
        "*(config-filter-map-policy-ipv4)#" { }
        "*(config-dhcp-server)#" { }
        "*(config-ip-pool)#" { }
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
cmd "no service-instance $env(V100_ID)"
cmd "no service-instance $env(V200_ID)"
cmd "no service-instance $env(V999_ID)"
cmd "exit"
cmd "port $env(WAN_PORT)"
cmd "no service-instance 1"
cmd "exit"
cmd "no interface eth.wan"
cmd "no interface eth.$env(V100_ID)"
cmd "no interface bmi.$env(V200_ID)"
cmd "no interface eth.$env(V999_ID)"
cmd "no interface tunnel.1"
cmd "no ip pool CLI_POOL"
cmd "no dhcp-server 1"
cmd "no ip nat pool LOCAL_NETS"
log_user 1

cmd "interface eth.wan"
cmd "ip address $env(WAN_IP)"
cmd "ip nat outside"
cmd "exit"

cmd "interface eth.$env(V100_ID)"
cmd "ip address $env(V100_IP)"
cmd "ip nat inside"
cmd "exit"

cmd "interface bmi.$env(V200_ID)"
cmd "ip address $env(V200_IP)"
cmd "ip nat inside"
cmd "exit"

cmd "interface eth.$env(V999_ID)"
cmd "ip address $env(V999_IP)"
cmd "ip nat inside"
cmd "exit"

cmd "ip pool CLI_POOL"
cmd "range $env(DHCP_RANGE)"
cmd "exit"

cmd "dhcp-server 1"
cmd "pool CLI_POOL 10"
cmd "gateway $env(V200_GW)"
cmd "mask $env(V200_MASK)"
cmd "dns $env(DNS_SRV)"
cmd "domain-name $env(DNS_DOMAIN)"
cmd "exit"

cmd "ip prefix-list ALL_NET permit 0.0.0.0/0"

cmd "filter-map policy ipv4 ALLOW_ALL 10"
cmd "match any any any"
cmd "set accept"
cmd "exit"

cmd "subscriber-policy POL_LAN"
cmd "bandwidth in kbps 100000"
cmd "bandwidth out kbps 100000"
cmd "set filter-map in ALLOW_ALL"
cmd "set filter-map out ALLOW_ALL"
cmd "exit"

cmd "subscriber-service SERV_LAN"
cmd "set policy POL_LAN"
cmd "exit"

cmd "subscriber-map MAP_LAN 10"
cmd "match dynamic prefix-list ALL_NET"
cmd "set subscriber-service SERV_LAN"
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

cmd "service-instance $env(V100_ID)"
cmd "encapsulation dot1q $env(V100_ID) exact"
cmd "rewrite pop 1"
cmd "connect ip interface eth.$env(V100_ID)"
cmd "exit"

cmd "service-instance $env(V200_ID)"
cmd "encapsulation dot1q $env(V200_ID) exact"
cmd "rewrite pop 1"
cmd "connect ip interface bmi.$env(V200_ID)"
cmd "exit"

cmd "service-instance $env(V999_ID)"
cmd "encapsulation dot1q $env(V999_ID) exact"
cmd "rewrite pop 1"
cmd "connect ip interface eth.$env(V999_ID)"
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
cmd "network $env(V100_NET) area 0"
cmd "network $env(V200_NET) area 0"
cmd "network $env(V999_NET) area 0"
cmd "network $env(GRE_NET) area 0"
cmd "area 0 authentication message-digest"
cmd "exit"

cmd "end"
cmd "write memory"

send_user "\n[OK] Настройка HQ-RTR завершена успешно.\n"
# Ctrl+O (0x0f) — штатный выход из qm terminal в Proxmox.
send "\x0f"
EXPECT_HQ

echo "[OK] Конфигурация HQ-RTR применена и сохранена (write memory)."

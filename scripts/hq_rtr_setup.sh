#!/bin/bash
# Скрипт настройки HQ-RTR (Альт JeOS / Linux-версия, не EcoRouter)
# Покрывает: задания 1, 4, 6, 7, 8, 9
# Демоэкзамен 09.02.06 Сетевое и системное администрирование, 2026

set -euo pipefail

# ─── Цветной вывод ────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'
NC='\033[0m'

info()  { echo -e "${CYAN}[INFO]${NC}  $*"; }
ok()    { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }

# ─── Проверка root ────────────────────────────────────────────────────────────
if [[ $EUID -ne 0 ]]; then
    error "Скрипт должен быть запущен от имени root (sudo или su -)"
    exit 1
fi

echo
echo "============================================================"
echo "  Настройка HQ-RTR — демоэкзамен 09.02.06 (2026)"
echo "  Задания: 1, 4, 6, 7, 8, 9"
echo "============================================================"
echo

# ─── Интерактивный ввод параметров ───────────────────────────────────────────
read -rp "Имя WAN-интерфейса (в сторону ISP) [eth0]: " WAN_IFACE
WAN_IFACE="${WAN_IFACE:-eth0}"

read -rp "Имя физического LAN-интерфейса (для VLAN) [eth1]: " LAN_IFACE
LAN_IFACE="${LAN_IFACE:-eth1}"

read -rp "Часовой пояс [Europe/Moscow]: " TZ_NAME
TZ_NAME="${TZ_NAME:-Europe/Moscow}"

read -rp "Внешний IP BR-RTR (WAN, для GRE-туннеля) [172.16.2.2]: " BR_WAN_IP
BR_WAN_IP="${BR_WAN_IP:-172.16.2.2}"

read -rsp "Пароль OSPF (по умолчанию P@ssw0rd): " OSPF_PASS
echo
OSPF_PASS="${OSPF_PASS:-P@ssw0rd}"

read -rp "IP-адрес HQ-SRV (DNS-сервер для DHCP) [192.168.1.2]: " HQ_SRV_IP
HQ_SRV_IP="${HQ_SRV_IP:-192.168.1.2}"

echo
info "Параметры конфигурации:"
echo "  WAN интерфейс:     $WAN_IFACE (172.16.1.2/28, шлюз 172.16.1.1)"
echo "  LAN интерфейс:     $LAN_IFACE"
echo "  VLAN 100 (HQ-SRV): ${LAN_IFACE}.100 — 192.168.1.1/27"
echo "  VLAN 200 (HQ-CLI): ${LAN_IFACE}.200 — 192.168.2.1/27"
echo "  VLAN 999 (Mgmt):   ${LAN_IFACE}.999 — 192.168.99.1/29"
echo "  GRE туннель:       local=172.16.1.2, remote=$BR_WAN_IP, tunnel=10.0.0.1/30"
echo "  Часовой пояс:      $TZ_NAME"
echo "  DNS для DHCP:      $HQ_SRV_IP"
echo
read -rp "Продолжить? [y/N]: " CONFIRM
if [[ ! "${CONFIRM,,}" =~ ^y ]]; then
    info "Операция отменена."
    exit 0
fi

declare -A STATUS

# ─── 1. Hostname ──────────────────────────────────────────────────────────────
info "Устанавливаю hostname: hq-rtr.au-team.irpo"
hostnamectl set-hostname hq-rtr.au-team.irpo
ok "Hostname: hq-rtr.au-team.irpo"
STATUS["hostname"]="OK"

# ─── 2. Часовой пояс ─────────────────────────────────────────────────────────
info "Часовой пояс: $TZ_NAME"
if timedatectl set-timezone "$TZ_NAME" 2>/dev/null; then
    ok "Часовой пояс установлен: $TZ_NAME"
    STATUS["timezone"]="OK"
else
    error "Ошибка установки часового пояса"
    STATUS["timezone"]="ERROR"
fi

# ─── 3. IP-адресация (задание 1) — WAN ───────────────────────────────────────
info "[Задание 1] Настройка IP на WAN ($WAN_IFACE): 172.16.1.2/28, шлюз 172.16.1.1"

nmcli con delete "wan-${WAN_IFACE}" &>/dev/null || true
nmcli con add type ethernet ifname "$WAN_IFACE" con-name "wan-${WAN_IFACE}" \
    ipv4.method manual \
    ipv4.addresses "172.16.1.2/28" \
    ipv4.gateway "172.16.1.1" \
    ipv4.dns "77.88.8.7 77.88.8.3" \
    connection.autoconnect yes
nmcli con up "wan-${WAN_IFACE}"
ok "WAN ($WAN_IFACE): 172.16.1.2/28, шлюз 172.16.1.1"
STATUS["ip_wan"]="OK"

# ─── 4. VLAN sub-интерфейсы (задание 4) ──────────────────────────────────────
info "[Задание 4] Создание VLAN sub-интерфейсов..."

create_vlan() {
    local vlan_id="$1" ip="$2" desc="$3"
    local con_name="vlan${vlan_id}"
    nmcli con delete "$con_name" &>/dev/null || true
    nmcli con add type vlan ifname "${LAN_IFACE}.${vlan_id}" con-name "$con_name" \
        dev "$LAN_IFACE" id "$vlan_id" \
        ipv4.method manual ipv4.addresses "$ip" \
        connection.autoconnect yes
    nmcli con up "$con_name"
    ok "VLAN $vlan_id ($desc): ${LAN_IFACE}.${vlan_id} = $ip"
}

create_vlan 100 "192.168.1.1/27"  "HQ-SRV"  && STATUS["vlan100"]="OK"  || STATUS["vlan100"]="ERROR"
create_vlan 200 "192.168.2.1/27"  "HQ-CLI"  && STATUS["vlan200"]="OK"  || STATUS["vlan200"]="ERROR"
create_vlan 999 "192.168.99.1/29" "Управление" && STATUS["vlan999"]="OK" || STATUS["vlan999"]="ERROR"

# ─── 5. IP forwarding ─────────────────────────────────────────────────────────
info "Включение IP forwarding..."
if grep -q '^net.ipv4.ip_forward' /etc/sysctl.conf; then
    sed -i 's/^#*\s*net\.ipv4\.ip_forward.*/net.ipv4.ip_forward=1/' /etc/sysctl.conf
else
    echo 'net.ipv4.ip_forward=1' >> /etc/sysctl.conf
fi
sysctl -w net.ipv4.ip_forward=1 >/dev/null
ok "IP forwarding включён"
STATUS["ip_forward"]="OK"

# ─── 6. GRE-туннель (задание 6) ──────────────────────────────────────────────
info "[Задание 6] Создание GRE-туннеля gre1..."
info "  local=172.16.1.2, remote=$BR_WAN_IP, tunnel IP=10.0.0.1/30"

# Удаляем старый туннель если есть
ip tunnel del gre1 2>/dev/null || true
nmcli con delete gre1 2>/dev/null || true

# Создаём через nmcli (тип ip-tunnel)
nmcli con add type ip-tunnel ifname gre1 con-name gre1 \
    tunnel.mode gre \
    tunnel.local "172.16.1.2" \
    tunnel.remote "$BR_WAN_IP" \
    ipv4.method manual ipv4.addresses "10.0.0.1/30" \
    connection.autoconnect yes
nmcli con up gre1
ok "GRE туннель gre1 создан: 10.0.0.1/30"
STATUS["gre_tunnel"]="OK"

# ─── 7. OSPF через FRR (задание 7) ───────────────────────────────────────────
info "[Задание 7] Настройка OSPF через FRR..."

if ! command -v ospfd &>/dev/null && ! command -v vtysh &>/dev/null; then
    info "Установка FRR..."
    apt-get install -y frr || {
        error "Не удалось установить frr"
        STATUS["ospf"]="ERROR"
    }
fi

if command -v vtysh &>/dev/null || [[ -f /etc/frr/daemons ]]; then
    # Включаем ospfd
    FRR_DAEMONS="/etc/frr/daemons"
    if [[ -f "$FRR_DAEMONS" ]]; then
        cp "$FRR_DAEMONS" "${FRR_DAEMONS}.bak"
        sed -i 's/^ospfd=no/ospfd=yes/' "$FRR_DAEMONS"
        ok "ospfd включён в $FRR_DAEMONS"
    fi

    # Генерируем конфиг OSPF
    FRR_OSPF="/etc/frr/frr.conf"
    [[ -f "$FRR_OSPF" ]] && cp "$FRR_OSPF" "${FRR_OSPF}.bak"

    cat > "$FRR_OSPF" <<EOF
!
! FRR OSPF конфигурация HQ-RTR — демоэкзамен 09.02.06 (2026)
!
frr version 8.1
frr defaults traditional
hostname hq-rtr.au-team.irpo
!
router ospf
 ospf router-id 10.0.0.1
 !
 ! Разрешаем OSPF только на туннельном интерфейсе
 network 10.0.0.0/30 area 0
 !
 ! Парольная защита
 area 0 authentication message-digest
 !
 ! Пассивный режим для всех интерфейсов кроме туннеля
 passive-interface default
 no passive-interface gre1
!
interface gre1
 ip ospf authentication message-digest
 ip ospf message-digest-key 1 md5 ${OSPF_PASS}
!
line vty
!
EOF
    systemctl enable --now frr 2>/dev/null || service frr restart 2>/dev/null || true
    ok "OSPF (FRR) настроен, router-id=10.0.0.1"
    STATUS["ospf"]="OK"
else
    warn "FRR не найден, пропускаю настройку OSPF"
    STATUS["ospf"]="SKIP"
fi

# ─── 8. NAT через nftables (задание 8) ───────────────────────────────────────
info "[Задание 8] Настройка NAT (masquerade) для VLAN 100, 200, 999..."

if ! command -v nft &>/dev/null; then
    info "Установка nftables..."
    apt-get install -y nftables
fi

NFT_CONF="/etc/nftables.conf"
[[ -f "$NFT_CONF" ]] && cp "$NFT_CONF" "${NFT_CONF}.bak"

cat > "$NFT_CONF" <<EOF
#!/usr/sbin/nft -f
# nftables конфигурация HQ-RTR — демоэкзамен 09.02.06 (2026)

flush ruleset

table ip nat {
    chain postrouting {
        type nat hook postrouting priority 100; policy accept;
        # Masquerade VLAN 100 (HQ-SRV) → Интернет
        iifname "${LAN_IFACE}.100" oifname "${WAN_IFACE}" masquerade
        # Masquerade VLAN 200 (HQ-CLI) → Интернет
        iifname "${LAN_IFACE}.200" oifname "${WAN_IFACE}" masquerade
        # Masquerade VLAN 999 (Управление) → Интернет
        iifname "${LAN_IFACE}.999" oifname "${WAN_IFACE}" masquerade
    }
}

table ip filter {
    chain forward {
        type filter hook forward priority 0; policy accept;
    }
}
EOF

systemctl enable --now nftables 2>/dev/null || true
nft -f "$NFT_CONF"
ok "NAT (nftables) настроен для VLAN 100, 200, 999"
STATUS["nat"]="OK"

# ─── 9. DHCP для HQ-CLI (задание 9) ──────────────────────────────────────────
info "[Задание 9] Настройка DHCP-сервера для HQ-CLI (VLAN 200: 192.168.2.0/27)..."

if ! command -v dhcpd &>/dev/null; then
    info "Установка dhcp-server..."
    apt-get install -y dhcp-server || apt-get install -y isc-dhcp-server || {
        error "Не удалось установить DHCP-сервер"
        STATUS["dhcp"]="ERROR"
    }
fi

DHCPD_CONF="/etc/dhcp/dhcpd.conf"
if [[ -f "$DHCPD_CONF" ]]; then
    cp "$DHCPD_CONF" "${DHCPD_CONF}.bak"
    info "Резервная копия: ${DHCPD_CONF}.bak"
fi

mkdir -p /etc/dhcp
cat > "$DHCPD_CONF" <<EOF
# dhcpd.conf — HQ-RTR DHCP для HQ-CLI (VLAN 200)
# Демоэкзамен 09.02.06 (2026)

option domain-name "au-team.irpo";
option domain-name-servers ${HQ_SRV_IP};

default-lease-time 600;
max-lease-time 7200;

authoritative;

# Подсеть VLAN 200 (HQ-CLI): 192.168.2.0/27
subnet 192.168.2.0 netmask 255.255.255.224 {
    # Диапазон выдачи (исключаем адрес маршрутизатора 192.168.2.1)
    range 192.168.2.2 192.168.2.30;
    option routers 192.168.2.1;
    option subnet-mask 255.255.255.224;
    option domain-name-servers ${HQ_SRV_IP};
    option domain-name "au-team.irpo";
}
EOF

# Настройка интерфейса DHCP-сервера (для Альт Линукс)
DHCP_SYSCONF="/etc/sysconfig/dhcpd"
if [[ -f "$DHCP_SYSCONF" ]]; then
    cp "$DHCP_SYSCONF" "${DHCP_SYSCONF}.bak"
    echo "DHCPDARGS=\"${LAN_IFACE}.200\"" > "$DHCP_SYSCONF"
fi

# Для isc-dhcp-server (Debian-based)
ISC_DEFAULT="/etc/default/isc-dhcp-server"
if [[ -f "$ISC_DEFAULT" ]]; then
    cp "$ISC_DEFAULT" "${ISC_DEFAULT}.bak"
    sed -i "s/^INTERFACESv4=.*/INTERFACESv4=\"${LAN_IFACE}.200\"/" "$ISC_DEFAULT"
fi

# Запуск DHCP-сервера
for svc in dhcpd isc-dhcp-server dhcp-server; do
    if systemctl enable --now "$svc" 2>/dev/null; then
        ok "DHCP-сервер ($svc) запущен и включён"
        STATUS["dhcp"]="OK"
        break
    fi
done
STATUS["dhcp"]="${STATUS[dhcp]:-ERROR}"

# ─── 10. Пользователь net_admin (задание 3) ───────────────────────────────────
info "[Задание 3] Создание пользователя net_admin..."
if ! id net_admin &>/dev/null; then
    useradd -m -s /bin/bash net_admin
    echo "net_admin:P@ssw0rd" | chpasswd
    echo "net_admin ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/net_admin
    chmod 440 /etc/sudoers.d/net_admin
    ok "Пользователь net_admin создан"
else
    warn "Пользователь net_admin уже существует"
fi
STATUS["net_admin"]="OK"

# ─── Итоговый статус ──────────────────────────────────────────────────────────
echo
echo "============================================================"
echo "  Итог настройки HQ-RTR"
echo "============================================================"
for key in hostname timezone ip_wan vlan100 vlan200 vlan999 ip_forward gre_tunnel ospf nat dhcp net_admin; do
    val="${STATUS[$key]:-SKIP}"
    case "$val" in
        OK)    echo -e "  ${GREEN}[OK]${NC}    $key" ;;
        ERROR) echo -e "  ${RED}[ERROR]${NC} $key" ;;
        *)     echo -e "  ${YELLOW}[SKIP]${NC}  $key" ;;
    esac
done
echo "============================================================"
echo
ok "Настройка HQ-RTR завершена!"

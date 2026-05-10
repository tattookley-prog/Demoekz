#!/bin/bash
# Скрипт настройки HQ-RTR (Альт JeOS / Linux-версия, не EcoRouter)
# Покрывает: задания 1, 4, 6, 7, 8, 9
# Демоэкзамен 09.02.06 Сетевое и системное администрирование, 2026

set -euo pipefail

# ─── Цветной вывод ─────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'
NC='\033[0m'

info()  { echo -e "${CYAN}[INFO]${NC}  $*"; }
ok()    { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }

# ─── Проверка root ──────────────────────────────────────────────────────────
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

# ─── Интерактивный ввод параметров ─────────────────────────────────────────
read -rp "Имя WAN-интерфейса (в сторону ISP) [ens18]: " WAN_IFACE
WAN_IFACE="${WAN_IFACE:-ens18}"

read -rp "Имя LAN-интерфейса (в сторону HQ-SRV) [ens19]: " LAN_IFACE
LAN_IFACE="${LAN_IFACE:-ens19}"

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
echo "  WAN интерфейс:  $WAN_IFACE (172.16.1.2/28, шлюз 172.16.1.1)"
echo "  LAN интерфейс:  $LAN_IFACE (192.168.1.1/27 — сторона HQ-SRV)"
echo "  GRE туннель:    local=172.16.1.2, remote=$BR_WAN_IP, tunnel=10.0.0.1/30"
echo "  Часовой пояс:   $TZ_NAME"
echo "  DNS для DHCP:   $HQ_SRV_IP"
echo
read -rp "Продолжить? [y/N]: " CONFIRM
if [[ ! "${CONFIRM,,}" =~ ^y ]]; then
    info "Операция отменена."
    exit 0
fi

declare -A STATUS

# ─── 1. Hostname ────────────────────────────────────────────────────────────
info "Устанавливаю hostname: hq-rtr.au-team.irpo"
hostnamectl set-hostname hq-rtr.au-team.irpo
ok "Hostname: hq-rtr.au-team.irpo"
STATUS["hostname"]="OK"

# ─── 2. Часовой пояс ────────────────────────────────────────────────────────
info "Часовой пояс: $TZ_NAME"
if timedatectl set-timezone "$TZ_NAME" 2>/dev/null; then
    ok "Часовой пояс установлен: $TZ_NAME"
    STATUS["timezone"]="OK"
else
    error "Ошибка установки часового пояса"
    STATUS["timezone"]="ERROR"
fi

# ─── 3. IP forwarding ───────────────────────────────────────────────────────
info "Включение IP forwarding..."
if grep -q '^net.ipv4.ip_forward' /etc/sysctl.conf 2>/dev/null; then
    sed -i 's/^#*\s*net\.ipv4\.ip_forward.*/net.ipv4.ip_forward=1/' /etc/sysctl.conf
else
    echo 'net.ipv4.ip_forward=1' >> /etc/sysctl.conf
fi
echo 1 > /proc/sys/net/ipv4/ip_forward
sysctl -w net.ipv4.ip_forward=1 >/dev/null
ok "IP forwarding включён"
STATUS["ip_forward"]="OK"

# ─── 4. IP-адресация WAN (задание 1) ────────────────────────────────────────
info "[Задание 1] Настройка WAN ($WAN_IFACE): 172.16.1.2/28, шлюз 172.16.1.1"

if command -v nmcli &>/dev/null; then
    nmcli con delete "wan-${WAN_IFACE}" &>/dev/null || true
    nmcli con add type ethernet ifname "$WAN_IFACE" con-name "wan-${WAN_IFACE}" \
        ipv4.method manual \
        ipv4.addresses "172.16.1.2/28" \
        ipv4.gateway "172.16.1.1" \
        ipv4.dns "77.88.8.7 77.88.8.3" \
        connection.autoconnect yes
    nmcli con up "wan-${WAN_IFACE}"
else
    ip addr flush dev "$WAN_IFACE" 2>/dev/null || true
    ip addr add 172.16.1.2/28 dev "$WAN_IFACE"
    ip link set "$WAN_IFACE" up
    ip route replace default via 172.16.1.1 dev "$WAN_IFACE"
fi
ok "WAN ($WAN_IFACE): 172.16.1.2/28, шлюз 172.16.1.1"
STATUS["ip_wan"]="OK"

# ─── 5. IP-адресация LAN (задание 1) — прямо на ens19 ──────────────────────
info "[Задание 1] Настройка LAN ($LAN_IFACE): 192.168.1.1/27"

if command -v nmcli &>/dev/null; then
    nmcli con delete "lan-${LAN_IFACE}" &>/dev/null || true
    nmcli con add type ethernet ifname "$LAN_IFACE" con-name "lan-${LAN_IFACE}" \
        ipv4.method manual \
        ipv4.addresses "192.168.1.1/27" \
        connection.autoconnect yes
    nmcli con up "lan-${LAN_IFACE}"
else
    ip addr flush dev "$LAN_IFACE" 2>/dev/null || true
    ip addr add 192.168.1.1/27 dev "$LAN_IFACE"
    ip link set "$LAN_IFACE" up
fi
ok "LAN ($LAN_IFACE): 192.168.1.1/27"
STATUS["ip_lan"]="OK"

# ─── 6. NAT через iptables (задание 8) ──────────────────────────────────────
info "[Задание 8] Настройка NAT (MASQUERADE) через iptables..."

# Устанавливаем iptables если нет
if ! command -v iptables &>/dev/null; then
    apt-get install -y iptables || {
        error "Не удалось установить iptables"
        STATUS["nat"]="ERROR"
    }
fi

if command -v iptables &>/dev/null; then
    # Сбрасываем старые правила NAT
    iptables -t nat -F POSTROUTING 2>/dev/null || true

    # Добавляем MASQUERADE для LAN → WAN
    iptables -t nat -A POSTROUTING -o "$WAN_IFACE" -j MASQUERADE
    ok "NAT: MASQUERADE добавлен (out: $WAN_IFACE)"

    # Сохраняем правила iptables
    if command -v iptables-save &>/dev/null; then
        mkdir -p /etc/iptables
        iptables-save > /etc/iptables/rules.v4
        ok "Правила iptables сохранены: /etc/iptables/rules.v4"
    fi

    # Автозагрузка правил при старте (через rc.local если нет iptables-persistent)
    RC_LOCAL="/etc/rc.local"
    if [[ ! -f "$RC_LOCAL" ]] || ! grep -q "iptables-restore" "$RC_LOCAL"; then
        cat > "$RC_LOCAL" <<'EOF'
#!/bin/bash
# Восстановление правил iptables при старте
if [[ -f /etc/iptables/rules.v4 ]]; then
    iptables-restore < /etc/iptables/rules.v4
fi
echo 1 > /proc/sys/net/ipv4/ip_forward
exit 0
EOF
        chmod +x "$RC_LOCAL"
        ok "Автозагрузка NAT добавлена в $RC_LOCAL"
    fi

    STATUS["nat"]="OK"
else
    warn "iptables не найден, пропускаю NAT"
    STATUS["nat"]="SKIP"
fi

# ─── 7. GRE-туннель (задание 6) ─────────────────────────────────────────────
info "[Задание 6] Создание GRE-туннеля gre1..."
info "  local=172.16.1.2, remote=$BR_WAN_IP, tunnel IP=10.0.0.1/30"

ip tunnel del gre1 2>/dev/null || true
if command -v nmcli &>/dev/null; then
    nmcli con delete gre1 2>/dev/null || true
    nmcli con add type ip-tunnel ifname gre1 con-name gre1 \
        tunnel.mode gre \
        tunnel.local "172.16.1.2" \
        tunnel.remote "$BR_WAN_IP" \
        ipv4.method manual ipv4.addresses "10.0.0.1/30" \
        connection.autoconnect yes
    nmcli con up gre1
else
    ip tunnel add gre1 mode gre local "172.16.1.2" remote "$BR_WAN_IP" ttl 255
    ip addr add 10.0.0.1/30 dev gre1
    ip link set gre1 up
fi
ok "GRE туннель gre1 создан: 10.0.0.1/30"
STATUS["gre_tunnel"]="OK"

# ─── 8. OSPF через FRR (задание 7) ──────────────────────────────────────────
info "[Задание 7] Настройка OSPF через FRR..."

if ! command -v vtysh &>/dev/null; then
    info "Установка FRR..."
    apt-get install -y frr || {
        error "Не удалось установить frr"
        STATUS["ospf"]="ERROR"
    }
fi

if command -v vtysh &>/dev/null || [[ -f /etc/frr/daemons ]]; then
    FRR_DAEMONS="/etc/frr/daemons"
    if [[ -f "$FRR_DAEMONS" ]]; then
        cp "$FRR_DAEMONS" "${FRR_DAEMONS}.bak"
        sed -i 's/^ospfd=no/ospfd=yes/' "$FRR_DAEMONS"
        ok "ospfd включён в $FRR_DAEMONS"
    fi

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
 network 10.0.0.0/30 area 0
 area 0 authentication message-digest
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

# ─── 9. DHCP для HQ-CLI (задание 9) ─────────────────────────────────────────
info "[Задание 9] Настройка DHCP-сервера для HQ-CLI (192.168.2.0/27)..."

if ! command -v dhcpd &>/dev/null; then
    apt-get install -y dhcp-server || apt-get install -y isc-dhcp-server || {
        error "Не удалось установить DHCP-сервер"
        STATUS["dhcp"]="ERROR"
    }
fi

DHCPD_CONF="/etc/dhcp/dhcpd.conf"
[[ -f "$DHCPD_CONF" ]] && cp "$DHCPD_CONF" "${DHCPD_CONF}.bak"
mkdir -p /etc/dhcp

cat > "$DHCPD_CONF" <<EOF
# dhcpd.conf — HQ-RTR DHCP для HQ-CLI
# Демоэкзамен 09.02.06 (2026)

option domain-name "au-team.irpo";
option domain-name-servers ${HQ_SRV_IP};

default-lease-time 600;
max-lease-time 7200;

authoritative;

subnet 192.168.2.0 netmask 255.255.255.224 {
    range 192.168.2.2 192.168.2.30;
    option routers 192.168.2.1;
    option subnet-mask 255.255.255.224;
    option domain-name-servers ${HQ_SRV_IP};
    option domain-name "au-team.irpo";
}
EOF

for svc in dhcpd isc-dhcp-server dhcp-server; do
    if systemctl enable --now "$svc" 2>/dev/null; then
        ok "DHCP-сервер ($svc) запущен"
        STATUS["dhcp"]="OK"
        break
    fi
done
STATUS["dhcp"]="${STATUS[dhcp]:-ERROR}"

# ─── 10. Пользователь net_admin (задание 3) ──────────────────────────────────
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

# ─── Итоговый статус ──────────────────────────────────────────────��─────────
echo
echo "============================================================"
echo "  Итог настройки HQ-RTR"
echo "============================================================"
for key in hostname timezone ip_forward ip_wan ip_lan nat gre_tunnel ospf dhcp net_admin; do
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
info "WAN: $WAN_IFACE (172.16.1.2/28) | LAN: $LAN_IFACE (192.168.1.1/27)"
info "NAT: iptables MASQUERADE через $WAN_IFACE"
info "GRE: 10.0.0.1/30 → $BR_WAN_IP"

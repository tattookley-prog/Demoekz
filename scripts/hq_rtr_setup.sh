#!/bin/bash
# Скрипт настройки HQ-RTR (Альт Сервер, не EcoRouter)
# Покрывает: задания 1, 4, 6, 7, 8, 9
# Демоэкзамен 09.02.06 Сетевое и системное администрирование, 2026
#
# Топология:
#   ens18              → ISP         172.16.1.2/28, шлюз 172.16.1.1
#   ens19 (trunk)      → HQ-SW
#     └─ ens19.100     → HQ-SRV      192.168.1.1/27  (VLAN 100, SRV-Net)
#     └─ ens19.200     → HQ-CLI      192.168.2.1/27  (VLAN 200, CLI-Net)
#   gre1               → BR-RTR      10.0.0.1/30

set -euo pipefail

# ─── Цветной вывод ─────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'
NC='\033[0m'

info()  { echo -e "${CYAN}[INFO]${NC}  $*"; }
ok()    { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }

# ─── Проверка root ──────────────────────────────────────────────────────────────
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
echo "  Топология:"
echo "    ens18          → ISP         172.16.1.2/28"
echo "    ens19 (trunk)  → HQ-SW"
echo "      ens19.100    → HQ-SRV      192.168.1.1/27  (VLAN 100)"
echo "      ens19.200    → HQ-CLI      192.168.2.1/27  (VLAN 200)"
echo "    gre1           → BR-RTR      10.0.0.1/30"
echo

# ─── Интерактивный ввод параметров ─────────────────────────────────────────────
read -rp "Имя WAN-интерфейса (в сторону ISP) [ens18]: " WAN_IFACE
WAN_IFACE="${WAN_IFACE:-ens18}"

read -rp "Имя trunk-интерфейса (в сторону HQ-SW) [ens19]: " TRUNK_IFACE
TRUNK_IFACE="${TRUNK_IFACE:-ens19}"

read -rp "Часовой пояс [Europe/Moscow]: " TZ_NAME
TZ_NAME="${TZ_NAME:-Europe/Moscow}"

read -rp "Внешний IP BR-RTR (WAN, для GRE-туннеля) [172.16.2.2]: " BR_WAN_IP
BR_WAN_IP="${BR_WAN_IP:-172.16.2.2}"

read -rsp "Пароль OSPF [P@ssw0rd]: " OSPF_PASS
echo
OSPF_PASS="${OSPF_PASS:-P@ssw0rd}"

read -rp "IP-адрес HQ-SRV (DNS-сервер для DHCP) [192.168.1.2]: " HQ_SRV_IP
HQ_SRV_IP="${HQ_SRV_IP:-192.168.1.2}"

echo
info "Параметры конфигурации:"
echo "  WAN:          $WAN_IFACE (172.16.1.2/28, шлюз 172.16.1.1)"
echo "  Trunk:        $TRUNK_IFACE"
echo "  VLAN 100:     ${TRUNK_IFACE}.100 = 192.168.1.1/27  (HQ-SRV)"
echo "  VLAN 200:     ${TRUNK_IFACE}.200 = 192.168.2.1/27  (HQ-CLI, DHCP)"
echo "  GRE туннель:  local=172.16.1.2, remote=$BR_WAN_IP, tunnel=10.0.0.1/30"
echo "  Часовой пояс: $TZ_NAME"
echo "  DNS для DHCP: $HQ_SRV_IP"
echo
read -rp "Продолжить? [y/N]: " CONFIRM
if [[ ! "${CONFIRM,,}" =~ ^y ]]; then
    info "Операция отменена."
    exit 0
fi

declare -A STATUS

# ─── 1. Hostname ───────────────────────────────────────────────────────────────
info "Устанавливаю hostname: hq-rtr.au-team.irpo"
hostnamectl set-hostname hq-rtr.au-team.irpo
ok "Hostname: hq-rtr.au-team.irpo"
STATUS["hostname"]="OK"

# ─── 2. Часовой пояс ──────────────────────────────────────────────────────────
info "Часовой пояс: $TZ_NAME"
if timedatectl set-timezone "$TZ_NAME" 2>/dev/null; then
    ok "Часовой пояс установлен: $TZ_NAME"
    STATUS["timezone"]="OK"
elif [[ -f "/usr/share/zoneinfo/${TZ_NAME}" ]]; then
    ln -sf "/usr/share/zoneinfo/${TZ_NAME}" /etc/localtime
    echo "$TZ_NAME" > /etc/timezone 2>/dev/null || true
    ok "Часовой пояс установлен через symlink: $TZ_NAME"
    STATUS["timezone"]="OK"
else
    error "Ошибка установки часового пояса"
    STATUS["timezone"]="ERROR"
fi

# ─── 3. IP forwarding ─────────────────────────────────────────────────────────
info "Включение IP forwarding..."
echo 'net.ipv4.ip_forward = 1' > /etc/sysctl.d/99-ipforward.conf
sysctl -w net.ipv4.ip_forward=1 >/dev/null
if grep -q '^net.ipv4.ip_forward' /etc/sysctl.conf 2>/dev/null; then
    sed -i 's/^#*\s*net\.ipv4\.ip_forward.*/net.ipv4.ip_forward=1/' /etc/sysctl.conf
else
    echo 'net.ipv4.ip_forward=1' >> /etc/sysctl.conf
fi
ok "IP forwarding включён"
STATUS["ip_forward"]="OK"

# ─── 4. Загрузка модуля 8021q ─────────────────────────────────────────────────
info "Загрузка модуля 8021q для VLAN..."
modprobe 8021q 2>/dev/null || true
echo '8021q' > /etc/modules-load.d/8021q.conf 2>/dev/null || true
ok "Модуль 8021q загружен"

# ─── 5. WAN-интерфейс (задание 1) — через etcnet ──────────────────────────────
info "[Задание 1] Настройка WAN ($WAN_IFACE): 172.16.1.2/28, шлюз 172.16.1.1"

WAN_DIR="/etc/net/ifaces/${WAN_IFACE}"
mkdir -p "$WAN_DIR"
cat > "${WAN_DIR}/options" <<EOF
BOOTPROTO=static
ONBOOT=yes
TYPE=eth
DISABLED=no
NM_CONTROLLED=no
CONFIG_IPV4=yes
EOF
echo "172.16.1.2/28" > "${WAN_DIR}/ipv4address"
echo "default via 172.16.1.1" > "${WAN_DIR}/ipv4route"

# Применяем немедленно
ip addr flush dev "$WAN_IFACE" 2>/dev/null || true
ip addr add 172.16.1.2/28 dev "$WAN_IFACE" 2>/dev/null || true
ip link set "$WAN_IFACE" up 2>/dev/null || true
ip route replace default via 172.16.1.1 dev "$WAN_IFACE" 2>/dev/null || true

ok "WAN ($WAN_IFACE): 172.16.1.2/28, шлюз 172.16.1.1"
STATUS["ip_wan"]="OK"

# ─── 6. Trunk-интерфейс (без IP, только поднять) ──────────────────────────────
info "Настройка trunk-интерфейса $TRUNK_IFACE (без IP, носитель VLAN)..."

TRUNK_DIR="/etc/net/ifaces/${TRUNK_IFACE}"
mkdir -p "$TRUNK_DIR"
cat > "${TRUNK_DIR}/options" <<EOF
BOOTPROTO=static
ONBOOT=yes
TYPE=eth
DISABLED=no
NM_CONTROLLED=no
CONFIG_IPV4=no
EOF

ip link set "$TRUNK_IFACE" up 2>/dev/null || true
ok "Trunk $TRUNK_IFACE поднят (без IP)"

# ─── 7. VLAN 100 — SRV-Net (HQ-SRV) ──────────────────────────────────────────
info "[Задание 1] Создание VLAN 100 (SRV-Net): ${TRUNK_IFACE}.100 = 192.168.1.1/27"

VLAN100="${TRUNK_IFACE}.100"
VLAN100_DIR="/etc/net/ifaces/${VLAN100}"
mkdir -p "$VLAN100_DIR"
cat > "${VLAN100_DIR}/options" <<EOF
BOOTPROTO=static
ONBOOT=yes
TYPE=vlan
HOST=${TRUNK_IFACE}
VID=100
DISABLED=no
NM_CONTROLLED=no
CONFIG_IPV4=yes
EOF
echo "192.168.1.1/27" > "${VLAN100_DIR}/ipv4address"
echo "mtu 1400"       > "${VLAN100_DIR}/iplink"

# Пр��меняем немедленно
ip link delete "$VLAN100" 2>/dev/null || true
ip link add link "$TRUNK_IFACE" name "$VLAN100" type vlan id 100
ip link set "$VLAN100" mtu 1400
ip addr add 192.168.1.1/27 dev "$VLAN100"
ip link set "$VLAN100" up

ok "VLAN 100 (SRV-Net): ${VLAN100} = 192.168.1.1/27, MTU 1400"
STATUS["vlan100"]="OK"

# ─── 8. VLAN 200 — CLI-Net (HQ-CLI) ──────────────────────────────────────────
info "[Задание 1] Создание VLAN 200 (CLI-Net): ${TRUNK_IFACE}.200 = 192.168.2.1/27"

VLAN200="${TRUNK_IFACE}.200"
VLAN200_DIR="/etc/net/ifaces/${VLAN200}"
mkdir -p "$VLAN200_DIR"
cat > "${VLAN200_DIR}/options" <<EOF
BOOTPROTO=static
ONBOOT=yes
TYPE=vlan
HOST=${TRUNK_IFACE}
VID=200
DISABLED=no
NM_CONTROLLED=no
CONFIG_IPV4=yes
EOF
echo "192.168.2.1/27" > "${VLAN200_DIR}/ipv4address"
echo "mtu 1400"       > "${VLAN200_DIR}/iplink"

# Применяем немедленно
ip link delete "$VLAN200" 2>/dev/null || true
ip link add link "$TRUNK_IFACE" name "$VLAN200" type vlan id 200
ip link set "$VLAN200" mtu 1400
ip addr add 192.168.2.1/27 dev "$VLAN200"
ip link set "$VLAN200" up

ok "VLAN 200 (CLI-Net): ${VLAN200} = 192.168.2.1/27, MTU 1400"
STATUS["vlan200"]="OK"

# ─── 9. NAT через iptables (задание 8) ────────────────────────────────────────
info "[Задание 8] Настройка NAT (MASQUERADE) через iptables..."

if ! command -v iptables &>/dev/null; then
    apt-get install -y iptables || {
        error "Не удалось установить iptables"
        STATUS["nat"]="ERROR"
    }
fi

if command -v iptables &>/dev/null; then
    iptables -t nat -F POSTROUTING 2>/dev/null || true
    iptables -t nat -A POSTROUTING -o "$WAN_IFACE" -j MASQUERADE
    ok "NAT: MASQUERADE добавлен (out: $WAN_IFACE)"

    mkdir -p /etc/iptables
    iptables-save > /etc/iptables/rules.v4
    ok "Правила iptables сохранены: /etc/iptables/rules.v4"

    RC_LOCAL="/etc/rc.local"
    if [[ ! -f "$RC_LOCAL" ]] || ! grep -q "iptables-restore" "$RC_LOCAL"; then
        cat > "$RC_LOCAL" <<'EOF'
#!/bin/bash
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

# ─── 10. GRE-туннель (задание 6) ──────────────────────────────────────────────
info "[Задание 6] Создание GRE-туннеля gre1..."
info "  local=172.16.1.2, remote=$BR_WAN_IP, tunnel IP=10.0.0.1/30"

ip tunnel del gre1 2>/dev/null || true
ip tunnel add gre1 mode gre local "172.16.1.2" remote "$BR_WAN_IP" ttl 255
ip addr add 10.0.0.1/30 dev gre1
ip link set gre1 up

# Сохраняем в etcnet
GRE_DIR="/etc/net/ifaces/gre1"
mkdir -p "$GRE_DIR"
cat > "${GRE_DIR}/options" <<EOF
BOOTPROTO=static
ONBOOT=yes
TYPE=iptun
TUNTYPE=gre
TUNLOCAL=172.16.1.2
TUNREMOTE=${BR_WAN_IP}
DISABLED=no
NM_CONTROLLED=no
CONFIG_IPV4=yes
EOF
echo "10.0.0.1/30" > "${GRE_DIR}/ipv4address"

ok "GRE туннель gre1 создан: 10.0.0.1/30 → $BR_WAN_IP"
STATUS["gre_tunnel"]="OK"

# ─── 11. OSPF через FRR (задание 7) ───────────────────────────────────────────
info "[Задание 7] Настройка OSPF через FRR..."

if ! command -v vtysh &>/dev/null; then
    info "Установка FRR..."
    apt-get install -y frr 2>/dev/null || {
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
 network 192.168.1.0/27 area 0
 network 192.168.2.0/27 area 0
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

# ─── 12. DHCP для HQ-CLI (задание 9) — на VLAN 200 ───────────────────────────
info "[Задание 9] Настройка DHCP-сервера для HQ-CLI (VLAN 200: 192.168.2.0/27)..."

if ! command -v dhcpd &>/dev/null; then
    apt-get install -y dhcp-server 2>/dev/null || apt-get install -y isc-dhcp-server 2>/dev/null || {
        error "Не удалось установить DHCP-сервер"
        STATUS["dhcp"]="ERROR"
    }
fi

DHCPD_CONF="/etc/dhcp/dhcpd.conf"
[[ -f "$DHCPD_CONF" ]] && cp "$DHCPD_CONF" "${DHCPD_CONF}.bak"
mkdir -p /etc/dhcp

cat > "$DHCPD_CONF" <<EOF
# dhcpd.conf — HQ-RTR DHCP для HQ-CLI (VLAN 200)
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

# Привязываем DHCP к интерфейсу VLAN 200
DHCP_SYSCONF="/etc/sysconfig/dhcpd"
if [[ -f "$DHCP_SYSCONF" ]]; then
    cp "$DHCP_SYSCONF" "${DHCP_SYSCONF}.bak"
    echo "DHCPDARGS=\"${VLAN200}\"" > "$DHCP_SYSCONF"
    ok "DHCP привязан к интерфейсу $VLAN200"
fi

for svc in dhcpd isc-dhcp-server dhcp-server; do
    if systemctl enable --now "$svc" 2>/dev/null; then
        ok "DHCP-сервер ($svc) запущен для VLAN 200"
        STATUS["dhcp"]="OK"
        break
    fi
done
STATUS["dhcp"]="${STATUS[dhcp]:-ERROR}"

# ─── 13. Пользователь net_admin (задание 3) ───────────────────────────────────
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

# ─── 14. Убираем myhostname из nsswitch.conf ──────────────────────────────────
if [[ -f /etc/nsswitch.conf ]] && grep -q 'myhostname' /etc/nsswitch.conf; then
    sed -i 's/\bmyhostname\b//' /etc/nsswitch.conf
    sed -i 's/  */ /g' /etc/nsswitch.conf
    ok "nsswitch.conf: убран myhostname"
fi

# ─── Итоговый статус ──────────────────────────────────────────────────────────
echo
echo "============================================================"
echo "  Итог настройки HQ-RTR"
echo "============================================================"
for key in hostname timezone ip_forward vlan100 vlan200 nat gre_tunnel ospf dhcp net_admin; do
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
info "WAN:      $WAN_IFACE (172.16.1.2/28, шлюз 172.16.1.1)"
info "VLAN 100: ${TRUNK_IFACE}.100 = 192.168.1.1/27 (HQ-SRV)"
info "VLAN 200: ${TRUNK_IFACE}.200 = 192.168.2.1/27 (HQ-CLI, DHCP)"
info "GRE:      10.0.0.1/30 → $BR_WAN_IP"
info "OSPF:     FRR, router-id=10.0.0.1, сети 192.168.1.0/27 + 192.168.2.0/27 + 10.0.0.0/30"
echo
warn "Следующий шаг — настройка HQ-SRV:"
warn "  HQ-SRV должен быть на VLAN 100 (тег 100 в Proxmox/VMware)"
warn "  IP: 192.168.1.2/27, шлюз 192.168.1.1, DNS: 127.0.0.1"
echo
warn "Следующий шаг — настройка HQ-CLI:"
warn "  HQ-CLI должен быть на VLAN 200 (тег 200 в Proxmox/VMware)"
warn "  Сеть: DHCP, адрес будет из диапазона 192.168.2.2-192.168.2.30"

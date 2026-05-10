#!/bin/bash
# Скрипт настройки BR-RTR (Альт JeOS / Linux-версия, не EcoRouter)
# Покрывает: задания 1, 3, 6, 7, 8
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
echo "  Настройка BR-RTR — демоэкзамен 09.02.06 (2026)"
echo "  Задания: 1, 3, 6, 7, 8"
echo "============================================================"
echo

echo "--- Общие параметры ---"
read -rp "Имя WAN-интерфейса (в сторону ISP) [ens18]: " WAN_IFACE
WAN_IFACE="${WAN_IFACE:-ens18}"

read -rp "Имя LAN-интерфейса (в сторону BR-SRV) [ens19]: " LAN_IFACE
LAN_IFACE="${LAN_IFACE:-ens19}"

read -rp "Часовой пояс [Europe/Moscow]: " TZ_NAME
TZ_NAME="${TZ_NAME:-Europe/Moscow}"

read -rp "DNS-домен [au-team.irpo]: " DOMAIN
DOMAIN="${DOMAIN:-au-team.irpo}"

echo
echo "--- WAN ---"
read -rp "IP/маска WAN [172.16.2.2/28]: " WAN_IP_CIDR
WAN_IP_CIDR="${WAN_IP_CIDR:-172.16.2.2/28}"

read -rp "Шлюз WAN [172.16.2.1]: " WAN_GW
WAN_GW="${WAN_GW:-172.16.2.1}"

WAN_IP_DEFAULT="${WAN_IP_CIDR%/*}"
read -rp "IP WAN без маски (для GRE local) [${WAN_IP_DEFAULT}]: " WAN_IP
WAN_IP="${WAN_IP:-${WAN_IP_CIDR%/*}}"

read -rp "Внешний IP HQ-RTR (WAN, для GRE) [172.16.1.2]: " HQ_WAN_IP
HQ_WAN_IP="${HQ_WAN_IP:-172.16.1.2}"

read -rp "DNS форвардер #1 для WAN [77.88.8.7]: " DNS_FORWARDER1
DNS_FORWARDER1="${DNS_FORWARDER1:-77.88.8.7}"

read -rp "DNS форвардер #2 для WAN [77.88.8.3]: " DNS_FORWARDER2
DNS_FORWARDER2="${DNS_FORWARDER2:-77.88.8.3}"

echo
echo "--- LAN ---"
read -rp "IP/маска LAN [192.168.3.1/28]: " LAN_IP_CIDR
LAN_IP_CIDR="${LAN_IP_CIDR:-192.168.3.1/28}"

echo
echo "--- GRE / OSPF ---"
GRE_LOCAL_DEFAULT="${WAN_IP}"
read -rp "GRE local IP [${GRE_LOCAL_DEFAULT}]: " GRE_LOCAL_IP
GRE_LOCAL_IP="${GRE_LOCAL_IP:-$WAN_IP}"

read -rp "IP/маска GRE-туннеля [10.0.0.2/30]: " GRE_TUNNEL_CIDR
GRE_TUNNEL_CIDR="${GRE_TUNNEL_CIDR:-10.0.0.2/30}"

read -rp "Сеть GRE для OSPF [10.0.0.0/30]: " GRE_NET
GRE_NET="${GRE_NET:-10.0.0.0/30}"

read -rp "OSPF router-id [10.0.0.2]: " OSPF_ROUTER_ID
OSPF_ROUTER_ID="${OSPF_ROUTER_ID:-10.0.0.2}"

read -rsp "Пароль OSPF [P@ssw0rd]: " OSPF_PASS
echo
OSPF_PASS="${OSPF_PASS:-P@ssw0rd}"

HOSTNAME_FQDN="br-rtr.${DOMAIN}"

echo
info "Параметры конфигурации:"
echo "  Hostname:      ${HOSTNAME_FQDN}"
echo "  WAN интерфейс: ${WAN_IFACE} = ${WAN_IP_CIDR}, шлюз ${WAN_GW}, GRE local ${GRE_LOCAL_IP}"
echo "  WAN DNS:       ${DNS_FORWARDER1}, ${DNS_FORWARDER2}"
echo "  LAN интерфейс: ${LAN_IFACE} = ${LAN_IP_CIDR}"
echo "  GRE туннель:   remote=${HQ_WAN_IP}, tunnel=${GRE_TUNNEL_CIDR}, network=${GRE_NET}"
echo "  OSPF:          router-id=${OSPF_ROUTER_ID}, password=${OSPF_PASS}"
echo "  Часовой пояс:  ${TZ_NAME}"
echo "  DNS-домен:     ${DOMAIN}"
echo
read -rp "Продолжить? [y/N]: " CONFIRM
if [[ ! "${CONFIRM,,}" =~ ^y ]]; then
    info "Операция отменена."
    exit 0
fi

declare -A STATUS

# ─── 1. Hostname ────────────────────────────────────────────────────────────
info "Устанавливаю hostname: ${HOSTNAME_FQDN}"
hostnamectl set-hostname "$HOSTNAME_FQDN"
ok "Hostname: ${HOSTNAME_FQDN}"
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

# ─── 3. IP forwarding (ПЕРВЫМ, до NAT и GRE) ────────────────────────────────
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
info "[Задание 1] Настройка WAN ($WAN_IFACE): $WAN_IP_CIDR, шлюз $WAN_GW"

if command -v nmcli &>/dev/null; then
    nmcli con delete "wan-${WAN_IFACE}" &>/dev/null || true
    nmcli con add type ethernet ifname "$WAN_IFACE" con-name "wan-${WAN_IFACE}" \
        ipv4.method manual \
        ipv4.addresses "$WAN_IP_CIDR" \
        ipv4.gateway "$WAN_GW" \
        ipv4.dns "${DNS_FORWARDER1} ${DNS_FORWARDER2}" \
        connection.autoconnect yes
    nmcli con up "wan-${WAN_IFACE}"
else
    ip addr flush dev "$WAN_IFACE" 2>/dev/null || true
    ip addr add "$WAN_IP_CIDR" dev "$WAN_IFACE"
    ip link set "$WAN_IFACE" up
    ip route replace default via "$WAN_GW" dev "$WAN_IFACE"
fi
ok "WAN ($WAN_IFACE): $WAN_IP_CIDR, шлюз $WAN_GW"
STATUS["ip_wan"]="OK"

# ─── 5. IP-адресация LAN (задание 1) — прямо на интерфейсе ──────────────────
info "[Задание 1] Настройка LAN ($LAN_IFACE): $LAN_IP_CIDR"

if command -v nmcli &>/dev/null; then
    nmcli con delete "lan-${LAN_IFACE}" &>/dev/null || true
    nmcli con add type ethernet ifname "$LAN_IFACE" con-name "lan-${LAN_IFACE}" \
        ipv4.method manual \
        ipv4.addresses "$LAN_IP_CIDR" \
        connection.autoconnect yes
    nmcli con up "lan-${LAN_IFACE}"
else
    ip addr flush dev "$LAN_IFACE" 2>/dev/null || true
    ip addr add "$LAN_IP_CIDR" dev "$LAN_IFACE"
    ip link set "$LAN_IFACE" up
fi
ok "LAN ($LAN_IFACE): $LAN_IP_CIDR"
STATUS["ip_lan"]="OK"

# ─── 6. NAT через iptables (задание 8) ──────────────────────────────────────
info "[Задание 8] Настройка NAT (MASQUERADE) через iptables..."

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

    # Сохраняем правила
    if command -v iptables-save &>/dev/null; then
        mkdir -p /etc/iptables
        iptables-save > /etc/iptables/rules.v4
        ok "Правила iptables сохранены: /etc/iptables/rules.v4"
    fi

    # Автозагрузка через rc.local
    RC_LOCAL="/etc/rc.local"
    if [[ ! -f "$RC_LOCAL" ]] || ! grep -q "iptables-restore" "$RC_LOCAL"; then
        cat > "$RC_LOCAL" <<'EOF2'
#!/bin/bash
# Восстановление правил iptables при старте
if [[ -f /etc/iptables/rules.v4 ]]; then
    iptables-restore < /etc/iptables/rules.v4
fi
echo 1 > /proc/sys/net/ipv4/ip_forward
exit 0
EOF2
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
info "  local=${GRE_LOCAL_IP}, remote=${HQ_WAN_IP}, tunnel IP=${GRE_TUNNEL_CIDR}"

ip tunnel del gre1 2>/dev/null || true
if command -v nmcli &>/dev/null; then
    nmcli con delete gre1 2>/dev/null || true
    nmcli con add type ip-tunnel ifname gre1 con-name gre1 \
        tunnel.mode gre \
        tunnel.local "$GRE_LOCAL_IP" \
        tunnel.remote "$HQ_WAN_IP" \
        ipv4.method manual ipv4.addresses "$GRE_TUNNEL_CIDR" \
        connection.autoconnect yes
    nmcli con up gre1
else
    ip tunnel add gre1 mode gre local "$GRE_LOCAL_IP" remote "$HQ_WAN_IP" ttl 255
    ip addr add "$GRE_TUNNEL_CIDR" dev gre1
    ip link set gre1 up
fi
ok "GRE туннель gre1 создан: ${GRE_TUNNEL_CIDR}"
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

    cat > "$FRR_OSPF" <<EOF2
!
! FRR OSPF конфигурация BR-RTR — демоэкзамен 09.02.06 (2026)
!
frr version 8.1
frr defaults traditional
hostname ${HOSTNAME_FQDN}
!
router ospf
 ospf router-id ${OSPF_ROUTER_ID}
 network ${GRE_NET} area 0
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
EOF2
    systemctl enable --now frr 2>/dev/null || service frr restart 2>/dev/null || true
    ok "OSPF (FRR) настроен, router-id=${OSPF_ROUTER_ID}"
    STATUS["ospf"]="OK"
else
    warn "FRR не найден, пропускаю настройку OSPF"
    STATUS["ospf"]="SKIP"
fi

# ─── 9. Пользователь net_admin (задание 3) ───────────────────────────────────
info "[Задание 3] Создание пользователя net_admin..."
if ! id net_admin &>/dev/null; then
    useradd -m -s /bin/bash net_admin
    echo "net_admin:P@ssw0rd" | chpasswd
    echo "net_admin ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/net_admin
    chmod 440 /etc/sudoers.d/net_admin
    ok "Пользователь net_admin создан"
else
    warn "Пользователь net_admin уже существует, обновляю пароль..."
    echo "net_admin:P@ssw0rd" | chpasswd
    ok "Пароль net_admin обновлён"
fi
STATUS["net_admin"]="OK"

# ─── Итоговый статус ────────────────────────────────────────────────────────
echo
echo "============================================================"
echo "  Итог настройки BR-RTR"
echo "============================================================"
for key in hostname timezone ip_forward ip_wan ip_lan nat gre_tunnel ospf net_admin; do
    val="${STATUS[$key]:-SKIP}"
    case "$val" in
        OK)    echo -e "  ${GREEN}[OK]${NC}    $key" ;;
        ERROR) echo -e "  ${RED}[ERROR]${NC} $key" ;;
        *)     echo -e "  ${YELLOW}[SKIP]${NC}  $key" ;;
    esac
done
echo "============================================================"
echo
ok "Настройка BR-RTR завершена!"
info "Hostname: ${HOSTNAME_FQDN}"
info "WAN: ${WAN_IFACE} (${WAN_IP_CIDR}, шлюз ${WAN_GW}) | LAN: ${LAN_IFACE} (${LAN_IP_CIDR})"
info "NAT: iptables MASQUERADE через $WAN_IFACE"
info "GRE: ${GRE_TUNNEL_CIDR} → ${HQ_WAN_IP}"

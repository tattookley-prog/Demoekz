#!/bin/bash
# Скрипт настройки HQ-RTR (Альт Сервер, не EcoRouter)
# Покрывает: задания 1, 4, 6, 7, 8, 9
# Демоэкзамен 09.02.06 Сетевое и системное администрирование, 2026
#
# Топология по умолчанию:
#   ens18              → ISP         172.16.1.2/28, шлюз 172.16.1.1
#   ens19 (trunk)      → HQ-SW
#     └─ ens19.100     → HQ-SRV      192.168.1.1/27  (VLAN 100, SRV-Net)
#     └─ ens19.200     → HQ-CLI      192.168.2.1/27  (VLAN 200, CLI-Net)
#   gre1               → BR-RTR      10.0.0.1/30

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

echo "--- Общие параметры ---"
read -rp "Имя WAN-интерфейса (в сторону ISP) [ens18]: " WAN_IFACE
WAN_IFACE="${WAN_IFACE:-ens18}"

read -rp "Имя trunk-интерфейса (в сторону HQ-SW) [ens19]: " TRUNK_IFACE
TRUNK_IFACE="${TRUNK_IFACE:-ens19}"

read -rp "Часовой пояс [Europe/Moscow]: " TZ_NAME
TZ_NAME="${TZ_NAME:-Europe/Moscow}"

read -rp "DNS-домен [au-team.irpo]: " DOMAIN
DOMAIN="${DOMAIN:-au-team.irpo}"

echo
echo "--- WAN ---"
read -rp "IP/маска WAN [172.16.1.2/28]: " WAN_IP_CIDR
WAN_IP_CIDR="${WAN_IP_CIDR:-172.16.1.2/28}"

read -rp "Шлюз WAN [172.16.1.1]: " WAN_GW
WAN_GW="${WAN_GW:-172.16.1.1}"

WAN_IP_DEFAULT="${WAN_IP_CIDR%/*}"
read -rp "IP WAN без маски (для GRE local) [${WAN_IP_DEFAULT}]: " WAN_IP
WAN_IP="${WAN_IP:-${WAN_IP_CIDR%/*}}"

read -rp "Внешний IP BR-RTR (WAN, для GRE) [172.16.2.2]: " BR_WAN_IP
BR_WAN_IP="${BR_WAN_IP:-172.16.2.2}"

echo
echo "--- VLAN 100 (SRV-Net) ---"
read -rp "VLAN ID для SRV-Net [100]: " VLAN100_ID
VLAN100_ID="${VLAN100_ID:-100}"

read -rp "IP/маска VLAN ${VLAN100_ID} [192.168.1.1/27]: " VLAN100_IP_CIDR
VLAN100_IP_CIDR="${VLAN100_IP_CIDR:-192.168.1.1/27}"

read -rp "Сеть VLAN ${VLAN100_ID} для OSPF [192.168.1.0/27]: " VLAN100_NET
VLAN100_NET="${VLAN100_NET:-192.168.1.0/27}"

read -rp "MTU VLAN-интерфейсов [1400]: " MTU_VLAN
MTU_VLAN="${MTU_VLAN:-1400}"

echo
echo "--- VLAN 200 (CLI-Net) ---"
read -rp "VLAN ID для CLI-Net [200]: " VLAN200_ID
VLAN200_ID="${VLAN200_ID:-200}"

read -rp "IP/маска VLAN ${VLAN200_ID} [192.168.2.1/27]: " VLAN200_IP_CIDR
VLAN200_IP_CIDR="${VLAN200_IP_CIDR:-192.168.2.1/27}"

VLAN200_IP_DEFAULT="${VLAN200_IP_CIDR%/*}"
read -rp "IP VLAN ${VLAN200_ID} без маски (option routers) [${VLAN200_IP_DEFAULT}]: " VLAN200_IP
VLAN200_IP="${VLAN200_IP:-${VLAN200_IP_CIDR%/*}}"

read -rp "Сеть VLAN ${VLAN200_ID} для OSPF [192.168.2.0/27]: " VLAN200_NET
VLAN200_NET="${VLAN200_NET:-192.168.2.0/27}"

echo
echo "--- GRE / OSPF ---"
GRE_LOCAL_DEFAULT="${WAN_IP}"
read -rp "GRE local IP [${GRE_LOCAL_DEFAULT}]: " GRE_LOCAL_IP
GRE_LOCAL_IP="${GRE_LOCAL_IP:-$WAN_IP}"

read -rp "IP/маска GRE-туннеля [10.0.0.1/30]: " GRE_TUNNEL_CIDR
GRE_TUNNEL_CIDR="${GRE_TUNNEL_CIDR:-10.0.0.1/30}"

read -rp "Сеть GRE для OSPF [10.0.0.0/30]: " GRE_NET
GRE_NET="${GRE_NET:-10.0.0.0/30}"

read -rp "OSPF router-id [10.0.0.1]: " OSPF_ROUTER_ID
OSPF_ROUTER_ID="${OSPF_ROUTER_ID:-10.0.0.1}"

read -rsp "Пароль OSPF [P@ssw0rd]: " OSPF_PASS
echo
OSPF_PASS="${OSPF_PASS:-P@ssw0rd}"

echo
echo "--- DHCP ---"
read -rp "IP-адрес HQ-SRV (DNS-сервер для DHCP) [192.168.1.2]: " HQ_SRV_IP
HQ_SRV_IP="${HQ_SRV_IP:-192.168.1.2}"

read -rp "Подсеть DHCP [192.168.2.0]: " DHCP_SUBNET
DHCP_SUBNET="${DHCP_SUBNET:-192.168.2.0}"

read -rp "Маска DHCP (десятичная) [255.255.255.224]: " DHCP_NETMASK
DHCP_NETMASK="${DHCP_NETMASK:-255.255.255.224}"

read -rp "Начало DHCP-пула [192.168.2.2]: " DHCP_RANGE_START
DHCP_RANGE_START="${DHCP_RANGE_START:-192.168.2.2}"

read -rp "Конец DHCP-пула [192.168.2.30]: " DHCP_RANGE_END
DHCP_RANGE_END="${DHCP_RANGE_END:-192.168.2.30}"

echo
info "Параметры конфигурации:"
VLAN100="${TRUNK_IFACE}.${VLAN100_ID}"
VLAN200="${TRUNK_IFACE}.${VLAN200_ID}"
HOSTNAME_FQDN="hq-rtr.${DOMAIN}"
echo "  Hostname:      ${HOSTNAME_FQDN}"
echo "  WAN:           ${WAN_IFACE} = ${WAN_IP_CIDR}, шлюз ${WAN_GW}, GRE local ${GRE_LOCAL_IP}"
echo "  Trunk:         ${TRUNK_IFACE}"
echo "  VLAN ${VLAN100_ID}:      ${VLAN100} = ${VLAN100_IP_CIDR}, OSPF ${VLAN100_NET}, MTU ${MTU_VLAN}"
echo "  VLAN ${VLAN200_ID}:      ${VLAN200} = ${VLAN200_IP_CIDR}, router ${VLAN200_IP}, OSPF ${VLAN200_NET}, MTU ${MTU_VLAN}"
echo "  GRE:           remote=${BR_WAN_IP}, tunnel=${GRE_TUNNEL_CIDR}, network=${GRE_NET}"
echo "  OSPF:          router-id=${OSPF_ROUTER_ID}, password=${OSPF_PASS}"
echo "  DHCP:          subnet=${DHCP_SUBNET}, mask=${DHCP_NETMASK}, range=${DHCP_RANGE_START}-${DHCP_RANGE_END}"
echo "  DHCP DNS:      ${HQ_SRV_IP}"
echo "  Часовой пояс:  ${TZ_NAME}"
echo "  DNS-домен:     ${DOMAIN}"
echo
read -rp "Продолжить? [y/N]: " CONFIRM
if [[ ! "${CONFIRM,,}" =~ ^y ]]; then
    info "Операция отменена."
    exit 0
fi

declare -A STATUS

# ─── 1. Hostname ──────────────────────────────────────────────────────────────
info "Устанавливаю hostname: ${HOSTNAME_FQDN}"
hostnamectl set-hostname "$HOSTNAME_FQDN"
ok "Hostname: ${HOSTNAME_FQDN}"
STATUS["hostname"]="OK"

# ─── 2. Часовой пояс ──────────────────────────────────────────────────────────
info "Часовой пояс: $TZ_NAME"
if timedatectl set-timezone "$TZ_NAME" 2>/dev/null; then
    ok "Часовой пояс установлен: $TZ_NAME"
    STATUS["timezone"]="OK"
elif [[ -f "/usr/share/zoneinfo/${TZ_NAME}" ]]; then
    rm -f /etc/localtime
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
mkdir -p /etc/net
if grep -q '^\s*net\.ipv4\.ip_forward' /etc/net/sysctl.conf 2>/dev/null; then
    sed -i 's/^#*\s*net\.ipv4\.ip_forward.*/net.ipv4.ip_forward = 1/' /etc/net/sysctl.conf
else
    echo 'net.ipv4.ip_forward = 1' >> /etc/net/sysctl.conf
fi
ok "IP forwarding включён (постоянно через /etc/sysctl.conf, /etc/sysctl.d/99-ipforward.conf и /etc/net/sysctl.conf)"
STATUS["ip_forward"]="OK"

# ─── 4. Загрузка модуля 8021q ─────────────────────────────────────────────────
info "Загрузка модуля 8021q для VLAN..."
modprobe 8021q 2>/dev/null || true
echo '8021q' > /etc/modules-load.d/8021q.conf 2>/dev/null || true
ok "Модуль 8021q загружен"

# ─── 5. WAN-интерфейс (задание 1) — через etcnet ──────────────────────────────
info "[Задание 1] Настройка WAN ($WAN_IFACE): $WAN_IP_CIDR, шлюз $WAN_GW"

WAN_DIR="/etc/net/ifaces/${WAN_IFACE}"
mkdir -p "$WAN_DIR"
cat > "${WAN_DIR}/options" <<EOF2
BOOTPROTO=static
ONBOOT=yes
TYPE=eth
DISABLED=no
NM_CONTROLLED=no
CONFIG_IPV4=yes
EOF2
echo "$WAN_IP_CIDR" > "${WAN_DIR}/ipv4address"
echo "default via $WAN_GW" > "${WAN_DIR}/ipv4route"

# Применяем немедленно
ip addr flush dev "$WAN_IFACE" 2>/dev/null || true
ip addr add "$WAN_IP_CIDR" dev "$WAN_IFACE" 2>/dev/null || true
ip link set "$WAN_IFACE" up 2>/dev/null || true
ip route replace default via "$WAN_GW" dev "$WAN_IFACE" 2>/dev/null || true

ok "WAN ($WAN_IFACE): $WAN_IP_CIDR, шлюз $WAN_GW"
STATUS["ip_wan"]="OK"

# ─── 6. Trunk-интерфейс (без IP, только поднять) ──────────────────────────────
info "Настройка trunk-интерфейса $TRUNK_IFACE (без IP, носитель VLAN)..."

TRUNK_DIR="/etc/net/ifaces/${TRUNK_IFACE}"
mkdir -p "$TRUNK_DIR"
cat > "${TRUNK_DIR}/options" <<EOF2
BOOTPROTO=static
ONBOOT=yes
TYPE=eth
DISABLED=no
NM_CONTROLLED=no
CONFIG_IPV4=no
EOF2

ip link set "$TRUNK_IFACE" up 2>/dev/null || true
ok "Trunk $TRUNK_IFACE поднят (без IP)"

# ─── 7. VLAN 100 — SRV-Net (HQ-SRV) ──────────────────────────────────────────
info "[Задание 1] Создание VLAN ${VLAN100_ID} (SRV-Net): ${VLAN100} = ${VLAN100_IP_CIDR}"

VLAN100_DIR="/etc/net/ifaces/${VLAN100}"
mkdir -p "$VLAN100_DIR"
cat > "${VLAN100_DIR}/options" <<EOF2
BOOTPROTO=static
ONBOOT=yes
TYPE=vlan
HOST=${TRUNK_IFACE}
VID=${VLAN100_ID}
DISABLED=no
NM_CONTROLLED=no
CONFIG_IPV4=yes
EOF2
echo "$VLAN100_IP_CIDR" > "${VLAN100_DIR}/ipv4address"
echo "mtu ${MTU_VLAN}" > "${VLAN100_DIR}/iplink"

# Применяем немедленно
ip link delete "$VLAN100" 2>/dev/null || true
ip link add link "$TRUNK_IFACE" name "$VLAN100" type vlan id "$VLAN100_ID"
ip link set "$VLAN100" mtu "$MTU_VLAN"
ip addr add "$VLAN100_IP_CIDR" dev "$VLAN100"
ip link set "$VLAN100" up

ok "VLAN ${VLAN100_ID} (SRV-Net): ${VLAN100} = ${VLAN100_IP_CIDR}, MTU ${MTU_VLAN}"
STATUS["vlan100"]="OK"

# ─── 8. VLAN 200 — CLI-Net (HQ-CLI) ──────────────────────────────────────────
info "[Задание 1] Создание VLAN ${VLAN200_ID} (CLI-Net): ${VLAN200} = ${VLAN200_IP_CIDR}"

VLAN200_DIR="/etc/net/ifaces/${VLAN200}"
mkdir -p "$VLAN200_DIR"
cat > "${VLAN200_DIR}/options" <<EOF2
BOOTPROTO=static
ONBOOT=yes
TYPE=vlan
HOST=${TRUNK_IFACE}
VID=${VLAN200_ID}
DISABLED=no
NM_CONTROLLED=no
CONFIG_IPV4=yes
EOF2
echo "$VLAN200_IP_CIDR" > "${VLAN200_DIR}/ipv4address"
echo "mtu ${MTU_VLAN}" > "${VLAN200_DIR}/iplink"

# Применяем немедленно
ip link delete "$VLAN200" 2>/dev/null || true
ip link add link "$TRUNK_IFACE" name "$VLAN200" type vlan id "$VLAN200_ID"
ip link set "$VLAN200" mtu "$MTU_VLAN"
ip addr add "$VLAN200_IP_CIDR" dev "$VLAN200"
ip link set "$VLAN200" up

ok "VLAN ${VLAN200_ID} (CLI-Net): ${VLAN200} = ${VLAN200_IP_CIDR}, MTU ${MTU_VLAN}"
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

    # Разрешаем форвардинг из локальных VLAN наружу и обратный трафик established/related
    iptables -F FORWARD 2>/dev/null || true
    iptables -P FORWARD ACCEPT

    iptables -A FORWARD -i "$VLAN100" -o "$WAN_IFACE" -j ACCEPT
    iptables -A FORWARD -i "$VLAN200" -o "$WAN_IFACE" -j ACCEPT
    iptables -A FORWARD -i "$WAN_IFACE" -o "$VLAN100" -m state --state RELATED,ESTABLISHED -j ACCEPT
    iptables -A FORWARD -i "$WAN_IFACE" -o "$VLAN200" -m state --state RELATED,ESTABLISHED -j ACCEPT

    # Форвардинг через GRE (для задания 7 — связность офисов)
    iptables -A FORWARD -i gre1 -j ACCEPT
    iptables -A FORWARD -o gre1 -j ACCEPT

    ok "FORWARD-правила добавлены (${VLAN100}/${VLAN200} ↔ $WAN_IFACE, gre1)"
    STATUS["forward"]="OK"

    # TCP MSS clamping — предотвращает зависание больших TCP-сессий при MTU VLAN
    iptables -t mangle -A FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu
    ok "MSS clamping добавлен (clamp-mss-to-pmtu)"
    STATUS["mss_clamp"]="OK"

    mkdir -p /etc/iptables
    iptables-save > /etc/iptables/rules.v4
    ok "Правила iptables сохранены: /etc/iptables/rules.v4"

    # Автозагрузка правил через systemd-unit (rc.local ненадёжен на systemd-Альте)
    cat > /etc/systemd/system/iptables-restore.service <<'EOF2'
[Unit]
Description=Restore iptables rules
Before=network.target
DefaultDependencies=no

[Service]
Type=oneshot
ExecStart=/sbin/iptables-restore /etc/iptables/rules.v4
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF2
    systemctl daemon-reload
    systemctl enable iptables-restore.service
    ok "Автозагрузка iptables настроена ��ерез systemd (iptables-restore.service)"

    STATUS["nat"]="OK"
else
    warn "iptables не найден, пропускаю NAT"
    STATUS["nat"]="SKIP"
fi

# ─── 10. GRE-туннель (задание 6) ──────────────────────────────────────────────
info "[Задание 6] Чистое воссоздание GRE-туннеля gre1..."
info "  local=${GRE_LOCAL_IP}, remote=${BR_WAN_IP}, tunnel IP=${GRE_TUNNEL_CIDR}"

# Сохраняем в etcnet
GRE_DIR="/etc/net/ifaces/gre1"
mkdir -p "$GRE_DIR"
cat > "${GRE_DIR}/options" <<EOF2
BOOTPROTO=static
ONBOOT=yes
TYPE=iptun
TUNTYPE=gre
TUNLOCAL=${GRE_LOCAL_IP}
TUNREMOTE=${BR_WAN_IP}
DISABLED=no
NM_CONTROLLED=no
CONFIG_IPV4=yes
EOF2
echo "$GRE_TUNNEL_CIDR" > "${GRE_DIR}/ipv4address"
# Закрепляем multicast и MTU через etcnet (iplink) — применяются при КАЖДОМ подъёме
# интерфейса, в т. ч. при systemctl restart network. Без multicast OSPF (224.0.0.5)
# не находит соседей; mtu 1400 + ip ospf mtu-ignore спасают от застревания в ExStart.
echo "mtu 1400 multicast on" > "${GRE_DIR}/iplink"

# Применяем немедленно с чистым воссозданием
ip tunnel del gre1 2>/dev/null || true
ip link del gre1 2>/dev/null || true
ip tunnel add gre1 mode gre local "$GRE_LOCAL_IP" remote "$BR_WAN_IP" ttl 255
ip addr add "$GRE_TUNNEL_CIDR" dev gre1
ip link set gre1 mtu 1400
ip link set gre1 up
ip link set gre1 multicast on

ok "GRE туннель gre1 чисто воссоздан: ${GRE_TUNNEL_CIDR} → ${BR_WAN_IP}"
STATUS["gre_tunnel"]="OK"

# ─── 10.1 Автовключение multicast на gre1 для OSPF ───────────────────────────
info "Настройка systemd-сервиса gre-multicast.service (persist multicast on gre1)..."
cat > /etc/systemd/system/gre-multicast.service <<'EOF2'
[Unit]
Description=Enable multicast on gre1 for OSPF
# PartOf + After network.service: сервис срабатывает и при systemctl restart network,
# а не только при загрузке — иначе после рестарта сети gre1 остаётся без multicast.
PartOf=network.service
Wants=network.target
After=network.target network.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/sh -c 'for i in $(seq 1 30); do ip link show gre1 >/dev/null 2>&1 && break; sleep 1; done; ip link set gre1 mtu 1400; ip link set gre1 multicast on'

[Install]
WantedBy=multi-user.target network.service
EOF2
systemctl daemon-reload 2>/dev/null || true
systemctl enable gre-multicast.service 2>/dev/null || true
ip link set gre1 multicast on 2>/dev/null || true
ok "gre-multicast.service установлен, multicast на gre1 включён"
STATUS["gre_multicast"]="OK"

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

    cat > "$FRR_OSPF" <<EOF2
!
! FRR OSPF конфигурация HQ-RTR — демоэкзамен 09.02.06 (2026)
!
frr version 8.1
frr defaults traditional
hostname ${HOSTNAME_FQDN}
!
router ospf
 ospf router-id ${OSPF_ROUTER_ID}
 network ${GRE_NET} area 0
 network ${VLAN100_NET} area 0
 network ${VLAN200_NET} area 0
 area 0 authentication message-digest
 passive-interface default
 no passive-interface gre1
!
interface gre1
 ip ospf authentication message-digest
 ip ospf message-digest-key 1 md5 ${OSPF_PASS}
 ip ospf mtu-ignore
 ip ospf hello-interval 1
 ip ospf dead-interval 4
 ip ospf retransmit-interval 3
!
line vty
!
EOF2
    # Drop-in: FRR ждёт появления gre1 и перезапускается после подъёма сети,
    # иначе OSPF стартует раньше, чем etcnet создал туннель → нет соседства.
    # Таймеры hello/dead на gre1 снижены до 1/4 с для быстрого восстановления
    # соседства после systemctl restart network (вместо стандартных ~40 с).
    mkdir -p /etc/systemd/system/frr.service.d
    cat > /etc/systemd/system/frr.service.d/after-network.conf <<'EOF2'
[Unit]
After=network.target network.service gre-multicast.service
Wants=gre-multicast.service

[Service]
ExecStartPre=/bin/sh -c 'for i in $(seq 1 30); do ip link show gre1 >/dev/null 2>&1 && break; sleep 1; done'
EOF2
    systemctl daemon-reload 2>/dev/null || true
    systemctl enable --now frr 2>/dev/null || service frr restart 2>/dev/null || true
    ok "OSPF (FRR) настроен, router-id=${OSPF_ROUTER_ID}"
    STATUS["ospf"]="OK"
else
    warn "FRR не найден, пропускаю настройку OSPF"
    STATUS["ospf"]="SKIP"
fi

# ─── 12. DHCP для HQ-CLI (задание 9) — на VLAN 200 ───────────────────────────
info "[Задание 9] Настройка DHCP-сервера для HQ-CLI (${VLAN200}: ${DHCP_SUBNET}/${DHCP_NETMASK})..."

if ! command -v dhcpd &>/dev/null; then
    apt-get install -y dhcp-server 2>/dev/null || apt-get install -y isc-dhcp-server 2>/dev/null || {
        error "Не удалось установить DHCP-сервер"
        STATUS["dhcp"]="ERROR"
    }
fi

DHCPD_CONF="/etc/dhcp/dhcpd.conf"
[[ -f "$DHCPD_CONF" ]] && cp "$DHCPD_CONF" "${DHCPD_CONF}.bak"
mkdir -p /etc/dhcp

cat > "$DHCPD_CONF" <<EOF2
# dhcpd.conf — HQ-RTR DHCP для HQ-CLI (VLAN ${VLAN200_ID})
# Демоэкзамен 09.02.06 (2026)

option domain-name "${DOMAIN}";
option domain-name-servers ${HQ_SRV_IP};

default-lease-time 600;
max-lease-time 7200;

authoritative;

subnet ${DHCP_SUBNET} netmask ${DHCP_NETMASK} {
    range ${DHCP_RANGE_START} ${DHCP_RANGE_END};
    option routers ${VLAN200_IP};
    option subnet-mask ${DHCP_NETMASK};
    option domain-name-servers ${HQ_SRV_IP};
    option domain-name "${DOMAIN}";
}
EOF2

# Привязываем DHCP к интерфейсу VLAN 200
DHCP_SYSCONF="/etc/sysconfig/dhcpd"
if [[ -f "$DHCP_SYSCONF" ]]; then
    cp "$DHCP_SYSCONF" "${DHCP_SYSCONF}.bak"
    echo "DHCPDARGS=\"${VLAN200}\"" > "$DHCP_SYSCONF"
    ok "DHCP привязан к интерфейсу $VLAN200"
fi

for svc in dhcpd isc-dhcp-server dhcp-server; do
    if systemctl enable --now "$svc" 2>/dev/null; then
        ok "DHCP-сервер ($svc) запущен для VLAN ${VLAN200_ID}"
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
for key in hostname timezone ip_forward vlan100 vlan200 nat forward mss_clamp gre_tunnel gre_multicast ospf dhcp net_admin; do
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
info "Hostname: ${HOSTNAME_FQDN}"
info "WAN:      ${WAN_IFACE} (${WAN_IP_CIDR}, шлюз ${WAN_GW})"
info "VLAN ${VLAN100_ID}: ${VLAN100} = ${VLAN100_IP_CIDR}"
info "VLAN ${VLAN200_ID}: ${VLAN200} = ${VLAN200_IP_CIDR}, DHCP ${DHCP_RANGE_START}-${DHCP_RANGE_END}"
info "GRE:      ${GRE_TUNNEL_CIDR} → ${BR_WAN_IP}"
info "OSPF:     FRR, router-id=${OSPF_ROUTER_ID}, сети ${VLAN100_NET} + ${VLAN200_NET} + ${GRE_NET}"
echo
warn "Следующий шаг — настройка HQ-SRV:"
warn "  HQ-SRV должен быть на VLAN ${VLAN100_ID} (тег ${VLAN100_ID} в Proxmox/VMware)"
warn "  IP: ${HQ_SRV_IP}, шлюз ${VLAN100_IP_CIDR%/*}, DNS: 127.0.0.1"
echo
warn "Следующий шаг — настройка HQ-CLI:"
warn "  HQ-CLI должен быть на VLAN ${VLAN200_ID} (тег ${VLAN200_ID} в Proxmox/VMware)"
warn "  Сеть: DHCP, адрес будет из диапазона ${DHCP_RANGE_START}-${DHCP_RANGE_END}"

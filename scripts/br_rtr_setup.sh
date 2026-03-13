#!/bin/bash
# Скрипт настройки BR-RTR (Альт JeOS / Linux-версия, не EcoRouter)
# Покрывает: задания 1, 3, 6, 7, 8
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
echo "  Настройка BR-RTR — демоэкзамен 09.02.06 (2026)"
echo "  Задания: 1, 3, 6, 7, 8"
echo "============================================================"
echo

# ─── Интерактивный ввод параметров ───────────────────────────────────────────
read -rp "Имя WAN-интерфейса (в сторону ISP) [eth0]: " WAN_IFACE
WAN_IFACE="${WAN_IFACE:-eth0}"

read -rp "Имя LAN-интерфейса (в сторону BR-SRV) [eth1]: " LAN_IFACE
LAN_IFACE="${LAN_IFACE:-eth1}"

read -rp "Часовой пояс [Europe/Moscow]: " TZ_NAME
TZ_NAME="${TZ_NAME:-Europe/Moscow}"

read -rp "Внешний IP HQ-RTR (WAN, для GRE-туннеля) [172.16.1.2]: " HQ_WAN_IP
HQ_WAN_IP="${HQ_WAN_IP:-172.16.1.2}"

read -rsp "Пароль OSPF [P@ssw0rd]: " OSPF_PASS
echo
OSPF_PASS="${OSPF_PASS:-P@ssw0rd}"

echo
info "Параметры конфигурации:"
echo "  WAN интерфейс:    $WAN_IFACE (172.16.2.2/28, шлюз 172.16.2.1)"
echo "  LAN интерфейс:    $LAN_IFACE (192.168.3.1/28)"
echo "  GRE туннель:      local=172.16.2.2, remote=$HQ_WAN_IP, tunnel=10.0.0.2/30"
echo "  Часовой пояс:     $TZ_NAME"
echo
read -rp "Продолжить? [y/N]: " CONFIRM
if [[ ! "${CONFIRM,,}" =~ ^y ]]; then
    info "Операция отменена."
    exit 0
fi

declare -A STATUS

# ─── 1. Hostname ──────────────────────────────────────────────────────────────
info "Устанавливаю hostname: br-rtr.au-team.irpo"
hostnamectl set-hostname br-rtr.au-team.irpo
ok "Hostname: br-rtr.au-team.irpo"
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

# ─── 3. IP-адресация (задание 1) ─────────────────────────────────────────────
info "[Задание 1] Настройка IP на WAN ($WAN_IFACE): 172.16.2.2/28, шлюз 172.16.2.1"
nmcli con delete "wan-${WAN_IFACE}" &>/dev/null || true
nmcli con add type ethernet ifname "$WAN_IFACE" con-name "wan-${WAN_IFACE}" \
    ipv4.method manual \
    ipv4.addresses "172.16.2.2/28" \
    ipv4.gateway "172.16.2.1" \
    ipv4.dns "77.88.8.7 77.88.8.3" \
    connection.autoconnect yes
nmcli con up "wan-${WAN_IFACE}"
ok "WAN ($WAN_IFACE): 172.16.2.2/28, шлюз 172.16.2.1"
STATUS["ip_wan"]="OK"

info "[Задание 1] Настройка IP на LAN ($LAN_IFACE): 192.168.3.1/28"
nmcli con delete "lan-${LAN_IFACE}" &>/dev/null || true
nmcli con add type ethernet ifname "$LAN_IFACE" con-name "lan-${LAN_IFACE}" \
    ipv4.method manual \
    ipv4.addresses "192.168.3.1/28" \
    connection.autoconnect yes
nmcli con up "lan-${LAN_IFACE}"
ok "LAN ($LAN_IFACE): 192.168.3.1/28"
STATUS["ip_lan"]="OK"

# ─── 4. IP forwarding ─────────────────────────────────────────────────────────
info "Включение IP forwarding..."
if grep -q '^net.ipv4.ip_forward' /etc/sysctl.conf; then
    sed -i 's/^#*\s*net\.ipv4\.ip_forward.*/net.ipv4.ip_forward=1/' /etc/sysctl.conf
else
    echo 'net.ipv4.ip_forward=1' >> /etc/sysctl.conf
fi
sysctl -w net.ipv4.ip_forward=1 >/dev/null
ok "IP forwarding включён"
STATUS["ip_forward"]="OK"

# ─── 5. GRE-туннель (задание 6) ──────────────────────────────────────────────
info "[Задание 6] Создание GRE-туннеля gre1..."
info "  local=172.16.2.2, remote=$HQ_WAN_IP, tunnel IP=10.0.0.2/30"

ip tunnel del gre1 2>/dev/null || true
nmcli con delete gre1 2>/dev/null || true

nmcli con add type ip-tunnel ifname gre1 con-name gre1 \
    tunnel.mode gre \
    tunnel.local "172.16.2.2" \
    tunnel.remote "$HQ_WAN_IP" \
    ipv4.method manual ipv4.addresses "10.0.0.2/30" \
    connection.autoconnect yes
nmcli con up gre1
ok "GRE туннель gre1 создан: 10.0.0.2/30"
STATUS["gre_tunnel"]="OK"

# ─── 6. OSPF через FRR (задание 7) ───────────────────────────────────────────
info "[Задание 7] Настройка OSPF через FRR..."

if ! command -v ospfd &>/dev/null && ! command -v vtysh &>/dev/null; then
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
! FRR OSPF конфигурация BR-RTR — демоэкзамен 09.02.06 (2026)
!
frr version 8.1
frr defaults traditional
hostname br-rtr.au-team.irpo
!
router ospf
 ospf router-id 10.0.0.2
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
    ok "OSPF (FRR) настроен, router-id=10.0.0.2"
    STATUS["ospf"]="OK"
else
    warn "FRR не найден, пропускаю настройку OSPF"
    STATUS["ospf"]="SKIP"
fi

# ─── 7. NAT через nftables (задание 8) ───────────────────────────────────────
info "[Задание 8] Настройка NAT (masquerade) для LAN → WAN..."

if ! command -v nft &>/dev/null; then
    info "Установка nftables..."
    apt-get install -y nftables
fi

NFT_CONF="/etc/nftables.conf"
[[ -f "$NFT_CONF" ]] && cp "$NFT_CONF" "${NFT_CONF}.bak"

cat > "$NFT_CONF" <<EOF
#!/usr/sbin/nft -f
# nftables конфигурация BR-RTR — демоэкзамен 09.02.06 (2026)

flush ruleset

table ip nat {
    chain postrouting {
        type nat hook postrouting priority 100; policy accept;
        # Masquerade LAN (BR-SRV сеть) → Интернет через WAN
        iifname "${LAN_IFACE}" oifname "${WAN_IFACE}" masquerade
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
ok "NAT (nftables) настроен: $LAN_IFACE → $WAN_IFACE"
STATUS["nat"]="OK"

# ─── 8. Пользователь net_admin (задание 3) ────────────────────────────────────
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

# ─── Итоговый статус ──────────────────────────────────────────────────────────
echo
echo "============================================================"
echo "  Итог настройки BR-RTR"
echo "============================================================"
for key in hostname timezone ip_wan ip_lan ip_forward gre_tunnel ospf nat net_admin; do
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

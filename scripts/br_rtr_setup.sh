#!/bin/bash
# Скрипт настройки BR-RTR (Альт Сервер — etcnet)
# Покрывает: задания 1, 3, 6, 7, 8
# Демоэкзамен 09.02.06 Сетевое и системное администрирование, 2026
#
# Вся сеть через etcnet (/etc/net/ifaces/) — как на HQ-RTR
# Перезапуск: systemctl restart network

set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'
NC='\033[0m'

info()  { echo -e "${CYAN}[INFO]${NC}  $*"; }
ok()    { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }

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

echo
echo "--- LAN ---"
read -rp "IP/маска LAN [192.168.3.1/28]: " LAN_IP_CIDR
LAN_IP_CIDR="${LAN_IP_CIDR:-192.168.3.1/28}"

read -rp "Сеть LAN (BR-SRV) для OSPF [192.168.3.0/28]: " LAN_NET
LAN_NET="${LAN_NET:-192.168.3.0/28}"

echo
echo "--- GRE / OSPF ---"
read -rp "GRE local IP [${WAN_IP}]: " GRE_LOCAL_IP
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
echo "  WAN:           ${WAN_IFACE} = ${WAN_IP_CIDR}, шлюз ${WAN_GW}"
echo "  LAN:           ${LAN_IFACE} = ${LAN_IP_CIDR}, OSPF ${LAN_NET}"
echo "  GRE:           local=${GRE_LOCAL_IP}, remote=${HQ_WAN_IP}, tunnel=${GRE_TUNNEL_CIDR}"
echo "  OSPF:          router-id=${OSPF_ROUTER_ID}, network ${GRE_NET} + ${LAN_NET}, password=${OSPF_PASS}"
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
echo "$HOSTNAME_FQDN" > /etc/hostname
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
if grep -q '^#*\s*net\.ipv4\.ip_forward' /etc/sysctl.conf 2>/dev/null; then
    sed -i 's/^#*\s*net\.ipv4\.ip_forward.*/net.ipv4.ip_forward=1/' /etc/sysctl.conf
else
    echo 'net.ipv4.ip_forward=1' >> /etc/sysctl.conf
fi
echo 'net.ipv4.ip_forward=1' > /etc/sysctl.d/99-ipforward.conf
sysctl -w net.ipv4.ip_forward=1 >/dev/null
# etcnet применяет /etc/net/sysctl.conf при подъёме сети — пишем сюда,
# чтобы форвардинг переживал systemctl restart network и ребут на Альт Сервере
mkdir -p /etc/net
if grep -q '^[[:space:]]*#*[[:space:]]*net\.ipv4\.ip_forward' /etc/net/sysctl.conf 2>/dev/null; then
    sed -i 's/^[[:space:]]*#*[[:space:]]*net\.ipv4\.ip_forward.*/net.ipv4.ip_forward = 1/' /etc/net/sysctl.conf
else
    echo 'net.ipv4.ip_forward = 1' >> /etc/net/sysctl.conf
fi
ok "IP forwarding включён (постоянно, в т. ч. /etc/net/sysctl.conf)"
STATUS["ip_forward"]="OK"

# ─── Вспомогательная функция: etcnet static ───────────────────────────────────
etcnet_static() {
    local iface="$1" ip="$2"
    local dir="/etc/net/ifaces/${iface}"
    mkdir -p "$dir"
    [[ -f "${dir}/options" ]] && cp "${dir}/options" "${dir}/options.bak"
    cat > "${dir}/options" <<EOF2
BOOTPROTO=static
ONBOOT=yes
TYPE=eth
DISABLED=no
NM_CONTROLLED=no
CONFIG_IPV4=yes
EOF2
    echo "$ip" > "${dir}/ipv4address"
}

# ─── Вспомогательная функция: включение демонов FRR ───────────────────────────
enable_frr_daemon() {
    local daemon="$1" file="$2"
    if grep -Eq "^[[:space:]]*#?[[:space:]]*${daemon}=" "$file" 2>/dev/null; then
        sed -i -E "s|^[[:space:]]*#?[[:space:]]*${daemon}=.*|${daemon}=yes|" "$file"
    else
        echo "${daemon}=yes" >> "$file"
    fi
}

set_frr_daemon_state() {
    local daemon="$1" state="$2" file="$3"
    if grep -Eq "^[[:space:]]*#?[[:space:]]*${daemon}=" "$file" 2>/dev/null; then
        sed -i -E "s|^[[:space:]]*#?[[:space:]]*${daemon}=.*|${daemon}=${state}|" "$file"
    else
        echo "${daemon}=${state}" >> "$file"
    fi
}

# ─── 4. WAN через etcnet (задание 1) ──────────────────────────────────────────
info "[Задание 1] Настройка WAN ($WAN_IFACE): $WAN_IP_CIDR, шлюз $WAN_GW"
etcnet_static "$WAN_IFACE" "$WAN_IP_CIDR"
echo "default via $WAN_GW" > "/etc/net/ifaces/${WAN_IFACE}/ipv4route"

# Применяем немедленно
ip addr flush dev "$WAN_IFACE" 2>/dev/null || true
ip addr add "$WAN_IP_CIDR" dev "$WAN_IFACE" 2>/dev/null || true
ip link set "$WAN_IFACE" up 2>/dev/null || true
ip route replace default via "$WAN_GW" dev "$WAN_IFACE" 2>/dev/null || true

ok "WAN ($WAN_IFACE): $WAN_IP_CIDR, шлюз $WAN_GW"
STATUS["ip_wan"]="OK"

# ─── 5. LAN через etcnet (задание 1) ──────────────────────────────────────────
info "[Задание 1] Настройка LAN ($LAN_IFACE): $LAN_IP_CIDR"
etcnet_static "$LAN_IFACE" "$LAN_IP_CIDR"

ip addr flush dev "$LAN_IFACE" 2>/dev/null || true
ip addr add "$LAN_IP_CIDR" dev "$LAN_IFACE" 2>/dev/null || true
ip link set "$LAN_IFACE" up 2>/dev/null || true

ok "LAN ($LAN_IFACE): $LAN_IP_CIDR"
STATUS["ip_lan"]="OK"

# ─── 6. Перезапуск сети ───────────────────────────────────────────────────────
info "Перезапуск службы network (etcnet)..."
if systemctl restart network 2>/dev/null; then
    ok "Служба network перезапущена"
elif service network restart 2>/dev/null; then
    ok "Служба network перезапущена (SysV)"
else
    warn "Не удалось перезапустить network — конфиги etcnet применятся после перезагрузки"
fi

# ─── 7. NAT через iptables (задание 8) ────────────────────────────────────────
info "[Задание 8] Настройка NAT (MASQUERADE) через iptables..."

# Отключаем nftables, чтобы избежать конфликта backend'ов (двойной NAT)
if command -v systemctl &>/dev/null; then
    systemctl disable --now nftables 2>/dev/null || true
fi
if command -v nft &>/dev/null; then
    nft flush ruleset 2>/dev/null || true
fi

if ! command -v iptables &>/dev/null; then
    info "Установка iptables..."
    apt-get install -y iptables || {
        error "Не удалось установить iptables"
        STATUS["nat"]="ERROR"
    }
fi

if command -v iptables &>/dev/null; then
    # MASQUERADE для всего трафика в сторону WAN (Интернет)
    iptables -t nat -F POSTROUTING 2>/dev/null || true
    iptables -t nat -A POSTROUTING -o "$WAN_IFACE" -j MASQUERADE
    ok "NAT: MASQUERADE добавлен (out: $WAN_IFACE)"

    # FORWARD: LAN → WAN, обратный established/related и GRE (связность офисов)
    iptables -F FORWARD 2>/dev/null || true
    iptables -P FORWARD ACCEPT
    iptables -A FORWARD -i "$LAN_IFACE" -o "$WAN_IFACE" -j ACCEPT
    iptables -A FORWARD -i "$WAN_IFACE" -o "$LAN_IFACE" -m state --state RELATED,ESTABLISHED -j ACCEPT
    iptables -A FORWARD -i gre1 -j ACCEPT
    iptables -A FORWARD -o gre1 -j ACCEPT
    ok "FORWARD-правила добавлены (${LAN_IFACE} ↔ ${WAN_IFACE}, gre1)"

    # Сохраняем правила для восстановления после перезагрузки
    mkdir -p /etc/iptables
    iptables-save > /etc/iptables/rules.v4
    ok "Правила iptables сохранены в /etc/iptables/rules.v4"

    # systemd-сервис автозагрузки правил (persist across reboot)
    cat > /etc/systemd/system/iptables-restore.service <<'EOF2'
[Unit]
Description=Restore iptables rules
Wants=network-pre.target
Before=network-pre.target
After=local-fs.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/sbin/iptables-restore /etc/iptables/rules.v4

[Install]
WantedBy=multi-user.target
EOF2
    systemctl daemon-reload 2>/dev/null || true
    systemctl enable iptables-restore.service 2>/dev/null || true
    ok "iptables-restore.service включён (правила переживут перезагрузку)"
    STATUS["nat"]="OK"
else
    warn "iptables не найден, пропускаю NAT"
    STATUS["nat"]="SKIP"
fi

# ─── 8. GRE-туннель через etcnet (задание 6) ──────────────────────────────────
info "[Задание 6] Чистое воссоздание GRE-туннеля gre1 (etcnet)..."
info "  local=${GRE_LOCAL_IP}, remote=${HQ_WAN_IP}, tunnel=${GRE_TUNNEL_CIDR}"

GRE_DIR="/etc/net/ifaces/gre1"
mkdir -p "$GRE_DIR"
[[ -f "${GRE_DIR}/options" ]] && cp "${GRE_DIR}/options" "${GRE_DIR}/options.bak"

cat > "${GRE_DIR}/options" <<EOF2
BOOTPROTO=static
ONBOOT=yes
TYPE=iptun
TUNTYPE=gre
TUNLOCAL=${GRE_LOCAL_IP}
TUNREMOTE=${HQ_WAN_IP}
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
ip tunnel add gre1 mode gre local "$GRE_LOCAL_IP" remote "$HQ_WAN_IP" ttl 255
ip addr add "$GRE_TUNNEL_CIDR" dev gre1
ip link set gre1 mtu 1400
ip link set gre1 up
ip link set gre1 multicast on

ok "GRE туннель gre1 чисто воссоздан: ${GRE_TUNNEL_CIDR} → ${HQ_WAN_IP} (etcnet — постоянно)"
STATUS["gre_tunnel"]="OK"

# ─── 8.1 Автовключение multicast на gre1 для OSPF ─────────────────────────────
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

# ─── 9. OSPF через FRR (задание 7) ────────────────────────────────────────────
info "[Задание 7] Настройка OSPF через FRR..."
# Graceful Restart (NSF) + helper + BFD нужны для устойчивости при
# systemctl restart network: маршруты соседа сохраняются, а не только быстрее
# пересобирается adjacency.

FRR_READY=0
if command -v vtysh &>/dev/null || rpm -q frr &>/dev/null; then
    FRR_READY=1
else
    info "FRR не найден, пробую офлайн-установку..."
    OFFLINE_FRR_DIR=""
    for dir in /root/pkgs /root/pkgs/br-rtr /tmp/offline_pkgs/br-rtr; do
        if compgen -G "${dir}/*.rpm" >/dev/null 2>&1; then
            OFFLINE_FRR_DIR="$dir"
            break
        fi
    done

    if [[ -n "$OFFLINE_FRR_DIR" ]]; then
        info "Пробую установить FRR из локальных пакетов: ${OFFLINE_FRR_DIR}"
        apt-get install -y "${OFFLINE_FRR_DIR}"/*.rpm >/dev/null 2>&1 || \
        rpm -Uvh --nodeps "${OFFLINE_FRR_DIR}"/*.rpm >/dev/null 2>&1 || true
    else
        warn "Локальные .rpm для FRR не найдены (/root/pkgs, /root/pkgs/br-rtr, /tmp/offline_pkgs/br-rtr)"
    fi

    if command -v vtysh &>/dev/null || rpm -q frr &>/dev/null; then
        FRR_READY=1
    else
        info "Пробую установить FRR из сетевого репозитория..."
        apt-get install -y frr >/dev/null 2>&1 || true
        if command -v vtysh &>/dev/null || rpm -q frr &>/dev/null; then
            FRR_READY=1
        fi
    fi
fi

if [[ "$FRR_READY" -eq 0 ]]; then
    error "Не удалось установить FRR (нет vtysh и пакета frr). Проверьте офлайн-пакеты в /root/pkgs или доступ к репозиторию."
    STATUS["ospf"]="ERROR"
    STATUS["ospf_neighbor"]="SKIP"
else
    mkdir -p /etc/frr

    FRR_DAEMONS="/etc/frr/daemons"
    [[ -f "$FRR_DAEMONS" ]] && cp "$FRR_DAEMONS" "${FRR_DAEMONS}.bak"
    touch "$FRR_DAEMONS"
    enable_frr_daemon zebra "$FRR_DAEMONS"
    enable_frr_daemon ospfd "$FRR_DAEMONS"
    BFDD_AVAILABLE=0
    if [[ -x /usr/lib/frr/bfdd || -x /usr/lib64/frr/bfdd || -x /usr/sbin/bfdd ]] || command -v bfdd &>/dev/null; then
        BFDD_AVAILABLE=1
        set_frr_daemon_state bfdd yes "$FRR_DAEMONS"
        ok "FRR daemons включены: zebra=yes, ospfd=yes, bfdd=yes"
    else
        set_frr_daemon_state bfdd no "$FRR_DAEMONS"
        warn "bfdd не найден в системе — запускаю OSPF без BFD"
        ok "FRR daemons включены: zebra=yes, ospfd=yes, bfdd=no"
    fi

    FRR_OSPF="/etc/frr/frr.conf"
    [[ -f "$FRR_OSPF" ]] && cp "$FRR_OSPF" "${FRR_OSPF}.bak"
    GRE_LOCAL_ONLY="${GRE_TUNNEL_CIDR%/*}"
    GRE_PREFIX="${GRE_LOCAL_ONLY%.*}"
    GRE_LAST="${GRE_LOCAL_ONLY##*.}"
    if (( GRE_LAST % 2 == 1 )); then
        GRE_PEER_IP="${GRE_PREFIX}.$((GRE_LAST + 1))"
    else
        GRE_PEER_IP="${GRE_PREFIX}.$((GRE_LAST - 1))"
    fi

    OSPF_BFD_LINE=""
    if [[ "$BFDD_AVAILABLE" -eq 1 ]]; then
        OSPF_BFD_LINE=" ip ospf bfd"
    fi

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
 capability opaque
 graceful-restart grace-period 120
 graceful-restart helper enable
 network ${GRE_NET} area 0
 network ${LAN_NET} area 0
 area 0 authentication message-digest
 passive-interface default
 no passive-interface gre1
!
interface gre1
 ip ospf authentication message-digest
 ip ospf message-digest-key 1 md5 ${OSPF_PASS}
${OSPF_BFD_LINE}
 ip ospf mtu-ignore
 ip ospf hello-interval 1
 ip ospf dead-interval 4
 ip ospf retransmit-interval 3
!
EOF2

    if [[ "$BFDD_AVAILABLE" -eq 1 ]]; then
        cat >> "$FRR_OSPF" <<EOF2
bfd
 peer ${GRE_PEER_IP}
  receive-interval 300
  transmit-interval 300
  detect-multiplier 3
!
EOF2
    fi

    cat >> "$FRR_OSPF" <<'EOF2'
line vty
!
EOF2

    # Права важны: на некоторых сборках FRR не стартует, если конфиги не читаются пользователем frr.
    if id -u frr >/dev/null 2>&1 && getent group frr >/dev/null 2>&1; then
        chown -R frr:frr /etc/frr 2>/dev/null || true
        chmod 640 "$FRR_OSPF" "$FRR_DAEMONS" 2>/dev/null || true
    else
        warn "Пользователь/группа frr не найдены — оставляю root-владельца и выставляю читаемые права"
        chown root:root "$FRR_OSPF" "$FRR_DAEMONS" 2>/dev/null || true
        chmod 644 "$FRR_OSPF" "$FRR_DAEMONS" 2>/dev/null || true
    fi

    # Drop-in: FRR ждёт появления gre1 и перезапускается вместе с сетью
    # (PartOf=network.service), чтобы ospfd переинициализировался на новом
    # gre1 и не держал протухший сокет; иначе OSPF может не поднять соседство.
    # Таймеры hello/dead на gre1 снижены до 1/4 с для быстрого восстановления
    # соседства после systemctl restart network (вместо стандартных ~40 с).
    mkdir -p /etc/systemd/system/frr.service.d
    cat > /etc/systemd/system/frr.service.d/after-network.conf <<'EOF2'
[Unit]
PartOf=network.service
After=network.target network.service gre-multicast.service
Wants=gre-multicast.service

[Service]
ExecStartPre=/bin/sh -c 'for i in $(seq 1 30); do ip link show gre1 >/dev/null 2>&1 && break; sleep 1; done; ip link set gre1 mtu 1400 multicast on || true'
EOF2

    FRR_STARTED=0
    systemctl daemon-reload 2>/dev/null || true
    systemctl unmask frr 2>/dev/null || true
    for i in $(seq 1 30); do
        ip link show gre1 >/dev/null 2>&1 && break
        sleep 1
    done
    systemctl enable --now frr 2>/dev/null || true

    if systemctl restart frr 2>/dev/null && systemctl is-active --quiet frr 2>/dev/null; then
        FRR_STARTED=1
    elif service frr restart 2>/dev/null; then
        if systemctl is-active --quiet frr 2>/dev/null || pgrep -x zebra >/dev/null 2>&1 || pgrep -x ospfd >/dev/null 2>&1; then
            FRR_STARTED=1
        fi
    fi

    if [[ "$FRR_STARTED" -eq 1 ]]; then
        ok "OSPF (FRR) настроен и сервис frr активен, router-id=${OSPF_ROUTER_ID}"
        STATUS["ospf"]="OK"
        if command -v vtysh &>/dev/null; then
            OSPF_NEI_OK=0
            for i in $(seq 1 60); do
                OSPF_NEI_OUT="$(vtysh -c 'show ip ospf neighbor' 2>/dev/null || true)"
                if echo "$OSPF_NEI_OUT" | grep -Eq '10\.0\.0\.1.*Full|Full.*10\.0\.0\.1'; then
                    OSPF_NEI_OK=1
                    break
                fi
                sleep 1
            done
            if [[ "$OSPF_NEI_OK" -eq 1 ]]; then
                ok "OSPF сосед с HQ-RTR (10.0.0.1) в состоянии Full"
                STATUS["ospf_neighbor"]="OK"
            else
                warn "OSPF сосед 10.0.0.1 не перешёл в Full за 60 секунд"
                STATUS["ospf_neighbor"]="ERROR"
            fi
        else
            warn "vtysh не найден — пропускаю проверку OSPF-соседа"
            STATUS["ospf_neighbor"]="SKIP"
        fi
    else
        error "FRR не запустился: проверьте вывод ниже и /etc/frr/frr.conf"
        systemctl status frr --no-pager -l 2>/dev/null || true
        journalctl -u frr -n 50 --no-pager 2>/dev/null || true
        warn "Подсказка: проверьте gre1, multicast и OSPF вручную:"
        warn "  ip -d link show gre1"
        warn "  vtysh -c 'show ip ospf neighbor'"
        warn "  ping -c1 10.0.0.1"
        STATUS["ospf"]="ERROR"
        STATUS["ospf_neighbor"]="ERROR"
    fi
fi

# ─── 10. Пользователь net_admin (задание 3) ───────────────────────────────────
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
echo "  Итог настройки BR-RTR (Альт Сервер — etcnet)"
echo "============================================================"
for key in hostname timezone ip_forward ip_wan ip_lan nat gre_tunnel gre_multicast ospf ospf_neighbor net_admin; do
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
info "WAN:      ${WAN_IFACE} (${WAN_IP_CIDR}, шлюз ${WAN_GW})"
info "LAN:      ${LAN_IFACE} (${LAN_IP_CIDR})"
info "GRE:      gre1 ${GRE_TUNNEL_CIDR} → ${HQ_WAN_IP}"
info "OSPF:     FRR, router-id=${OSPF_ROUTER_ID}, сети ${GRE_NET} + ${LAN_NET}"
echo
warn "Если check_all.sh всё ещё показывает FAIL по OSPF соседям, проверьте на BR-RTR:"
warn "  systemctl status frr --no-pager -l"
warn "  vtysh -c 'show ip ospf neighbor'"
warn "  ping -c1 10.0.0.1"
warn "Конфиги etcnet: /etc/net/ifaces/ — применяются при systemctl restart network"
warn "iptables правила: /etc/iptables/rules.v4 (автозагрузка: iptables-restore.service)"
warn "После перезагрузки всё должно подняться автоматически!"

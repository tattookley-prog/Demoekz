#!/bin/bash
# Скрипт настройки ISP (ОС: Альт сервер)
# Покрывает: задание 2 (доступ к сети Интернет), задание 8 (NAT/ISP-часть)
# Демоэкзамен 09.02.06 Сетевое и системное администрирование, 2026
#
# Сеть настраивается через etcnet (/etc/net/ifaces/) — штатный механизм
# Альт сервер. Перезапуск сети: systemctl restart network

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

# ─── Проверка ОС: требуется Альт сервер ──────────────────────────────────────
if [[ ! -f /etc/altlinux-release ]]; then
    warn "Файл /etc/altlinux-release не найден."
    warn "Скрипт предназначен для ОС Альт сервер (Alt Server Linux)."
    read -rp "Продолжить на свой страх и риск? [y/N]: " _FORCE
    [[ "${_FORCE,,}" =~ ^y ]] || { info "Отменено."; exit 1; }
else
    ALT_RELEASE="$(cat /etc/altlinux-release)"
    info "ОС: ${ALT_RELEASE}"
    if ! grep -qi "server\|сервер" /etc/altlinux-release 2>/dev/null; then
        warn "Ожидается Альт сервер, обнаружен другой выпуск: ${ALT_RELEASE}"
        warn "Скрипт продолжит работу, но конфигурация может отличаться."
    fi
fi

echo
echo "============================================================"
echo "  Настройка ISP (Альт сервер) — демоэкзамен 09.02.06 (2026)"
echo "============================================================"
echo

# ─── Интерактивный ввод параметров ───────────────────────────────────────────
read -rp "Имя WAN-интерфейса (внешняя сеть, DHCP от провайдера) [eth0]: " WAN_IFACE
WAN_IFACE="${WAN_IFACE:-eth0}"

read -rp "Имя интерфейса в сторону HQ-RTR [eth1]: " HQ_IFACE
HQ_IFACE="${HQ_IFACE:-eth1}"

read -rp "Имя интерфейса в сторону BR-RTR [eth2]: " BR_IFACE
BR_IFACE="${BR_IFACE:-eth2}"

read -rp "IP-адрес интерфейса в сторону HQ-RTR [172.16.1.1/28]: " HQ_IP
HQ_IP="${HQ_IP:-172.16.1.1/28}"

read -rp "IP-адрес интерфейса в сторону BR-RTR [172.16.2.1/28]: " BR_IP
BR_IP="${BR_IP:-172.16.2.1/28}"

read -rp "Часовой пояс [Europe/Moscow]: " TZ_NAME
TZ_NAME="${TZ_NAME:-Europe/Moscow}"

echo
info "Параметры конфигурации:"
echo "  ОС:                      Альт сервер (etcnet)"
echo "  WAN интерфейс:           $WAN_IFACE (DHCP)"
echo "  Интерфейс → HQ-RTR:     $HQ_IFACE ($HQ_IP)"
echo "  Интерфейс → BR-RTR:     $BR_IFACE ($BR_IP)"
echo "  Часовой пояс:            $TZ_NAME"
echo
read -rp "Продолжить? [y/N]: " CONFIRM
if [[ ! "${CONFIRM,,}" =~ ^y ]]; then
    info "Операция отменена."
    exit 0
fi

# ─── Отслеживание статуса операций ───────────────────────────────────────────
declare -A STATUS

# ─── 1. Hostname ──────────────────────────────────────────────────────────────
info "Устанавливаю hostname: isp.au-team.irpo"
# Альт сервер: hostname хранится в /etc/hostname, hostnamectl тоже работает
hostnamectl set-hostname isp.au-team.irpo
# Дополнительно прописываем в /etc/hostname (на случай без systemd)
echo "isp.au-team.irpo" > /etc/hostname
ok "Hostname установлен: isp.au-team.irpo"
STATUS["hostname"]="OK"

# ─── 2. Часовой пояс ─────────────────────────────────────────────────────────
info "Устанавливаю часовой пояс: $TZ_NAME"
if timedatectl set-timezone "$TZ_NAME" 2>/dev/null; then
    ok "Часовой пояс: $TZ_NAME"
    STATUS["timezone"]="OK"
else
    # Ручной метод для Альт сервер если timedatectl недоступен
    if [[ -f "/usr/share/zoneinfo/${TZ_NAME}" ]]; then
        cp "/usr/share/zoneinfo/${TZ_NAME}" /etc/localtime
        echo "$TZ_NAME" > /etc/timezone 2>/dev/null || true
        ok "Часовой пояс установлен вручную: $TZ_NAME"
        STATUS["timezone"]="OK"
    else
        error "Не удалось установить часовой пояс $TZ_NAME"
        STATUS["timezone"]="ERROR"
    fi
fi

# ─── 3. IP-адресация через etcnet ────────────────────────────────────────────
# Альт сервер использует etcnet: /etc/net/ifaces/<имя_интерфейса>/
# Файлы: options (параметры), ipv4address (адрес/маска), ipv4route (маршруты)
info "Настройка IP-адресов через etcnet (/etc/net/ifaces/)..."

# ── Функция: создать конфиг etcnet для статического IP ──
etcnet_static() {
    local iface="$1" ip="$2"
    local dir="/etc/net/ifaces/${iface}"
    local addr="${ip%/*}"
    local prefix="${ip#*/}"

    mkdir -p "$dir"
    # Резервная копия если уже есть конфиг
    [[ -f "${dir}/options" ]] && cp "${dir}/options" "${dir}/options.bak"
    [[ -f "${dir}/ipv4address" ]] && cp "${dir}/ipv4address" "${dir}/ipv4address.bak"

    cat > "${dir}/options" <<EOF
# etcnet options — Альт сервер
BOOTPROTO=static
TYPE=eth
ONBOOT=yes
DISABLED=no
NM_CONTROLLED=no
CONFIG_IPV4=yes
EOF

    # ipv4address: адрес в формате addr/prefix
    echo "${addr}/${prefix}" > "${dir}/ipv4address"

    info "  etcnet: ${dir}/options и ipv4address созданы"

    # Немедленно применяем через ip (без перезапуска сети)
    ip addr flush dev "$iface" 2>/dev/null || true
    ip addr add "${addr}/${prefix}" dev "$iface"
    ip link set "$iface" up
}

# ── Функция: создать конфиг etcnet для DHCP ──
etcnet_dhcp() {
    local iface="$1"
    local dir="/etc/net/ifaces/${iface}"

    mkdir -p "$dir"
    [[ -f "${dir}/options" ]] && cp "${dir}/options" "${dir}/options.bak"

    cat > "${dir}/options" <<EOF
# etcnet options — Альт сервер
BOOTPROTO=dhcp
TYPE=eth
ONBOOT=yes
DISABLED=no
NM_CONTROLLED=no
CONFIG_IPV4=yes
EOF

    info "  etcnet: ${dir}/options создан (DHCP)"

    # Применяем DHCP немедленно
    if command -v dhclient &>/dev/null; then
        dhclient "$iface" 2>/dev/null &
    elif command -v udhcpc &>/dev/null; then
        udhcpc -i "$iface" -b 2>/dev/null &
    else
        ip link set "$iface" up
        warn "  dhclient/udhcpc не найден, интерфейс $iface поднят, DHCP применится при перезапуске сети"
    fi
}

info "  WAN ($WAN_IFACE): DHCP"
etcnet_dhcp "$WAN_IFACE"
ok "WAN ($WAN_IFACE) настроен на DHCP"
STATUS["ip_wan"]="OK"

info "  HQ-RTR side ($HQ_IFACE): $HQ_IP"
etcnet_static "$HQ_IFACE" "$HQ_IP"
ok "Интерфейс $HQ_IFACE настроен: $HQ_IP"
STATUS["ip_hq"]="OK"

info "  BR-RTR side ($BR_IFACE): $BR_IP"
etcnet_static "$BR_IFACE" "$BR_IP"
ok "Интерфейс $BR_IFACE настроен: $BR_IP"
STATUS["ip_br"]="OK"

# Перезапуск сети для применения конфигов etcnet
info "Перезапуск службы network (etcnet)..."
if systemctl restart network 2>/dev/null; then
    ok "Служба network перезапущена"
elif service network restart 2>/dev/null; then
    ok "Служба network перезапущена (SysV)"
else
    warn "Не удалось перезапустить network — конфиги etcnet применятся после перезагрузки"
fi

# ─── 4. IP forwarding ─────────────────────────────────────────────────────────
info "Включение IP forwarding..."
SYSCTL_CONF="/etc/sysctl.conf"
if grep -q '^#*\s*net\.ipv4\.ip_forward' "$SYSCTL_CONF"; then
    sed -i 's/^#*\s*net\.ipv4\.ip_forward.*/net.ipv4.ip_forward=1/' "$SYSCTL_CONF"
else
    echo 'net.ipv4.ip_forward=1' >> "$SYSCTL_CONF"
fi
sysctl -w net.ipv4.ip_forward=1 >/dev/null
ok "IP forwarding включён (постоянно через /etc/sysctl.conf)"
STATUS["ip_forward"]="OK"

# ─── 5. NAT через nftables ────────────────────────────────────────────────────
# На Альт сервер nftables устанавливается: apt-get install -y nftables
info "Настройка NAT (masquerade) через nftables..."

if ! command -v nft &>/dev/null; then
    info "Установка nftables (apt-get)..."
    apt-get install -y nftables || {
        error "Не удалось установить nftables"
        STATUS["nat"]="ERROR"
    }
fi

NFT_CONF="/etc/nftables/nftables.nft"
# На Альт сервер конфиг может лежать в /etc/nftables/
mkdir -p /etc/nftables
# Также создаём /etc/nftables.conf как симлинк или копию
[[ -f /etc/nftables.conf ]] && cp /etc/nftables.conf /etc/nftables.conf.bak
[[ -f "$NFT_CONF" ]] && cp "$NFT_CONF" "${NFT_CONF}.bak"

cat > "$NFT_CONF" <<EOF
#!/usr/sbin/nft -f
# nftables конфигурация ISP (Альт сервер) — демоэкзамен 09.02.06 (2026)
# NAT: masquerade для HQ-RTR и BR-RTR в сторону WAN (Интернет)

flush ruleset

table ip nat {
    chain postrouting {
        type nat hook postrouting priority srcnat; policy accept;
        # Masquerade: трафик от HQ-RTR (172.16.1.x) → Интернет
        iifname "${HQ_IFACE}" oifname "${WAN_IFACE}" masquerade
        # Masquerade: трафик от BR-RTR (172.16.2.x) → Интернет
        iifname "${BR_IFACE}" oifname "${WAN_IFACE}" masquerade
    }
}

table ip filter {
    chain forward {
        type filter hook forward priority filter; policy accept;
    }
}
EOF

# На Альт сервер конфиг может читаться из /etc/nftables.conf
cp "$NFT_CONF" /etc/nftables.conf

# Включаем и применяем
if systemctl enable --now nftables 2>/dev/null; then
    nft -f "$NFT_CONF"
    ok "nftables запущен и активирован (автозапуск включён)"
    STATUS["nat"]="OK"
else
    # Применяем правила напрямую и добавляем в автозапуск вручную
    if nft -f "$NFT_CONF"; then
        ok "nftables правила применены напрямую"
        # Для Альт сервер добавляем в /etc/rc.d/rc.local как резерв
        if [[ -f /etc/rc.d/rc.local ]]; then
            if ! grep -q "nft -f" /etc/rc.d/rc.local; then
                echo "nft -f ${NFT_CONF}" >> /etc/rc.d/rc.local
                chmod +x /etc/rc.d/rc.local
                info "Добавлен автозапуск nftables в /etc/rc.d/rc.local"
            fi
        fi
        STATUS["nat"]="OK"
    else
        error "Ошибка применения nftables"
        STATUS["nat"]="ERROR"
    fi
fi

# ─── Итоговый статус ──────────────────────────────────────────────────────────
echo
echo "============================================================"
echo "  Итог настройки ISP (Альт сервер)"
echo "============================================================"
for key in hostname timezone ip_wan ip_hq ip_br ip_forward nat; do
    val="${STATUS[$key]:-SKIP}"
    case "$val" in
        OK)    echo -e "  ${GREEN}[OK]${NC}    $key" ;;
        ERROR) echo -e "  ${RED}[ERROR]${NC} $key" ;;
        *)     echo -e "  ${YELLOW}[SKIP]${NC}  $key" ;;
    esac
done
echo "============================================================"
echo
ok "Настройка ISP завершена!"
info "Hostname:  isp.au-team.irpo"
info "WAN:       $WAN_IFACE (DHCP от провайдера)"
info "→ HQ-RTR: $HQ_IFACE = $HQ_IP"
info "→ BR-RTR: $BR_IFACE = $BR_IP"
info ""
warn "Конфиги etcnet: /etc/net/ifaces/ — применятся при перезапуске сети"
warn "nftables правила сохранены в: $NFT_CONF"

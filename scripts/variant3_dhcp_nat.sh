#!/bin/bash
# Скрипт настройки Вариант 3: Автоматизация сети и Трансляция адресов
# Темы: DHCP и NAT (PAT/Masquerade)
# Запускается на HQ-RTR (пограничный маршрутизатор)
# Демоэкзамен 09.02.06 Сетевое и системное администрирование, 2026
# Покрывает: DHCP, NAT/Masquerade, etcnet-автосохранение IP

set -euo pipefail

# ─── Цветной вывод ────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'
NC='\033[0m'

info()  { echo -e "${CYAN}[INFO]${NC}  $*"; }
ok()    { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }

# ─── Автосохранение статического IP (etcnet, /etc/net/ifaces/) ───────────────
# Альт Сервер использует etcnet как штатный механизм управления сетью.
# Функция записывает конфиг интерфейса в /etc/net/ifaces/<iface>/ для того,
# чтобы статический адрес переживал перезагрузку без nmcli/systemd-networkd.
save_static_ip_etcnet() {
    local iface="$1"
    local cidr="$2"          # формат: A.B.C.D/PREFIX
    local gateway="${3:-}"   # необязательный шлюз

    local iface_dir="/etc/net/ifaces/${iface}"
    mkdir -p "$iface_dir"

    # options — тип настройки и автозапуск
    cat > "${iface_dir}/options" <<EOF
BOOTPROTO=static
ONBOOT=yes
TYPE=eth
EOF

    # ipv4address — статический адрес с маской
    echo "${cidr}" > "${iface_dir}/ipv4address"

    # ipv4route — маршрут по умолчанию (если шлюз задан)
    if [[ -n "$gateway" ]]; then
        echo "default via ${gateway}" > "${iface_dir}/ipv4route"
    fi

    ok "etcnet: IP ${cidr} сохранён в ${iface_dir}/ (переживёт перезагрузку)"
}

# ─── Проверка root ────────────────────────────────────────────────────────────
if [[ $EUID -ne 0 ]]; then
    error "Скрипт должен быть запущен от имени root (sudo или su -)"
    exit 1
fi

echo
echo "============================================================"
echo "  Вариант 3: Автоматизация сети и Трансляция адресов"
echo "  Темы: DHCP и NAT"
echo "  Демоэкзамен 09.02.06 (2026)"
echo "============================================================"
echo
echo "Схема топологии:"
echo "  WAN (eth0): подключён к vmbr0 (интернет/Proxmox)"
echo "  LAN (eth1): подключён к vmbr1 (локальная сеть клиентов)"
echo "  DHCP-пул: адреса .50 – .100 с передачей шлюза и DNS"
echo "  NAT: PAT (Masquerade) на WAN-интерфейсе"
echo

# ─── Интерактивный ввод параметров ───────────────────────────────────────────
read -rp "WAN-интерфейс (интернет, vmbr0) [eth0]: " WAN_IFACE
WAN_IFACE="${WAN_IFACE:-eth0}"

read -rp "LAN-интерфейс (локальная сеть, vmbr1) [eth1]: " LAN_IFACE
LAN_IFACE="${LAN_IFACE:-eth1}"

read -rp "IP LAN-интерфейса (шлюз для клиентов) [192.168.0.1]: " LAN_IP
LAN_IP="${LAN_IP:-192.168.0.1}"

read -rp "Маска LAN-сети [24]: " LAN_PREFIX
LAN_PREFIX="${LAN_PREFIX:-24}"

# Вычисляем сеть из IP и маски
IFS='.' read -ra LAN_OCTETS <<< "$LAN_IP"
LAN_NET="${LAN_OCTETS[0]}.${LAN_OCTETS[1]}.${LAN_OCTETS[2]}.0/${LAN_PREFIX}"

read -rp "Начало DHCP-пула [${LAN_OCTETS[0]}.${LAN_OCTETS[1]}.${LAN_OCTETS[2]}.50]: " DHCP_START
DHCP_START="${DHCP_START:-${LAN_OCTETS[0]}.${LAN_OCTETS[1]}.${LAN_OCTETS[2]}.50}"

read -rp "Конец DHCP-пула [${LAN_OCTETS[0]}.${LAN_OCTETS[1]}.${LAN_OCTETS[2]}.100]: " DHCP_END
DHCP_END="${DHCP_END:-${LAN_OCTETS[0]}.${LAN_OCTETS[1]}.${LAN_OCTETS[2]}.100}"

read -rp "DNS-сервер для клиентов [8.8.8.8]: " DNS_SERVER
DNS_SERVER="${DNS_SERVER:-8.8.8.8}"

# Вычисляем маску подсети из префикса
prefix_to_mask() {
    local prefix="$1"
    local mask=""
    for i in 1 2 3 4; do
        if [[ $prefix -ge 8 ]]; then
            mask+="255"
            prefix=$((prefix - 8))
        elif [[ $prefix -gt 0 ]]; then
            mask+="$((256 - (1 << (8 - prefix))))"
            prefix=0
        else
            mask+="0"
        fi
        [[ $i -lt 4 ]] && mask+="."
    done
    echo "$mask"
}

SUBNET_MASK=$(prefix_to_mask "$LAN_PREFIX")

echo
info "Параметры конфигурации:"
echo "  WAN интерфейс:   $WAN_IFACE (получает IP от провайдера/DHCP)"
echo "  LAN интерфейс:   $LAN_IFACE = ${LAN_IP}/${LAN_PREFIX}"
echo "  Сеть LAN:        $LAN_NET (маска: $SUBNET_MASK)"
echo "  DHCP-пул:        ${DHCP_START} – ${DHCP_END}"
echo "  Шлюз для клиентов: $LAN_IP"
echo "  DNS для клиентов:  $DNS_SERVER"
echo "  NAT:             Masquerade ${LAN_NET} → $WAN_IFACE"
echo
read -rp "Продолжить? [y/N]: " CONFIRM
if [[ ! "${CONFIRM,,}" =~ ^y ]]; then
    info "Операция отменена."
    exit 0
fi

declare -A STATUS

# ─── 1. Настройка LAN-интерфейса ─────────────────────────────────────────────
info "Настройка LAN-интерфейса $LAN_IFACE: ${LAN_IP}/${LAN_PREFIX}..."

if command -v nmcli &>/dev/null; then
    nmcli con delete "lan-${LAN_IFACE}" &>/dev/null || true
    nmcli con add type ethernet ifname "$LAN_IFACE" con-name "lan-${LAN_IFACE}" \
        ipv4.method manual \
        ipv4.addresses "${LAN_IP}/${LAN_PREFIX}" \
        connection.autoconnect yes
    nmcli con up "lan-${LAN_IFACE}"
elif systemctl is-active systemd-networkd &>/dev/null; then
    cat > "/etc/systemd/network/10-${LAN_IFACE}.network" <<EOF
[Match]
Name=${LAN_IFACE}

[Network]
Address=${LAN_IP}/${LAN_PREFIX}
EOF
    systemctl restart systemd-networkd
    sleep 1
    ok "Интерфейс $LAN_IFACE настроен через systemd-networkd"
else
    warn "Ни nmcli, ни systemd-networkd — настройка временная"
    ip addr flush dev "$LAN_IFACE" 2>/dev/null || true
    ip addr add "${LAN_IP}/${LAN_PREFIX}" dev "$LAN_IFACE"
    ip link set "$LAN_IFACE" up
fi
ok "LAN ($LAN_IFACE): ${LAN_IP}/${LAN_PREFIX}"
STATUS["ip_lan"]="OK"
save_static_ip_etcnet "$LAN_IFACE" "${LAN_IP}/${LAN_PREFIX}"

# WAN-интерфейс обычно получает адрес через DHCP от Proxmox/vmbr0
if command -v nmcli &>/dev/null; then
    nmcli con delete "wan-${WAN_IFACE}" &>/dev/null || true
    nmcli con add type ethernet ifname "$WAN_IFACE" con-name "wan-${WAN_IFACE}" \
        ipv4.method auto \
        connection.autoconnect yes
    nmcli con up "wan-${WAN_IFACE}"
elif systemctl is-active systemd-networkd &>/dev/null; then
    cat > "/etc/systemd/network/10-${WAN_IFACE}.network" <<EOF
[Match]
Name=${WAN_IFACE}

[Network]
DHCP=ipv4
EOF
    systemctl restart systemd-networkd
    sleep 1
    ok "Интерфейс $WAN_IFACE (DHCP) настроен через systemd-networkd"
else
    ip link set "$WAN_IFACE" up
fi
ok "WAN ($WAN_IFACE): DHCP (получает IP от vmbr0)"
STATUS["ip_wan"]="OK"

# WAN — DHCP, сохраняем тип в etcnet
mkdir -p "/etc/net/ifaces/${WAN_IFACE}"
printf 'BOOTPROTO=dhcp\nONBOOT=yes\nTYPE=eth\n' > "/etc/net/ifaces/${WAN_IFACE}/options"
ok "etcnet: WAN ${WAN_IFACE} — DHCP, конфиг сохранён"

# ─── 2. IP forwarding ─────────────────────────────────────────────────────────
# ─── Включение IP forwarding (надёжный способ для Альт Линукс) ───────────────
info "Включение IP forwarding..."
# Записываем в sysctl.d — применяется при загрузке (надёжнее на Альт)
echo 'net.ipv4.ip_forward = 1' > /etc/sysctl.d/99-ipforward.conf
# Применяем немедленно
sysctl -w net.ipv4.ip_forward=1 >/dev/null
# Также обновляем sysctl.conf для совместимости
if grep -q '^net.ipv4.ip_forward' /etc/sysctl.conf 2>/dev/null; then
    sed -i 's/^#*\s*net\.ipv4\.ip_forward.*/net.ipv4.ip_forward=1/' /etc/sysctl.conf
else
    echo 'net.ipv4.ip_forward=1' >> /etc/sysctl.conf
fi
ok "IP forwarding включён (/etc/sysctl.d/99-ipforward.conf)"
STATUS["ip_forward"]="OK"

# ─── Задание 1: DHCP-сервер ───────────────────────────────────────────────────
info "[Задание 1] Настройка DHCP-сервера: пул ${DHCP_START} – ${DHCP_END}..."

if ! command -v dhcpd &>/dev/null; then
    info "Установка dhcp-server..."
    apt-get install -y dhcp-server 2>/dev/null \
        || apt-get install -y isc-dhcp-server 2>/dev/null \
        || { error "Не удалось установить DHCP-сервер"; STATUS["dhcp"]="ERROR"; }
fi

if command -v dhcpd &>/dev/null || [[ -d /etc/dhcp ]]; then
    DHCPD_CONF="/etc/dhcp/dhcpd.conf"
    [[ -f "$DHCPD_CONF" ]] && cp "$DHCPD_CONF" "${DHCPD_CONF}.bak"
    mkdir -p /etc/dhcp

    cat > "$DHCPD_CONF" <<EOF
# dhcpd.conf — Вариант 3: DHCP для локальной сети
# Демоэкзамен 09.02.06 (2026)

# Глобальные параметры
option domain-name-servers ${DNS_SERVER};

default-lease-time 600;
max-lease-time 7200;

authoritative;

# Подсеть LAN: ${LAN_NET}
subnet ${LAN_OCTETS[0]}.${LAN_OCTETS[1]}.${LAN_OCTETS[2]}.0 netmask ${SUBNET_MASK} {
    # Задание 1: Пул начинается с .50 и заканчивается на .100
    range ${DHCP_START} ${DHCP_END};
    # Задание 1: Передаём адрес шлюза
    option routers ${LAN_IP};
    option subnet-mask ${SUBNET_MASK};
    # Задание 1: Передаём адрес DNS-сервера
    option domain-name-servers ${DNS_SERVER};
}
EOF

    ok "DHCP конфиг записан: ${DHCPD_CONF}"
    ok "  Пул:    ${DHCP_START} – ${DHCP_END}"
    ok "  Шлюз:   ${LAN_IP}"
    ok "  DNS:    ${DNS_SERVER}"

    # Привязываем DHCP к LAN-интерфейсу
    DHCP_SYSCONF="/etc/sysconfig/dhcpd"
    if [[ -f "$DHCP_SYSCONF" ]]; then
        cp "$DHCP_SYSCONF" "${DHCP_SYSCONF}.bak"
        echo "DHCPDARGS=\"${LAN_IFACE}\"" > "$DHCP_SYSCONF"
    fi
    ISC_DEFAULT="/etc/default/isc-dhcp-server"
    if [[ -f "$ISC_DEFAULT" ]]; then
        cp "$ISC_DEFAULT" "${ISC_DEFAULT}.bak"
        sed -i "s|^INTERFACESv4=.*|INTERFACESv4=\"${LAN_IFACE}\"|" "$ISC_DEFAULT"
    fi

    # Запуск DHCP-сервера
    for svc in dhcpd isc-dhcp-server dhcp-server; do
        if systemctl enable --now "$svc" 2>/dev/null; then
            ok "DHCP-сервер ($svc) запущен"
            STATUS["dhcp"]="OK"
            break
        fi
    done
    STATUS["dhcp"]="${STATUS[dhcp]:-ERROR}"
else
    warn "dhcpd не найден, пропускаю настройку DHCP"
    STATUS["dhcp"]="SKIP"
fi

# ─── Задание 2: NAT (PAT/Masquerade) ─────────────────────────────────────────
info "[Задание 2] Настройка NAT (Masquerade) на $WAN_IFACE..."

# Пробуем nftables (предпочтительно)
if command -v nft &>/dev/null || apt-get install -y nftables 2>/dev/null; then
    NFT_CONF="/etc/nftables.conf"
    [[ -f "$NFT_CONF" ]] && cp "$NFT_CONF" "${NFT_CONF}.bak"

    cat > "$NFT_CONF" <<EOF
#!/usr/sbin/nft -f
# nftables конфигурация — Вариант 3: NAT (PAT/Masquerade)
# Демоэкзамен 09.02.06 (2026)

flush ruleset

table ip nat {
    chain postrouting {
        type nat hook postrouting priority 100; policy accept;
        # Задание 2: PAT — подмена внутренних IP на внешний при выходе в интернет
        iifname "${LAN_IFACE}" oifname "${WAN_IFACE}" masquerade
    }
}

table ip filter {
    chain forward {
        type filter hook forward priority 0; policy accept;
        # Разрешаем трафик из LAN в WAN и обратно (установленные соединения)
        iifname "${LAN_IFACE}" oifname "${WAN_IFACE}" accept
        iifname "${WAN_IFACE}" oifname "${LAN_IFACE}" ct state established,related accept
    }
}
EOF

    systemctl enable --now nftables 2>/dev/null || true
    if nft -f "$NFT_CONF"; then
        ok "NAT (nftables Masquerade) настроен: ${LAN_IFACE} → ${WAN_IFACE}"
        STATUS["nat"]="OK"
    else
        error "Ошибка применения nftables конфигурации"
        STATUS["nat"]="ERROR"
    fi

# Fallback: iptables
elif command -v iptables &>/dev/null; then
    info "nftables недоступен, используем iptables..."
    iptables -t nat -F POSTROUTING 2>/dev/null || true
    iptables -t nat -A POSTROUTING -o "$WAN_IFACE" -j MASQUERADE
    iptables -A FORWARD -i "$LAN_IFACE" -o "$WAN_IFACE" -j ACCEPT
    iptables -A FORWARD -i "$WAN_IFACE" -o "$LAN_IFACE" -m state --state ESTABLISHED,RELATED -j ACCEPT

    # Сохраняем правила iptables
    if command -v iptables-save &>/dev/null; then
        iptables-save > /etc/iptables/rules.v4 2>/dev/null \
            || iptables-save > /etc/iptables.rules 2>/dev/null || true
    fi
    ok "NAT (iptables Masquerade) настроен: ${LAN_IFACE} → ${WAN_IFACE}"
    STATUS["nat"]="OK"
else
    error "Ни nftables, ни iptables не найдены"
    STATUS["nat"]="ERROR"
fi

# ─── Проверка: доступность интернета ─────────────────────────────────────────
info "Проверка выхода в интернет через $WAN_IFACE..."
if ping -c 3 -W 3 -I "$WAN_IFACE" 8.8.8.8 &>/dev/null 2>&1 \
    || ping -c 3 -W 3 8.8.8.8 &>/dev/null 2>&1; then
    ok "Выход в интернет доступен"
    STATUS["internet"]="OK"
else
    warn "Пинг до 8.8.8.8 недоступен (возможно WAN ещё не подключён)"
    STATUS["internet"]="SKIP"
fi

# ─── Итоговый статус ──────────────────────────────────────────────────────────
echo
echo "============================================================"
echo "  Итог: Вариант 3 — DHCP и NAT"
echo "============================================================"
for key in ip_wan ip_lan ip_forward dhcp nat internet; do
    val="${STATUS[$key]:-SKIP}"
    case "$val" in
        OK)    echo -e "  ${GREEN}[OK]${NC}    $key" ;;
        ERROR) echo -e "  ${RED}[ERROR]${NC} $key" ;;
        *)     echo -e "  ${YELLOW}[SKIP]${NC}  $key" ;;
    esac
done
echo "============================================================"
echo
ok "Вариант 3 завершён!"
echo
info "Следующие шаги:"
echo "  1. Подключите клиентскую машину к vmbr1 (LAN)"
echo "  2. Проверьте получение DHCP-адреса: dhclient eth0 && ip addr"
echo "  3. Ожидаемый адрес клиента: ${DHCP_START} – ${DHCP_END}"
echo "  4. Проверьте выход в интернет с клиента: ping 8.8.8.8"
echo "  5. Проверьте NAT: tcpdump -i ${WAN_IFACE} icmp"
echo
echo "------------------------------------------------------------"
echo "  ПРОВЕРКА ПОСЛЕ ПЕРЕЗАГРУЗКИ:"
echo "------------------------------------------------------------"
echo "  1. ip addr show $LAN_IFACE — IP ${LAN_IP}/${LAN_PREFIX} должен присутствовать"
echo "  2. systemctl status dhcpd (или dhcp-server) — DHCP должен быть active"
echo "  3. cat /proc/sys/net/ipv4/ip_forward — должно быть 1"
echo "  4. nft list ruleset — правила NAT должны присутствовать"
echo "     (или: iptables -t nat -L -n — если использовался iptables)"
echo "  5. ping -I $WAN_IFACE 8.8.8.8 — интернет через WAN должен работать"
echo "  6. ls /etc/net/ifaces/ — конфиги интерфейсов (etcnet) должны существовать"
echo "------------------------------------------------------------"

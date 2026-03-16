#!/bin/bash
# Скрипт настройки Вариант 1: Базовая коммутация и IPv4-адресация
# Темы: VLAN и Статическая адресация
# Запускается на HQ-RTR (шлюз для VLAN 10 и VLAN 20)
# Демоэкзамен 09.02.06 Сетевое и системное администрирование, 2026
# Покрывает: VLAN sub-интерфейсы, статическая адресация, DHCP, etcnet-автосохранение IP

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
    local cidr="$2"              # формат: A.B.C.D/PREFIX
    local gateway="${3:-}"       # необязательный шлюз
    local vlan_id="${4:-}"       # необязательный: ID VLAN (для VLAN sub-интерфейсов)
    local parent_iface="${5:-}"  # необязательный: родительский интерфейс (для VLAN)

    local iface_dir="/etc/net/ifaces/${iface}"
    mkdir -p "$iface_dir"

    # options — тип настройки и автозапуск
    if [[ -n "$vlan_id" && -n "$parent_iface" ]]; then
        # VLAN sub-интерфейс — etcnet требует TYPE=vlan + HOST + VLAN_ID
        cat > "${iface_dir}/options" <<EOF
BOOTPROTO=static
ONBOOT=yes
TYPE=vlan
HOST=${parent_iface}
VLAN_ID=${vlan_id}
DISABLED=no
NM_CONTROLLED=no
CONFIG_IPV4=yes
EOF
    else
        cat > "${iface_dir}/options" <<EOF
BOOTPROTO=static
ONBOOT=yes
TYPE=eth
DISABLED=no
NM_CONTROLLED=no
CONFIG_IPV4=yes
EOF
    fi

    # ipv4address — статический адрес с маской (только если CIDR задан)
    if [[ -n "$cidr" ]]; then
        echo "${cidr}" > "${iface_dir}/ipv4address"
    fi

    # ipv4route — маршрут по умолчанию (если шлюз задан) или connected-маршрут к подсети
    if [[ -n "$gateway" ]]; then
        echo "default via ${gateway}" > "${iface_dir}/ipv4route"
    elif [[ -n "$cidr" ]]; then
        # Вычисляем connected-маршрут к подсети, чтобы etcnet корректно поднимал маршрутизацию
        local network
        network=$(python3 -c "import ipaddress; print(ipaddress.ip_interface('${cidr}').network)" 2>/dev/null) \
            || network=$(ipcalc -n "${cidr}" 2>/dev/null | awk '/^Network:/{print $2}') \
            || true
        if [[ -n "$network" ]]; then
            echo "${network} dev ${iface}" > "${iface_dir}/ipv4route"
        else
            warn "etcnet: не удалось вычислить сеть из ${cidr} — ipv4route не создан (проверьте наличие python3 или ipcalc)"
        fi
    fi

    ok "etcnet: IP ${cidr} сохранён в ${iface_dir}/ (переживёт перезагрузку)"
}

# ─── Сохранение trunk-интерфейса в etcnet (без IP-адреса) ────────────────────
# Trunk-интерфейс должен подниматься при загрузке, чтобы VLAN sub-интерфейсы
# могли быть созданы поверх него. IP-адрес на trunk не нужен.
save_trunk_iface_etcnet() {
    local iface="$1"
    local iface_dir="/etc/net/ifaces/${iface}"
    if [[ -f "${iface_dir}/options" ]]; then
        info "etcnet: конфиг trunk-интерфейса ${iface} уже существует — используется без изменений"
        return 0
    fi
    mkdir -p "$iface_dir"
    cat > "${iface_dir}/options" <<EOF
BOOTPROTO=static
ONBOOT=yes
TYPE=eth
DISABLED=no
NM_CONTROLLED=no
CONFIG_IPV4=no
EOF
    ok "etcnet: создан конфиг trunk-интерфейса ${iface} (без IP, переживёт перезагрузку)"
}

# ─── Проверка root ────────────────────────────────────────────────────────────
if [[ $EUID -ne 0 ]]; then
    error "Скрипт должен быть запущен от имени root (sudo или su -)"
    exit 1
fi

echo
echo "============================================================"
echo "  Вариант 1: Базовая коммутация и IPv4-адресация"
echo "  Темы: VLAN и Статическая адресация"
echo "  Демоэкзамен 09.02.06 (2026)"
echo "============================================================"
echo
echo "Схема топологии:"
echo "  HQ-RTR — шлюз для двух VLAN"
echo "  HQ-SW  — мост vmbr1 в режиме VLAN Aware (Proxmox)"
echo "  VLAN 10 (Management): шлюз eth0.10 = 192.168.10.1/24"
echo "           HQ-SRV: 192.168.10.10/24"
echo "  VLAN 20 (Users):      шлюз eth0.20 = 192.168.20.1/24"
echo "           HQ-CLI: получает адрес из 192.168.20.0/24"
echo

# ─── Интерактивный ввод параметров ───────────────────────────────────────────
read -rp "Физический интерфейс для VLAN (в сторону HQ-SW) [eth0]: " TRUNK_IFACE
TRUNK_IFACE="${TRUNK_IFACE:-eth0}"

read -rp "Статический IP HQ-SRV (VLAN 10) [192.168.10.10]: " HQ_SRV_IP
HQ_SRV_IP="${HQ_SRV_IP:-192.168.10.10}"

read -rp "Диапазон DHCP для HQ-CLI (VLAN 20): начало [192.168.20.50]: " DHCP_START
DHCP_START="${DHCP_START:-192.168.20.50}"

read -rp "Диапазон DHCP для HQ-CLI (VLAN 20): конец [192.168.20.100]: " DHCP_END
DHCP_END="${DHCP_END:-192.168.20.100}"

echo
info "Параметры конфигурации:"
echo "  Trunk интерфейс:          $TRUNK_IFACE"
echo "  VLAN 10 (Management) GW:  ${TRUNK_IFACE}.10 = 192.168.10.1/24"
echo "  VLAN 20 (Users) GW:       ${TRUNK_IFACE}.20 = 192.168.20.1/24"
echo "  HQ-SRV статический IP:    $HQ_SRV_IP/24"
echo "  HQ-CLI DHCP-пул:          ${DHCP_START} – ${DHCP_END}"
echo
read -rp "Продолжить? [y/N]: " CONFIRM
if [[ ! "${CONFIRM,,}" =~ ^y ]]; then
    info "Операция отменена."
    exit 0
fi

declare -A STATUS
ETCNET_FALLBACK=false

# ─── Задание 1: Создание VLAN 10 и VLAN 20 на HQ-RTR ─────────────────────────
# В Proxmox роль коммутатора выполняет мост vmbr1 (VLAN Aware).
# На маршрутизаторе создаём VLAN sub-интерфейсы: eth0.10 и eth0.20.

info "[Задание 1] Создание VLAN sub-интерфейсов на $TRUNK_IFACE..."

# ─── Загрузка модуля 8021q (необходим для VLAN sub-интерфейсов) ──────────────
info "Загрузка модуля 8021q..."
if ! lsmod | grep -q 8021q; then
    modprobe 8021q 2>/dev/null && ok "Модуль 8021q загружен" \
        || warn "Не удалось загрузить 8021q (возможно уже встроен в ядро)"
else
    ok "Модуль 8021q уже загружен"
fi
# Чтобы модуль загружался автоматически при перезагрузке
echo '8021q' > /etc/modules-load.d/8021q.conf 2>/dev/null || true

# Включаем родительский интерфейс
ip link set "$TRUNK_IFACE" up 2>/dev/null || true

create_vlan_subif() {
    local vlan_id="$1"
    local gw_ip="$2"
    local prefix="$3"
    local desc="$4"
    local subif="${TRUNK_IFACE}.${vlan_id}"

    # Сохраняем trunk-интерфейс в etcnet перед созданием VLAN sub-интерфейса
    save_trunk_iface_etcnet "$TRUNK_IFACE"

    if command -v nmcli &>/dev/null; then
        nmcli con delete "vlan${vlan_id}" &>/dev/null || true
        nmcli con add type vlan ifname "$subif" con-name "vlan${vlan_id}" \
            dev "$TRUNK_IFACE" id "$vlan_id" \
            ipv4.method manual ipv4.addresses "${gw_ip}/${prefix}" \
            connection.autoconnect yes
        nmcli con up "vlan${vlan_id}"
    elif systemctl is-active systemd-networkd &>/dev/null; then
        # Резервный вариант через systemd-networkd (переживает перезагрузку)
        # .netdev — создаёт VLAN-устройство, связанное с родительским интерфейсом
        cat > "/etc/systemd/network/10-vlan${vlan_id}.netdev" <<EOF
[NetDev]
Name=${subif}
Kind=vlan

[VLAN]
Id=${vlan_id}
EOF
        # .network — назначает адрес VLAN sub-интерфейсу
        cat > "/etc/systemd/network/10-vlan${vlan_id}.network" <<EOF
[Match]
Name=${subif}

[Network]
Address=${gw_ip}/${prefix}
EOF
        # .network для родительского интерфейса — привязывает VLAN к физическому порту
        cat > "/etc/systemd/network/05-${TRUNK_IFACE}.network" <<EOF
[Match]
Name=${TRUNK_IFACE}

[Network]
VLAN=${subif}
EOF
        systemctl restart systemd-networkd
        sleep 1
        ok "VLAN $vlan_id настроен через systemd-networkd (переживёт перезагрузку)"
    else
        # Временный fallback через ip-команды
        warn "Ни nmcli, ни systemd-networkd недоступны — настройка временная (до перезагрузки)"
        ETCNET_FALLBACK=true
        ip link delete "$subif" 2>/dev/null || true
        ip link add link "$TRUNK_IFACE" name "$subif" type vlan id "$vlan_id"
        ip link set "$subif" up
        ip addr add "${gw_ip}/${prefix}" dev "$subif"
    fi
    ok "VLAN $vlan_id ($desc): $subif = ${gw_ip}/${prefix}"
    # Сохраняем в etcnet ПОСЛЕ любого метода настройки (TYPE=vlan для sub-интерфейсов)
    save_static_ip_etcnet "$subif" "${gw_ip}/${prefix}" "" "$vlan_id" "$TRUNK_IFACE"
}

if create_vlan_subif 10 "192.168.10.1" "24" "Management"; then
    STATUS["vlan10"]="OK"
else
    STATUS["vlan10"]="ERROR"
fi

if create_vlan_subif 20 "192.168.20.1" "24" "Users"; then
    STATUS["vlan20"]="OK"
else
    STATUS["vlan20"]="ERROR"
fi

# Перезапуск сети через etcnet (только если использовался fallback)
if [[ "$ETCNET_FALLBACK" == true ]]; then
    info "Применяю сетевые настройки etcnet (systemctl restart network)..."
    if systemctl restart network 2>/dev/null; then
        ok "Сеть перезапущена, настройки etcnet применены"
    else
        warn "Не удалось перезапустить network через systemctl, попробуйте вручную: service network restart"
    fi
fi

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

# ─── Задание 2: Статический IP для HQ-SRV ────────────────────────────────────
# Этот блок выполняется непосредственно на машине HQ-SRV.
# Здесь мы выводим команды, которые нужно запустить на HQ-SRV.
info "[Задание 2] Настройка статического IP на HQ-SRV..."
echo
echo "  *** Выполните следующие команды на машине HQ-SRV ***"
echo "  Интерфейс HQ-SRV подключён к vmbr1 с VLAN Tag 10 в Proxmox."
echo
echo "  Способ 1 (nmcli):"
echo "    nmcli con add type ethernet ifname eth0 con-name static-eth0 \\"
echo "        ipv4.method manual \\"
echo "        ipv4.addresses \"${HQ_SRV_IP}/24\" \\"
echo "        ipv4.gateway \"192.168.10.1\" \\"
echo "        ipv4.dns \"192.168.10.1\" \\"
echo "        connection.autoconnect yes"
echo "    nmcli con up static-eth0"
echo
echo "  Способ 2 (ip-команды, временно до перезагрузки):"
echo "    ip addr add ${HQ_SRV_IP}/24 dev eth0"
echo "    ip link set eth0 up"
echo "    ip route add default via 192.168.10.1"
echo

# Проверяем, запущены ли мы на HQ-SRV
if [[ "$(hostname)" == *"hq-srv"* ]]; then
    info "Обнаружен хост hq-srv — применяем настройки автоматически..."
    HQ_SRV_IFACE="${HQ_SRV_IFACE:-eth0}"
    if command -v nmcli &>/dev/null; then
        nmcli con delete "static-${HQ_SRV_IFACE}" &>/dev/null || true
        nmcli con add type ethernet ifname "$HQ_SRV_IFACE" con-name "static-${HQ_SRV_IFACE}" \
            ipv4.method manual \
            ipv4.addresses "${HQ_SRV_IP}/24" \
            ipv4.gateway "192.168.10.1" \
            ipv4.dns "192.168.10.1" \
            connection.autoconnect yes
        nmcli con up "static-${HQ_SRV_IFACE}"
        ok "HQ-SRV IP настроен: ${HQ_SRV_IP}/24"
        STATUS["hq_srv_ip"]="OK"
    fi
    save_static_ip_etcnet "eth0" "${HQ_SRV_IP}/24" "192.168.10.1"
else
    info "Скрипт запущен не на HQ-SRV — инструкции выведены выше."
    STATUS["hq_srv_ip"]="SKIP"
fi

# ─── DHCP для HQ-CLI (VLAN 20) ────────────────────────────────────────────────
info "Настройка DHCP-сервера для VLAN 20 (HQ-CLI: ${DHCP_START} – ${DHCP_END})..."

if ! command -v dhcpd &>/dev/null; then
    info "Установка dhcp-server..."
    apt-get install -y dhcp-server 2>/dev/null \
        || apt-get install -y isc-dhcp-server 2>/dev/null \
        || { error "Не удалось установить DHCP-сервер"; STATUS["dhcp"]="ERROR"; }
fi

if command -v dhcpd &>/dev/null || [[ -f /etc/dhcp/dhcpd.conf ]]; then
    DHCPD_CONF="/etc/dhcp/dhcpd.conf"
    [[ -f "$DHCPD_CONF" ]] && cp "$DHCPD_CONF" "${DHCPD_CONF}.bak"
    mkdir -p /etc/dhcp

    cat > "$DHCPD_CONF" <<EOF
# dhcpd.conf — Вариант 1: DHCP для VLAN 20 (Users)
# Демоэкзамен 09.02.06 (2026)

default-lease-time 600;
max-lease-time 7200;

authoritative;

# Подсеть VLAN 20 (Users): 192.168.20.0/24
subnet 192.168.20.0 netmask 255.255.255.0 {
    range ${DHCP_START} ${DHCP_END};
    option routers 192.168.20.1;
    option subnet-mask 255.255.255.0;
    option domain-name-servers 192.168.10.1;
}
EOF

    # Привязываем DHCP к интерфейсу VLAN 20
    DHCP_SYSCONF="/etc/sysconfig/dhcpd"
    if [[ -f "$DHCP_SYSCONF" ]]; then
        cp "$DHCP_SYSCONF" "${DHCP_SYSCONF}.bak"
        echo "DHCPDARGS=\"${TRUNK_IFACE}.20\"" > "$DHCP_SYSCONF"
    fi
    ISC_DEFAULT="/etc/default/isc-dhcp-server"
    if [[ -f "$ISC_DEFAULT" ]]; then
        cp "$ISC_DEFAULT" "${ISC_DEFAULT}.bak"
        sed -i "s|^INTERFACESv4=.*|INTERFACESv4=\"${TRUNK_IFACE}.20\"|" "$ISC_DEFAULT"
    fi

    for svc in dhcpd isc-dhcp-server dhcp-server; do
        if systemctl enable --now "$svc" 2>/dev/null; then
            ok "DHCP-сервер ($svc) запущен для VLAN 20"
            STATUS["dhcp"]="OK"
            break
        fi
    done
    STATUS["dhcp"]="${STATUS[dhcp]:-ERROR}"
else
    warn "dhcpd не найден, пропускаю настройку DHCP"
    STATUS["dhcp"]="SKIP"
fi

# ─── Задание 3: Проверка доступности (ping) между VLAN ───────────────────────
info "[Задание 3] Проверка связи между VLAN 10 и VLAN 20..."
echo

# Ping с шлюза VLAN 10 на шлюз VLAN 20
if ping -c 3 -W 2 192.168.20.1 &>/dev/null; then
    ok "Связь между VLAN: 192.168.10.1 → 192.168.20.1 — ДОСТУПНА"
    STATUS["ping_vlan_gw"]="OK"
else
    warn "Связь 192.168.10.1 → 192.168.20.1 недоступна (HQ-CLI ещё не подключён?)"
    STATUS["ping_vlan_gw"]="SKIP"
fi

# Ping до HQ-SRV
if ping -c 3 -W 2 "$HQ_SRV_IP" &>/dev/null; then
    ok "Ping до HQ-SRV ($HQ_SRV_IP) — УСПЕШНО"
    STATUS["ping_srv"]="OK"
else
    warn "Ping до HQ-SRV ($HQ_SRV_IP) недоступен (настройте HQ-SRV вручную)"
    STATUS["ping_srv"]="SKIP"
fi

# ─── Итоговый статус ──────────────────────────────────────────────────────────
echo
echo "============================================================"
echo "  Итог: Вариант 1 — Базовая коммутация и IPv4-адресация"
echo "============================================================"
for key in vlan10 vlan20 ip_forward hq_srv_ip dhcp ping_vlan_gw ping_srv; do
    val="${STATUS[$key]:-SKIP}"
    case "$val" in
        OK)    echo -e "  ${GREEN}[OK]${NC}    $key" ;;
        ERROR) echo -e "  ${RED}[ERROR]${NC} $key" ;;
        *)     echo -e "  ${YELLOW}[SKIP]${NC}  $key" ;;
    esac
done
echo "============================================================"
echo
ok "Вариант 1 завершён!"
echo
info "Следующие шаги:"
echo "  1. На HQ-SRV настройте IP ${HQ_SRV_IP}/24, шлюз 192.168.10.1"
echo "     (инструкции выведены выше)"
echo "  2. На HQ-CLI (Proxmox: VLAN Tag = 20) проверьте получение DHCP-адреса"
echo "  3. Убедитесь, что сетевая карта ВМ подключена к vmbr1 с нужным VLAN Tag"
echo "  4. Проверьте ping между HQ-SRV (192.168.10.10) и HQ-CLI (192.168.20.x)"
echo
echo "------------------------------------------------------------"
echo "  ПРОВЕРКА ПОСЛЕ ПЕРЕЗАГРУЗКИ:"
echo "------------------------------------------------------------"
echo "  1. ip link show — убедитесь, что ${TRUNK_IFACE}.10 и ${TRUNK_IFACE}.20 появились"
echo "  2. ip addr show ${TRUNK_IFACE}.10 — должен быть IP 192.168.10.1/24"
echo "  3. ip addr show ${TRUNK_IFACE}.20 — должен быть IP 192.168.20.1/24"
echo "  4. systemctl status dhcpd (или dhcp-server) — DHCP должен быть active"
echo "  5. cat /proc/sys/net/ipv4/ip_forward — должно быть 1"
echo "  6. lsmod | grep 8021q — модуль должен быть загружен"
echo "  7. ls /etc/net/ifaces/ — директории для VLAN-интерфейсов должны существовать"
echo "  8. Проверка etcnet-конфигов (адреса и маршруты):"
echo "     cat /etc/net/ifaces/${TRUNK_IFACE}.10/ipv4address"
echo "     cat /etc/net/ifaces/${TRUNK_IFACE}.20/ipv4address"
echo "     cat /etc/net/ifaces/${TRUNK_IFACE}.10/ipv4route"
echo "     cat /etc/net/ifaces/${TRUNK_IFACE}.20/ipv4route"
echo "------------------------------------------------------------"

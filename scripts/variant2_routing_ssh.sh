#!/bin/bash
# Скрипт настройки Вариант 2: Маршрутизация и Безопасный доступ
# Темы: Статическая маршрутизация и SSH
# Запускается поочерёдно на HQ-RTR и BR-RTR
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
echo "  Вариант 2: Маршрутизация и Безопасный доступ"
echo "  Темы: Статическая маршрутизация и SSH"
echo "  Демоэкзамен 09.02.06 (2026)"
echo "============================================================"
echo
echo "Схема топологии:"
echo "  HQ-RTR — LAN 192.168.1.0/24, WAN 10.0.0.1/30 (провайдер)"
echo "  BR-RTR — LAN 192.168.2.0/24, WAN 10.0.0.2/30 (провайдер)"
echo "  Стык ISP: vmbr2 (Proxmox), сеть 10.0.0.0/30"
echo

# ─── Интерактивный ввод параметров ───────────────────────────────────────────
echo "На каком устройстве запущен скрипт?"
echo "  1) HQ-RTR (192.168.1.0/24, стык 10.0.0.1/30)"
echo "  2) BR-RTR (192.168.2.0/24, стык 10.0.0.2/30)"
read -rp "Выберите устройство [1]: " DEVICE_CHOICE
DEVICE_CHOICE="${DEVICE_CHOICE:-1}"

case "$DEVICE_CHOICE" in
    1)
        DEVICE_NAME="HQ-RTR"
        HOSTNAME="hq-rtr"
        LAN_NET="192.168.1.0/24"
        LAN_GW="192.168.1.1"
        ISP_LOCAL="10.0.0.1"
        ISP_REMOTE="10.0.0.2"
        REMOTE_LAN="192.168.2.0/24"
        NEXT_HOP="10.0.0.2"
        ;;
    2)
        DEVICE_NAME="BR-RTR"
        HOSTNAME="br-rtr"
        LAN_NET="192.168.2.0/24"
        LAN_GW="192.168.2.1"
        ISP_LOCAL="10.0.0.2"
        ISP_REMOTE="10.0.0.1"
        REMOTE_LAN="192.168.1.0/24"
        NEXT_HOP="10.0.0.1"
        ;;
    *)
        error "Неверный выбор устройства"
        exit 1
        ;;
esac

read -rp "WAN-интерфейс (в сторону ISP/провайдера) [eth0]: " WAN_IFACE
WAN_IFACE="${WAN_IFACE:-eth0}"

read -rp "LAN-интерфейс (локальная сеть) [eth1]: " LAN_IFACE
LAN_IFACE="${LAN_IFACE:-eth1}"

read -rp "Пользователь для SSH-доступа [admin]: " SSH_USER
SSH_USER="${SSH_USER:-admin}"

read -rsp "Пароль пользователя $SSH_USER [P@ssw0rd]: " SSH_PASS
echo
SSH_PASS="${SSH_PASS:-P@ssw0rd}"

echo
info "Параметры конфигурации ($DEVICE_NAME):"
echo "  Hostname:       ${HOSTNAME}"
echo "  WAN интерфейс: $WAN_IFACE = ${ISP_LOCAL}/30"
echo "  LAN интерфейс: $LAN_IFACE = ${LAN_GW}/24"
echo "  Маршрут:       $REMOTE_LAN via $NEXT_HOP"
echo "  SSH пользователь: $SSH_USER (root-вход запрещён)"
echo
read -rp "Продолжить? [y/N]: " CONFIRM
if [[ ! "${CONFIRM,,}" =~ ^y ]]; then
    info "Операция отменена."
    exit 0
fi

declare -A STATUS

# ─── 1. Hostname ──────────────────────────────────────────────────────────────
info "Устанавливаю hostname: ${HOSTNAME}"
hostnamectl set-hostname "$HOSTNAME"
ok "Hostname: ${HOSTNAME}"
STATUS["hostname"]="OK"

# ─── Задание 1: Настройка IP-адресов ─────────────────────────────────────────
info "[Задание 1] Настройка IP-адресов на $DEVICE_NAME..."

# WAN (стык с провайдером 10.0.0.0/30)
if command -v nmcli &>/dev/null; then
    nmcli con delete "wan-${WAN_IFACE}" &>/dev/null || true
    nmcli con add type ethernet ifname "$WAN_IFACE" con-name "wan-${WAN_IFACE}" \
        ipv4.method manual \
        ipv4.addresses "${ISP_LOCAL}/30" \
        connection.autoconnect yes
    nmcli con up "wan-${WAN_IFACE}"
else
    ip addr flush dev "$WAN_IFACE" 2>/dev/null || true
    ip addr add "${ISP_LOCAL}/30" dev "$WAN_IFACE"
    ip link set "$WAN_IFACE" up
fi
ok "WAN ($WAN_IFACE): ${ISP_LOCAL}/30"
STATUS["ip_wan"]="OK"

# LAN (локальная сеть)
if command -v nmcli &>/dev/null; then
    nmcli con delete "lan-${LAN_IFACE}" &>/dev/null || true
    nmcli con add type ethernet ifname "$LAN_IFACE" con-name "lan-${LAN_IFACE}" \
        ipv4.method manual \
        ipv4.addresses "${LAN_GW}/24" \
        connection.autoconnect yes
    nmcli con up "lan-${LAN_IFACE}"
else
    ip addr flush dev "$LAN_IFACE" 2>/dev/null || true
    ip addr add "${LAN_GW}/24" dev "$LAN_IFACE"
    ip link set "$LAN_IFACE" up
fi
ok "LAN ($LAN_IFACE): ${LAN_GW}/24"
STATUS["ip_lan"]="OK"

# ─── IP forwarding ────────────────────────────────────────────────────────────
info "Включение IP forwarding..."
if grep -q '^net.ipv4.ip_forward' /etc/sysctl.conf 2>/dev/null; then
    sed -i 's/^#*\s*net\.ipv4\.ip_forward.*/net.ipv4.ip_forward=1/' /etc/sysctl.conf
else
    echo 'net.ipv4.ip_forward=1' >> /etc/sysctl.conf
fi
sysctl -w net.ipv4.ip_forward=1 >/dev/null
ok "IP forwarding включён"
STATUS["ip_forward"]="OK"

# ─── Задание 1: Статическая маршрутизация ─────────────────────────────────────
info "[Задание 1] Настройка статического маршрута: $REMOTE_LAN via $NEXT_HOP..."

# Добавляем маршрут через nmcli (постоянный) или ip route (временный)
if command -v nmcli &>/dev/null; then
    nmcli con modify "wan-${WAN_IFACE}" \
        +ipv4.routes "${REMOTE_LAN} ${NEXT_HOP}" 2>/dev/null || true
    nmcli con up "wan-${WAN_IFACE}" 2>/dev/null || true
fi

# Временный маршрут через ip route (применяется немедленно)
ip route del "$REMOTE_LAN" 2>/dev/null || true
ip route add "$REMOTE_LAN" via "$NEXT_HOP" dev "$WAN_IFACE"
ok "Маршрут добавлен: $REMOTE_LAN via $NEXT_HOP"
STATUS["static_route"]="OK"

# Постоянный маршрут через /etc/rc.local (fallback)
if [[ ! -f /etc/rc.local ]]; then
    cat > /etc/rc.local <<EOF
#!/bin/bash
# Статические маршруты — Вариант 2
ip route add ${REMOTE_LAN} via ${NEXT_HOP} dev ${WAN_IFACE} 2>/dev/null || true
exit 0
EOF
    chmod +x /etc/rc.local
    ok "Маршрут прописан в /etc/rc.local"
elif ! grep -q "$REMOTE_LAN" /etc/rc.local; then
    sed -i "/^exit 0/i ip route add ${REMOTE_LAN} via ${NEXT_HOP} dev ${WAN_IFACE} 2>/dev/null || true" /etc/rc.local
    ok "Маршрут добавлен в /etc/rc.local"
fi

# ─── Задание 2: Создание пользователя admin ───────────────────────────────────
info "[Задание 2] Создание пользователя $SSH_USER для SSH..."

if ! id "$SSH_USER" &>/dev/null; then
    useradd -m -s /bin/bash "$SSH_USER"
    ok "Пользователь $SSH_USER создан"
else
    warn "Пользователь $SSH_USER уже существует"
fi
echo "${SSH_USER}:${SSH_PASS}" | chpasswd
ok "Пароль для $SSH_USER установлен"
STATUS["user_admin"]="OK"

# ─── Задание 2: Настройка SSH ─────────────────────────────────────────────────
info "[Задание 2] Настройка SSH: разрешён только $SSH_USER, root-вход запрещён..."

SSHD_CONF="/etc/ssh/sshd_config"
if [[ ! -f "$SSHD_CONF" ]]; then
    error "Файл $SSHD_CONF не найден"
    STATUS["ssh"]="ERROR"
else
    cp "$SSHD_CONF" "${SSHD_CONF}.bak"
    info "Резервная копия: ${SSHD_CONF}.bak"

    # Функция замены/добавления параметра в sshd_config
    set_sshd_param() {
        local param="$1" value="$2"
        if grep -qE "^#?[[:space:]]*${param}[[:space:]]" "$SSHD_CONF"; then
            sed -i "s|^#*[[:space:]]*${param}[[:space:]].*|${param} ${value}|" "$SSHD_CONF"
        else
            echo "${param} ${value}" >> "$SSHD_CONF"
        fi
    }

    # По заданию: разрешить только admin, запретить root по паролю
    set_sshd_param "AllowUsers"      "$SSH_USER"
    set_sshd_param "PermitRootLogin" "no"
    set_sshd_param "PasswordAuthentication" "yes"
    set_sshd_param "PubkeyAuthentication"   "yes"

    # Проверяем конфиг перед перезапуском
    if sshd -t 2>/dev/null; then
        ok "Конфиг SSH валиден"
    else
        warn "Конфиг SSH содержит ошибки, проверьте вручную"
    fi

    # Перезапуск sshd
    if systemctl restart sshd 2>/dev/null || systemctl restart ssh 2>/dev/null; then
        ok "sshd перезапущен"
        STATUS["ssh"]="OK"
    else
        error "Ошибка перезапуска sshd"
        STATUS["ssh"]="ERROR"
    fi
fi

# ─── Проверка маршрутизации: ping до удалённого маршрутизатора ────────────────
info "Проверка связи с удалённым маршрутизатором ($ISP_REMOTE)..."
if ping -c 3 -W 2 "$ISP_REMOTE" &>/dev/null; then
    ok "Ping до $ISP_REMOTE — УСПЕШНО (стык работает)"
    STATUS["ping_isp"]="OK"
else
    warn "Ping до $ISP_REMOTE недоступен (настройте второй маршрутизатор)"
    STATUS["ping_isp"]="SKIP"
fi

# ─── Итоговый статус ──────────────────────────────────────────────────────────
echo
echo "============================================================"
echo "  Итог: Вариант 2 — Маршрутизация и Безопасный доступ"
echo "  Устройство: $DEVICE_NAME"
echo "============================================================"
for key in hostname ip_wan ip_lan ip_forward static_route user_admin ssh ping_isp; do
    val="${STATUS[$key]:-SKIP}"
    case "$val" in
        OK)    echo -e "  ${GREEN}[OK]${NC}    $key" ;;
        ERROR) echo -e "  ${RED}[ERROR]${NC} $key" ;;
        *)     echo -e "  ${YELLOW}[SKIP]${NC}  $key" ;;
    esac
done
echo "============================================================"
echo
ok "Вариант 2 ($DEVICE_NAME) завершён!"
echo
info "Следующие шаги:"
echo "  1. Запустите этот скрипт на втором маршрутизаторе"
echo "  2. Проверьте ping: ping ${REMOTE_LAN%/*} — должен работать через ${NEXT_HOP}"
echo "  3. Проверьте SSH: ssh ${SSH_USER}@${LAN_GW}"
echo "  4. Убедитесь, что root-логин по паролю запрещён: ssh root@${LAN_GW} (должен быть отказ)"

#!/bin/bash
# Скрипт настройки HQ-CLI (Альт рабочая станция / Linux)
# Покрывает: задания 1, 3, 5
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
echo "  Настройка HQ-CLI — демоэкзамен 09.02.06 (2026)"
echo "  Задания: 1, 3, 5"
echo "============================================================"
echo

# ─── Интерактивный ввод параметров ───────────────────────────────────────────
read -rp "Имя сетевого интерфейса [eth0]: " NET_IFACE
NET_IFACE="${NET_IFACE:-eth0}"

read -rp "Часовой пояс [Europe/Moscow]: " TZ_NAME
TZ_NAME="${TZ_NAME:-Europe/Moscow}"

echo
info "Параметры конфигурации:"
echo "  Интерфейс:    $NET_IFACE (DHCP от HQ-RTR, VLAN 200)"
echo "  Ожидаемый IP: 192.168.2.x/27, шлюз 192.168.2.1"
echo "  Часовой пояс: $TZ_NAME"
echo
read -rp "Продолжить? [y/N]: " CONFIRM
if [[ ! "${CONFIRM,,}" =~ ^y ]]; then
    info "Операция отменена."
    exit 0
fi

declare -A STATUS

# ─── 1. Hostname ──────────────────────────────────────────────────────────────
info "Устанавливаю hostname: hq-cli.au-team.irpo"
hostnamectl set-hostname hq-cli.au-team.irpo
echo "hq-cli.au-team.irpo" > /etc/hostname
ok "Hostname: hq-cli.au-team.irpo"
STATUS["hostname"]="OK"

# ─── 2. Часовой пояс ─────────────────────────────────────────────────────────
info "Часовой пояс: $TZ_NAME"
if timedatectl set-timezone "$TZ_NAME" 2>/dev/null; then
    ok "Часовой пояс установлен: $TZ_NAME"
    STATUS["timezone"]="OK"
elif [[ -f "/usr/share/zoneinfo/${TZ_NAME}" ]]; then
    cp "/usr/share/zoneinfo/${TZ_NAME}" /etc/localtime
    echo "$TZ_NAME" > /etc/timezone 2>/dev/null || true
    ok "Часовой пояс установлен вручную: $TZ_NAME"
    STATUS["timezone"]="OK"
else
    error "Ошибка установки часового пояса $TZ_NAME"
    STATUS["timezone"]="ERROR"
fi

# ─── 3. IP-адресация (задание 1) — DHCP от HQ-RTR ───────────────────────────
# HQ-CLI: DHCP (192.168.2.x/27, VLAN 200), шлюз 192.168.2.1
info "[Задание 1] Настройка IP на $NET_IFACE: DHCP (VLAN 200, 192.168.2.x/27)"

if command -v nmcli &>/dev/null; then
    # Альт рабочая станция / JeOS — через nmcli
    nmcli con delete "dhcp-${NET_IFACE}" &>/dev/null || true
    nmcli con add type ethernet ifname "$NET_IFACE" con-name "dhcp-${NET_IFACE}" \
        ipv4.method auto \
        ipv4.dns "192.168.1.2" \
        connection.autoconnect yes
    nmcli con up "dhcp-${NET_IFACE}"
else
    # Альт сервер — через etcnet (/etc/net/ifaces/)
    IFACE_DIR="/etc/net/ifaces/${NET_IFACE}"
    mkdir -p "$IFACE_DIR"
    [[ -f "${IFACE_DIR}/options" ]] && cp "${IFACE_DIR}/options" "${IFACE_DIR}/options.bak"

    cat > "${IFACE_DIR}/options" <<EOF
BOOTPROTO=dhcp
TYPE=eth
ONBOOT=yes
DISABLED=no
NM_CONTROLLED=no
CONFIG_IPV4=yes
EOF

    # Немедленное применение
    ip link set "$NET_IFACE" up
    if command -v dhclient &>/dev/null; then
        dhclient "$NET_IFACE" &
    elif command -v udhcpc &>/dev/null; then
        udhcpc -i "$NET_IFACE" -b
    fi

    # Перезапуск network
    systemctl restart network 2>/dev/null || service network restart 2>/dev/null || \
        warn "Перезапустите сеть вручную: systemctl restart network"
fi
ok "Интерфейс $NET_IFACE настроен на DHCP (ожидаемый пул: 192.168.2.50–192.168.2.100)"
STATUS["ip"]="OK"

# ─── 4. Пользователь sshuser (задание 3) ─────────────────────────────────────
info "[Задание 3] Создание пользователя sshuser (uid=2026)..."
if ! id sshuser &>/dev/null; then
    useradd -u 2026 -m -s /bin/bash sshuser
    ok "Пользователь sshuser создан (uid=2026)"
else
    warn "Пользователь sshuser уже существует"
fi
echo "sshuser:P@ssw0rd" | chpasswd
echo "sshuser ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/sshuser
chmod 440 /etc/sudoers.d/sshuser
ok "Пароль sshuser установлен, sudo без пароля настроен"
STATUS["sshuser"]="OK"

# ─── 5. Настройка SSH (задание 5) ─────────────────────────────────────────────
info "[Задание 5] Настройка SSH: порт 2026, AllowUsers sshuser, MaxAuthTries 2, баннер..."

SSHD_CONF="/etc/ssh/sshd_config"
if [[ ! -f "$SSHD_CONF" ]]; then
    error "Файл $SSHD_CONF не найден. Установите openssh-server."
    STATUS["ssh"]="ERROR"
else
    cp "$SSHD_CONF" "${SSHD_CONF}.bak"
    info "Резервная копия: ${SSHD_CONF}.bak"

    # Создаём баннер
    echo "Authorized access only" > /etc/ssh/banner
    ok "Баннер создан: /etc/ssh/banner"

    # Функция установки/замены параметра sshd_config
    set_sshd_param() {
        local param="$1" value="$2"
        if grep -qE "^#?[[:space:]]*${param}[[:space:]]" "$SSHD_CONF"; then
            sed -i "s|^#*[[:space:]]*${param}[[:space:]].*|${param} ${value}|" "$SSHD_CONF"
        else
            echo "${param} ${value}" >> "$SSHD_CONF"
        fi
    }

    set_sshd_param "Port"            "2026"
    set_sshd_param "AllowUsers"      "sshuser"
    set_sshd_param "MaxAuthTries"    "2"
    set_sshd_param "PermitRootLogin" "no"
    set_sshd_param "Banner"          "/etc/ssh/banner"

    # Проверка конфига
    if sshd -t 2>/dev/null; then
        ok "Конфиг SSH валиден"
    else
        warn "Конфиг SSH может содержать ошибки — проверьте вручную"
    fi

    # Перезапуск sshd
    if systemctl restart sshd 2>/dev/null || systemctl restart ssh 2>/dev/null; then
        ok "sshd перезапущен (порт 2026)"
        STATUS["ssh"]="OK"
    else
        error "Ошибка перезапуска sshd"
        STATUS["ssh"]="ERROR"
    fi
fi

# ─── Итоговый статус ──────────────────────────────────────────────────────────
echo
echo "============================================================"
echo "  Итог настройки HQ-CLI"
echo "============================================================"
for key in hostname timezone ip sshuser ssh; do
    val="${STATUS[$key]:-SKIP}"
    case "$val" in
        OK)    echo -e "  ${GREEN}[OK]${NC}    $key" ;;
        ERROR) echo -e "  ${RED}[ERROR]${NC} $key" ;;
        *)     echo -e "  ${YELLOW}[SKIP]${NC}  $key" ;;
    esac
done
echo "============================================================"
echo
ok "Настройка HQ-CLI завершена!"
info "SSH: порт 2026, пользователь sshuser"
info "IP: DHCP (ожидаемый диапазон 192.168.2.50–192.168.2.100, шлюз 192.168.2.1)"
info "DNS: 192.168.1.2 (HQ-SRV)"

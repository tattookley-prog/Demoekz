#!/bin/bash
# Скрипт настройки BR-SRV (Альт сервер)
# Покрывает: задания 1, 3, 5
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
echo "  Настройка BR-SRV (Альт сервер) — демоэкзамен 09.02.06 (2026)"
echo "  Задания: 1, 3, 5"
echo "============================================================"
echo

# ─── Интерактивный ввод параметров ─────────────────────────────────────────
read -rp "Имя сетевого интерфейса [ens18]: " NET_IFACE
NET_IFACE="${NET_IFACE:-ens18}"

read -rp "Часовой пояс [Europe/Moscow]: " TZ_NAME
TZ_NAME="${TZ_NAME:-Europe/Moscow}"

echo
info "Параметры конфигурации:"
echo "  Интерфейс:    $NET_IFACE (192.168.3.2/28, шлюз 192.168.3.1)"
echo "  Часовой пояс: $TZ_NAME"
echo
read -rp "Продолжить? [y/N]: " CONFIRM
if [[ ! "${CONFIRM,,}" =~ ^y ]]; then
    info "Операция отменена."
    exit 0
fi

declare -A STATUS

# ─── 1. Hostname ─────────────────────────────────────────────────────────────
info "Устанавливаю hostname: br-srv.au-team.irpo"
hostnamectl set-hostname br-srv.au-team.irpo
echo "br-srv.au-team.irpo" > /etc/hostname
ok "Hostname: br-srv.au-team.irpo"
STATUS["hostname"]="OK"

# ─── 2. Часовой пояс ─────────────────────────────────────────────────────────
info "Часовой пояс: $TZ_NAME"
TZ_SET=0
# Пробуем timedatectl
if timedatectl set-timezone "$TZ_NAME" 2>/dev/null; then
    ok "Часовой пояс установлен через timedatectl: $TZ_NAME"
    TZ_SET=1
fi
# Fallback: симлинк напрямую
if [[ $TZ_SET -eq 0 ]]; then
    if [[ -f "/usr/share/zoneinfo/${TZ_NAME}" ]]; then
        ln -sf "/usr/share/zoneinfo/${TZ_NAME}" /etc/localtime
        echo "$TZ_NAME" > /etc/timezone 2>/dev/null || true
        ok "Часовой пояс установлен через symlink: $TZ_NAME"
        TZ_SET=1
    fi
fi
if [[ $TZ_SET -eq 1 ]]; then
    STATUS["timezone"]="OK"
else
    error "Не удалось установить часовой пояс: $TZ_NAME"
    STATUS["timezone"]="ERROR"
fi

# ─── 3. IP-адресация (задание 1) ─────────────────────────────────────────────
info "[Задание 1] Настройка IP на $NET_IFACE: 192.168.3.2/28, шлюз 192.168.3.1"

if command -v nmcli &>/dev/null; then
    nmcli con delete "static-${NET_IFACE}" &>/dev/null || true
    nmcli con add type ethernet ifname "$NET_IFACE" con-name "static-${NET_IFACE}" \
        ipv4.method manual \
        ipv4.addresses "192.168.3.2/28" \
        ipv4.gateway "192.168.3.1" \
        ipv4.dns "192.168.1.2" \
        connection.autoconnect yes
    nmcli con up "static-${NET_IFACE}"
else
    ip addr flush dev "$NET_IFACE" 2>/dev/null || true
    ip addr add 192.168.3.2/28 dev "$NET_IFACE"
    ip link set "$NET_IFACE" up
    ip route replace default via 192.168.3.1 2>/dev/null || true

    # DNS — указываем HQ-SRV
    RESOLV="/etc/resolv.conf"
    [[ -f "$RESOLV" ]] && cp "$RESOLV" "${RESOLV}.bak"
    cat > "$RESOLV" <<EOF
# /etc/resolv.conf — BR-SRV
search au-team.irpo
nameserver 192.168.1.2
EOF
fi
ok "IP настроен: 192.168.3.2/28, шлюз 192.168.3.1"
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

# ─── 4a. Пользователь remote_user (задание 3) ────────────────────────────────
info "[Задание 3] Создание пользователя remote_user..."
if ! id remote_user &>/dev/null; then
    useradd -m -s /bin/bash remote_user
    ok "Пользователь remote_user создан"
else
    warn "Пользователь remote_user уже существует"
fi
echo "remote_user:P@ssw0rd" | chpasswd
ok "Пароль remote_user установлен"
STATUS["remote_user"]="OK"

# ─── 5. Настройка SSH (задание 5) ─────────────────────────────────────────────
info "[Задание 5] Настройка SSH: порт 2026, AllowUsers sshuser, MaxAuthTries 2, баннер..."

# Устанавливаем openssh-server если не установлен
SSHD_CONF="/etc/ssh/sshd_config"
if [[ ! -f "$SSHD_CONF" ]]; then
    info "openssh-server не найден, устанавливаю..."
    apt-get install -y openssh-server 2>/dev/null || \
    apt-get install -y ssh 2>/dev/null || \
    yum install -y openssh-server 2>/dev/null || true
fi

if [[ ! -f "$SSHD_CONF" ]]; then
    error "Файл $SSHD_CONF не найден даже после установки"
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
        if grep -qE "^#?\s*${param}\s" "$SSHD_CONF"; then
            sed -i "s|^#*\s*${param}\s.*|${param} ${value}|" "$SSHD_CONF"
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
    if systemctl enable sshd 2>/dev/null && systemctl restart sshd 2>/dev/null; then
        ok "sshd перезапущен (порт 2026)"
        STATUS["ssh"]="OK"
    elif systemctl enable ssh 2>/dev/null && systemctl restart ssh 2>/dev/null; then
        ok "ssh перезапущен (порт 2026)"
        STATUS["ssh"]="OK"
    else
        error "Ошибка перезапуска sshd"
        STATUS["ssh"]="ERROR"
    fi
fi

# ─── Итоговый статус ────────────────────────────────────────────────────────
echo
echo "============================================================"
echo "  Итог настройки BR-SRV"
echo "============================================================"
for key in hostname timezone ip sshuser remote_user ssh; do
    val="${STATUS[$key]:-SKIP}"
    case "$val" in
        OK)    echo -e "  ${GREEN}[OK]${NC}    $key" ;;
        ERROR) echo -e "  ${RED}[ERROR]${NC} $key" ;;
        *)     echo -e "  ${YELLOW}[SKIP]${NC}  $key" ;;
    esac
done
echo "============================================================"
echo
ok "Настройка BR-SRV завершена!"
info "SSH: порт 2026, пользователь sshuser"
info "IP: 192.168.3.2/28, шлюз 192.168.3.1"

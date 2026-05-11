#!/bin/bash
# =============================================================================
# hq_cli_setup.sh — настройка HQ-CLI (ОС: Alt Workstation)
# Покрывает: задания 1, 3, 5
# Демоэкзамен 09.02.06 Сетевое и системное администрирование, 2026
#
# ОС: Alt Workstation — сеть через NetworkManager (nmcli)
# IP: DHCP от HQ-RTR (VLAN 200: 192.168.2.0/27)
# DNS: 192.168.1.2 (HQ-SRV)
#
# Запуск: bash hq_cli_setup.sh
# Требуется: root (sudo или su -)
# =============================================================================

set -euo pipefail

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

# ─── Проверка: Alt Workstation ────────────────────────────────────────────────
if [[ -f /etc/altlinux-release ]]; then
    ALT_RELEASE="$(cat /etc/altlinux-release)"
    info "ОС: ${ALT_RELEASE}"
    if grep -qi "workstation\|рабочая" /etc/altlinux-release 2>/dev/null; then
        ok "Обнаружен Alt Workstation — продолжаем"
    else
        warn "Ожидается Alt Workstation, обнаружен: ${ALT_RELEASE}"
        warn "Скрипт продолжит, но настройка сети рассчитана на nmcli (NetworkManager)"
    fi
else
    warn "Файл /etc/altlinux-release не найден — убедись что это Alt Workstation"
fi

# ─── Проверка nmcli ───────────────────────────────────────────────────────────
if ! command -v nmcli &>/dev/null; then
    error "nmcli не найден. На Alt Workstation должен быть NetworkManager."
    error "Попробуй: apt-get install -y NetworkManager"
    exit 1
fi

# Убеждаемся что sudo установлен (на голом Alt Workstation иногда нет)
if ! command -v sudo &>/dev/null; then
    info "Устанавливаю пакет sudo..."
    apt-get install -y sudo 2>/dev/null || warn "Не удалось установить sudo автоматически"
fi

echo
echo "============================================================"
echo "  Настройка HQ-CLI (Alt Workstation) — демоэкзамен 2026"
echo "  Задания: 1, 3, 5"
echo "============================================================"
echo

echo "--- Общие параметры ---"
read -rp "Имя сетевого интерфейса [eth0]: " NET_IFACE
NET_IFACE="${NET_IFACE:-eth0}"

read -rp "Часовой пояс [Europe/Moscow]: " TZ_NAME
TZ_NAME="${TZ_NAME:-Europe/Moscow}"

read -rp "DNS-домен [au-team.irpo]: " DOMAIN
DOMAIN="${DOMAIN:-au-team.irpo}"

echo
echo "--- Сеть ---"
read -rp "Режим сети: dhcp или static? [dhcp]: " NET_MODE
NET_MODE="${NET_MODE:-dhcp}"

STATIC_IP=""
STATIC_GW=""
if [[ "$NET_MODE" == "static" ]]; then
    read -rp "IP-адрес/маска [192.168.2.2/27]: " STATIC_IP
    STATIC_IP="${STATIC_IP:-192.168.2.2/27}"
    read -rp "Шлюз [192.168.2.1]: " STATIC_GW
    STATIC_GW="${STATIC_GW:-192.168.2.1}"
fi

read -rp "IP DNS-сервера (HQ-SRV) [192.168.1.2]: " DNS_IP
DNS_IP="${DNS_IP:-192.168.1.2}"

echo
echo "--- SSH ---"
read -rp "SSH порт [2026]: " SSH_PORT
SSH_PORT="${SSH_PORT:-2026}"

read -rp "SSH пользователь [sshuser]: " SSH_USER
SSH_USER="${SSH_USER:-sshuser}"

read -rp "MaxAuthTries [2]: " SSH_MAX_TRIES
SSH_MAX_TRIES="${SSH_MAX_TRIES:-2}"

read -rp "UID для ${SSH_USER} [2026]: " USER_UID
USER_UID="${USER_UID:-2026}"

read -rp "Текст SSH-баннера [Authorized access only]: " SSH_BANNER_TEXT
SSH_BANNER_TEXT="${SSH_BANNER_TEXT:-Authorized access only}"

read -rp "SSH порт для роутеров [22]: " ROUTER_SSH_PORT
ROUTER_SSH_PORT="${ROUTER_SSH_PORT:-22}"

HQ_SRV_HOST_DEFAULT="hq-srv.${DOMAIN}"
BR_SRV_HOST_DEFAULT="br-srv.${DOMAIN}"
HQ_RTR_HOST_DEFAULT="hq-rtr.${DOMAIN}"
BR_RTR_HOST_DEFAULT="br-rtr.${DOMAIN}"

echo
echo "--- SSH client config ---"
read -rp "HostName для HQ-SRV [${HQ_SRV_HOST_DEFAULT}]: " HQ_SRV_HOST
HQ_SRV_HOST="${HQ_SRV_HOST:-$HQ_SRV_HOST_DEFAULT}"

read -rp "HostName для BR-SRV [${BR_SRV_HOST_DEFAULT}]: " BR_SRV_HOST
BR_SRV_HOST="${BR_SRV_HOST:-$BR_SRV_HOST_DEFAULT}"

read -rp "HostName для HQ-RTR [${HQ_RTR_HOST_DEFAULT}]: " HQ_RTR_HOST
HQ_RTR_HOST="${HQ_RTR_HOST:-$HQ_RTR_HOST_DEFAULT}"

read -rp "HostName для BR-RTR [${BR_RTR_HOST_DEFAULT}]: " BR_RTR_HOST
BR_RTR_HOST="${BR_RTR_HOST:-$BR_RTR_HOST_DEFAULT}"

HOSTNAME_FQDN="hq-cli.${DOMAIN}"

echo
info "Параметры конфигурации:"
echo "  Hostname:      ${HOSTNAME_FQDN}"
echo "  Интерфейс:     ${NET_IFACE}"
echo "  Сеть:          ${NET_MODE}"
[[ "$NET_MODE" == "static" ]] && echo "  IP:            ${STATIC_IP}, шлюз ${STATIC_GW}"
echo "  DNS:           ${DNS_IP}, search ${DOMAIN}"
echo "  Часовой пояс:  ${TZ_NAME}"
echo "  SSH:           порт ${SSH_PORT}, user ${SSH_USER}, uid ${USER_UID}, MaxAuthTries ${SSH_MAX_TRIES}"
echo "  SSH роутеры:   порт ${ROUTER_SSH_PORT}"
echo "  SSH баннер:    ${SSH_BANNER_TEXT}"
echo "  SSH hosts:     HQ-SRV=${HQ_SRV_HOST}, BR-SRV=${BR_SRV_HOST}, HQ-RTR=${HQ_RTR_HOST}, BR-RTR=${BR_RTR_HOST}"
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

# Прописываем в /etc/hosts чтобы hostname резолвился локально
if ! grep -q "$HOSTNAME_FQDN" /etc/hosts; then
    echo "127.0.1.1  ${HOSTNAME_FQDN} hq-cli" >> /etc/hosts
fi
ok "Hostname: ${HOSTNAME_FQDN}"
STATUS["hostname"]="OK"

# ─── 2. Часовой пояс ─────────────────────────────────────────────────────────
info "Устанавливаю часовой пояс: $TZ_NAME"
if timedatectl set-timezone "$TZ_NAME" 2>/dev/null; then
    ok "Часовой пояс: $TZ_NAME"
    STATUS["timezone"]="OK"
elif [[ -f "/usr/share/zoneinfo/${TZ_NAME}" ]]; then
    rm -f /etc/localtime
    ln -sf "/usr/share/zoneinfo/${TZ_NAME}" /etc/localtime
    echo "$TZ_NAME" > /etc/timezone 2>/dev/null || true
    ok "Часовой пояс установлен через symlink: $TZ_NAME"
    STATUS["timezone"]="OK"
else
    error "Не удалось установить часовой пояс: $TZ_NAME"
    STATUS["timezone"]="ERROR"
fi

# ─── 3. Настройка сети через nmcli (задание 1) ───────────────────────────────
info "[Задание 1] Настройка сети ($NET_MODE) через nmcli..."

# Убедимся что NetworkManager запущен
systemctl enable --now NetworkManager 2>/dev/null || true

CON_NAME="hq-cli-${NET_IFACE}"
# Удаляем старое соединение если есть
nmcli con delete "$CON_NAME" &>/dev/null || true

if [[ "$NET_MODE" == "static" ]]; then
    nmcli con add type ethernet \
        ifname "$NET_IFACE" \
        con-name "$CON_NAME" \
        ipv4.method manual \
        ipv4.addresses "$STATIC_IP" \
        ipv4.gateway "$STATIC_GW" \
        ipv4.dns "$DNS_IP" \
        ipv4.dns-search "$DOMAIN" \
        connection.autoconnect yes
    ok "Сеть: статический IP $STATIC_IP, шлюз $STATIC_GW"
else
    # DHCP — адрес выдаёт HQ-RTR
    nmcli con add type ethernet \
        ifname "$NET_IFACE" \
        con-name "$CON_NAME" \
        ipv4.method auto \
        ipv4.dns "$DNS_IP" \
        ipv4.dns-search "$DOMAIN" \
        connection.autoconnect yes
    ok "Сеть: DHCP (адрес от HQ-RTR)"
fi

nmcli con up "$CON_NAME" && ok "Соединение $CON_NAME поднято" || \
    warn "Не удалось поднять соединение — возможно HQ-RTR ещё не настроен"

STATUS["network"]="OK"

# ─── 4. DNS — resolv.conf ─────────────────────────────────────────────────────
info "Настройка DNS → $DNS_IP (${DOMAIN})"
# NetworkManager управляет resolv.conf, но продублируем для надёжности
if [[ -f /etc/resolv.conf ]] && ! grep -q "immutable" /etc/resolv.conf 2>/dev/null; then
    cp /etc/resolv.conf /etc/resolv.conf.bak 2>/dev/null || true
fi
nmcli con modify "$CON_NAME" ipv4.dns "$DNS_IP" ipv4.dns-search "$DOMAIN"
ok "DNS: $DNS_IP, домен поиска: $DOMAIN"
STATUS["dns"]="OK"

# Гарантируем существование /etc/sudoers.d (на минимальном Alt Workstation может отсутствовать)
mkdir -p /etc/sudoers.d
chmod 750 /etc/sudoers.d
# Подключаем sudoers.d в основной /etc/sudoers если ещё не подключён
if [[ -f /etc/sudoers ]] && ! grep -qE "^#?includedir /etc/sudoers.d" /etc/sudoers; then
    echo "#includedir /etc/sudoers.d" >> /etc/sudoers
fi

# ─── 5. Пользователь sshuser (задание 3) ─────────────────────────────────────
info "[Задание 3] Создание пользователя ${SSH_USER} (uid=${USER_UID})..."
if ! id "$SSH_USER" &>/dev/null; then
    useradd -u "$USER_UID" -m -s /bin/bash "$SSH_USER"
    ok "Пользователь ${SSH_USER} создан (uid=${USER_UID})"
else
    warn "Пользователь ${SSH_USER} уже существует"
fi
echo "${SSH_USER}:P@ssw0rd" | chpasswd
echo "${SSH_USER} ALL=(ALL) NOPASSWD:ALL" > "/etc/sudoers.d/${SSH_USER}"
chmod 440 "/etc/sudoers.d/${SSH_USER}"
ok "Пароль ${SSH_USER} установлен, sudo без пароля настроен"
STATUS["sshuser"]="OK"

# ─── 6. Пользователь remote_user (задание 3) ──────────────────────────────────
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

# ─── 7. Настройка SSH клиента и сервера (задание 5) ──────────────────────────
info "[Задание 5] Настройка SSH..."

# На Alt Workstation openssh-server может не быть — проверяем и ставим
if ! command -v sshd &>/dev/null; then
    info "sshd не найден, устанавливаю openssh-server..."
    if apt-get install -y openssh-server 2>/dev/null; then
        ok "openssh-server установлен"
    else
        warn "Не удалось установить openssh-server (нет интернета?)"
        warn "Установи вручную: apt-get install -y openssh-server"
        STATUS["ssh"]="SKIP"
    fi
fi

if command -v sshd &>/dev/null; then
    SSHD_CONF="/etc/ssh/sshd_config"
    cp "$SSHD_CONF" "${SSHD_CONF}.bak"

    # Баннер
    echo "$SSH_BANNER_TEXT" > /etc/ssh/banner

    set_sshd_param() {
        local param="$1" value="$2"
        if grep -qE "^#?[[:space:]]*${param}[[:space:]]" "$SSHD_CONF"; then
            sed -i "s|^#*[[:space:]]*${param}[[:space:]].*|${param} ${value}|" "$SSHD_CONF"
        else
            echo "${param} ${value}" >> "$SSHD_CONF"
        fi
    }

    set_sshd_param "Port"            "$SSH_PORT"
    set_sshd_param "AllowUsers"      "$SSH_USER"
    set_sshd_param "MaxAuthTries"    "$SSH_MAX_TRIES"
    set_sshd_param "PermitRootLogin" "no"
    set_sshd_param "Banner"          "/etc/ssh/banner"

    if sshd -t 2>/dev/null; then
        ok "Конфиг SSH валиден"
    else
        warn "Конфиг SSH может содержать ошибки — проверь вручную"
    fi

    if systemctl enable --now sshd 2>/dev/null || systemctl enable --now ssh 2>/dev/null; then
        ok "sshd запущен и включён (порт ${SSH_PORT})"
        STATUS["ssh"]="OK"
    else
        error "Ошибка запуска sshd"
        STATUS["ssh"]="ERROR"
    fi
fi

# ─── 8. SSH-ключ для подключения к HQ-SRV/BR-SRV (задание 5) ─────────────────
info "[Задание 5] Генерация SSH-ключа для пользователя ${SSH_USER}..."
SSH_KEY_DIR="/home/${SSH_USER}/.ssh"
mkdir -p "$SSH_KEY_DIR"
if [[ ! -f "${SSH_KEY_DIR}/id_rsa" ]]; then
    ssh-keygen -t rsa -b 2048 -N "" -f "${SSH_KEY_DIR}/id_rsa" -C "${SSH_USER}@hq-cli" >/dev/null
    ok "SSH-ключ сгенерирован: ${SSH_KEY_DIR}/id_rsa"
else
    warn "SSH-ключ уже существует: ${SSH_KEY_DIR}/id_rsa"
fi
chown -R "${SSH_USER}:${SSH_USER}" "$SSH_KEY_DIR"
chmod 700 "$SSH_KEY_DIR"
chmod 600 "${SSH_KEY_DIR}/id_rsa"
chmod 644 "${SSH_KEY_DIR}/id_rsa.pub"

# Создаём ssh_config для удобного подключения к серверам через нестандартный порт
SSH_CLIENT_CONF="${SSH_KEY_DIR}/config"
cat > "$SSH_CLIENT_CONF" <<EOF2
# SSH client config для ${SSH_USER}@hq-cli
# Подключение: ssh hq-srv  или  ssh br-srv

Host hq-srv
    HostName ${HQ_SRV_HOST}
    User ${SSH_USER}
    Port ${SSH_PORT}
    IdentityFile ~/.ssh/id_rsa

Host br-srv
    HostName ${BR_SRV_HOST}
    User ${SSH_USER}
    Port ${SSH_PORT}
    IdentityFile ~/.ssh/id_rsa

Host hq-rtr
    HostName ${HQ_RTR_HOST}
    User net_admin
    Port ${ROUTER_SSH_PORT}

Host br-rtr
    HostName ${BR_RTR_HOST}
    User net_admin
    Port ${ROUTER_SSH_PORT}
EOF2
chmod 600 "$SSH_CLIENT_CONF"
chown "${SSH_USER}:${SSH_USER}" "$SSH_CLIENT_CONF"
ok "SSH client config создан: $SSH_CLIENT_CONF"
STATUS["ssh_key"]="OK"

info "Публичный ключ (скопируй на серверы командой ssh-copy-id):"
echo
cat "${SSH_KEY_DIR}/id_rsa.pub"
echo

# ─── Итоговый статус ──────────────────────────────────────────────────────────
echo
echo "============================================================"
echo "  Итог настройки HQ-CLI (Alt Workstation)"
echo "============================================================"
for key in hostname timezone network dns sshuser remote_user ssh ssh_key; do
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
echo
info "Полезные команды после настройки:"
echo "  Проверить IP:        ip a show $NET_IFACE"
echo "  Проверить шлюз:      ip route"
echo "  Проверить DNS:       nslookup ${HQ_SRV_HOST}"
echo "  Пинг до HQ-SRV:      ping -c3 ${DNS_IP}"
echo "  SSH на HQ-SRV:       ssh hq-srv          (через ~/.ssh/config)"
echo "  SSH на BR-SRV:       ssh br-srv          (через ~/.ssh/config)"
echo
warn "Если сеть DHCP — адрес появится только когда HQ-RTR настроен и запущен dhcpd"
warn "Копирование ключа на сервер: ssh-copy-id -p ${SSH_PORT} ${SSH_USER}@${DNS_IP}"

#!/bin/bash
# Скрипт настройки HQ-SRV (Альт сервер)
# Покрывает: задания 1, 3, 5, 10
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
echo "  Настройка HQ-SRV — демоэкзамен 09.02.06 (2026)"
echo "  Задания: 1, 3, 5, 10"
echo "============================================================"
echo

# ─── Интерактивный ввод параметров ───────────────────────────────────────────
read -rp "Имя сетевого интерфейса [eth0]: " NET_IFACE
NET_IFACE="${NET_IFACE:-eth0}"

read -rp "Часовой пояс [Europe/Moscow]: " TZ_NAME
TZ_NAME="${TZ_NAME:-Europe/Moscow}"

echo
echo "--- DNS-записи (Задание 10) ---"
echo "Введите IP-адреса устройств для зоны DNS au-team.irpo:"
read -rp "IP HQ-RTR [192.168.1.1]: "   IP_HQ_RTR;  IP_HQ_RTR="${IP_HQ_RTR:-192.168.1.1}"
read -rp "IP BR-RTR [192.168.3.1]: "   IP_BR_RTR;  IP_BR_RTR="${IP_BR_RTR:-192.168.3.1}"
read -rp "IP HQ-SRV [192.168.1.2]: "   IP_HQ_SRV;  IP_HQ_SRV="${IP_HQ_SRV:-192.168.1.2}"
read -rp "IP HQ-CLI [192.168.2.x] [192.168.2.2]: " IP_HQ_CLI; IP_HQ_CLI="${IP_HQ_CLI:-192.168.2.2}"
read -rp "IP BR-SRV [192.168.3.2]: "   IP_BR_SRV;  IP_BR_SRV="${IP_BR_SRV:-192.168.3.2}"
read -rp "IP ISP→HQ (docker) [172.16.1.1]: " IP_DOCKER; IP_DOCKER="${IP_DOCKER:-172.16.1.1}"
read -rp "IP ISP→BR (web)    [172.16.2.1]: " IP_WEB;    IP_WEB="${IP_WEB:-172.16.2.1}"

echo
info "Параметры конфигурации:"
echo "  Интерфейс:  $NET_IFACE (192.168.1.2/27, шлюз 192.168.1.1)"
echo "  Часовой пояс: $TZ_NAME"
echo "  DNS зона:   au-team.irpo"
echo
read -rp "Продолжить? [y/N]: " CONFIRM
if [[ ! "${CONFIRM,,}" =~ ^y ]]; then
    info "Операция отменена."
    exit 0
fi

declare -A STATUS

# ─── 1. Hostname ──────────────────────────────────────────────────────────────
info "Устанавливаю hostname: hq-srv.au-team.irpo"
hostnamectl set-hostname hq-srv.au-team.irpo
ok "Hostname: hq-srv.au-team.irpo"
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
info "[Задание 1] Настройка IP на $NET_IFACE: 192.168.1.2/27, шлюз 192.168.1.1"
if command -v nmcli &>/dev/null; then
    nmcli con delete "static-${NET_IFACE}" &>/dev/null || true
    nmcli con add type ethernet ifname "$NET_IFACE" con-name "static-${NET_IFACE}" \
        ipv4.method manual \
        ipv4.addresses "192.168.1.2/27" \
        ipv4.gateway "192.168.1.1" \
        ipv4.dns "127.0.0.1" \
        connection.autoconnect yes
    nmcli con up "static-${NET_IFACE}"
else
    ip addr flush dev "$NET_IFACE" 2>/dev/null || true
    ip addr add 192.168.1.2/27 dev "$NET_IFACE"
    ip link set "$NET_IFACE" up
    ip route add default via 192.168.1.1 2>/dev/null || true
fi
ok "IP настроен: 192.168.1.2/27, шлюз 192.168.1.1"
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

SSHD_CONF="/etc/ssh/sshd_config"
if [[ ! -f "$SSHD_CONF" ]]; then
    error "Файл $SSHD_CONF не найден"
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
        if grep -qE "^#?${param}" "$SSHD_CONF"; then
            sed -i "s|^#*\s*${param}.*|${param} ${value}|" "$SSHD_CONF"
        else
            echo "${param} ${value}" >> "$SSHD_CONF"
        fi
    }

    set_sshd_param "Port"           "2026"
    set_sshd_param "AllowUsers"     "sshuser"
    set_sshd_param "MaxAuthTries"   "2"
    set_sshd_param "PermitRootLogin" "no"
    set_sshd_param "Banner"         "/etc/ssh/banner"

    # Проверяем конфиг
    if sshd -t 2>/dev/null; then
        ok "Конфиг SSH валиден"
    else
        warn "Конфиг SSH содержит ошибки, проверьте вручную"
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

# ─── 6. DNS-сервер (задание 10) ──────────────────────────────────────────────
info "[Задание 10] Настройка DNS-сервера bind/named..."

# Установка bind если не установлен
if ! command -v named &>/dev/null; then
    info "Установка bind..."
    apt-get install -y bind || apt-get install -y bind9 || {
        error "Не удалось установить bind/bind9"
        STATUS["dns"]="ERROR"
    }
fi

if command -v named &>/dev/null || [[ -d /etc/bind ]] || [[ -d /var/named ]]; then
    # Определяем пути (Альт Линукс vs Debian)
    if [[ -f /etc/named.conf ]] || [[ -d /var/named ]]; then
        NAMED_CONF="/etc/named.conf"
        ZONE_DIR="/var/named"
        NAMED_USER="named"
    else
        NAMED_CONF="/etc/bind/named.conf.local"
        ZONE_DIR="/var/lib/bind"
        NAMED_USER="bind"
        mkdir -p "$ZONE_DIR"
    fi

    # Резервные копии
    [[ -f "$NAMED_CONF" ]] && cp "$NAMED_CONF" "${NAMED_CONF}.bak"

    # Определяем последний октет для PTR-записей
    IFS='.' read -ra HQ_SRV_OCTETS <<< "$IP_HQ_SRV"
    IFS='.' read -ra HQ_RTR_OCTETS <<< "$IP_HQ_RTR"
    IFS='.' read -ra HQ_CLI_OCTETS <<< "$IP_HQ_CLI"

    # ── named.conf ──
    info "Генерирую $NAMED_CONF..."
    cat > "$NAMED_CONF" <<EOF
// named.conf — HQ-SRV DNS-сервер
// Демоэкзамен 09.02.06 (2026)

options {
    listen-on { any; };
    directory "/var/named";
    allow-query { any; };
    recursion yes;
    forwarders {
        77.88.8.7;
        77.88.8.3;
    };
    forward only;
    dnssec-validation no;
};

// Зона прямого просмотра
zone "au-team.irpo" IN {
    type master;
    file "${ZONE_DIR}/au-team.irpo.zone";
    allow-update { none; };
};

// Зона обратного просмотра для 192.168.1.x
zone "1.168.192.in-addr.arpa" IN {
    type master;
    file "${ZONE_DIR}/192.168.1.zone";
    allow-update { none; };
};
EOF
    ok "Сгенерирован $NAMED_CONF"

    # Для Debian-based добавляем include в основной named.conf
    if [[ "$NAMED_CONF" == "/etc/bind/named.conf.local" ]]; then
        MAIN_CONF="/etc/bind/named.conf"
        if [[ -f "$MAIN_CONF" ]] && ! grep -q "named.conf.local" "$MAIN_CONF"; then
            echo 'include "/etc/bind/named.conf.local";' >> "$MAIN_CONF"
        fi
        # Обновляем путь к каталогу зон в options
        OPTS_CONF="/etc/bind/named.conf.options"
        if [[ -f "$OPTS_CONF" ]]; then
            cp "$OPTS_CONF" "${OPTS_CONF}.bak"
            cat > "$OPTS_CONF" <<EOF
options {
    directory "/var/cache/bind";
    forwarders {
        77.88.8.7;
        77.88.8.3;
    };
    forward only;
    dnssec-validation no;
    listen-on { any; };
    allow-query { any; };
};
EOF
        fi
        ZONE_DIR="/var/lib/bind"
    fi

    # ── Зона прямого просмотра ──
    info "Генерирую файл прямой зоны: ${ZONE_DIR}/au-team.irpo.zone"
    mkdir -p "$ZONE_DIR"

    cat > "${ZONE_DIR}/au-team.irpo.zone" <<EOF
\$TTL 3600
@   IN  SOA hq-srv.au-team.irpo. admin.au-team.irpo. (
            2026031301  ; Serial (год+месяц+день+номер)
            3600        ; Refresh
            900         ; Retry
            604800      ; Expire
            3600 )      ; Minimum TTL

; Серверы имён
    IN  NS  hq-srv.au-team.irpo.

; A-записи устройств (Таблица 3)
hq-rtr    IN  A   ${IP_HQ_RTR}
br-rtr    IN  A   ${IP_BR_RTR}
hq-srv    IN  A   ${IP_HQ_SRV}
hq-cli    IN  A   ${IP_HQ_CLI}
br-srv    IN  A   ${IP_BR_SRV}
docker    IN  A   ${IP_DOCKER}
web       IN  A   ${IP_WEB}
EOF
    ok "Сгенерирована прямая зона: au-team.irpo"

    # ── Зона обратного просмотра для 192.168.1.x ──
    info "Генерирую файл обратной зоны: ${ZONE_DIR}/192.168.1.zone"

    cat > "${ZONE_DIR}/192.168.1.zone" <<EOF
\$TTL 3600
@   IN  SOA hq-srv.au-team.irpo. admin.au-team.irpo. (
            2026031301  ; Serial
            3600        ; Refresh
            900         ; Retry
            604800      ; Expire
            3600 )      ; Minimum TTL

; Серверы имён
    IN  NS  hq-srv.au-team.irpo.

; PTR-записи (только для 192.168.1.x)
${HQ_RTR_OCTETS[3]}   IN  PTR hq-rtr.au-team.irpo.
${HQ_SRV_OCTETS[3]}   IN  PTR hq-srv.au-team.irpo.
EOF

    # Добавляем PTR для HQ-CLI если он в 192.168.1.x
    IFS='.' read -ra HQ_CLI_OCTS <<< "$IP_HQ_CLI"
    if [[ "${HQ_CLI_OCTS[0]}.${HQ_CLI_OCTS[1]}.${HQ_CLI_OCTS[2]}" == "192.168.1" ]]; then
        echo "${HQ_CLI_OCTS[3]}   IN  PTR hq-cli.au-team.irpo." >> "${ZONE_DIR}/192.168.1.zone"
    fi
    ok "Сгенерирована обратная зона: 192.168.1.x"

    # Устанавливаем права на файлы зон
    chown -R "${NAMED_USER}:${NAMED_USER}" "$ZONE_DIR" 2>/dev/null || true
    chmod 640 "${ZONE_DIR}/au-team.irpo.zone" "${ZONE_DIR}/192.168.1.zone" 2>/dev/null || true

    # Запускаем named
    for svc in named bind9; do
        if systemctl enable --now "$svc" 2>/dev/null; then
            ok "DNS-сервер ($svc) запущен и включён"
            STATUS["dns"]="OK"
            break
        fi
    done
    STATUS["dns"]="${STATUS[dns]:-ERROR}"
else
    warn "bind/named не найден, пропускаю настройку DNS"
    STATUS["dns"]="SKIP"
fi

# ─── Итоговый статус ──────────────────────────────────────────────────────────
echo
echo "============================================================"
echo "  Итог настройки HQ-SRV"
echo "============================================================"
for key in hostname timezone ip sshuser remote_user ssh dns; do
    val="${STATUS[$key]:-SKIP}"
    case "$val" in
        OK)    echo -e "  ${GREEN}[OK]${NC}    $key" ;;
        ERROR) echo -e "  ${RED}[ERROR]${NC} $key" ;;
        *)     echo -e "  ${YELLOW}[SKIP]${NC}  $key" ;;
    esac
done
echo "============================================================"
echo
ok "Настройка HQ-SRV завершена!"
info "SSH: порт 2026, пользователь sshuser"
info "DNS: зона au-team.irpo, форвардеры 77.88.8.7, 77.88.8.3"

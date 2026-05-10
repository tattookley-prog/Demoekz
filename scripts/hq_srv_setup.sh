#!/bin/bash
# Скрипт настройки HQ-SRV (Альт сервер)
# Покрывает: задания 1, 3, 5, 10
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
echo "  Настройка HQ-SRV — демоэкзамен 09.02.06 (2026)"
echo "  Задания: 1, 3, 5, 10"
echo "============================================================"
echo

# ─── Интерактивный ввод параметров ─────────────────────────────────────────
read -rp "Имя сетевого интерфейса [ens18]: " NET_IFACE
NET_IFACE="${NET_IFACE:-ens18}"

read -rp "Часовой пояс [Europe/Moscow]: " TZ_NAME
TZ_NAME="${TZ_NAME:-Europe/Moscow}"

echo
echo "--- DNS-записи (Задание 10) ---"
echo "Введите IP-адреса устройств для зоны DNS au-team.irpo:"
read -rp "IP HQ-RTR [192.168.1.1]: "   IP_HQ_RTR;  IP_HQ_RTR="${IP_HQ_RTR:-192.168.1.1}"
read -rp "IP BR-RTR [192.168.3.1]: "   IP_BR_RTR;  IP_BR_RTR="${IP_BR_RTR:-192.168.3.1}"
read -rp "IP HQ-SRV [192.168.1.2]: "   IP_HQ_SRV;  IP_HQ_SRV="${IP_HQ_SRV:-192.168.1.2}"
read -rp "IP HQ-CLI [192.168.2.2]: "   IP_HQ_CLI;  IP_HQ_CLI="${IP_HQ_CLI:-192.168.2.2}"
read -rp "IP BR-SRV [192.168.3.2]: "   IP_BR_SRV;  IP_BR_SRV="${IP_BR_SRV:-192.168.3.2}"
read -rp "IP ISP→HQ (docker) [172.16.1.1]: " IP_DOCKER; IP_DOCKER="${IP_DOCKER:-172.16.1.1}"
read -rp "IP ISP→BR (web)    [172.16.2.1]: " IP_WEB;    IP_WEB="${IP_WEB:-172.16.2.1}"

echo
info "Параметры конфигурации:"
echo "  Интерфейс:    $NET_IFACE (192.168.1.2/27, шлюз 192.168.1.1)"
echo "  Часовой пояс: $TZ_NAME"
echo "  DNS зона:     au-team.irpo"
echo
read -rp "Продолжить? [y/N]: " CONFIRM
if [[ ! "${CONFIRM,,}" =~ ^y ]]; then
    info "Операция отменена."
    exit 0
fi

declare -A STATUS

# ─── 1. Hostname ─────────────────────────────────────────────────────────────
info "Устанавливаю hostname: hq-srv.au-team.irpo"
hostnamectl set-hostname hq-srv.au-team.irpo
ok "Hostname: hq-srv.au-team.irpo"
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
    ip route replace default via 192.168.1.1 2>/dev/null || true
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

    # Проверяем конфиг
    if sshd -t 2>/dev/null; then
        ok "Конфиг SSH валиден"
    else
        warn "Конфиг SSH содержит ошибки, проверьте вручную"
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

# ─── 6. DNS-сервер (задание 10) ──────────────────────────────────────────────
info "[Задание 10] Настройка DNS-сервера bind/named..."

# Устанавливаем bind если не установлен
if ! command -v named &>/dev/null; then
    info "Установка bind..."
    apt-get install -y bind 2>/dev/null || \
    apt-get install -y bind9 2>/dev/null || \
    yum install -y bind 2>/dev/null || {
        error "Не удалось установить bind/bind9"
        STATUS["dns"]="ERROR"
    }
fi

if command -v named &>/dev/null; then
    # Определяем систему: Альт Линукс или Debian-based
    if [[ -d /var/named ]] || [[ -f /etc/named.conf ]]; then
        # Альт Линукс / RHEL-based
        NAMED_CONF="/etc/named.conf"
        ZONE_DIR="/var/named"
        NAMED_USER="named"
        info "Обнаружена Альт/RHEL-система, пути: $NAMED_CONF, $ZONE_DIR"
    else
        # Debian/Ubuntu-based
        NAMED_CONF="/etc/bind/named.conf.local"
        ZONE_DIR="/var/lib/bind"
        NAMED_USER="bind"
        mkdir -p "$ZONE_DIR"
        info "Обнаружена Debian-система, пути: $NAMED_CONF, $ZONE_DIR"
    fi

    mkdir -p "$ZONE_DIR"
    [[ -f "$NAMED_CONF" ]] && cp "$NAMED_CONF" "${NAMED_CONF}.bak"

    # Разбираем октеты IP для PTR
    IFS='.' read -ra HQ_SRV_OCTETS <<< "$IP_HQ_SRV"
    IFS='.' read -ra HQ_RTR_OCTETS <<< "$IP_HQ_RTR"

    # ── named.conf (для Альт Линукс — полный, для Debian — только зоны) ──
    if [[ "$NAMED_CONF" == "/etc/named.conf" ]]; then
        cat > "$NAMED_CONF" <<EOF
// named.conf — HQ-SRV DNS-сервер
// Демоэкзамен 09.02.06 (2026)

options {
    listen-on { any; };
    listen-on-v6 { any; };
    directory "${ZONE_DIR}";
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
    else
        # Debian: пишем только зоны в named.conf.local
        cat > "$NAMED_CONF" <<EOF
// named.conf.local — HQ-SRV DNS зоны
// Демоэкзамен 09.02.06 (2026)

zone "au-team.irpo" IN {
    type master;
    file "${ZONE_DIR}/au-team.irpo.zone";
    allow-update { none; };
};

zone "1.168.192.in-addr.arpa" IN {
    type master;
    file "${ZONE_DIR}/192.168.1.zone";
    allow-update { none; };
};
EOF
        # Настраиваем options (форвардеры)
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
    recursion yes;
};
EOF
        fi
    fi
    ok "Сгенерирован $NAMED_CONF"

    # ── Зона прямого просмотра ──
    info "Генерирую прямую зону: ${ZONE_DIR}/au-team.irpo.zone"
    cat > "${ZONE_DIR}/au-team.irpo.zone" <<EOF
\$TTL 3600
@   IN  SOA hq-srv.au-team.irpo. admin.au-team.irpo. (
            2026031301  ; Serial
            3600        ; Refresh
            900         ; Retry
            604800      ; Expire
            3600 )      ; Minimum TTL

    IN  NS  hq-srv.au-team.irpo.

hq-rtr  IN  A   ${IP_HQ_RTR}
br-rtr  IN  A   ${IP_BR_RTR}
hq-srv  IN  A   ${IP_HQ_SRV}
hq-cli  IN  A   ${IP_HQ_CLI}
br-srv  IN  A   ${IP_BR_SRV}
docker  IN  A   ${IP_DOCKER}
web     IN  A   ${IP_WEB}
EOF
    ok "Прямая зона au-team.irpo создана"

    # ── Зона обратного просмотра 192.168.1.x ──
    info "Генерирую обратную зону: ${ZONE_DIR}/192.168.1.zone"
    cat > "${ZONE_DIR}/192.168.1.zone" <<EOF
\$TTL 3600
@   IN  SOA hq-srv.au-team.irpo. admin.au-team.irpo. (
            2026031301  ; Serial
            3600        ; Refresh
            900         ; Retry
            604800      ; Expire
            3600 )      ; Minimum TTL

    IN  NS  hq-srv.au-team.irpo.

${HQ_RTR_OCTETS[3]}  IN  PTR hq-rtr.au-team.irpo.
${HQ_SRV_OCTETS[3]}  IN  PTR hq-srv.au-team.irpo.
EOF
    # Добавляем PTR для HQ-CLI если он в 192.168.1.x
    IFS='.' read -ra HQ_CLI_OCTS <<< "$IP_HQ_CLI"
    if [[ "${HQ_CLI_OCTS[0]}.${HQ_CLI_OCTS[1]}.${HQ_CLI_OCTS[2]}" == "192.168.1" ]]; then
        echo "${HQ_CLI_OCTS[3]}  IN  PTR hq-cli.au-team.irpo." >> "${ZONE_DIR}/192.168.1.zone"
    fi
    ok "Обратная зона 192.168.1.x создана"

    # Права на файлы зон
    chown -R "${NAMED_USER}:${NAMED_USER}" "$ZONE_DIR" 2>/dev/null || true
    chmod 640 "${ZONE_DIR}/au-team.irpo.zone" "${ZONE_DIR}/192.168.1.zone" 2>/dev/null || true

    # Проверка конфига
    if named-checkconf 2>/dev/null; then
        ok "Конфиг named валиден"
    else
        warn "named-checkconf выявил ошибки, проверьте вручную"
    fi

    # Запуск
    for svc in named bind9; do
        if systemctl enable --now "$svc" 2>/dev/null; then
            ok "DNS-сервер ($svc) запущен и включён"
            STATUS["dns"]="OK"
            break
        fi
    done
    STATUS["dns"]="${STATUS[dns]:-ERROR}"
else
    warn "bind/named не найден после установки, пропускаю DNS"
    STATUS["dns"]="SKIP"
fi

# ─── Итоговый статус ────────────────────────────────────────────────────────
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

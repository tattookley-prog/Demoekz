#!/bin/bash
# Скрипт настройки BR-SRV (Альт сервер)
# Покрывает: задания 1, 3, 5, 10
# Демоэкзамен 09.02.06 Сетевое и системное администрирование, 2026

set -euo pipefail

# ─── Цветной вывод ─────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'
NC='\033[0m'

info()  { echo -e "${CYAN}[INFO]${NC}  $*"; }
ok()    { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }

# ─── Проверка root ──────────────────────────────────────────────────────
if [[ $EUID -ne 0 ]]; then
    error "Скрипт должен быть запущен от имени root (sudo или su -)"
    exit 1
fi

echo
echo "============================================================"
echo "  Настройка BR-SRV (Альт сервер) — демоэкзамен 09.02.06 (2026)"
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
echo "  Интерфейс:    $NET_IFACE (192.168.3.2/28, шлюз 192.168.3.1)"
echo "  Часовой пояс: $TZ_NAME"
echo "  DNS зона:     au-team.irpo"
echo
read -rp "Продолжить? [y/N]: " CONFIRM
if [[ ! "${CONFIRM,,}" =~ ^y ]]; then
    info "Операция отменена."
    exit 0
fi

declare -A STATUS

# ─── 1. Hostname ─────────────────────────────────────────────────────────
info "Устанавливаю hostname: br-srv.au-team.irpo"
hostnamectl set-hostname br-srv.au-team.irpo
echo "br-srv.au-team.irpo" > /etc/hostname
ok "Hostname: br-srv.au-team.irpo"
STATUS["hostname"]="OK"

# ─── 2. Часовой пояс ────────────────────────────────────────────────────
info "Часовой пояс: $TZ_NAME"
TZ_SET=0
if timedatectl set-timezone "$TZ_NAME" 2>/dev/null; then
    ok "Часовой пояс установлен через timedatectl: $TZ_NAME"
    TZ_SET=1
fi
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

# ─── 3. IP-адресация (задание 1) — Альт Линукс /etc/net/ifaces ──────────────
info "[Задание 1] Настройка IP на $NET_IFACE: 192.168.3.2/28, шлюз 192.168.3.1"
INET_DIR="/etc/net/ifaces/${NET_IFACE}"
mkdir -p "$INET_DIR"

cat > "${INET_DIR}/options" <<EOF
NM_CONTROLLED=no
DISABLED=no
BOOTPROTO=static
TYPE=eth
CONFIG_IPV4=yes
EOF

echo "192.168.3.2/28" > "${INET_DIR}/ipv4address"
echo "default via 192.168.3.1" > "${INET_DIR}/ipv4route"

# Применяем сразу без ребута
ip addr flush dev "$NET_IFACE" 2>/dev/null || true
ip addr add 192.168.3.2/28 dev "$NET_IFACE" 2>/dev/null || true
ip link set "$NET_IFACE" up 2>/dev/null || true
ip route replace default via 192.168.3.1 2>/dev/null || true

# resolv.conf НЕ трогаем здесь — пропишем после запуска dnsmasq
ok "IP настроен: 192.168.3.2/28, шлюз 192.168.3.1 (сохранено в /etc/net/ifaces)"
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

if [[ -f /etc/openssh/sshd_config ]]; then
    SSHD_CONF="/etc/openssh/sshd_config"
    SSH_DIR="/etc/openssh"
elif [[ -f /etc/ssh/sshd_config ]]; then
    SSHD_CONF="/etc/ssh/sshd_config"
    SSH_DIR="/etc/ssh"
else
    info "openssh-server не найден, устанавливаю..."
    apt-get install -y openssh-server 2>/dev/null || \
    apt-get install -y openssh 2>/dev/null || \
    yum install -y openssh-server 2>/dev/null || true
    if [[ -f /etc/openssh/sshd_config ]]; then
        SSHD_CONF="/etc/openssh/sshd_config"
        SSH_DIR="/etc/openssh"
    elif [[ -f /etc/ssh/sshd_config ]]; then
        SSHD_CONF="/etc/ssh/sshd_config"
        SSH_DIR="/etc/ssh"
    else
        SSHD_CONF=""
        SSH_DIR=""
    fi
fi

if [[ -z "$SSHD_CONF" ]]; then
    error "Файл sshd_config не найден даже после установки"
    STATUS["ssh"]="ERROR"
else
    info "Используем конфиг: $SSHD_CONF"
    cp "$SSHD_CONF" "${SSHD_CONF}.bak"
    info "Резервная копия: ${SSHD_CONF}.bak"

    echo "Authorized access only" > "${SSH_DIR}/banner"
    ok "Баннер создан: ${SSH_DIR}/banner"

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
    set_sshd_param "Banner"          "${SSH_DIR}/banner"

    if sshd -t 2>/dev/null; then
        ok "Конфиг SSH валиден"
    else
        warn "Конфиг SSH может содержать ошибки — проверьте вручную"
    fi

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

# ─── 6. DNS-сервер через dnsmasq (задание 10) ────────────────────────────────
info "[Задание 10] Настройка DNS-сервера dnsmasq..."

systemctl stop bind named bind9 2>/dev/null || true
systemctl disable bind named bind9 2>/dev/null || true
service bind stop 2>/dev/null || true

if ! command -v dnsmasq &>/dev/null; then
    info "Установка dnsmasq..."
    apt-get install -y dnsmasq 2>/dev/null || \
    yum install -y dnsmasq 2>/dev/null || {
        error "Не удалось установить dnsmasq"
        STATUS["dns"]="ERROR"
    }
fi

if command -v dnsmasq &>/dev/null; then
    systemctl stop systemd-resolved 2>/dev/null || true
    systemctl disable systemd-resolved 2>/dev/null || true

    if [[ -f /etc/sysconfig/dnsmasq ]]; then
        echo 'OPTIONS=""' > /etc/sysconfig/dnsmasq
    fi

    info "Генерирую /etc/dnsmasq.conf"
    cat > /etc/dnsmasq.conf <<EOF
# dnsmasq конфиг — BR-SRV DNS-сервер
# Демоэкзамен 09.02.06 (2026)

no-resolv
no-poll
no-hosts

server=77.88.8.7
server=77.88.8.3

cache-size=1000
all-servers
no-negcache

host-record=hq-rtr.au-team.irpo,${IP_HQ_RTR}
host-record=hq-srv.au-team.irpo,${IP_HQ_SRV}
host-record=hq-cli.au-team.irpo,${IP_HQ_CLI}
host-record=br-rtr.au-team.irpo,${IP_BR_RTR}
host-record=br-srv.au-team.irpo,${IP_BR_SRV}
host-record=docker.au-team.irpo,${IP_DOCKER}
host-record=web.au-team.irpo,${IP_WEB}

ptr-record=$(echo "$IP_BR_RTR" | awk -F. '{print $4"."$3"."$2"."$1}').in-addr.arpa,br-rtr.au-team.irpo
ptr-record=$(echo "$IP_BR_SRV" | awk -F. '{print $4"."$3"."$2"."$1}').in-addr.arpa,br-srv.au-team.irpo
ptr-record=$(echo "$IP_HQ_SRV" | awk -F. '{print $4"."$3"."$2"."$1}').in-addr.arpa,hq-srv.au-team.irpo
EOF

    ok "Конфиг /etc/dnsmasq.conf создан"

    DNS_STARTED=0
    if systemctl enable --now dnsmasq 2>/dev/null; then
        ok "dnsmasq запущен через systemctl"
        DNS_STARTED=1
    elif service dnsmasq start 2>/dev/null; then
        chkconfig dnsmasq on 2>/dev/null || true
        ok "dnsmasq запущен через service"
        DNS_STARTED=1
    fi

    if [[ $DNS_STARTED -eq 1 ]]; then
        # Пишем resolv.conf только ПОСЛЕ успешного запуска dnsmasq
        cat > /etc/resolv.conf <<EOF
search au-team.irpo
nameserver 127.0.0.1
EOF
        ok "resolv.conf обновлён → nameserver 127.0.0.1"
        sleep 1
        if dig +short br-srv.au-team.irpo @127.0.0.1 &>/dev/null; then
            ok "DNS отвечает: br-srv.au-team.irpo → ${IP_BR_SRV}"
        else
            warn "dnsmasq запущен, но dig не отвечает — проверьте вручную"
        fi
        STATUS["dns"]="OK"
    else
        error "Не удалось запустить dnsmasq"
        STATUS["dns"]="ERROR"
    fi
else
    warn "dnsmasq не найден после установки, пропускаю DNS"
    STATUS["dns"]="SKIP"
fi

# ─── Итоговый статус ───────────────────────────────────────────────────
echo
echo "============================================================"
echo "  Итог настройки BR-SRV"
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
ok "Настройка BR-SRV завершена!"
info "SSH: порт 2026, пользователь sshuser, конфиг: $SSHD_CONF"
info "DNS: dnsmasq, зона au-team.irpo, форвардеры 77.88.8.7, 77.88.8.3"
info "IP сохранён в: /etc/net/ifaces/${NET_IFACE} (переживёт ребут)"

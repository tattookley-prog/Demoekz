#!/bin/bash
# Скрипт настройки Вариант 4: Туннелирование и Имена узлов
# Темы: GRE/IPIP туннели и DNS
# Запускается поочерёдно на HQ-RTR/BR-RTR и HQ-SRV
# Демоэкзамен 09.02.06 Сетевое и системное администрирование, 2026
#
# ─── Совместимость с операционными системами ──────────────────────────────────
# ✔ Альт Линукс JeOS / Альт сервер    — основная целевая ОС (apt-get, nmcli, bind/named)
# ✔ Debian 11/12 (Bullseye/Bookworm)  — полная поддержка (nmcli, bind9)
# ✔ Ubuntu 20.04/22.04/24.04 LTS      — полная поддержка (nmcli, bind9)
# ✔ Любой Linux с iproute2            — туннель через ip tunnel (без nmcli, временный)
# △ Linux без NetworkManager          — туннель через ip tunnel + rc.local (постоянство
#                                        после перезагрузки требует ручной проверки)
# ✘ EcoRouter                         — только CLI EcoRouter, этот скрипт неприменим
# ✘ Windows / macOS                   — bash-скрипт, не поддерживается
#
# Требуемые пакеты:
#   iproute2 (ip tunnel), nmcli (NetworkManager) — для туннеля
#   bind или bind9 (named) — для DNS-сервера

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
echo "  Вариант 4: Туннелирование и Имена узлов"
echo "  Темы: GRE/IPIP туннели и DNS"
echo "  Демоэкзамен 09.02.06 (2026)"
echo "============================================================"
echo
echo "Схема топологии:"
echo "  HQ-RTR (WAN: например 10.10.10.1) ──[GRE]──  BR-RTR (WAN: например 10.10.10.2)"
echo "  Туннель gre0: HQ-RTR=172.16.0.1/30 ↔ BR-RTR=172.16.0.2/30"
echo "  HQ-SRV: DNS-сервер, зона lab.local"
echo

# ─── Интерактивный ввод: режим работы ────────────────────────────────────────
echo "Режим работы:"
echo "  1) Настройка GRE-туннеля на маршрутизаторе (HQ-RTR или BR-RTR)"
echo "  2) Настройка DNS-сервера (HQ-SRV)"
echo "  3) Оба (туннель + DNS, для варианта, когда оба на одном хосте)"
read -rp "Выберите режим [1]: " MODE_CHOICE
MODE_CHOICE="${MODE_CHOICE:-1}"

declare -A STATUS

# ═══════════════════════════════════════════════════════════════════════════════
# РЕЖИМ 1/3: Настройка GRE-туннеля
# ═══════════════════════════════════════════════════════════════════════════════
if [[ "$MODE_CHOICE" == "1" || "$MODE_CHOICE" == "3" ]]; then

    echo
    echo "--- Настройка GRE-туннеля ---"
    echo "На каком устройстве запущен скрипт?"
    echo "  1) HQ-RTR (туннельный адрес 172.16.0.1/30)"
    echo "  2) BR-RTR (туннельный адрес 172.16.0.2/30)"
    read -rp "Выберите устройство [1]: " DEVICE_CHOICE
    DEVICE_CHOICE="${DEVICE_CHOICE:-1}"

    case "$DEVICE_CHOICE" in
        1)
            DEVICE_NAME="HQ-RTR"
            TUN_LOCAL_IP="172.16.0.1"
            TUN_REMOTE_IP="172.16.0.2"
            ;;
        2)
            DEVICE_NAME="BR-RTR"
            TUN_LOCAL_IP="172.16.0.2"
            TUN_REMOTE_IP="172.16.0.1"
            ;;
        *)
            error "Неверный выбор устройства"
            exit 1
            ;;
    esac

    read -rp "WAN-интерфейс (через который строится туннель) [eth0]: " WAN_IFACE
    WAN_IFACE="${WAN_IFACE:-eth0}"

    # Определяем внешний IP WAN-интерфейса автоматически
    WAN_IP_AUTO=$(ip -4 addr show "$WAN_IFACE" 2>/dev/null \
        | grep -oP '(?<=inet\s)\d+\.\d+\.\d+\.\d+' | head -1 || echo "")

    read -rp "Внешний IP этого маршрутизатора на $WAN_IFACE [${WAN_IP_AUTO:-10.10.10.1}]: " WAN_LOCAL
    WAN_LOCAL="${WAN_LOCAL:-${WAN_IP_AUTO:-10.10.10.1}}"

    read -rp "Внешний IP удалённого маршрутизатора [10.10.10.2]: " WAN_REMOTE
    WAN_REMOTE="${WAN_REMOTE:-10.10.10.2}"

    read -rp "Тип туннеля: gre или ipip [gre]: " TUN_TYPE
    TUN_TYPE="${TUN_TYPE:-gre}"
    TUN_NAME="gre0"
    [[ "$TUN_TYPE" == "ipip" ]] && TUN_NAME="tunl0"

    echo
    info "Параметры GRE-туннеля ($DEVICE_NAME):"
    echo "  Тип туннеля:     $TUN_TYPE"
    echo "  Интерфейс:       $TUN_NAME"
    echo "  Локальный WAN:   $WAN_LOCAL"
    echo "  Удалённый WAN:   $WAN_REMOTE"
    echo "  Туннельный IP:   ${TUN_LOCAL_IP}/30"
    echo "  Удалённый тун.:  $TUN_REMOTE_IP"
    echo
    read -rp "Продолжить настройку туннеля? [y/N]: " CONFIRM_TUN
    if [[ ! "${CONFIRM_TUN,,}" =~ ^y ]]; then
        info "Настройка туннеля пропущена."
        STATUS["tunnel"]="SKIP"
    else
        # ─── Задание 1: Создание GRE/IPIP-туннеля ────────────────────────────
        info "[Задание 1] Создание туннеля $TUN_TYPE ($TUN_NAME)..."

        # Удаляем старый туннель если есть
        ip tunnel del "$TUN_NAME" 2>/dev/null || true
        nmcli con delete "$TUN_NAME" 2>/dev/null || true

        if command -v nmcli &>/dev/null; then
            # Создаём через nmcli (постоянный, переживёт перезагрузку)
            nmcli con add type ip-tunnel ifname "$TUN_NAME" con-name "$TUN_NAME" \
                tunnel.mode "$TUN_TYPE" \
                tunnel.local "$WAN_LOCAL" \
                tunnel.remote "$WAN_REMOTE" \
                ipv4.method manual ipv4.addresses "${TUN_LOCAL_IP}/30" \
                connection.autoconnect yes
            nmcli con up "$TUN_NAME"
            ok "Туннель $TUN_NAME создан через nmcli"
        else
            # Создаём через ip команды (временный до перезагрузки)
            ip tunnel add "$TUN_NAME" mode "$TUN_TYPE" \
                remote "$WAN_REMOTE" \
                local "$WAN_LOCAL" \
                ttl 255
            ip link set "$TUN_NAME" up
            ip addr add "${TUN_LOCAL_IP}/30" dev "$TUN_NAME"
            ok "Туннель $TUN_NAME создан через ip tunnel"

            # Делаем постоянным через rc.local
            RC_LOCAL="/etc/rc.local"
            if [[ ! -f "$RC_LOCAL" ]]; then
                cat > "$RC_LOCAL" <<EOF
#!/bin/bash
# GRE-туннель — Вариант 4
ip tunnel add ${TUN_NAME} mode ${TUN_TYPE} remote ${WAN_REMOTE} local ${WAN_LOCAL} ttl 255
ip link set ${TUN_NAME} up
ip addr add ${TUN_LOCAL_IP}/30 dev ${TUN_NAME}
exit 0
EOF
                chmod +x "$RC_LOCAL"
            elif ! grep -q "$TUN_NAME" "$RC_LOCAL"; then
                sed -i "/^exit 0/i # GRE-туннель\nip tunnel add ${TUN_NAME} mode ${TUN_TYPE} remote ${WAN_REMOTE} local ${WAN_LOCAL} ttl 255\nip link set ${TUN_NAME} up\nip addr add ${TUN_LOCAL_IP}/30 dev ${TUN_NAME}" "$RC_LOCAL"
            fi
            ok "Туннель прописан в /etc/rc.local"
        fi

        ok "Туннель $TUN_NAME: ${TUN_LOCAL_IP}/30 ↔ $TUN_REMOTE_IP"
        STATUS["tunnel"]="OK"

        # IP forwarding
        if grep -q '^net.ipv4.ip_forward' /etc/sysctl.conf 2>/dev/null; then
            sed -i 's/^#*\s*net\.ipv4\.ip_forward.*/net.ipv4.ip_forward=1/' /etc/sysctl.conf
        else
            echo 'net.ipv4.ip_forward=1' >> /etc/sysctl.conf
        fi
        sysctl -w net.ipv4.ip_forward=1 >/dev/null
        ok "IP forwarding включён"
        STATUS["ip_forward"]="OK"

        # Проверка: ping до удалённого конца туннеля
        info "Проверка связи через туннель (ping $TUN_REMOTE_IP)..."
        sleep 1
        if ping -c 3 -W 3 "$TUN_REMOTE_IP" &>/dev/null; then
            ok "Туннель работает: ping $TUN_REMOTE_IP — УСПЕШНО"
            STATUS["tunnel_ping"]="OK"
        else
            warn "Ping $TUN_REMOTE_IP недоступен (настройте второй маршрутизатор)"
            STATUS["tunnel_ping"]="SKIP"
        fi
    fi
fi

# ═══════════════════════════════════════════════════════════════════════════════
# РЕЖИМ 2/3: Настройка DNS-сервера (lab.local)
# ═══════════════════════════════════════════════════════════════════════════════
if [[ "$MODE_CHOICE" == "2" || "$MODE_CHOICE" == "3" ]]; then

    echo
    echo "--- Настройка DNS-сервера (зона lab.local) ---"

    read -rp "IP этого сервера (HQ-SRV) [192.168.1.1]: " SRV_IP
    SRV_IP="${SRV_IP:-192.168.1.1}"

    echo
    echo "Введите IP-адреса сетевых устройств для зоны lab.local:"
    read -rp "IP HQ-RTR  [192.168.1.254]: " IP_HQ_RTR; IP_HQ_RTR="${IP_HQ_RTR:-192.168.1.254}"
    read -rp "IP BR-RTR  [192.168.2.254]: " IP_BR_RTR; IP_BR_RTR="${IP_BR_RTR:-192.168.2.254}"
    read -rp "IP HQ-SRV  [${SRV_IP}]: "    IP_HQ_SRV; IP_HQ_SRV="${IP_HQ_SRV:-${SRV_IP}}"
    read -rp "IP BR-SRV  [192.168.2.1]: "  IP_BR_SRV; IP_BR_SRV="${IP_BR_SRV:-192.168.2.1}"
    read -rp "IP туннеля HQ (gre0) [172.16.0.1]: " IP_TUN_HQ; IP_TUN_HQ="${IP_TUN_HQ:-172.16.0.1}"
    read -rp "IP туннеля BR (gre0) [172.16.0.2]: " IP_TUN_BR; IP_TUN_BR="${IP_TUN_BR:-172.16.0.2}"

    echo
    read -rp "Продолжить настройку DNS? [y/N]: " CONFIRM_DNS
    if [[ ! "${CONFIRM_DNS,,}" =~ ^y ]]; then
        info "Настройка DNS пропущена."
        STATUS["dns"]="SKIP"
    else
        # ─── Задание 2: DNS-сервер ────────────────────────────────────────────
        info "[Задание 2] Установка и настройка DNS-сервера bind/named..."

        if ! command -v named &>/dev/null; then
            info "Установка bind..."
            apt-get install -y bind 2>/dev/null \
                || apt-get install -y bind9 2>/dev/null \
                || { error "Не удалось установить bind/bind9"; STATUS["dns"]="ERROR"; }
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

            [[ -f "$NAMED_CONF" ]] && cp "$NAMED_CONF" "${NAMED_CONF}.bak"

            # ── named.conf ──
            info "Генерирую $NAMED_CONF..."
            cat > "$NAMED_CONF" <<EOF
// named.conf — HQ-SRV DNS-сервер
// Вариант 4: зона lab.local
// Демоэкзамен 09.02.06 (2026)

options {
    listen-on { any; };
    directory "${ZONE_DIR}";
    allow-query { any; };
    recursion yes;
    forwarders {
        8.8.8.8;
        8.8.4.4;
    };
    forward only;
    dnssec-validation no;
};

// Задание 2: Зона lab.local
zone "lab.local" IN {
    type master;
    file "${ZONE_DIR}/lab.local.zone";
    allow-update { none; };
};

// Обратная зона для 192.168.1.x
zone "1.168.192.in-addr.arpa" IN {
    type master;
    file "${ZONE_DIR}/192.168.1.zone";
    allow-update { none; };
};

// Обратная зона для 172.16.0.x (туннели)
zone "0.16.172.in-addr.arpa" IN {
    type master;
    file "${ZONE_DIR}/172.16.0.zone";
    allow-update { none; };
};
EOF
            ok "Сгенерирован $NAMED_CONF"

            # Для Debian-based добавляем include
            if [[ "$NAMED_CONF" == "/etc/bind/named.conf.local" ]]; then
                MAIN_CONF="/etc/bind/named.conf"
                if [[ -f "$MAIN_CONF" ]] && ! grep -q "named.conf.local" "$MAIN_CONF"; then
                    echo 'include "/etc/bind/named.conf.local";' >> "$MAIN_CONF"
                fi
                OPTS_CONF="/etc/bind/named.conf.options"
                if [[ -f "$OPTS_CONF" ]]; then
                    cp "$OPTS_CONF" "${OPTS_CONF}.bak"
                    cat > "$OPTS_CONF" <<EOF
options {
    directory "/var/cache/bind";
    forwarders { 8.8.8.8; 8.8.4.4; };
    forward only;
    dnssec-validation no;
    listen-on { any; };
    allow-query { any; };
};
EOF
                fi
                ZONE_DIR="/var/lib/bind"
            fi

            mkdir -p "$ZONE_DIR"

            # ── Задание 2: Зона прямого просмотра lab.local ──
            info "Генерирую файл зоны: ${ZONE_DIR}/lab.local.zone"
            cat > "${ZONE_DIR}/lab.local.zone" <<EOF
\$TTL 3600
@   IN  SOA hq-srv.lab.local. admin.lab.local. (
            2026031401  ; Serial
            3600        ; Refresh
            900         ; Retry
            604800      ; Expire
            3600 )      ; Minimum TTL

; Серверы имён
    IN  NS  hq-srv.lab.local.

; Задание 2: A-записи для всех активных сетевых устройств
hq-rtr      IN  A   ${IP_HQ_RTR}
br-rtr      IN  A   ${IP_BR_RTR}
hq-srv      IN  A   ${IP_HQ_SRV}
br-srv      IN  A   ${IP_BR_SRV}

; A-записи для туннельных интерфейсов (gre0)
gre-hq      IN  A   ${IP_TUN_HQ}
gre-br      IN  A   ${IP_TUN_BR}
EOF
            ok "Сгенерирована зона lab.local"

            # ── Обратная зона для 192.168.1.x ──
            IFS='.' read -ra RTR_OCTS <<< "$IP_HQ_RTR"
            IFS='.' read -ra SRV_OCTS <<< "$IP_HQ_SRV"

            info "Генерирую обратную зону: ${ZONE_DIR}/192.168.1.zone"
            cat > "${ZONE_DIR}/192.168.1.zone" <<EOF
\$TTL 3600
@   IN  SOA hq-srv.lab.local. admin.lab.local. (
            2026031401  ; Serial
            3600        ; Refresh
            900         ; Retry
            604800      ; Expire
            3600 )      ; Minimum TTL

; Серверы имён
    IN  NS  hq-srv.lab.local.

; PTR-записи
${RTR_OCTS[3]}  IN  PTR hq-rtr.lab.local.
${SRV_OCTS[3]}  IN  PTR hq-srv.lab.local.
EOF
            ok "Сгенерирована обратная зона 192.168.1.x"

            # ── Обратная зона для 172.16.0.x (туннели) ──
            IFS='.' read -ra TUN_HQ_OCTS <<< "$IP_TUN_HQ"
            IFS='.' read -ra TUN_BR_OCTS <<< "$IP_TUN_BR"

            info "Генерирую обратную зону туннелей: ${ZONE_DIR}/172.16.0.zone"
            cat > "${ZONE_DIR}/172.16.0.zone" <<EOF
\$TTL 3600
@   IN  SOA hq-srv.lab.local. admin.lab.local. (
            2026031401  ; Serial
            3600        ; Refresh
            900         ; Retry
            604800      ; Expire
            3600 )      ; Minimum TTL

; Серверы имён
    IN  NS  hq-srv.lab.local.

; PTR-записи для туннельных интерфейсов
${TUN_HQ_OCTS[3]}  IN  PTR gre-hq.lab.local.
${TUN_BR_OCTS[3]}  IN  PTR gre-br.lab.local.
EOF
            ok "Сгенерирована обратная зона туннелей 172.16.0.x"

            # Права на файлы зон
            chown -R "${NAMED_USER}:${NAMED_USER}" "$ZONE_DIR" 2>/dev/null || true
            chmod 640 "${ZONE_DIR}/lab.local.zone" \
                      "${ZONE_DIR}/192.168.1.zone" \
                      "${ZONE_DIR}/172.16.0.zone" 2>/dev/null || true

            # Запускаем named
            for svc in named bind9; do
                if systemctl enable --now "$svc" 2>/dev/null; then
                    ok "DNS-сервер ($svc) запущен"
                    STATUS["dns"]="OK"
                    break
                fi
            done
            STATUS["dns"]="${STATUS[dns]:-ERROR}"

            # Проверка DNS
            info "Проверка DNS: nslookup hq-rtr.lab.local 127.0.0.1..."
            sleep 2
            if command -v nslookup &>/dev/null; then
                if nslookup hq-rtr.lab.local 127.0.0.1 &>/dev/null; then
                    ok "DNS работает: hq-rtr.lab.local → $IP_HQ_RTR"
                    STATUS["dns_check"]="OK"
                else
                    warn "nslookup не разрешил hq-rtr.lab.local (проверьте конфиг named)"
                    STATUS["dns_check"]="SKIP"
                fi
            elif command -v dig &>/dev/null; then
                if dig @127.0.0.1 hq-rtr.lab.local +short | grep -q "$IP_HQ_RTR"; then
                    ok "DNS работает: hq-rtr.lab.local → $IP_HQ_RTR"
                    STATUS["dns_check"]="OK"
                else
                    warn "dig не разрешил hq-rtr.lab.local (проверьте конфиг named)"
                    STATUS["dns_check"]="SKIP"
                fi
            else
                warn "nslookup/dig не найдены, пропускаю проверку DNS"
                STATUS["dns_check"]="SKIP"
            fi

        else
            warn "bind/named не найден, пропускаю настройку DNS"
            STATUS["dns"]="SKIP"
        fi
    fi
fi

# ─── Итоговый статус ──────────────────────────────────────────────────────────
echo
echo "============================================================"
echo "  Итог: Вариант 4 — Туннелирование и Имена узлов"
echo "============================================================"
declare -a KEYS=()
[[ "$MODE_CHOICE" == "1" || "$MODE_CHOICE" == "3" ]] && KEYS+=(tunnel ip_forward tunnel_ping)
[[ "$MODE_CHOICE" == "2" || "$MODE_CHOICE" == "3" ]] && KEYS+=(dns dns_check)

for key in "${KEYS[@]}"; do
    val="${STATUS[$key]:-SKIP}"
    case "$val" in
        OK)    echo -e "  ${GREEN}[OK]${NC}    $key" ;;
        ERROR) echo -e "  ${RED}[ERROR]${NC} $key" ;;
        *)     echo -e "  ${YELLOW}[SKIP]${NC}  $key" ;;
    esac
done
echo "============================================================"
echo
ok "Вариант 4 завершён!"
echo
info "Следующие шаги:"
if [[ "$MODE_CHOICE" == "1" || "$MODE_CHOICE" == "3" ]]; then
    echo "  1. Запустите скрипт на втором маршрутизаторе (режим 1)"
    echo "  2. Проверьте туннель: ping 172.16.0.1 / ping 172.16.0.2"
    echo "  3. Убедитесь, что трафик между офисами проходит через туннель"
fi
if [[ "$MODE_CHOICE" == "2" || "$MODE_CHOICE" == "3" ]]; then
    echo "  4. Проверьте DNS с клиентских машин: nslookup hq-rtr.lab.local <IP_HQ_SRV>"
    echo "  5. Проверьте обратный DNS: nslookup 172.16.0.1 <IP_HQ_SRV>"
    echo "  6. На клиентах укажите DNS-сервер: $SRV_IP"
fi

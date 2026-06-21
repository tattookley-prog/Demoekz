#!/bin/bash
# Скрипт добавления статической ARP-записи с автозагрузкой через systemd
# Платформа: Альт Сервер
# Демоэкзамен 09.02.06 (2026)

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
echo "  Статическая ARP-запись с автозагрузкой (systemd)"
echo "  Платформа: Альт Сервер"
echo "  Демоэкзамен 09.02.06 (2026)"
echo "============================================================"
echo

# ─── Интерактивный ввод параметров ───────────────────────────────────────────
read -rp "IP-адрес для ARP-записи [10.12.34.254]: " ARP_IP
ARP_IP="${ARP_IP:-10.12.34.254}"

read -rp "MAC-адрес [28:af:fd:86:8d:49]: " ARP_MAC
ARP_MAC="${ARP_MAC:-28:af:fd:86:8d:49}"

echo
info "Параметры конфигурации:"
echo "  IP-адрес:  $ARP_IP"
echo "  MAC-адрес: $ARP_MAC"
echo "  Сервис:    /etc/systemd/system/static-arp.service"
echo
read -rp "Продолжить? [y/N]: " CONFIRM
if [[ ! "${CONFIRM,,}" =~ ^y ]]; then
    info "Операция отменена."
    exit 0
fi

declare -A STATUS

SERVICE_FILE="/etc/systemd/system/static-arp.service"

# ─── Проверка существующего сервиса ──────────────────────────────────────────
if [[ -f "$SERVICE_FILE" ]]; then
    warn "Файл сервиса уже существует: $SERVICE_FILE"
    read -rp "Перезаписать? [y/N]: " OVERWRITE
    if [[ ! "${OVERWRITE,,}" =~ ^y ]]; then
        info "Операция отменена. Существующий файл сервиса оставлен без изменений."
        exit 0
    fi
    info "Перезаписываю существующий файл сервиса..."
fi

# ─── Создание файла сервиса ───────────────────────────────────────────────────
info "Создание файла сервиса: $SERVICE_FILE"

cat > "$SERVICE_FILE" <<EOF
[Unit]
Description="static arp"
After=default.target

[Service]
ExecStart=/bin/arp -s ${ARP_IP} ${ARP_MAC}

[Install]
WantedBy=default.target
EOF

ok "Файл сервиса создан: $SERVICE_FILE"
STATUS["service_file"]="OK"

# ─── Перезапуск демонов ───────────────────────────────────────────────────────
info "Перезапуск systemd демонов (daemon-reload)..."
if systemctl daemon-reload; then
    ok "daemon-reload выполнен"
    STATUS["daemon_reload"]="OK"
else
    error "Ошибка при выполнении daemon-reload"
    STATUS["daemon_reload"]="ERROR"
fi

# ─── Добавление в автозагрузку и немедленный запуск ──────────────────────────
info "Включение и запуск сервиса static-arp..."
if systemctl enable --now static-arp; then
    ok "Сервис static-arp включён в автозагрузку и запущен"
    STATUS["enable_start"]="OK"
else
    error "Ошибка при включении/запуске сервиса static-arp"
    STATUS["enable_start"]="ERROR"
fi

# ─── Проверка результата ──────────────────────────────────────────────────────
info "Проверка ARP-записи для $ARP_IP..."
if arp -n | grep -q "$ARP_IP"; then
    ok "ARP-запись найдена:"
    arp -n | grep "$ARP_IP"
    STATUS["arp_check"]="OK"
else
    warn "ARP-запись для $ARP_IP не обнаружена в таблице (возможно, сервис ещё не завершил инициализацию)"
    STATUS["arp_check"]="SKIP"
fi

# ─── Итоговый статус ──────────────────────────────────────────────────────────
echo
echo "============================================================"
echo "  Итог: Статическая ARP-запись с автозагрузкой"
echo "============================================================"
for key in service_file daemon_reload enable_start arp_check; do
    val="${STATUS[$key]:-SKIP}"
    case "$val" in
        OK)    echo -e "  ${GREEN}[OK]${NC}    $key" ;;
        ERROR) echo -e "  ${RED}[ERROR]${NC} $key" ;;
        *)     echo -e "  ${YELLOW}[SKIP]${NC}  $key" ;;
    esac
done
echo "============================================================"
echo
ok "Настройка статической ARP-записи завершена!"
info "Сервис: static-arp | IP: $ARP_IP | MAC: $ARP_MAC"

#!/bin/bash
# =============================================================================
# offline_pkg_deploy.sh — скачать пакеты на ISP и раздать на машины без интернета
# Запуск: bash offline_pkg_deploy.sh
# ОС: Альт Сервер (apt-get + rpm)
# =============================================================================

set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'
NC='\033[0m'
info()  { echo -e "${CYAN}[INFO]${NC}  $*"; }
ok()    { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }

[[ $EUID -eq 0 ]] || { error "Нужен root"; exit 1; }

# ─── Параметры машин ───���────────────────────────────────────────────────────
# Поменяй IP и интерфейс если отличаются от дефолтных
HQ_RTR_IP="172.16.1.2"
BR_RTR_IP="172.16.2.2"
# HQ-SRV и BR-SRV доступны только через роутеры — укажи после их настройки
# HQ_SRV_IP="192.168.1.2"
# BR_SRV_IP="192.168.3.2"

PKG_DIR="/tmp/offline_pkgs"
SCRIPTS_DIR="/tmp/scripts"

# ─── Шаг 1: Скачать репозиторий со скриптами ────────────────────────────────
info "=== Шаг 1: Скачиваем скрипты с GitHub ==="
if command -v curl &>/dev/null; then
    curl -L https://github.com/tattookley-prog/Demoekz/archive/refs/heads/main.zip \
        -o /tmp/Demoekz.zip
elif command -v wget &>/dev/null; then
    wget -O /tmp/Demoekz.zip \
        https://github.com/tattookley-prog/Demoekz/archive/refs/heads/main.zip
else
    error "Нет curl и wget. Установи: apt-get install -y curl"
    exit 1
fi

mkdir -p "$SCRIPTS_DIR"
if command -v unzip &>/dev/null; then
    unzip -o /tmp/Demoekz.zip -d /tmp/Demoekz_extracted/
else
    apt-get install -y unzip
    unzip -o /tmp/Demoekz.zip -d /tmp/Demoekz_extracted/
fi

cp /tmp/Demoekz_extracted/Demoekz-main/scripts/*.sh "$SCRIPTS_DIR/"
chmod +x "$SCRIPTS_DIR/"*.sh
ok "Скрипты сохранены в $SCRIPTS_DIR"

# ─── Шаг 2: Скачать пакеты с зависимостями (без установки) ─────────────────
info "=== Шаг 2: Скачиваем пакеты (apt-get download) ==="
mkdir -p \
    "${PKG_DIR}/hq-rtr" \
    "${PKG_DIR}/br-rtr" \
    "${PKG_DIR}/hq-srv" \
    "${PKG_DIR}/br-srv"

# Обновляем кэш пакетов
apt-get update -qq

download_pkg() {
    local dest="$1"; shift
    local pkgs=("$@")
    cd "$dest"
    for pkg in "${pkgs[@]}"; do
        info "  Скачиваю $pkg → $dest"
        # apt-get download скачивает пакет в текущую директорию
        apt-get download "$pkg" 2>/dev/null && ok "  $pkg — OK" || warn "  $pkg — не найден, пропускаю"
    done
    cd - > /dev/null
}

# Пакеты для HQ-RTR
info "--- HQ-RTR: frr, nftables, dhcp-server ---"
download_pkg "${PKG_DIR}/hq-rtr" frr nftables dhcp-server isc-dhcp-server

# Пакеты для BR-RTR
info "--- BR-RTR: frr, nftables ---"
download_pkg "${PKG_DIR}/br-rtr" frr nftables

# Пакеты для HQ-SRV
info "--- HQ-SRV: bind, openssh-server ---"
download_pkg "${PKG_DIR}/hq-srv" bind bind9 bind9utils openssh-server

# Пакеты для BR-SRV
info "--- BR-SRV: openssh-server ---"
download_pkg "${PKG_DIR}/br-srv" openssh-server

ok "Все пакеты скачаны в $PKG_DIR"

# ─── Шаг 3: Раздать пакеты и скрипты на машины по SCP ──────────────────────
info "=== Шаг 3: Отправка на машины по SCP ==="

scp_to() {
    local host="$1" src_pkgs="$2" label="$3"
    info "Отправляю на $label ($host)..."
    # Скрипты
    scp -o StrictHostKeyChecking=no -r "$SCRIPTS_DIR" "root@${host}:/root/" && \
        ok "Скрипты → $label: OK" || warn "Скрипты → $label: ОШИБКА (проверь SSH)"
    # Пакеты
    scp -o StrictHostKeyChecking=no -r "$src_pkgs" "root@${host}:/root/pkgs" && \
        ok "Пакеты → $label: OK" || warn "Пакеты → $label: ОШИБКА"
    # Инструкция по установке
    ssh -o StrictHostKeyChecking=no "root@${host}" \
        "echo 'Установка: apt-get install -y /root/pkgs/*.rpm 2>/dev/null || dpkg -i /root/pkgs/*.deb 2>/dev/null || true' \
         > /root/install_pkgs.sh && chmod +x /root/install_pkgs.sh" 2>/dev/null || true
}

echo
warn "Сейчас начнётся отправка файлов по SSH. Убедись что:"
warn "  1. SSH доступен на HQ-RTR ($HQ_RTR_IP) и BR-RTR ($BR_RTR_IP)"
warn "  2. Ты знаешь пароль root на этих машинах"
echo
read -rp "Отправить файлы? [y/N]: " SEND
if [[ "${SEND,,}" =~ ^y ]]; then
    scp_to "$HQ_RTR_IP" "${PKG_DIR}/hq-rtr" "HQ-RTR"
    scp_to "$BR_RTR_IP" "${PKG_DIR}/br-rtr" "BR-RTR"
    # HQ-SRV и BR-SRV — через роутеры, раскомментируй после настройки сети
    # scp_to "192.168.1.2" "${PKG_DIR}/hq-srv" "HQ-SRV"
    # scp_to "192.168.3.2" "${PKG_DIR}/br-srv" "BR-SRV"
    ok "Готово!"
else
    info "Отправка пропущена. Файлы лежат в:"
    echo "  Скрипты:  $SCRIPTS_DIR"
    echo "  Пакеты:   $PKG_DIR"
    echo
    info "Отправь вручную позже:"
    echo "  scp -r $SCRIPTS_DIR root@${HQ_RTR_IP}:/root/"
    echo "  scp -r ${PKG_DIR}/hq-rtr root@${HQ_RTR_IP}:/root/pkgs"
    echo "  scp -r $SCRIPTS_DIR root@${BR_RTR_IP}:/root/"
    echo "  scp -r ${PKG_DIR}/br-rtr root@${BR_RTR_IP}:/root/pkgs"
fi

echo
echo "============================================================"
echo "  Итог. На каждой машине выполни:"
echo "============================================================"
echo "  # Установить пакеты (Альт Сервер / rpm):"
echo "  apt-get install -y /root/pkgs/*.rpm"
echo ""
echo "  # или если пакеты в .deb:"
echo "  dpkg -i /root/pkgs/*.deb && apt-get -f install -y"
echo ""
echo "  # Затем запустить скрипт настройки:"
echo "  bash /root/scripts/hq_rtr_setup.sh   # на HQ-RTR"
echo "  bash /root/scripts/br_rtr_setup.sh   # на BR-RTR"
echo "  bash /root/scripts/hq_srv_setup.sh   # на HQ-SRV"
echo "  bash /root/scripts/br_srv_setup.sh   # на BR-SRV"
echo "============================================================"

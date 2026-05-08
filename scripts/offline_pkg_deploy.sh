#!/bin/bash
# =============================================================================
# offline_pkg_deploy.sh — скачать пакеты на ISP и раздать на машины без интернета
# Запуск: bash offline_pkg_deploy.sh
# ОС: Альт Сервер (apt-get + rpm)
#
# ВАЖНО: apt-get download на Альт НЕ работает (это Debian-команда).
#        Здесь используется apt-get install --download-only,
#        пакеты скачиваются в /var/cache/apt/archives/*.rpm
# =============================================================================

set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'
NC='\033[0m'
info()  { echo -e "${CYAN}[INFO]${NC}  $*"; }
ok()    { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }

[[ $EUID -eq 0 ]] || { error "Нужен root"; exit 1; }

# ─── Параметры машин ─────────────────────────────────────────────────────────
HQ_RTR_IP="172.16.1.2"
BR_RTR_IP="172.16.2.2"
# HQ-SRV и BR-SRV доступны только после настройки роутеров:
# HQ_SRV_IP="192.168.1.2"
# BR_SRV_IP="192.168.3.2"

PKG_DIR="/tmp/offline_pkgs"
APT_CACHE="/var/cache/apt/archives"
SCRIPTS_DIR="/tmp/scripts"

# ─── Шаг 1: Скачать репозиторий со скриптами ─────────────────────────────────
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

if ! command -v unzip &>/dev/null; then
    apt-get install -y unzip
fi
mkdir -p "$SCRIPTS_DIR"
unzip -o /tmp/Demoekz.zip -d /tmp/Demoekz_extracted/
cp /tmp/Demoekz_extracted/Demoekz-main/scripts/*.sh "$SCRIPTS_DIR/"
chmod +x "$SCRIPTS_DIR/"*.sh
ok "Скрипты сохранены в $SCRIPTS_DIR"

# ─── Шаг 2: Скачать пакеты для Альт Сервер ───────────────────────────────────
# На Альт Сервер apt-get download НЕ работает.
# Используем: apt-get install --download-only -y <пакет>
# Пакеты (.rpm) скачиваются в /var/cache/apt/archives/
# Затем копируем нужные в отдельные папки по машинам.
info "=== Шаг 2: Скачиваем пакеты для Альт Сервер ==="
apt-get update -qq

mkdir -p \
    "${PKG_DIR}/hq-rtr" \
    "${PKG_DIR}/br-rtr" \
    "${PKG_DIR}/hq-srv" \
    "${PKG_DIR}/br-srv"

# Функция: скачать пакет (и зависимости) в папку назначения
# Механизм: очищаем кэш → скачиваем через --download-only → копируем .rpm
download_to() {
    local dest="$1"; shift
    local pkgs=("$@")

    for pkg in "${pkgs[@]}"; do
        info "  Скачиваю '$pkg' с зависимостями → $dest"
        # Очищаем старые .rpm из кэша чтобы точно знать что скачалось
        rm -f "${APT_CACHE}"/*.rpm 2>/dev/null || true
        # --download-only: только скачать, не устанавливать
        # -y --force-yes: без вопросов
        if apt-get install --download-only -y "$pkg" &>/dev/null; then
            COUNT=$(ls "${APT_CACHE}"/*.rpm 2>/dev/null | wc -l)
            if [[ "$COUNT" -gt 0 ]]; then
                cp "${APT_CACHE}"/*.rpm "$dest"/
                ok "  $pkg — скачано файлов: $COUNT"
            else
                warn "  $pkg — apt отработал, но .rpm не найдены в кэше"
            fi
        else
            warn "  $pkg — не найден в репозитории, пропускаю"
        fi
    done
}

# ── Пакеты для HQ-RTR: frr, nftables, dhcp-server ──
info "--- HQ-RTR: frr, nftables, dhcp-server ---"
download_to "${PKG_DIR}/hq-rtr" frr nftables dhcp-server

# ── Пакеты для BR-RTR: frr, nftables ──
info "--- BR-RTR: frr, nftables ---"
download_to "${PKG_DIR}/br-rtr" frr nftables

# ── Пакеты для HQ-SRV: bind, openssh-server ──
info "--- HQ-SRV: bind, openssh-server ---"
download_to "${PKG_DIR}/hq-srv" bind openssh-server

# ── Пакеты для BR-SRV: openssh-server ──
info "--- BR-SRV: openssh-server ---"
download_to "${PKG_DIR}/br-srv" openssh-server

echo
info "Содержимое папок с пакетами:"
for dir in hq-rtr br-rtr hq-srv br-srv; do
    COUNT=$(ls "${PKG_DIR}/${dir}"/*.rpm 2>/dev/null | wc -l)
    echo "  ${dir}: $COUNT .rpm файлов"
done
echo

# ─── Шаг 3: Раздать пакеты и скрипты на машины по SCP ───────────────────────
info "=== Шаг 3: Отправка на машины по SCP ==="

scp_to() {
    local host="$1" src_pkgs="$2" label="$3"
    info "Отправляю на $label ($host)..."

    scp -o StrictHostKeyChecking=no -r "$SCRIPTS_DIR" "root@${host}:/root/" && \
        ok "  Скрипты → $label: OK" || warn "  Скрипты → $label: ОШИБКА (проверь SSH)"

    ssh -o StrictHostKeyChecking=no "root@${host}" "mkdir -p /root/pkgs" 2>/dev/null || true
    scp -o StrictHostKeyChecking=no "${src_pkgs}"/*.rpm "root@${host}:/root/pkgs/" && \
        ok "  Пакеты → $label: OK" || warn "  Пакеты → $label: ОШИБКА"

    # Создаём скрипт установки прямо на машине
    ssh -o StrictHostKeyChecking=no "root@${host}" bash <<'REMOTE'
cat > /root/install_pkgs.sh << 'EOF'
#!/bin/bash
# Установка пакетов на Альт Сервер (rpm)
echo "[INFO] Устанавливаем пакеты из /root/pkgs/"
rpm -Uvh --nodeps /root/pkgs/*.rpm 2>/dev/null && echo "[OK] Установлено через rpm" || \
apt-get install -y /root/pkgs/*.rpm 2>/dev/null && echo "[OK] Установлено через apt-get" || \
echo "[WARN] Проверь пакеты вручную: ls /root/pkgs/"
EOF
chmod +x /root/install_pkgs.sh
REMOTE
    ok "  install_pkgs.sh создан на $label"
}

echo
warn "Сейчас начнётся отправка файлов по SSH. Убедись что:"
warn "  1. ISP уже видит HQ-RTR ($HQ_RTR_IP) и BR-RTR ($BR_RTR_IP)"
warn "  2. SSH работает на этих машинах (порт 22)"
echo
read -rp "Отправить файлы на HQ-RTR и BR-RTR? [y/N]: " SEND
if [[ "${SEND,,}" =~ ^y ]]; then
    scp_to "$HQ_RTR_IP" "${PKG_DIR}/hq-rtr" "HQ-RTR"
    scp_to "$BR_RTR_IP" "${PKG_DIR}/br-rtr" "BR-RTR"
    echo
    warn "HQ-SRV и BR-SRV — раскомментируй строки ниже и запусти скрипт повторно"
    warn "ПОСЛЕ того как настроишь HQ-RTR и BR-RTR (нужна маршрутизация):"
    echo "  # scp_to '192.168.1.2' '${PKG_DIR}/hq-srv' 'HQ-SRV'"
    echo "  # scp_to '192.168.3.2' '${PKG_DIR}/br-srv' 'BR-SRV'"
    ok "Готово!"
else
    info "Отправка пропущена. Отправь вручную:"
    echo "  scp -r $SCRIPTS_DIR root@${HQ_RTR_IP}:/root/"
    echo "  scp ${PKG_DIR}/hq-rtr/*.rpm root@${HQ_RTR_IP}:/root/pkgs/"
    echo "  scp -r $SCRIPTS_DIR root@${BR_RTR_IP}:/root/"
    echo "  scp ${PKG_DIR}/br-rtr/*.rpm root@${BR_RTR_IP}:/root/pkgs/"
fi

echo
echo "============================================================"
echo "  На каждой машине после получения файлов выполни:"
echo "============================================================"
echo "  bash /root/install_pkgs.sh        # установить пакеты"
echo ""
echo "  bash /root/scripts/hq_rtr_setup.sh   # на HQ-RTR"
echo "  bash /root/scripts/br_rtr_setup.sh   # на BR-RTR"
echo "  bash /root/scripts/hq_srv_setup.sh   # на HQ-SRV"
echo "  bash /root/scripts/br_srv_setup.sh   # на BR-SRV"
echo "============================================================"

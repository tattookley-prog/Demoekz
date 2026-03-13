#!/usr/bin/env bash
# =============================================================================
# proxmox_setup.sh — базовый скрипт для Proxmox VE
# Запуск: bash proxmox_setup.sh
# =============================================================================

set -euo pipefail

# ---------------------------------------------------------------------------
# Цвета вывода
# ---------------------------------------------------------------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# ---------------------------------------------------------------------------
# Вспомогательные функции
# ---------------------------------------------------------------------------
info()    { echo -e "${CYAN}[INFO]${NC}  $*"; }
success() { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*" >&2; }
die()     { error "$*"; exit 1; }

require_root() {
    [[ $EUID -eq 0 ]] || die "Этот скрипт должен быть запущен от имени root."
}

require_proxmox() {
    command -v pvesh &>/dev/null || die "Команда pvesh не найдена. Запустите скрипт на узле Proxmox VE."
}

press_enter() {
    echo
    read -r -p "Нажмите Enter для продолжения..."
}

# ---------------------------------------------------------------------------
# Функции валидации ввода
# ---------------------------------------------------------------------------
validate_vmid() {
    [[ "$1" =~ ^[0-9]+$ ]] || die "VMID должен быть числом (получено: $1)"
}

validate_positive_int() {
    [[ "$1" =~ ^[0-9]+$ ]] && [[ "$1" -gt 0 ]] || die "Значение должно быть положительным числом (получено: $1)"
}

validate_hostname() {
    [[ "$1" =~ ^[a-zA-Z0-9]([a-zA-Z0-9\-]{0,61}[a-zA-Z0-9])?$ ]] || \
        die "Недопустимое имя хоста (допустимы буквы, цифры и дефис): $1"
}

validate_snap_name() {
    [[ "$1" =~ ^[a-zA-Z0-9_\-]+$ ]] || \
        die "Имя снапшота может содержать только буквы, цифры, '-' и '_' (получено: $1)"
}

# ---------------------------------------------------------------------------
# Раздел: Информация об узле
# ---------------------------------------------------------------------------
show_node_info() {
    info "=== Информация об узле Proxmox ==="
    pvesh get "/nodes/$(hostname)" --output-format yaml 2>/dev/null || pveversion
    press_enter
}

# ---------------------------------------------------------------------------
# Раздел: Список виртуальных машин и контейнеров
# ---------------------------------------------------------------------------
list_vms() {
    info "=== Список виртуальных машин (KVM) ==="
    qm list 2>/dev/null || warn "Не удалось получить список ВМ."
    echo
    info "=== Список контейнеров (LXC) ==="
    pct list 2>/dev/null || warn "Не удалось получить список контейнеров."
    press_enter
}

# ---------------------------------------------------------------------------
# Раздел: Создание LXC-контейнера
# ---------------------------------------------------------------------------
create_lxc() {
    info "=== Создание нового LXC-контейнера ==="

    read -r -p "VMID (например, 100): "          VMID
    read -r -p "Имя хоста контейнера: "          HOSTNAME
    read -r -s -p "Пароль root: "                PASSWORD; echo
    read -r -p "Шаблон (например, local:vztmpl/ubuntu-22.04-standard_22.04-1_amd64.tar.zst): " TEMPLATE
    read -r -p "Размер диска в ГБ (например, 8): "    DISK_GB
    read -r -p "RAM в МБ (например, 512): "      RAM
    read -r -p "Число CPU (например, 1): "       CPUS
    read -r -p "Сетевой мост (например, vmbr0): " BRIDGE
    read -r -p "IP-адрес/маска (например, 192.168.1.100/24 или dhcp): " IP
    read -r -p "Шлюз (оставьте пустым при dhcp): " GW

    validate_vmid "$VMID"
    validate_hostname "$HOSTNAME"
    validate_positive_int "$DISK_GB"
    validate_positive_int "$RAM"
    validate_positive_int "$CPUS"

    NET_STR="name=eth0,bridge=${BRIDGE}"
    if [[ "$IP" == "dhcp" ]]; then
        NET_STR+=",ip=dhcp"
    else
        NET_STR+=",ip=${IP}"
        [[ -n "$GW" ]] && NET_STR+=",gw=${GW}"
    fi

    info "Создаём контейнер VMID=${VMID}..."
    pct create "$VMID" "$TEMPLATE" \
        --hostname "$HOSTNAME" \
        --password "$PASSWORD" \
        --rootfs "local-lvm:${DISK_GB}" \
        --memory "$RAM" \
        --cores "$CPUS" \
        --net0 "$NET_STR" \
        --unprivileged 1 \
        --start 1

    success "Контейнер ${VMID} создан и запущен."
    press_enter
}

# ---------------------------------------------------------------------------
# Раздел: Создание виртуальной машины (KVM)
# ---------------------------------------------------------------------------
create_vm() {
    info "=== Создание новой виртуальной машины (KVM) ==="

    read -r -p "VMID (например, 200): "          VMID
    read -r -p "Имя ВМ: "                        VMNAME
    read -r -p "Объём RAM в МБ (например, 2048): " RAM
    read -r -p "Число vCPU (например, 2): "      CPUS
    read -r -p "Размер диска в ГБ (например, 20): " DISK_GB
    read -r -p "Сетевой мост (например, vmbr0): " BRIDGE
    read -r -p "Путь к ISO-образу (например, local:iso/debian-12.iso): " ISO

    validate_vmid "$VMID"
    validate_positive_int "$RAM"
    validate_positive_int "$CPUS"
    validate_positive_int "$DISK_GB"

    info "Создаём ВМ VMID=${VMID}..."
    qm create "$VMID" \
        --name "$VMNAME" \
        --memory "$RAM" \
        --cores "$CPUS" \
        --net0 "virtio,bridge=${BRIDGE}" \
        --cdrom "$ISO" \
        --bootdisk scsi0 \
        --scsihw virtio-scsi-pci \
        --ostype l26

    pvesm alloc local-lvm "$VMID" "vm-${VMID}-disk-0" "${DISK_GB}G"
    qm set "$VMID" --scsi0 "local-lvm:vm-${VMID}-disk-0"
    qm set "$VMID" --boot order=scsi0

    success "ВМ ${VMID} создана."
    press_enter
}

# ---------------------------------------------------------------------------
# Раздел: Управление снапшотами ВМ/контейнера
# ---------------------------------------------------------------------------
manage_snapshots() {
    info "=== Управление снапшотами ==="
    echo "1) Создать снапшот ВМ (KVM)"
    echo "2) Создать снапшот контейнера (LXC)"
    echo "3) Показать снапшоты ВМ"
    echo "4) Показать снапшоты контейнера"
    echo "5) Назад"
    read -r -p "Выберите пункт: " OPT

    case "$OPT" in
        1)
            read -r -p "VMID ВМ: " VMID
            read -r -p "Имя снапшота: " SNAP
            validate_vmid "$VMID"
            validate_snap_name "$SNAP"
            qm snapshot "$VMID" "$SNAP" && success "Снапшот ${SNAP} создан."
            ;;
        2)
            read -r -p "VMID контейнера: " VMID
            read -r -p "Имя снапшота: " SNAP
            validate_vmid "$VMID"
            validate_snap_name "$SNAP"
            pct snapshot "$VMID" "$SNAP" && success "Снапшот ${SNAP} создан."
            ;;
        3)
            read -r -p "VMID ВМ: " VMID
            validate_vmid "$VMID"
            qm listsnapshot "$VMID"
            ;;
        4)
            read -r -p "VMID контейнера: " VMID
            validate_vmid "$VMID"
            pct listsnapshot "$VMID"
            ;;
        5) return ;;
        *) warn "Неверный выбор." ;;
    esac
    press_enter
}

# ---------------------------------------------------------------------------
# Раздел: Управление хранилищем
# ---------------------------------------------------------------------------
show_storage() {
    info "=== Хранилище ==="
    pvesm status
    echo
    info "Использование дисков:"
    df -h --output=source,size,used,avail,pcent,target | grep -v tmpfs | grep -v udev || true
    press_enter
}

# ---------------------------------------------------------------------------
# Раздел: Сетевые настройки
# ---------------------------------------------------------------------------
show_network() {
    info "=== Сетевые интерфейсы ==="
    ip -brief address
    echo
    info "=== Мосты Proxmox ==="
    brctl show 2>/dev/null || ip link show type bridge
    press_enter
}

# ---------------------------------------------------------------------------
# Раздел: Обновление Proxmox
# ---------------------------------------------------------------------------
update_proxmox() {
    warn "Будет выполнено обновление системы. Продолжить? (y/N)"
    read -r CONFIRM
    if [[ "$CONFIRM" =~ ^[Yy]$ ]]; then
        info "Обновляем пакеты..."
        apt-get update -qq || die "Не удалось обновить список пакетов."
        apt-get dist-upgrade -y || die "Ошибка при обновлении пакетов."
        success "Обновление завершено."
    else
        info "Обновление отменено."
    fi
    press_enter
}

# ---------------------------------------------------------------------------
# Главное меню
# ---------------------------------------------------------------------------
main_menu() {
    while true; do
        clear
        echo -e "${CYAN}"
        echo "╔══════════════════════════════════════════════╗"
        echo "║       Proxmox VE — Скрипт управления         ║"
        echo "║              Демоэкзамен                      ║"
        echo "╚══════════════════════════════════════════════╝"
        echo -e "${NC}"
        echo "  1) Информация об узле"
        echo "  2) Список ВМ и контейнеров"
        echo "  3) Создать LXC-контейнер"
        echo "  4) Создать виртуальную машину (KVM)"
        echo "  5) Управление снапшотами"
        echo "  6) Состояние хранилища"
        echo "  7) Сетевые настройки"
        echo "  8) Обновить Proxmox"
        echo "  0) Выход"
        echo
        read -r -p "Выберите действие: " CHOICE

        case "$CHOICE" in
            1) show_node_info ;;
            2) list_vms ;;
            3) create_lxc ;;
            4) create_vm ;;
            5) manage_snapshots ;;
            6) show_storage ;;
            7) show_network ;;
            8) update_proxmox ;;
            0) info "Выход."; exit 0 ;;
            *) warn "Неверный выбор. Повторите." ; sleep 1 ;;
        esac
    done
}

# ---------------------------------------------------------------------------
# Точка входа
# ---------------------------------------------------------------------------
require_root
require_proxmox
main_menu

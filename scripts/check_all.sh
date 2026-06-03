#!/bin/bash
# =============================================================================
# check_all.sh — интерактивная проверка выполнения демоэкзамена
# Запуск: sudo bash scripts/check_all.sh
# =============================================================================

set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'
NC='\033[0m'

info()  { echo -e "${CYAN}[INFO]${NC}  $*"; }
ok()    { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }
fail()  { echo -e "${RED}[FAIL]${NC}  $*"; }

if [[ $EUID -ne 0 ]]; then
    error "Скрипт должен быть запущен от имени root (пример: sudo bash scripts/check_all.sh)"
    exit 1
fi

declare -a RESULT_KEYS=()
declare -A RESULT_TITLE
declare -A RESULT_STATUS

add_result() {
    local key="$1" title="$2" status="$3"
    RESULT_KEYS+=("$key")
    RESULT_TITLE["$key"]="$title"
    RESULT_STATUS["$key"]="$status"
}

run_ok_fail_check() {
    local key="$1" title="$2" cmd="$3"
    info "$title"
    if bash -o pipefail -c "$cmd" >/dev/null 2>&1; then
        ok "$title"
        add_result "$key" "$title" "OK"
    else
        fail "$title"
        add_result "$key" "$title" "FAIL"
    fi
}

# Как run_ok_fail_check, но с активным ожиданием: повторяет проверку каждую секунду
# до timeout секунд, прежде чем признать FAIL. Нужно для асинхронных вещей вроде
# OSPF-соседства, которое после restart network/ребута встаёт за ~40-50 секунд
# (Hello 10с + обмен БД + Dead 40с). Без ожидания проверка даёт ложный FAIL.
run_wait_check() {
    local key="$1" title="$2" cmd="$3" timeout="${4:-60}"
    info "$title (ожидание до ${timeout}с)"
    local i
    for ((i = 1; i <= timeout; i++)); do
        if bash -o pipefail -c "$cmd" >/dev/null 2>&1; then
            ok "$title (установлено за ~${i}с)"
            add_result "$key" "$title" "OK"
            return 0
        fi
        sleep 1
    done
    fail "$title (таймаут ${timeout}с)"
    add_result "$key" "$title" "FAIL"
    return 0
}

run_skip_check() {
    local key="$1" title="$2" reason="$3"
    warn "$title (SKIP: $reason)"
    add_result "$key" "$title" "SKIP"
}

check_cmd() {
    command -v "$1" >/dev/null 2>&1
}

detect_sshd_conf() {
    if [[ -f /etc/openssh/sshd_config ]]; then
        echo "/etc/openssh/sshd_config"
    elif [[ -f /etc/ssh/sshd_config ]]; then
        echo "/etc/ssh/sshd_config"
    else
        return 1
    fi
}

run_hostname_check() {
    local key="$1" expected="$2"
    run_ok_fail_check "$key" "Hostname = $expected" "[[ \"\$(hostnamectl --static 2>/dev/null || hostname)\" == '$expected' ]]"
}

run_isp_checks() {
    info "Проверки роли: ISP"

    run_hostname_check "isp_hostname" "isp.au-team.irpo"

    if check_cmd ip; then
        run_ok_fail_check "isp_ip_hq" "IP 172.16.1.1/28" "ip -o -4 addr show | awk '{print \$4}' | grep -Fxq '172.16.1.1/28'"
        run_ok_fail_check "isp_ip_br" "IP 172.16.2.1/28" "ip -o -4 addr show | awk '{print \$4}' | grep -Fxq '172.16.2.1/28'"
    else
        run_skip_check "isp_ip_hq" "IP 172.16.1.1/28" "нет команды ip"
        run_skip_check "isp_ip_br" "IP 172.16.2.1/28" "нет команды ip"
    fi

    run_ok_fail_check "isp_ip_forward" "net.ipv4.ip_forward = 1" "[[ \"\$(sysctl -n net.ipv4.ip_forward 2>/dev/null || cat /proc/sys/net/ipv4/ip_forward 2>/dev/null || echo 0)\" == '1' ]]"

    if check_cmd nft; then
        info "Проверка NAT смотрит активный ruleset (nft list ruleset), а не только файл конфигурации."
        run_ok_fail_check "isp_nft_nat" "NAT masquerade в nft" "nft list ruleset | grep -qi masquerade"
    else
        run_skip_check "isp_nft_nat" "NAT masquerade в nft" "нет команды nft"
    fi

    if check_cmd ping; then
        run_ok_fail_check "isp_ping_hq" "Ping 172.16.1.2" "ping -c1 -W2 172.16.1.2"
        run_ok_fail_check "isp_ping_br" "Ping 172.16.2.2" "ping -c1 -W2 172.16.2.2"
    else
        run_skip_check "isp_ping_hq" "Ping 172.16.1.2" "нет команды ping"
        run_skip_check "isp_ping_br" "Ping 172.16.2.2" "нет команды ping"
    fi
}

run_hq_rtr_checks() {
    info "Проверки роли: HQ-RTR"

    run_hostname_check "hq_rtr_hostname" "hq-rtr.au-team.irpo"

    if check_cmd ip; then
        run_ok_fail_check "hq_rtr_wan" "WAN 172.16.1.2/28" "ip -o -4 addr show | awk '{print \$4}' | grep -Fxq '172.16.1.2/28'"
        run_ok_fail_check "hq_rtr_vlan100" "VLAN100 192.168.1.1/27" "ip -o -4 addr show | awk '{print \$4}' | grep -Fxq '192.168.1.1/27'"
        run_ok_fail_check "hq_rtr_vlan200" "VLAN200 192.168.2.1/27" "ip -o -4 addr show | awk '{print \$4}' | grep -Fxq '192.168.2.1/27'"
        run_ok_fail_check "hq_rtr_vlan999" "VLAN999 192.168.99.1/29" "ip -o -4 addr show | awk '{print \$4}' | grep -Fxq '192.168.99.1/29'"
        run_ok_fail_check "hq_rtr_gre_ip" "GRE gre1 = 10.0.0.1/30" "ip -o -4 addr show dev gre1 | awk '{print \$4}' | grep -Fxq '10.0.0.1/30'"
    else
        run_skip_check "hq_rtr_wan" "WAN 172.16.1.2/28" "нет команды ip"
        run_skip_check "hq_rtr_vlan100" "VLAN100 192.168.1.1/27" "нет команды ip"
        run_skip_check "hq_rtr_vlan200" "VLAN200 192.168.2.1/27" "нет команды ip"
        run_skip_check "hq_rtr_vlan999" "VLAN999 192.168.99.1/29" "нет команды ip"
        run_skip_check "hq_rtr_gre_ip" "GRE gre1 = 10.0.0.1/30" "нет команды ip"
    fi

    if check_cmd ping; then
        run_ok_fail_check "hq_rtr_gre_ping" "Ping 10.0.0.2" "ping -c1 -W2 10.0.0.2"
    else
        run_skip_check "hq_rtr_gre_ping" "Ping 10.0.0.2" "нет команды ping"
    fi

    run_ok_fail_check "hq_rtr_frr_active" "FRR active" "systemctl is-active --quiet frr"

    if check_cmd vtysh; then
        run_wait_check "hq_rtr_ospf_neighbors" "OSPF соседи (vtysh)" "vtysh -c 'show ip ospf neighbor' | grep -Eq '([0-9]{1,3}\\.){3}[0-9]{1,3}|Full'" 60
    else
        run_skip_check "hq_rtr_ospf_neighbors" "OSPF соседи (vtysh)" "нет команды vtysh"
    fi

    if check_cmd iptables; then
        run_ok_fail_check "hq_rtr_nat" "iptables MASQUERADE" "iptables -t nat -S | grep -qi MASQUERADE"
        run_ok_fail_check "hq_rtr_forward" "iptables FORWARD правила" "iptables -S FORWARD | grep -q '^-A FORWARD'"
    else
        run_skip_check "hq_rtr_nat" "iptables MASQUERADE" "нет команды iptables"
        run_skip_check "hq_rtr_forward" "iptables FORWARD правила" "нет команды iptables"
    fi

    run_ok_fail_check "hq_rtr_iptables_restore" "iptables-restore.service enabled" "systemctl is-enabled --quiet iptables-restore.service"

    run_ok_fail_check "hq_rtr_dhcp" "DHCP service active" "systemctl is-active --quiet dhcpd || systemctl is-active --quiet isc-dhcp-server || systemctl is-active --quiet dhcp-server"

    run_ok_fail_check "hq_rtr_net_admin" "Пользователь net_admin" "id net_admin"

    if check_cmd ip; then
        run_ok_fail_check "hq_rtr_default_route" "Default route присутствует" "ip route | grep -q '^default'"
    else
        run_skip_check "hq_rtr_default_route" "Default route присутствует" "нет команды ip"
    fi

    if check_cmd ping; then
        run_ok_fail_check "hq_rtr_ping_inet" "Ping 77.88.8.8" "ping -c1 -W2 77.88.8.8"
    else
        run_skip_check "hq_rtr_ping_inet" "Ping 77.88.8.8" "нет команды ping"
    fi
}

run_br_rtr_checks() {
    info "Проверки роли: BR-RTR"

    run_hostname_check "br_rtr_hostname" "br-rtr.au-team.irpo"

    if check_cmd ip; then
        run_ok_fail_check "br_rtr_wan" "WAN 172.16.2.2/28" "ip -o -4 addr show | awk '{print \$4}' | grep -Fxq '172.16.2.2/28'"
        run_ok_fail_check "br_rtr_lan" "LAN 192.168.3.1/28" "ip -o -4 addr show | awk '{print \$4}' | grep -Fxq '192.168.3.1/28'"
        run_ok_fail_check "br_rtr_gre_ip" "GRE gre1 = 10.0.0.2/30" "ip -o -4 addr show dev gre1 | awk '{print \$4}' | grep -Fxq '10.0.0.2/30'"
    else
        run_skip_check "br_rtr_wan" "WAN 172.16.2.2/28" "нет команды ip"
        run_skip_check "br_rtr_lan" "LAN 192.168.3.1/28" "нет команды ip"
        run_skip_check "br_rtr_gre_ip" "GRE gre1 = 10.0.0.2/30" "нет команды ip"
    fi

    if check_cmd ping; then
        run_ok_fail_check "br_rtr_gre_ping" "Ping 10.0.0.1" "ping -c1 -W2 10.0.0.1"
    else
        run_skip_check "br_rtr_gre_ping" "Ping 10.0.0.1" "нет команды ping"
    fi

    run_ok_fail_check "br_rtr_frr_active" "FRR active" "systemctl is-active --quiet frr"

    if check_cmd vtysh; then
        run_wait_check "br_rtr_ospf_neighbors" "OSPF соседи (vtysh)" "vtysh -c 'show ip ospf neighbor' | grep -Eq '([0-9]{1,3}\\.){3}[0-9]{1,3}|Full'" 60
    else
        run_skip_check "br_rtr_ospf_neighbors" "OSPF соседи (vtysh)" "нет команды vtysh"
    fi

    if check_cmd iptables; then
        run_ok_fail_check "br_rtr_nat" "iptables MASQUERADE" "iptables -t nat -S | grep -qi MASQUERADE"
    else
        run_skip_check "br_rtr_nat" "iptables MASQUERADE" "нет команды iptables"
    fi

    run_ok_fail_check "br_rtr_net_admin" "Пользователь net_admin" "id net_admin"

    if check_cmd ip; then
        run_ok_fail_check "br_rtr_default_route" "Default route присутствует" "ip route | grep -q '^default'"
    else
        run_skip_check "br_rtr_default_route" "Default route присутствует" "нет команды ip"
    fi

    if check_cmd ping; then
        run_ok_fail_check "br_rtr_ping_inet" "Ping 77.88.8.8" "ping -c1 -W2 77.88.8.8"
    else
        run_skip_check "br_rtr_ping_inet" "Ping 77.88.8.8" "нет команды ping"
    fi
}

run_hq_srv_checks() {
    info "Проверки роли: HQ-SRV"

    run_hostname_check "hq_srv_hostname" "hq-srv.au-team.irpo"

    if check_cmd ip; then
        run_ok_fail_check "hq_srv_ip" "IP 192.168.1.2/27" "ip -o -4 addr show | awk '{print \$4}' | grep -Fxq '192.168.1.2/27'"
    else
        run_skip_check "hq_srv_ip" "IP 192.168.1.2/27" "нет команды ip"
    fi

    run_ok_fail_check "hq_srv_sshuser" "Пользователь sshuser uid=2026" "[[ \"\$(id -u sshuser 2>/dev/null || echo -1)\" == '2026' ]]"

    local sshd_conf
    if sshd_conf="$(detect_sshd_conf 2>/dev/null)"; then
        run_ok_fail_check "hq_srv_ssh_port_conf" "sshd_config: Port 2026" "grep -Eq '^[[:space:]]*Port[[:space:]]+2026([[:space:]]*#.*)?$' \"$sshd_conf\""
    else
        run_skip_check "hq_srv_ssh_port_conf" "sshd_config: Port 2026" "sshd_config не найден"
    fi

    if check_cmd ss; then
        run_ok_fail_check "hq_srv_ssh_port_listen" "SSH слушает порт 2026" "ss -tlnp | grep -Eq '[:.]2026[[:space:]]'"
    else
        run_skip_check "hq_srv_ssh_port_listen" "SSH слушает порт 2026" "нет команды ss"
    fi

    run_ok_fail_check "hq_srv_dnsmasq" "dnsmasq active" "systemctl is-active --quiet dnsmasq"

    if check_cmd nslookup; then
        run_ok_fail_check "hq_srv_dns_direct" "nslookup hq-srv.au-team.irpo @127.0.0.1" "nslookup hq-srv.au-team.irpo 127.0.0.1"
        run_ok_fail_check "hq_srv_dns_ptr" "nslookup 192.168.1.1 @127.0.0.1 (PTR)" "nslookup 192.168.1.1 127.0.0.1"
    else
        run_skip_check "hq_srv_dns_direct" "nslookup hq-srv.au-team.irpo @127.0.0.1" "нет команды nslookup (установите: apt-get install -y bind-utils)"
        run_skip_check "hq_srv_dns_ptr" "nslookup 192.168.1.1 @127.0.0.1 (PTR)" "нет команды nslookup (установите: apt-get install -y bind-utils)"
    fi
}

run_br_srv_checks() {
    info "Проверки роли: BR-SRV"

    run_hostname_check "br_srv_hostname" "br-srv.au-team.irpo"

    if check_cmd ip; then
        run_ok_fail_check "br_srv_ip" "IP 192.168.3.2/28" "ip -o -4 addr show | awk '{print \$4}' | grep -Fxq '192.168.3.2/28'"
    else
        run_skip_check "br_srv_ip" "IP 192.168.3.2/28" "нет команды ip"
    fi

    run_ok_fail_check "br_srv_sshuser" "Пользователь sshuser uid=2026" "[[ \"\$(id -u sshuser 2>/dev/null || echo -1)\" == '2026' ]]"

    local sshd_conf
    if sshd_conf="$(detect_sshd_conf 2>/dev/null)"; then
        run_ok_fail_check "br_srv_ssh_port_conf" "sshd_config: Port 2026" "grep -Eq '^[[:space:]]*Port[[:space:]]+2026([[:space:]]*#.*)?$' \"$sshd_conf\""
        run_ok_fail_check "br_srv_ssh_banner_conf" "sshd_config: Banner задан" "grep -Eq '^[[:space:]]*Banner[[:space:]]+[^#[:space:]]+' \"$sshd_conf\""
    else
        run_skip_check "br_srv_ssh_port_conf" "sshd_config: Port 2026" "sshd_config не найден"
        run_skip_check "br_srv_ssh_banner_conf" "sshd_config: Banner задан" "sshd_config не найден"
    fi

    if check_cmd ss; then
        run_ok_fail_check "br_srv_ssh_port_listen" "SSH слушает порт 2026" "ss -tlnp | grep -Eq '[:.]2026[[:space:]]'"
    else
        run_skip_check "br_srv_ssh_port_listen" "SSH слушает порт 2026" "нет команды ss"
    fi

    run_ok_fail_check "br_srv_dnsmasq" "dnsmasq active" "systemctl is-active --quiet dnsmasq"

    if check_cmd nslookup; then
        run_ok_fail_check "br_srv_dns_direct" "nslookup br-srv.au-team.irpo @127.0.0.1" "nslookup br-srv.au-team.irpo 127.0.0.1"
    else
        run_skip_check "br_srv_dns_direct" "nslookup br-srv.au-team.irpo @127.0.0.1" "нет команды nslookup (установите: apt-get install -y bind-utils)"
    fi
}

run_hq_cli_checks() {
    info "Проверки роли: HQ-CLI"

    run_hostname_check "hq_cli_hostname" "hq-cli.au-team.irpo"

    if check_cmd ip; then
        run_ok_fail_check "hq_cli_dhcp_ip" "DHCP IP из 192.168.2.x/27" "ip -o -4 addr show | awk '{print \$4}' | grep -Eq '^192\\.168\\.2\\.[0-9]+/27$'"
        run_ok_fail_check "hq_cli_default_route" "Default route через 192.168.2.1" "ip route | grep -Eq '^default[[:space:]]+via[[:space:]]+192\\.168\\.2\\.1([[:space:]]|$)'"
    else
        run_skip_check "hq_cli_dhcp_ip" "DHCP IP из 192.168.2.x/27" "нет команды ip"
        run_skip_check "hq_cli_default_route" "Default route через 192.168.2.1" "нет команды ip"
    fi

    run_ok_fail_check "hq_cli_resolv" "resolv.conf -> 192.168.1.2" "grep -Eq '^nameserver[[:space:]]+192\\.168\\.1\\.2$' /etc/resolv.conf"

    if check_cmd nslookup; then
        run_ok_fail_check "hq_cli_dns_name" "Резолв hq-srv.au-team.irpo" "nslookup hq-srv.au-team.irpo"
    else
        run_skip_check "hq_cli_dns_name" "Резолв hq-srv.au-team.irpo" "нет команды nslookup (установите: apt-get install -y bind-utils)"
    fi
}

run_end_to_end_checks() {
    local role="${1:-unknown}"
    info "Сквозная проверка (end-to-end)"
    info "Подсказка: результаты E2E зависят от роли узла, с которого выполняется проверка."
    if [[ "$role" == "isp" ]]; then
        info "На ISP адреса 192.168.x.x (LAN офисов) и 10.0.0.1/10.0.0.2 (GRE HQ-RTR↔BR-RTR) недостижимы by design."
        info "Для осмысленной проверки LAN/GRE запускайте E2E с HQ-RTR, BR-RTR или конечных узлов офисов."
    fi

    local ips=(
        172.16.1.1 172.16.1.2 172.16.2.1 172.16.2.2
        192.168.1.1 192.168.1.2 192.168.2.1 192.168.3.1 192.168.3.2
        10.0.0.1 10.0.0.2
    )

    if check_cmd ping; then
        local ip
        for ip in "${ips[@]}"; do
            run_ok_fail_check "e2e_ping_ip_${ip//./_}" "E2E ping $ip" "ping -c1 -W2 $ip"
        done
    else
        local ip
        for ip in "${ips[@]}"; do
            run_skip_check "e2e_ping_ip_${ip//./_}" "E2E ping $ip" "нет команды ping"
        done
    fi

    local names=(
        hq-rtr.au-team.irpo
        br-rtr.au-team.irpo
        hq-srv.au-team.irpo
        hq-cli.au-team.irpo
        br-srv.au-team.irpo
    )

    if check_cmd nslookup; then
        local name
        for name in "${names[@]}"; do
            run_ok_fail_check "e2e_dns_name_${name//./_}" "E2E DNS $name" "nslookup $name"
        done
    else
        local name
        for name in "${names[@]}"; do
            run_skip_check "e2e_dns_name_${name//./_}" "E2E DNS $name" "нет команды nslookup (установите: apt-get install -y bind-utils)"
        done
    fi
}

detect_role() {
    local h
    h="$(hostnamectl --static 2>/dev/null || hostname 2>/dev/null || echo unknown)"
    case "$h" in
        isp|isp.au-team.irpo) echo "isp" ;;
        hq-rtr|hq-rtr.au-team.irpo) echo "hq-rtr" ;;
        br-rtr|br-rtr.au-team.irpo) echo "br-rtr" ;;
        hq-srv|hq-srv.au-team.irpo) echo "hq-srv" ;;
        br-srv|br-srv.au-team.irpo) echo "br-srv" ;;
        hq-cli|hq-cli.au-team.irpo) echo "hq-cli" ;;
        *) echo "unknown" ;;
    esac
}

select_role_menu() {
    while true; do
        echo
        echo "Выберите роль машины:"
        echo "  0) выход"
        echo "  1) isp"
        echo "  2) hq-rtr"
        echo "  3) br-rtr"
        echo "  4) hq-srv"
        echo "  5) br-srv"
        echo "  6) hq-cli"
        read -rp "Пункт [0-6]: " role_pick
        case "$role_pick" in
            0) info "Проверка отменена пользователем."; exit 0 ;;
            1) echo "isp"; return 0 ;;
            2) echo "hq-rtr"; return 0 ;;
            3) echo "br-rtr"; return 0 ;;
            4) echo "hq-srv"; return 0 ;;
            5) echo "br-srv"; return 0 ;;
            6) echo "hq-cli"; return 0 ;;
            *) warn "Некорректный выбор, попробуйте снова." ;;
        esac
    done
}

run_role_checks() {
    local role="$1"
    case "$role" in
        isp) run_isp_checks ;;
        hq-rtr) run_hq_rtr_checks ;;
        br-rtr) run_br_rtr_checks ;;
        hq-srv) run_hq_srv_checks ;;
        br-srv) run_br_srv_checks ;;
        hq-cli) run_hq_cli_checks ;;
        *) error "Неизвестная роль: $role"; exit 1 ;;
    esac
}

print_summary() {
    local ok_count=0 fail_count=0 skip_count=0

    echo
    echo "================================================================================================================"
    echo "  ИТОГОВАЯ ТАБЛИЦА ПРОВЕРОК"
    echo "================================================================================================================"
    printf "%-8s | %s\n" "СТАТУС" "ПРОВЕРКА"
    echo "----------------------------------------------------------------------------------------------------------------"

    local key status title
    for key in "${RESULT_KEYS[@]}"; do
        status="${RESULT_STATUS[$key]}"
        title="${RESULT_TITLE[$key]}"

        case "$status" in
            OK)
                printf "${GREEN}%-8s${NC} | %s\n" "[OK]" "$title"
                ok_count=$((ok_count + 1))
                ;;
            FAIL)
                printf "${RED}%-8s${NC} | %s\n" "[FAIL]" "$title"
                fail_count=$((fail_count + 1))
                ;;
            *)
                printf "${YELLOW}%-8s${NC} | %s\n" "[SKIP]" "$title"
                skip_count=$((skip_count + 1))
                ;;
        esac
    done

    echo "----------------------------------------------------------------------------------------------------------------"
    echo "OK: $ok_count | FAIL: $fail_count | SKIP: $skip_count"
    echo "================================================================================================================"
}

main() {
    echo
    echo "============================================================"
    echo "  check_all.sh — проверка демоэкзамена (au-team.irpo)"
    echo "============================================================"

    local detected_role selected_role action
    detected_role="$(detect_role)"

    if [[ "$detected_role" != "unknown" ]]; then
        info "Автоопределена роль: $detected_role"
        read -rp "Использовать эту роль? [Y/n]: " use_detected
        if [[ "${use_detected,,}" =~ ^n ]]; then
            selected_role="$(select_role_menu)"
        else
            selected_role="$detected_role"
        fi
    else
        warn "Не удалось автоопределить роль по hostname."
        selected_role="$(select_role_menu)"
    fi

    echo
    echo "Что запустить?"
    echo "  1) Проверка выбранной роли: $selected_role"
    echo "  2) Сквозная проверка (end-to-end)"
    echo "  3) Проверка роли + сквозная"
    echo "  4) Сменить роль и проверить её"
    read -rp "Пункт [1-4]: " action

    case "$action" in
        1)
            run_role_checks "$selected_role"
            ;;
        2)
            run_end_to_end_checks "$selected_role"
            ;;
        3)
            run_role_checks "$selected_role"
            run_end_to_end_checks "$selected_role"
            ;;
        4)
            selected_role="$(select_role_menu)"
            run_role_checks "$selected_role"
            ;;
        *)
            warn "Неизвестный пункт, запускаю проверку выбранной роли по умолчанию."
            run_role_checks "$selected_role"
            ;;
    esac

    print_summary
}

main "$@"

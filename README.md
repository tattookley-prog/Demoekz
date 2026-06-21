# Demoekz

Репозиторий содержит bash-скрипты для демоэкзамена по специальности **09.02.06 Сетевое и системное администрирование** (базовый уровень, 2026), а также скрипты управления инфраструктурой **Proxmox VE**.

---

## Скрипты для демоэкзамена (Модуль 1)

> ⚠️ **Предупреждение:** Скрипты в `scripts/` рассчитаны на **Linux-версии** устройств (Альт сервер / Альт JeOS).  
> Для стенда на **EcoRouter** используйте раздел ниже: «Настройка роутеров на EcoRouter (Rose)».

### Настройка роутеров на EcoRouter (Rose)

Это альтернатива Linux-скриптам для случая, когда HQ-RTR и BR-RTR реализованы на EcoRouter.  
Настройка выполняется в CLI EcoRouter (Rose), автоматизированно с узла Proxmox через `expect` + `qm terminal`.

Новые файлы:
- `ecorouter/hq_rtr_ecorouter.sh`
- `ecorouter/br_rtr_ecorouter.sh`

#### Запуск во время экзамена
1. Скопируйте репозиторий на узел Proxmox:
   ```bash
   git clone https://github.com/tattookley-prog/Demoekz.git
   ```
   Либо скопируйте только каталог `ecorouter/`.
2. Перейдите в каталог и сделайте скрипты исполняемыми:
   ```bash
   cd Demoekz/ecorouter
   chmod +x *.sh
   ```
3. Узнайте VMID нужной ВМ EcoRouter:
   ```bash
   qm list
   ```
4. Запустите настройку HQ-RTR:
   ```bash
   sudo bash hq_rtr_ecorouter.sh
   ```
   Можно и так: `./hq_rtr_ecorouter.sh` (если запуск от root).  
   Введите VMID и параметры (Enter = значение по умолчанию), затем текущий логин/пароль EcoRouter.
5. Аналогично запустите настройку BR-RTR:
   ```bash
   sudo bash br_rtr_ecorouter.sh
   ```
6. Скрипты сами проверяют/устанавливают `expect` и `python3`, подключаются к консоли ВМ через `qm terminal <VMID>`, применяют конфигурацию и в конце выполняют `write memory`.
7. Требования:
   - запуск только от `root` на самом узле Proxmox;
   - EcoRouter-ВМ должна быть включена;
   - физические порты `ge0`/`ge1` должны соответствовать вашей топологии.

#### Основные параметры по умолчанию (EcoRouter)

| Устройство | WAN IP/CIDR | Шлюз WAN | VLAN ID | GRE (внешний remote) | GRE (внутренний) | OSPF пароль |
|---|---|---|---|---|---|---|
| HQ-RTR | `172.16.50.2/28` | `172.16.50.1` | `100` (HQ-SRV), `200` (HQ-CLI), `999` (Mgmt) | `172.16.60.2` | `172.16.0.1/30` | `P@ssword` |
| BR-RTR | `172.16.60.2/28` | `172.16.60.1` | без VLAN (LAN untagged) | `172.16.50.2` | `172.16.0.2/30` | `P@ssword` |

### Билеты (варианты экзамена)

| Скрипт | Вариант | Темы | Устройство |
|---|---|---|---|
| `scripts/variant1_vlan_ipv4.sh` | Вариант 1 | VLAN и Статическая адресация | HQ-RTR |
| `scripts/variant2_routing_ssh.sh` | Вариант 2 | Статическая маршрутизация и SSH | HQ-RTR / BR-RTR |
| `scripts/variant3_dhcp_nat.sh` | Вариант 3 | DHCP и NAT (PAT/Masquerade) | HQ-RTR |
| `scripts/variant4_gre_dns.sh` | Вариант 4 | GRE/IPIP туннели и DNS | HQ-RTR / BR-RTR / HQ-SRV |

#### Вариант 1 — Базовая коммутация и IPv4-адресация
```bash
sudo bash scripts/variant1_vlan_ipv4.sh
```
**Что делает:** создаёт VLAN 10 (Management) и VLAN 20 (Users) на HQ-RTR (sub-интерфейсы eth0.10/eth0.20),
настраивает DHCP для VLAN 20, выводит инструкции для статической настройки HQ-SRV (192.168.10.10/24),
проверяет ping между VLAN.

#### Вариант 2 — Маршрутизация и Безопасный доступ
```bash
sudo bash scripts/variant2_routing_ssh.sh
```
**Что делает:** настраивает IP-адреса (стык 10.0.0.0/30 + LAN), добавляет статический маршрут
до удалённой сети через next-hop, создаёт пользователя `admin` для SSH, запрещает root-вход по паролю.
Запускается поочерёдно на HQ-RTR и BR-RTR.

#### Вариант 3 — Автоматизация сети и Трансляция адресов
```bash
sudo bash scripts/variant3_dhcp_nat.sh
```
**Что делает:** настраивает LAN/WAN интерфейсы, разворачивает DHCP-сервер с пулом от .50 до .100
(с передачей шлюза и DNS), настраивает PAT (Masquerade) через nftables или iptables.

#### Вариант 4 — Туннелирование и Имена узлов
```bash
sudo bash scripts/variant4_gre_dns.sh
```
**Что делает:** создаёт GRE (или IPIP) туннель между офисами с адресацией 172.16.0.0/30,
настраивает DNS-сервер bind/named с зоной `lab.local` и A-записями для всех сетевых устройств
(маршрутизаторов, серверов, туннельных интерфейсов). Имеет три режима: туннель, DNS, оба сразу.

---

### Описание скриптов (основная топология)

| Скрипт | Устройство | ОС | Задания |
|---|---|---|---|
| `scripts/isp_setup.sh` | ISP | **Альт сервер** (etcnet) | 2, 8 (часть) |
| `scripts/hq_rtr_setup.sh` | HQ-RTR | Альт JeOS / Linux | 1, 4, 6, 7, 8, 9 |
| `scripts/br_rtr_setup.sh` | BR-RTR | Альт JeOS / Linux | 1, 3, 6, 7, 8 |
| `scripts/hq_srv_setup.sh` | HQ-SRV | Альт сервер | 1, 3, 5, 10 |
| `scripts/br_srv_setup.sh` | BR-SRV | Альт сервер | 1, 3, 5 |
| `scripts/check_all.sh` | Любая машина | Все роли | Проверка результата (OK/FAIL/SKIP) |

---

### Таблица адресации (Таблица 2)

| Устройство | Интерфейс | IP-адрес | Маска | Шлюз | VLAN |
|---|---|---|---|---|---|
| ISP | WAN (eth0) | DHCP | — | — | — |
| ISP | → HQ-RTR (eth1) | 172.16.1.1 | /28 | — | — |
| ISP | → BR-RTR (eth2) | 172.16.2.1 | /28 | — | — |
| HQ-RTR | WAN (eth0) | 172.16.1.2 | /28 | 172.16.1.1 | — |
| HQ-RTR | VLAN 100 (HQ-SRV) | 192.168.1.1 | /27 (32 хоста) | — | 100 |
| HQ-RTR | VLAN 200 (HQ-CLI) | 192.168.2.1 | /27 (32 хоста) | — | 200 |
| HQ-RTR | VLAN 999 (Управление) | 192.168.99.1 | /29 (8 хостов) | — | 999 |
| HQ-RTR | GRE туннель (gre1) | 10.0.0.1 | /30 | — | — |
| BR-RTR | WAN (eth0) | 172.16.2.2 | /28 | 172.16.2.1 | — |
| BR-RTR | LAN → BR-SRV (eth1) | 192.168.3.1 | /28 (16 хостов) | — | — |
| BR-RTR | GRE туннель (gre1) | 10.0.0.2 | /30 | — | — |
| HQ-SRV | eth0 | 192.168.1.2 | /27 | 192.168.1.1 | 100 |
| HQ-CLI | eth0 | DHCP (192.168.2.x) | /27 | 192.168.2.1 | 200 |
| BR-SRV | eth0 | 192.168.3.2 | /28 | 192.168.3.1 | — |

**Домен:** `au-team.irpo`

---

### DNS-записи (Таблица 3)

| Запись | Тип | IP-адрес |
|---|---|---|
| hq-rtr.au-team.irpo | A, PTR | 192.168.1.1 |
| br-rtr.au-team.irpo | A | 192.168.3.1 |
| hq-srv.au-team.irpo | A, PTR | 192.168.1.2 |
| hq-cli.au-team.irpo | A, PTR | 192.168.2.2 |
| br-srv.au-team.irpo | A | 192.168.3.2 |
| docker.au-team.irpo | A | 172.16.1.1 |
| web.au-team.irpo | A | 172.16.2.1 |

DNS-форвардеры: `77.88.8.7`, `77.88.8.3`

---

### Инструкция по запуску

#### Общие требования
- Запуск **от имени root** (`sudo bash <скрипт>` или `su -` → `bash <скрипт>`)
- Скрипты интерактивны — значения по умолчанию указаны в квадратных скобках
- Рекомендуемый порядок запуска: ISP → HQ-RTR → BR-RTR → HQ-SRV → BR-SRV

#### `scripts/isp_setup.sh` — настройка ISP (Альт сервер)
```bash
sudo bash scripts/isp_setup.sh
```
**Что делает:** hostname `isp.au-team.irpo`, IP-адреса через etcnet (`/etc/net/ifaces/`),
IP forwarding, NAT через nftables (masquerade для HQ-RTR и BR-RTR).

**Особенность ISP:** использует **etcnet** — штатную систему управления сетью Альт сервер.
Конфиги пишутся в `/etc/net/ifaces/<интерфейс>/`, сеть применяется через `systemctl restart network`.

#### `scripts/hq_rtr_setup.sh` — настройка HQ-RTR
```bash
sudo bash scripts/hq_rtr_setup.sh
```
**Что делает:** hostname, IP через etcnet, VLAN 100/200, GRE-туннель `gre1`,
OSPF через FRR (на `gre1` ускоренные таймеры hello/dead 1/4 для быстрого
восстановления соседства после `systemctl restart network`; FRR также
перезапускается вместе с сетью, чтобы `ospfd` заново инициализировался на
новом `gre1`; дополнительно включены OSPF graceful-restart (NSF) и BFD для
сохранения маршрутов/устойчивости при `systemctl restart network`), NAT через
iptables (MASQUERADE), правила FORWARD и MSS clamp
(задание №8 — доступ в Интернет для всех устройств офиса), DHCP для HQ-CLI,
автозагрузка iptables через systemd (`iptables-restore.service`), пользователь `net_admin`.

#### `scripts/br_rtr_setup.sh` — настройка BR-RTR
```bash
sudo bash scripts/br_rtr_setup.sh
```
**Что делает:** hostname, IP (nmcli), GRE-туннель `gre1`, OSPF через FRR
(на `gre1` ускоренные таймеры hello/dead 1/4 для быстрого восстановления
соседства после `systemctl restart network`; FRR также перезапускается вместе
с сетью, чтобы `ospfd` заново инициализировался на новом `gre1`; дополнительно
включены OSPF graceful-restart (NSF), а BFD включается только если в системе
доступен `bfdd`), NAT через iptables, пользователь `net_admin`.
Скрипт гарантирует попытку установки FRR сначала из офлайн-пакетов (`/root/pkgs`,
`/root/pkgs/br-rtr`, `/tmp/offline_pkgs/br-rtr`), затем из сетевого репозитория,
и в конце активно проверяет поднятие OSPF-соседа `10.0.0.1` (до 60 секунд).

#### Troubleshooting: FRR на BR-RTR неактивен / нет OSPF-соседа / нет пинга HQ-CLI → BR-SRV
```bash
systemctl status frr --no-pager -l
journalctl -u frr -n 50 --no-pager
rpm -q frr
vtysh -c 'show ip ospf neighbor'
ip -d link show gre1
ping -c1 10.0.0.1
```

#### `scripts/hq_srv_setup.sh` — настройка HQ-SRV
```bash
sudo bash scripts/hq_srv_setup.sh
```
**Что делает:** hostname, IP, пользователь `sshuser` (uid=2026), SSH на порту 2026,
DNS-сервер `dnsmasq` с зоной `au-team.irpo` и PTR-записями для локальных адресов.

#### `scripts/br_srv_setup.sh` — настройка BR-SRV
```bash
sudo bash scripts/br_srv_setup.sh
```
**Что делает:** hostname, IP (192.168.3.2/28), пользователь `sshuser` (uid=2026),
SSH на порту 2026 с баннером, DNS-сервер `dnsmasq`.

#### `scripts/check_all.sh` — проверка выполнения
```bash
sudo bash scripts/check_all.sh
```
**Что делает:** интерактивно определяет роль узла (или даёт выбрать вручную),
выполняет релевантные проверки по топологии (`isp`, `hq-rtr`, `br-rtr`, `hq-srv`, `br-srv`, `hq-cli`),
поддерживает пункт **«Сквозная проверка (end-to-end)»** (ping по всем адресам + проверка DNS-имён)
и в конце выводит итоговую таблицу со статусами **OK / FAIL / SKIP**.

---

### Параметры скриптов

Все setup-скрипты теперь спрашивают сетевые параметры интерактивно и показывают полную сводку перед подтверждением. Если просто нажимать `Enter`, будет применена прежняя эталонная схема адресации. Основные defaults:

- `scripts/hq_rtr_setup.sh`: `WAN_IFACE=ens18`, `TRUNK_IFACE=ens19`, `TZ_NAME=Europe/Moscow`, `DOMAIN=au-team.irpo`, `WAN_IP_CIDR=172.16.1.2/28`, `WAN_GW=172.16.1.1`, `WAN_IP=172.16.1.2`, `BR_WAN_IP=172.16.2.2`, `VLAN100_ID=100`, `VLAN100_IP_CIDR=192.168.1.1/27`, `VLAN100_NET=192.168.1.0/27`, `VLAN200_ID=200`, `VLAN200_IP_CIDR=192.168.2.1/27`, `VLAN200_IP=192.168.2.1`, `VLAN200_NET=192.168.2.0/27`, `MTU_VLAN=1400`, `GRE_LOCAL_IP=172.16.1.2`, `GRE_TUNNEL_CIDR=10.0.0.1/30`, `GRE_NET=10.0.0.0/30`, `OSPF_ROUTER_ID=10.0.0.1`, `OSPF_PASS=P@ssw0rd`, `HQ_SRV_IP=192.168.1.2`, `DHCP_SUBNET=192.168.2.0`, `DHCP_NETMASK=255.255.255.224`, `DHCP_RANGE_START=192.168.2.2`, `DHCP_RANGE_END=192.168.2.30`.
- `scripts/hq_srv_setup.sh`: `NET_IFACE=ens18`, `TZ_NAME=Europe/Moscow`, `DOMAIN=au-team.irpo`, `SRV_IP_CIDR=192.168.1.2/27`, `SRV_GW=192.168.1.1`, `SSH_PORT=2026`, `SSH_USER=sshuser`, `SSH_MAX_TRIES=2`, `USER_UID=2026`, `SSH_BANNER_TEXT=Authorized access only`, `DNS_FORWARDER1=77.88.8.7`, `DNS_FORWARDER2=77.88.8.3` и IP-записи зоны (`IP_HQ_RTR`, `IP_BR_RTR`, `IP_HQ_SRV`, `IP_HQ_CLI`, `IP_BR_SRV`, `IP_DOCKER`, `IP_WEB`) со старыми значениями по умолчанию.
- `scripts/hq_cli_setup.sh`: `NET_IFACE=eth0`, `TZ_NAME=Europe/Moscow`, `DOMAIN=au-team.irpo`, `NET_MODE=dhcp`, `STATIC_IP=192.168.2.2/27`, `STATIC_GW=192.168.2.1`, `DNS_IP=192.168.1.2`, `SSH_PORT=2026`, `SSH_USER=sshuser`, `SSH_MAX_TRIES=2`, `USER_UID=2026`, `SSH_BANNER_TEXT=Authorized access only`, `ROUTER_SSH_PORT=22`, `HQ_SRV_HOST=hq-srv.au-team.irpo`, `BR_SRV_HOST=br-srv.au-team.irpo`, `HQ_RTR_HOST=hq-rtr.au-team.irpo`, `BR_RTR_HOST=br-rtr.au-team.irpo`.
- `scripts/br_rtr_setup.sh`: `WAN_IFACE=ens18`, `LAN_IFACE=ens19`, `TZ_NAME=Europe/Moscow`, `DOMAIN=au-team.irpo`, `WAN_IP_CIDR=172.16.2.2/28`, `WAN_GW=172.16.2.1`, `WAN_IP=172.16.2.2`, `HQ_WAN_IP=172.16.1.2`, `DNS_FORWARDER1=77.88.8.7`, `DNS_FORWARDER2=77.88.8.3`, `LAN_IP_CIDR=192.168.3.1/28`, `GRE_LOCAL_IP=172.16.2.2`, `GRE_TUNNEL_CIDR=10.0.0.2/30`, `GRE_NET=10.0.0.0/30`, `OSPF_ROUTER_ID=10.0.0.2`, `OSPF_PASS=P@ssw0rd`.
- `scripts/br_srv_setup.sh`: `NET_IFACE=ens18`, `TZ_NAME=Europe/Moscow`, `DOMAIN=au-team.irpo`, `SRV_IP_CIDR=192.168.3.2/28`, `SRV_GW=192.168.3.1`, `SSH_PORT=2026`, `SSH_USER=sshuser`, `SSH_MAX_TRIES=2`, `USER_UID=2026`, `SSH_BANNER_TEXT=Authorized access only`, `DNS_FORWARDER1=77.88.8.7`, `DNS_FORWARDER2=77.88.8.3` и IP-записи зоны со старыми defaults.
- `scripts/isp_setup.sh`: `WAN_IFACE=eth0`, `HQ_IFACE=eth1`, `BR_IFACE=eth2`, `TZ_NAME=Europe/Moscow`, `DOMAIN=au-team.irpo`, `HQ_IP=172.16.1.1/28`, `BR_IP=172.16.2.1/28`, `HQ_NAT_NET=172.16.1.0/28`, `BR_NAT_NET=172.16.2.0/28`.

---

### Технические особенности скриптов

| Возможность | Реализация |
|---|---|
| `set -euo pipefail` | Немедленная остановка при любой ошибке |
| Цветной вывод | `[INFO]` cyan, `[OK]` green, `[WARN]` yellow, `[ERROR]` red |
| Проверка root | В начале каждого скрипта |
| Резервные копии | `.bak` для всех изменяемых конфигов |
| Значения по умолчанию | В квадратных скобках при каждом вводе |
| Итоговый статус | Таблица OK/ERROR/SKIP в конце каждого скрипта |
| Совместимость | apt-get, имена пакетов Альт Линукс |

---

## Что было сделано

### Создан файл `proxmox_setup.sh`

Это интерактивный bash-скрипт с текстовым меню, который запускается непосредственно на узле Proxmox VE от имени `root`. При старте скрипт проверяет два условия:

1. **Права root** — если запустить без `sudo`/под обычным пользователем, скрипт сразу завершится с ошибкой.
2. **Наличие Proxmox** — проверяется наличие утилиты `pvesh`; если её нет, значит скрипт запущен не на узле PVE.

После проверок открывается **главное меню** с 8 пунктами.

---

## Подробное описание каждого пункта меню

### 1 — Информация об узле

Выводит техническую информацию о текущем узле Proxmox:
- Версию Proxmox VE, ядро, статус памяти, CPU и дисков через `pvesh get /nodes/<hostname>`.
- Если команда недоступна — показывает краткую версию через `pveversion`.

### 2 — Список ВМ и контейнеров

Выводит две таблицы:
- **`qm list`** — список всех виртуальных машин KVM: их VMID, имя, статус (running/stopped), используемая память.
- **`pct list`** — список всех LXC-контейнеров: их VMID, статус, имя хоста.

### 3 — Создать LXC-контейнер

Интерактивно спрашивает у пользователя параметры и создаёт Linux-контейнер (LXC):

| Параметр | Пример |
|---|---|
| VMID | `100` |
| Имя хоста | `mycontainer` |
| Пароль root (скрытый ввод) | `••••••••` |
| Шаблон | `local:vztmpl/ubuntu-22.04-standard_22.04-1_amd64.tar.zst` |
| Размер диска (ГБ) | `8` |
| RAM (МБ) | `512` |
| Число CPU | `1` |
| Сетевой мост | `vmbr0` |
| IP / маска или `dhcp` | `192.168.1.100/24` |
| Шлюз | `192.168.1.1` |

После ввода скрипт **проверяет корректность** данных (VMID — число, имя хоста — допустимые символы, размер/RAM/CPU — положительные числа), затем вызывает `pct create` и **автоматически запускает** контейнер (`--start 1`).

> Пароль вводится в скрытом режиме — символы не отображаются на экране.

### 4 — Создать виртуальную машину (KVM)

Интерактивно создаёт полноценную виртуальную машину с эмуляцией железа через KVM/QEMU:

| Параметр | Пример |
|---|---|
| VMID | `200` |
| Имя ВМ | `debian-server` |
| RAM (МБ) | `2048` |
| Число vCPU | `2` |
| Размер диска (ГБ) | `20` |
| Сетевой мост | `vmbr0` |
| Путь к ISO | `local:iso/debian-12.iso` |

Скрипт:
1. Создаёт ВМ через `qm create` с сетевым адаптером VirtIO.
2. Выделяет диск в хранилище `local-lvm` через `pvesm alloc`.
3. Привязывает диск к ВМ и настраивает порядок загрузки.

### 5 — Управление снапшотами

Вложенное меню из 4 действий:

- **Создать снапшот ВМ** — `qm snapshot <VMID> <имя>`. Сохраняет текущее состояние ВМ, включая RAM.
- **Создать снапшот контейнера** — `pct snapshot <VMID> <имя>`. Фиксирует состояние файловой системы LXC.
- **Показать снапшоты ВМ** — `qm listsnapshot <VMID>`.
- **Показать снапшоты контейнера** — `pct listsnapshot <VMID>`.

Имена снапшотов проверяются: допустимы только латинские буквы, цифры, дефис и подчёркивание.

### 6 — Состояние хранилища

Выводит:
- `pvesm status` — список всех хранилищ Proxmox (local, local-lvm и т.д.) с их типом, статусом, доступным местом.
- `df -h` — использование файловых систем (отфильтрованы служебные `tmpfs`/`udev`).

### 7 — Сетевые настройки

Выводит:
- `ip -brief address` — краткий список сетевых интерфейсов с IP-адресами.
- `brctl show` (или `ip link show type bridge`) — список сетевых мостов Proxmox (например, `vmbr0`), к которым подключаются ВМ и контейнеры.

### 8 — Обновить Proxmox

Перед обновлением просит подтверждение (`y/N`). При согласии выполняет:
```bash
apt-get update      # обновляет список пакетов
apt-get dist-upgrade # устанавливает обновления, включая ядро и PVE-пакеты
```
При ошибке на любом шаге скрипт немедленно останавливается с сообщением.

### 9 — Управление пользователями PVE

Вложенное меню из 5 действий:

- **Список пользователей** — `pveum user list`. Выводит всех пользователей Proxmox.
- **Создать пользователя** — `pveum user add <user@realm>`. Запрашивает userid (в формате `user@realm`), пароль (дважды, скрытый ввод, минимум 8 символов) и необязательный комментарий.
- **Изменить пароль** — `pveum passwd <user@realm>`. Запрашивает userid и новый пароль (дважды, с подтверждением).
- **Назначить роль** — `pveum acl modify`. Показывает список доступных ролей, запрашивает userid, роль и путь ACL (например, `/` или `/vms`).
- **Удалить пользователя** — `pveum user delete <user@realm>`. Запрашивает подтверждение перед удалением.

Формат userid проверяется: допустимы только строки вида `имя@realm` (латиница, цифры, `.`, `-`, `_`).

---

## Технические решения, реализованные в скрипте

| Решение | Зачем |
|---|---|
| `set -euo pipefail` | Скрипт падает при любой ошибке, неопределённой переменной или сбое в пайпе |
| Цветной вывод (`[INFO]`, `[OK]`, `[WARN]`, `[ERROR]`) | Удобно читать вывод в терминале |
| Валидация всех вводимых данных | Защита от случайных опечаток и некорректных команд |
| `read -s` для пароля | Пароль не отображается на экране |
| Проверки `require_root` и `require_proxmox` | Скрипт не запустится в неподходящей среде |
| Модульная структура (функция на раздел) | Легко добавлять новые пункты меню |

---

## Требования для запуска

- Proxmox VE **7** или **8**
- Запуск **от имени root** (`sudo` или напрямую как root)
- Узел PVE (скрипт должен выполняться на самом сервере Proxmox, не удалённо)

## Запуск

```bash
chmod +x proxmox_setup.sh
bash proxmox_setup.sh
```

---

> Скрипт будет расширяться в процессе подготовки к демоэкзамену. Следующие возможные дополнения: настройка сети (`/etc/network/interfaces`), резервное копирование ВМ, работа с кластером.

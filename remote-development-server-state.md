# Remote Development Server — текущее состояние

Снимок состояния сервера: **2026-08-31 19:58:18 UTC**  
Снимок получен через рабочее SSH-подключение по приватной сети Tailscale.

> Документ не содержит приватных ключей, токенов или паролей. Это операционный снимок, который следует обновлять после существенных изменений на сервере.

## 1. Доступ и сеть

| Параметр | Значение |
|---|---|
| Пользователь | `vpsadmin` |
| Публичный адрес | `164.5.249.213:22` |
| Приватный SSH-адрес | `100.76.79.34:22` через `tailscale0` |
| Tailscale IPv6 | `fd7a:115c:a1e0::8d2a:4f23` |
| Локальный клиент | `igor-big`, `100.92.71.48` |
| Имя узла Tailscale | `remoteworkserver` |

Новые подключения к публичному TCP-порту 22 заблокированы UFW. Рабочий SSH-доступ выполняется через Tailscale.

Пример подключения с локального Windows-компьютера:

```powershell
ssh -o HostKeyAlias=164.5.249.213 -o IdentitiesOnly=no vpsadmin@100.76.79.34
```

`HostKeyAlias` позволяет использовать уже подтверждённую запись ключа хоста для публичного адреса при подключении к тому же серверу через Tailscale IP. Отключать проверку host key не следует.

## 2. Операционная система и ресурсы

| Параметр | Значение |
|---|---|
| Hostname | `MyServAlphaLab` |
| ОС | Ubuntu 24.04.4 LTS (Noble) |
| Архитектура | x86_64 |
| Kernel | `6.8.0-138-generic` |
| Пользователь | `vpsadmin` (UID 1000) |
| Группы | `vpsadmin`, `sudo`, `docker` |
| ОЗУ на момент снимка | 5.8 GiB всего; около 5.3 GiB доступно |
| Root filesystem | `/dev/vda2`, ext4, 54 GiB; 7.8 GiB занято, 43 GiB свободно |

## 3. Tailscale

- Версия: `1.102.3`.
- Сервис `tailscaled`: `enabled` и `active`.
- Интерфейс: `tailscale0`.
- IPv4 сервера: `100.76.79.34`.
- IPv6 сервера: `fd7a:115c:a1e0::8d2a:4f23`.
- В tailnet активны сервер `remoteworkserver` и клиент Windows `igor-big`.
- UFW и SSH-настройки после установки Tailscale дополнительно ограничены так, чтобы публичный SSH был закрыт, а SSH через `tailscale0` оставался доступным.

## 4. Firewall и SSH

### UFW

Состояние UFW: активен.

Политики по умолчанию:

```text
deny (incoming)
allow (outgoing)
deny (routed)
```

Разрешения для SSH:

```text
22/tcp ALLOW IN on tailscale0
22/tcp (v6) ALLOW IN on tailscale0
```

Глобальных правил `22/tcp ALLOW IN Anywhere` и `Anywhere (v6)` нет. Другие правила UFW в рамках этой настройки не изменялись. Состояние внешнего firewall провайдера этим снимком не проверялось.

### Effective SSH configuration

```text
port 22
permitrootlogin no
passwordauthentication no
kbdinteractiveauthentication no
pubkeyauthentication yes
allowtcpforwarding yes
clientaliveinterval 60
clientalivecountmax 3
```

Прикладной drop-in:

`/etc/ssh/sshd_config.d/90-remote-dev.conf`

```text
# Remote Development Server settings
AllowTcpForwarding yes
ClientAliveInterval 60
ClientAliveCountMax 3
```

## 5. Swap и persistence

Активны оба ресурса Swap:

| Ресурс | Размер | Состояние |
|---|---:|---|
| `/dev/vda3` | около 1 GiB | active |
| `/swapfile` | 3 GiB | active |
| Итого | около 4 GiB | active |

Записи в `/etc/fstab`:

```text
/dev/vda3 none swap sw 0 0
/swapfile none swap sw 0 0
```

`/swapfile` имеет размер `3221225472` bytes, владельца `root:root` и права `600` (`-rw-------`).

## 6. Sysctl

Эффективные значения:

```text
vm.swappiness = 10
vm.vfs_cache_pressure = 50
fs.inotify.max_user_watches = 524288
fs.inotify.max_user_instances = 512
```

Источники конфигурации:

- `/etc/sysctl.d/60-dev-limits.conf` содержит лимиты inotify.
- `/etc/sysctl.d/99-sysctl.conf` — symlink на `/etc/sysctl.conf`; это один источник, а не независимое дублирование.
- `/etc/sysctl.conf` содержит `vm.swappiness=10` и `vm.vfs_cache_pressure=50`.
- `systemd-sysctl.service` успешно применил настройки и после перезагрузки находится в состоянии `active (exited)`.

## 7. Systemd-сервисы

| Сервис | Автозапуск | Состояние после reboot |
|---|---|---|
| `docker` | enabled | active |
| `ssh` | enabled | active |
| `tailscaled` | enabled | active |
| `systemd-sysctl.service` | system-managed | active (exited) |

Автозапуск проверен после перезагрузки сервера.

## 8. Dev-инструменты

| Инструмент | Версия / состояние |
|---|---|
| Docker Engine | `29.7.2`, enabled/active |
| Docker Compose plugin | `v5.5.0` |
| Docker без `sudo` | работает для `vpsadmin` после новой login-сессии |
| Запущенные контейнеры | отсутствуют (`docker ps` пуст) |
| Git | `2.43.0` |
| Curl | `8.5.0` |
| NVM | `v0.40.6`, установлен в `/home/vpsadmin/.nvm` |
| Node.js | `v24.20.0` (LTS на момент установки) |
| npm | `11.19.0` |
| pnpm | `11.24.0` |
| Supabase CLI | `2.116.0` |
| tmux | `3.4` |

Не выполнялись проектные команды `supabase login`, `supabase init` и `supabase start`.

Конфигурация tmux в `/home/vpsadmin/.tmux.conf`:

```text
set -g mouse on
set -g history-limit 10000
```

## 9. Сетевые слушатели и Docker

- SSH слушает `0.0.0.0:22` и `[::]:22`; доступ на уровне UFW разрешён только через `tailscale0`.
- Tailscale использует UDP-порт `41641` и внутренние TCP-сокеты.
- Docker bridge: `docker0`, адрес `172.17.0.1/16`; публичные Docker-порты не публиковались.
- Запущенных контейнеров на момент снимка нет.

## 10. Reboot и обновления

- Перезагрузка сервера выполнена и проверена повторным подключением через Tailscale.
- После reboot восстановились Swap, sysctl, Docker, SSH и Tailscale.
- `reboot-required`: `no`.
- Осталось одно доступное обновление пакета: `cpio` (`2.15+dfsg-1ubuntu2.1`). Полное обновление системы в текущую настройку не входило.

## 11. Что было изменено в рамках настройки

- Добавлен `/swapfile` размером 3 GiB; существующий Swap-раздел `/dev/vda3` не изменялся.
- Настроены параметры памяти и лимиты inotify.
- Добавлен SSH drop-in для forwarding и keepalive.
- Установлены Docker Engine, Compose plugin, Tailscale и dev-инструменты.
- Включён автозапуск `docker`, `ssh` и `tailscaled`.
- SSH в UFW ограничен интерфейсом `tailscale0`; публичный SSH-порт закрыт для новых соединений.
- Локальный рабочий проект на сервере в рамках этих действий не изменялся.

## 12. Команды для обновления снимка

Минимальная проверка текущего состояния:

```bash
hostname
id
sudo tailscale status
tailscale ip -4
sudo ufw status verbose
swapon --show
free -h
sysctl vm.swappiness vm.vfs_cache_pressure fs.inotify.max_user_watches fs.inotify.max_user_instances

for service in docker ssh tailscaled; do
  printf '%s enabled=' "$service"
  sudo systemctl is-enabled "$service"
  printf '%s active=' "$service"
  sudo systemctl is-active "$service"
done

docker version
docker compose version
node --version
pnpm --version
supabase --version
tmux -V
```

При изменении SSH или UFW необходимо сохранять текущую рабочую Tailscale-сессию до завершения проверки нового подключения.

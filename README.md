# Secure VPS Bootstrap

Универсальный Codex-скилл для первоначальной защиты VPS на Ubuntu или Debian.

Он создаёт отдельного администратора с авторизацией по SSH-ключу, настраивает `NOPASSWD sudo`, отключает удалённый root-доступ и парольную/keyboard-interactive авторизацию, включает UFW и Fail2ban, устанавливает базовые утилиты и настраивает автоматические security updates без автоматической перезагрузки.

Главное правило: исходная SSH-сессия остаётся открытой до тех пор, пока новый ключевой вход не проверен в отдельной сессии.

## Состав проекта

```text
secure-vps-bootstrap/
├── SKILL.md
├── agents/openai.yaml
├── references/security-policy.md
├── scripts/secure_vps_bootstrap.sh
└── tests/run.sh
```

## Требования

На управляющей машине:

- SSH-клиент и `scp`.
- Приватный SSH-ключ, соответствующий публичному ключу, который будет установлен на VPS.
- Доступ к VPS под `root` или пользователем с рабочим `sudo`.

На сервере:

- Ubuntu или Debian.
- `systemd`, `apt-get` и OpenSSH Server.
- Открытая текущая SSH-сессия на время всей настройки.

Приватный ключ никогда не загружается на VPS и не передаётся агенту в тексте сообщения.

## Установка скилла в Codex

Исходник уже находится здесь:

```text
C:\Users\safro\Desktop\ServSetup\secure-vps-bootstrap
```

Для автоматического обнаружения Codex скопируйте только каталог скилла в пользовательский каталог skills:

```powershell
$source = 'C:\Users\safro\Desktop\ServSetup\secure-vps-bootstrap'
$destination = Join-Path $env:USERPROFILE '.codex\skills\secure-vps-bootstrap'
New-Item -ItemType Directory -Force -Path (Split-Path $destination) | Out-Null
Copy-Item -LiteralPath $source -Destination $destination -Recurse -Force
```

Если скилл нужен только в текущем проекте, этот шаг не требуется: используйте его по пути выше или явно укажите агенту путь к `SKILL.md`.

## Если есть только IP и root-пароль

Это нормальный стартовый сценарий. Сначала создайте ключ на своём компьютере, а не на VPS.

В PowerShell:

```powershell
ssh-keygen -t ed25519 `
  -f "$env:USERPROFILE\.ssh\vps_admin" `
  -C "vps-admin"
```

Нажимайте Enter для значений по умолчанию. Появятся:

```text
C:\Users\ВАШ_ПОЛЬЗОВАТЕЛЬ\.ssh\vps_admin
C:\Users\ВАШ_ПОЛЬЗОВАТЕЛЬ\.ssh\vps_admin.pub
```

Файл без `.pub` — приватный ключ. Не отправляйте его в чат и не загружайте на VPS.

После этого откройте Codex в папке проекта и отправьте prompt:

```text
Use $secure-vps-bootstrap to harden my fresh VPS.

Host: YOUR_SERVER_IP
Initial user: root
Initial SSH port: 22
Initial authentication: root password entered interactively in the terminal
Public key: C:\Users\YOUR_USER\.ssh\vps_admin.pub
Private key: C:\Users\YOUR_USER\.ssh\vps_admin
New administrator: vpsadmin
Additional public ports: none

Inspect first, preserve the original SSH session, and proceed autonomously through the second-SSH checkpoint. Do not reboot the server.
```

Замените `YOUR_SERVER_IP` и `YOUR_USER`. Root-пароль не вставляйте в prompt: введите его только в интерактивном запросе SSH в терминале. Если Codex ещё не видит скилл по имени, сначала выполните установку из раздела выше или явно укажите путь к `secure-vps-bootstrap/SKILL.md`.

## Рекомендуемый запуск через Codex

Откройте Codex в проекте и отправьте запрос примерно такого вида:

```text
Use $secure-vps-bootstrap to harden my fresh VPS.

Host: 203.0.113.10
Initial user: root
Initial SSH port: 22
Public key: C:\Users\me\.ssh\id_ed25519.pub
Private key: C:\Users\me\.ssh\id_ed25519
New administrator: vpsadmin
Additional public ports: none

Inspect first, preserve the original SSH session, and proceed autonomously through the second-SSH checkpoint. Do not reboot the server.
```

Замените примерный IP, пути и имя пользователя на свои значения. Агент должен:

1. Проверить fingerprint SSH host key через панель VPS-провайдера или показать его для подтверждения.
2. Открыть исходную SSH-сессию и не закрывать её.
3. Выполнить `inspect`, затем `prepare`.
4. Подключиться новой SSH-сессией по ключу под новым администратором.
5. Проверить `sudo -n true`.
6. Выполнить `lockdown` из новой сессии.
7. Создать ещё одну SSH-сессию и выполнить `verify`.
8. Удалить только временный staging-каталог, сохранив установленный исполнитель и backups.

Не просите агента отключать парольный вход одним длинным блоком команд и не закрывайте исходную root-сессию до успешного `STATUS=SECURE`.

## Ручной запуск исполнителя

Скилл содержит серверный Bash-исполнитель. Сначала создайте или выберите ключ на локальной машине:

```bash
ssh-keygen -t ed25519 -f ~/.ssh/vps_admin -C "vps-admin"
```

Публичный ключ находится в `~/.ssh/vps_admin.pub`, приватный остаётся локально.

### 1. Загрузить файлы

В исходной root-сессии создайте уникальный root-only staging-каталог и загрузите туда публичный ключ и скрипт. Пример для Linux/macOS/Git Bash:

```bash
HOST=203.0.113.10
STAGE="/root/.secure-vps-bootstrap-upload-$(date -u +%Y%m%dT%H%M%SZ)-$$"

ssh root@"$HOST" "install -d -m 700 '$STAGE'"
scp ~/.ssh/vps_admin.pub root@"$HOST":"$STAGE/admin.pub"
scp secure-vps-bootstrap/scripts/secure_vps_bootstrap.sh root@"$HOST":"$STAGE/secure_vps_bootstrap.sh"
ssh root@"$HOST" "install -o root -g root -m 0755 '$STAGE/secure_vps_bootstrap.sh' /usr/local/sbin/secure-vps-bootstrap"
```

Если destination `/usr/local/sbin/secure-vps-bootstrap` уже содержит неизвестный файл, остановитесь и не перезаписывайте его.

### 2. Инспекция

Не закрывая исходную сессию:

```bash
/usr/local/sbin/secure-vps-bootstrap inspect
```

Проверьте ОС, фактический SSH-порт, слушающие сервисы и полный список правил UFW. Если нужны только определённые публичные порты, сначала разберите уже существующие правила: скилл их сохраняет и не удаляет автоматически.

### 3. Подготовка

```bash
/usr/local/sbin/secure-vps-bootstrap prepare \
  --admin-user vpsadmin \
  --public-key-file "$STAGE/admin.pub"
```

Для нестандартного SSH-порта:

```bash
/usr/local/sbin/secure-vps-bootstrap prepare \
  --admin-user vpsadmin \
  --public-key-file "$STAGE/admin.pub" \
  --ssh-port 2222 \
  --allow-port 443/tcp
```

Дополнительные порты добавляйте отдельными параметрами `--allow-port PORT/tcp` или `--allow-port PORT/udp`. Успешная подготовка напечатает:

```text
STATUS=CHECKPOINT_READY
RUN_ID=...
```

Сохраните `RUN_ID`.

### 4. Проверка нового входа

Из управляющей машины откройте отдельное соединение. Параметры ниже не позволяют SSH-клиенту принять другой ключ или переиспользовать старый multiplexed connection:

```bash
ssh -p 22 -i ~/.ssh/vps_admin \
  -o IdentitiesOnly=yes \
  -o PreferredAuthentications=publickey \
  -o PasswordAuthentication=no \
  -o ControlMaster=no \
  -o ControlPath=none \
  vpsadmin@203.0.113.10
```

В новой сессии выполните:

```bash
sudo -n true
```

Если команда неуспешна, не выполняйте lockdown. Исправьте ключ или пользователя через исходную root-сессию.

### 5. Lockdown

Только в новой сессии `vpsadmin`:

```bash
sudo --preserve-env=SSH_CONNECTION \
  /usr/local/sbin/secure-vps-bootstrap lockdown --run-id RUN_ID
```

Скрипт проверит эффективную конфигурацию OpenSSH через `sshd -t` и `sshd -T`, затем отключит удалённый root, password и keyboard-interactive login. Он не перезагружает сервер, а только делает reload SSH.

### 6. Финальная проверка

Откройте третью новую SSH-сессию с теми же `-o IdentitiesOnly=yes`, `-o ControlMaster=no` и `-o ControlPath=none`, затем выполните:

```bash
sudo --preserve-env=SSH_CONNECTION \
  /usr/local/sbin/secure-vps-bootstrap verify --run-id RUN_ID
```

Ожидаемый результат:

```text
STATUS=SECURE
```

После этого временный staging-каталог можно удалить. Файл `/usr/local/sbin/secure-vps-bootstrap`, состояние и backups оставьте на сервере для будущей проверки и rollback.

## Проверка состояния после настройки

```bash
sudo --preserve-env=SSH_CONNECTION \
  /usr/local/sbin/secure-vps-bootstrap verify --run-id RUN_ID
```

Скрипт также выведет фактические правила UFW, состояние Fail2ban, статус reboot requirement и путь к backup.

## Откат

Если новый вход после lockdown не работает, не закрывайте исходную root-сессию и выполните в ней:

```bash
sudo /usr/local/sbin/secure-vps-bootstrap rollback --run-id RUN_ID
```

После rollback проверьте исходный доступ. Откат восстанавливает управляемые конфигурационные файлы и состояние служб, но не отменяет уже установленные пакеты и package upgrades.

## Тесты проекта

Из Git Bash или другой Bash-среды:

```bash
bash -n secure-vps-bootstrap/scripts/secure_vps_bootstrap.sh
bash -n secure-vps-bootstrap/tests/run.sh
bash secure-vps-bootstrap/tests/run.sh
```

В тестовой среде Codex дополнительно:

```bash
python C:/Users/safro/.codex/skills/.system/skill-creator/scripts/quick_validate.py \
  C:/Users/safro/Desktop/ServSetup/secure-vps-bootstrap
```

## Ограничения

- Поддерживаются Ubuntu и Debian с `apt-get`, systemd и OpenSSH.
- Provider firewall, security groups, NAT и upstream-фильтрация не проверяются этим скиллом.
- Существующие UFW allow rules сохраняются; скилл не удаляет их автоматически.
- Сервер не перезагружается автоматически.
- Приватные ключи, пароли, токены и содержимое `.env` не обрабатываются.
- Ручная установка прикладного runtime, Docker, веб-сервера и reverse proxy не входит в scope.

## Полезные ссылки

- [OpenSSH `sshd_config`](https://man.openbsd.org/sshd_config)
- [Ubuntu Firewall/UFW](https://ubuntu.com/server/docs/how-to/security/firewalls/)
- [Debian Fail2ban configuration](https://manpages.debian.org/bookworm/fail2ban/jail.conf.5.en.html)
- [Ubuntu security updates](https://documentation.ubuntu.com/security/security-updates/)

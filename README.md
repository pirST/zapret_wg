# zapret-wg

Docker-контейнер с WireGuard-сервером, через который проходит трафик клиентов,
с обходом DPI через
[zapret-discord-youtube-linux](https://github.com/Sergeydigl3/zapret-discord-youtube-linux)
(nfqws + стратегии Flowseal) и с опциональным DNS-прокси на
[AdGuard dnsproxy](https://github.com/adguardteam/dnsproxy), который
пересылает запросы клиентов на DoH через тот же zapret.

## Как это работает

- Контейнер поднимает WireGuard-сервер (`wg0`) и NAT для клиентов.
- Если задан `DNSPROXY_CONF` (строка с флагами dnsproxy), контейнер
  запускает [dnsproxy](https://github.com/adguardteam/dnsproxy): он слушает
  `53/udp` и `53/tcp`, принимает обычный DNS от клиентов WireGuard (и из LAN,
  если порт опубликован) и пересылает запросы на DoH-апстрим. При пустой
  переменной dnsproxy не запускается.
- DoH-соединения dnsproxy выходят через WAN и попадают в NFQUEUE, поэтому
  обрабатываются zapret так же, как обычный HTTPS.
- Адаптер `zapret-discord-youtube-linux` разбирает выбранный `.bat`-файл
  стратегии и запускает `nfqws`.
- nftables-правила адаптера цепляются к `postrouting` по WAN-интерфейсу,
  поэтому **форвардный трафик из WireGuard тоже попадает в NFQUEUE** и
  обрабатывается zapret.
- Исходящие UDP-пакеты самого WireGuard (порт `51820`) исключены из NFQUEUE,
  чтобы zapret не ломал туннель.
- DoH-домены из флагов `-u/--upstream` автоматически добавляются в
  general-профили стратегии, чтобы nfqws применял desync к их TLS-хендшейкам.
  Домены и IP/CIDR из `ZAPRET_EXTRA_HOSTS` добавляются туда же (IP/CIDR —
  через отдельные IP-профили с `--ipset`).

### NAT и desync

NAT (masquerade) не пересобирает TCP и не «склеивает» сегменты обратно: он
переписывает source IP/port и инкрементально корректирует контрольные суммы
каждого пакета отдельно. Намеренно испорченная чексумма (`badsum`) при этом
остаётся испорченной. TCP-поток собирается только на конечных узлах или в
полноценном прокси.
Очередь NFQUEUE стоит в `postrouting` с приоритетом `mangle`, то есть **до**
NAT: nfqws видит пакет с исходным адресом клиента, делает desync, а NAT уже
после этого меняет адрес/порт. Сгенерированные nfqws fake-пакеты помечены
`fwmark`, поэтому не попадают в очередь повторно, и маскарадятся тем же
правилом WAN. Это же правило `postrouting` применяется к локально
сгенерированным DoH-пакетам dnsproxy.

Что действительно может помешать desync:

- conntrack с проверкой чексумм может отбрасывать/не транслировать fake-пакеты
  с `badsum` — контейнер выставляет `nf_conntrack_checksum=0`;
- обычный TCP tracking conntrack может пометить fake-пакеты с `badseq` как
  `INVALID` — выставляется `nf_conntrack_tcp_be_liberal=1`;
- conntrack дефрагментирует IP-фрагменты (это влияет только на стратегии с
  `ipfrag*`, но не на обычный split/fake);
- GSO/TSO/GRO на veth или сетевой карте может укрупнять сегменты до DPI. Если
  конкретная стратегия не работает, проверьте offloads на хосте:
  `ethtool -K <iface> gso off tso off gro off`.

Стандартные стратегии Flowseal используют fake/hostfakesplit и под эти
ограничения обычно не попадают.

## Структура

```text
zapret_wg/
├── .github/workflows/
│   └── docker-publish.yml      # сборка и публикация образа в Docker Hub
├── Dockerfile
├── run.sh
├── config/                     # монтируется в контейнер как /opt/config
│   ├── wg0.conf.example
│   └── clients/                # клиентские конфиги (создаются автоматически)
└── docker/                     # скрипты контейнера
    ├── entrypoint.sh
    ├── zapret.sh
    ├── dnsproxy.sh
    ├── wireguard.sh
    ├── genconfig.sh
    ├── update.sh
    ├── healthcheck.sh
    └── lib.sh
```

Каталоги зависимостей внутри контейнера:

```text
/opt/zapret-discord-youtube-linux/   # git-клон адаптера
├── nfqws                            # бинарник zapret
├── zapret-latest/                   # стратегии Flowseal + bin/ + lists/
├── custom-strategies/
└── src/                             # скрипты адаптера

/opt/zapret-wg/                      # скрипты этого контейнера
/opt/config/                         # wg0.conf и ключи WireGuard
/run/zapret-wg/                      # runtime-файлы (PID, maintenance)
```

## Требования

- Linux-хост (не Docker Desktop на macOS/Windows).
- Поддержка WireGuard в ядре хоста:

  ```bash
  sudo modprobe wireguard
  lsmod | grep wireguard
  ```

- nftables, conntrack и NFQUEUE в ядре (стандарт для современных дистрибутивов).
- Docker с правами root.
- Открытый на хосте/роутере UDP-порт WireGuard (по умолчанию `51820/udp`).
- Свободный UDP-порт `53` на хосте, если публикуете DNS dnsproxy. Если он
  занят (например, `systemd-resolved`), используйте `DNS_PORT=5353 ./run.sh`
  или не публикуйте порт — WG-клиенты всё равно смогут обращаться к DNS
  по адресу сервера внутри туннеля.

Контейнеру нужны capabilities `NET_ADMIN` и `NET_RAW`, а также
`net.ipv4.ip_forward=1`, `net.netfilter.nf_conntrack_checksum=0` и
`net.netfilter.nf_conntrack_tcp_be_liberal=1` внутри network namespace
(нужны для стратегий с `badsum`/`badseq` за NAT).

## Быстрый старт

### Готовый образ из Docker Hub

Образ публикуется в [`pir888/zapret-wg`](https://hub.docker.com/r/pir888/zapret-wg)
для `linux/amd64` и `linux/arm64`:

```bash
docker pull pir888/zapret-wg:latest

mkdir -p config

docker run -d \
  --name zapret-wg \
  --restart unless-stopped \
  --cap-add NET_ADMIN \
  --cap-add NET_RAW \
  --sysctl net.ipv4.ip_forward=1 \
  --sysctl net.netfilter.nf_conntrack_checksum=0 \
  --sysctl net.netfilter.nf_conntrack_tcp_be_liberal=1 \
  -p 51820:51820/udp \
  -p 53:53/udp \
  -v "$PWD/config:/opt/config" \
  -e ZAPRET_STRATEGY=general_alt9.bat \
  -e DNSPROXY_CONF="-l 0.0.0.0 -p 53 -u https://dns.google/dns-query -b 1.1.1.1:53 --cache" \
  pir888/zapret-wg:latest
```

### Локальная сборка

```bash
cd zapret_wg
./run.sh
```

`run.sh` соберёт образ, создаст каталог `config/` и запустит контейнер.
Скрипт всегда публикует `51820/udp`, а DNS-порт `53/udp` — только если задан
`DNSPROXY_CONF` (порт хоста меняется через `DNS_PORT`, например `5353`):

```bash
DNSPROXY_CONF="-l 0.0.0.0 -p 53 -u https://dns.google/dns-query -b 1.1.1.1:53 --cache" \
  ./run.sh
```

Готовый образ и локальная сборка ведут себя одинаково: при первом запуске
контейнер сам сгенерирует `config/wg0.conf`, если его нет (`WG_AUTOGEN=1`),
и создаст первого клиента
`config/clients/client1.conf` с настоящими ключами. Конфиги клиентов из
`config/clients/` выводятся в лог при каждом старте контейнера:

```bash
docker logs zapret-wg
```

В клиентском конфиге будут реальные значения `PrivateKey`, `PresharedKey` и
публичного ключа сервера. Замените только `Endpoint` (по умолчанию
`<SERVER_PUBLIC_IP>:51820`) на публичный IP или домен сервера.

Публичный ключ также можно получить так:

```bash
docker exec zapret-wg wg show wg0 public-key
```

### Запуск без скрипта

```bash
docker build --build-arg DNSPROXY_CACHE_BUST=$(date +%s) -t zapret-wg:latest .

docker run -d \
  --name zapret-wg \
  --restart unless-stopped \
  --cap-add NET_ADMIN \
  --cap-add NET_RAW \
  --sysctl net.ipv4.ip_forward=1 \
  --sysctl net.netfilter.nf_conntrack_checksum=0 \
  --sysctl net.netfilter.nf_conntrack_tcp_be_liberal=1 \
  -p 51820:51820/udp \
  -p 53:53/udp \
  -v "$PWD/config:/opt/config" \
  -e ZAPRET_STRATEGY=general_alt9.bat \
  -e ZAPRET_EXTRA_HOSTS="example.com,example.org" \
  -e DNSPROXY_CONF="-l 0.0.0.0 -p 53 -u https://dns.google/dns-query -b 1.1.1.1:53 --cache" \
  zapret-wg:latest
```

## Переменные контейнера

| Переменная | По умолчанию | Назначение |
|---|---|---|
| `ZAPRET_STRATEGY` | `general_alt9.bat` | Имя файла стратегии zapret из `zapret-latest/` или `custom-strategies/`. |
| `ZAPRET_EXTRA_HOSTS` | пусто | Дополнительные домены и/или IP/CIDR (IPv4/IPv6) для general-профилей стратегии. |
| `DNSPROXY_CONF` | пусто | Флаги командной строки dnsproxy одной строкой. Пусто — dnsproxy не запускается. Пример: `-l 0.0.0.0 -p 53 -u https://dns.google/dns-query -b 1.1.1.1:53 --cache`. |
| `WG_AUTOGEN` | `1` | Сгенерировать конфиг и ключи, если файла нет. `0` — завершиться с ошибкой. |
| `WG_CLIENT_NAME` | `client1` | Имя автоматически создаваемого клиента (`clients/<имя>.conf`). |
| `WG_CLIENT_ADDRESS` | `10.13.13.2/32` | Адрес клиента в автоматически создаваемом конфиге. |
| `WG_CLIENT_DNS` | авто | DNS в клиентском конфиге. Не задано — IP dnsproxy, если он запущен, иначе `1.1.1.1`. Задано пустым — `1.1.1.1`. |
| `WG_CLIENT_ENDPOINT` | `<SERVER_PUBLIC_IP>:51820` | Endpoint в клиентском конфиге. |
| `WG_MTU` | `1420` | MTU интерфейса, если в конфиге не задан `MTU`. |
| `ZAPRET_DEBUG` | `0` | `1` — вывести полную команду запуска `nfqws`. |
| `ZAPRET_DRY_RUN` | `0` | `1` — проверить параметры стратегии через `nfqws --dry-run` и выйти без изменения nftables. |

Путь к конфигу (`/opt/config/wg0.conf`), имя интерфейса (`wg0`) и UDP-порт
`51820` фиксированы.

`ZAPRET_EXTRA_HOSTS` принимает домены и IP/CIDR (IPv4 и IPv6), например:

```bash
-e ZAPRET_EXTRA_HOSTS="example.com,sub.example.org 1.2.3.4 10.0.0.0/8 2001:db8::1"
```

- Домены добавляются как дополнительный `--hostlist` только в general-профили
  стратегии (фильтры, которые уже используют `list-general.txt` или
  `list-general-user.txt`). DoH-домены dnsproxy добавляются туда же.
- IP и CIDR пишутся в отдельный ipset-файл. nfqws считает `--ipset` жёстким
  фильтром (AND с hostlist), поэтому нельзя просто добавить его в тот же
  профиль — домены перестали бы совпадать. Вместо этого для каждого
  general-профиля создаётся IP-копия с теми же параметрами desync, но только
  с `--ipset=...`.
- IP-правило действует на весь трафик к этому адресу, а не на конкретный
  домен. Указывайте IP/CIDR без порта и без схемы URL: `1.2.3.4:443` и
  `https://example.com` не поддерживаются.
- Это не меняет порядок выбора Google/Discord-профилей. Порты, на которых
  работает desync, задаются стратегией. Если у стратегии нет general-профиля,
  контейнер выведет предупреждение в лог.
- Некорректный IP/CIDR может привести к ошибке загрузки ipset при старте
  nfqws — проверяйте `docker logs`.

## WireGuard

Пример конфига лежит в [`config/wg0.conf.example`](config/wg0.conf.example).

Сгенерировать конфиг вручную (если `WG_AUTOGEN=0` или нужен отдельный файл):

```bash
docker run --rm -v "$PWD/config:/opt/config" \
  --entrypoint /usr/local/bin/wg-genconfig zapret-wg:latest /opt/config/wg0.conf
```

При такой ручной генерации dnsproxy в контейнере не запущен, поэтому DNS =
`1.1.1.1`. Чтобы указать DNS dnsproxy, задайте `WG_CLIENT_DNS=10.13.13.1`.
Клиентский конфиг создаётся в `config/clients/<имя>.conf` и выводится в лог
при следующем обычном старте контейнера; при ручной генерации посмотрите файл
напрямую.

### Добавление клиента

При автогенерации контейнер сразу создаёт одного клиента (`client1`) вместе с
серверным пиром. Его конфиг лежит в `config/clients/client1.conf` и содержит
настоящие ключи; поменять имя, адрес, DNS и endpoint можно переменными
`WG_CLIENT_NAME`, `WG_CLIENT_ADDRESS`, `WG_CLIENT_DNS`, `WG_CLIENT_ENDPOINT`
(см. таблицу выше). Содержимое всех конфигов из `config/clients/` выводится в
`docker logs` при каждом старте контейнера. Если `WG_CLIENT_DNS` не задан,
контейнер сам выбирает DNS: IP dnsproxy, если он запущен, иначе публичный
`1.1.1.1`. Если переменная задана пустой, тоже используется `1.1.1.1`.
Повторный запуск `wg-genconfig` не перезаписывает существующие файлы.

Чтобы добавить ещё одного клиента:

1. Сгенерируйте клиентские ключи на хосте:

   ```bash
   CLIENT_PRIVATE=$(wg genkey)
   CLIENT_PUBLIC=$(printf '%s\n' "$CLIENT_PRIVATE" | wg pubkey)
   ```

2. Добавьте пира в `config/wg0.conf` на хосте:

   ```ini
   [Peer]
   PublicKey = <CLIENT_PUBLIC>
   AllowedIPs = 10.13.13.3/32
   ```

3. Перезапустите контейнер (конфиг применяется при старте):

   ```bash
   docker restart zapret-wg
   ```

Файл `config/wg0.conf` создаётся контейнером от `root` с правами `600`.
Клиентские конфиги в `config/clients/` тоже создаются с правами `600`.
Редактируйте их через `sudo` на хосте или внутри контейнера:

```bash
docker exec -it zapret-wg nano /opt/config/wg0.conf
```

Клиентский конфиг:

```ini
[Interface]
PrivateKey = <CLIENT_PRIVATE>
Address = 10.13.13.3/32
DNS = 10.13.13.1
MTU = 1420

[Peer]
PublicKey = <SERVER_PUBLIC_KEY>
Endpoint = <SERVER_PUBLIC_IP>:51820
AllowedIPs = 0.0.0.0/0, ::/0
PersistentKeepalive = 25
```

`Endpoint` — публичный IP или домен сервера и проброшенный UDP-порт.
Для каждого клиента используйте свой адрес `10.13.13.x`.

`DNS = 10.13.13.1` направляет DNS-запросы клиента в dnsproxy контейнера,
который пересылает их на DoH через zapret (см. раздел «DNS и DoH»).
В старых клиентских конфигах замените `DNS` вручную; автоматический выбор
применяется только к новым клиентам.

`run.sh` пробрасывает UDP-порт `51820`. Если в готовом `wg0.conf` указан
другой `ListenPort`, измените проброс в `run.sh`.

Сервер устанавливает маршруты из `AllowedIPs`, кроме `0.0.0.0/0` и `::/0`
(контейнер — шлюз, а не клиент). Если нужен site-to-site, перечислите подсети
клиента в `AllowedIPs`.

## DNS и DoH

dnsproxy запускается только при непустом `DNSPROXY_CONF`. Переменная содержит
флаги командной строки dnsproxy в одной строке:

```bash
DNSPROXY_CONF="-l 0.0.0.0 -p 53 -u https://dns.google/dns-query -b 1.1.1.1:53 --cache"
```

Для автоматического выбора DNS на первом старте dnsproxy должен успеть
запуститься до генерации клиентского конфига — используйте `-l 0.0.0.0`
(как в примере). Порт должен быть `53` (`-p 53`): в WireGuard-конфиге `DNS`
задаётся без порта.

При пустой переменной сервис не стартует, healthcheck его не проверяет, а
`run.sh` не публикует порт 53. Конфигурация задаётся только флагами: YAML
(`--config-path`) в проекте не используется. Флаги разделяются пробелами,
поэтому в `docker run` значение передавайте в кавычках.

DoH-домены из `-u`/`--upstream` (только `https://`) автоматически
добавляются в general-профили стратегии, чтобы zapret обрабатывал их
TLS-хендшейки. При изменении переменной перезапустите контейнер. Полный
список параметров: `dnsproxy --help`.

DNS клиентов WireGuard выбирается при генерации клиентского конфига:

- dnsproxy запущен — в `DNS` попадает IP dnsproxy в туннеле: первый
  конкретный (не `0.0.0.0`/loopback) адрес из `-l/--listen`, иначе адрес
  сервера (`10.13.13.1`);
- dnsproxy не запущен — публичный DNS `1.1.1.1`;
- `WG_CLIENT_DNS` задан непустым — используется он; задан пустым — `1.1.1.1`.

Автовыбор работает только для новых клиентов; в существующих конфигах
`DNS` нужно поправить вручную. Если dnsproxy не смог запуститься (неверные
флаги, занятый порт), смотрите `docker logs` — клиенты останутся с указанным
в их конфиге DNS.

Порт на хосте публикуется как UDP (`run.sh` делает это автоматически,
когда задан `DNSPROXY_CONF`):

```bash
-p 53:53/udp
```

Если на хосте 53 занят (часто `systemd-resolved`), используйте
`DNS_PORT=5353 ./run.sh` — на хосте будет `5353/udp`, внутри контейнера и
для WG-клиентов останется `53`.

Проверка:

```bash
dig @127.0.0.1 example.com
docker exec zapret-wg dig @127.0.0.1 example.com
docker logs -f zapret-wg
```

В образ скачивается последняя версия dnsproxy на момент сборки. `run.sh` и
GitHub Actions сбрасывают кеш этого слоя, поэтому пересборка подтягивает
свежий релиз; при ручной сборке используйте
`--build-arg DNSPROXY_CACHE_BUST=$(date +%s)` или `--no-cache`. При
необходимости версию можно зафиксировать:
`--build-arg DNSPROXY_VERSION=v0.86.0`.

## Стратегии zapret

Посмотреть доступные стратегии:

```bash
docker exec zapret-wg bash -lc \
  'ls /opt/zapret-discord-youtube-linux/zapret-latest/*.bat'
```

Или через CLI адаптера:

```bash
docker exec zapret-wg bash -lc \
  'cd /opt/zapret-discord-youtube-linux && ./service.sh strategy list'
```

Сменить стратегию — пересоздать контейнер с другим `-e ZAPRET_STRATEGY=...`
(конфиг WireGuard в `config/` при этом сохраняется).

Если ни одна стратегия не подходит, смотрите
[репозиторий Flowseal](https://github.com/Flowseal/zapret-discord-youtube/issues)
и пробуйте другие варианты `general_altN.bat`.

## Обновление компонентов

В контейнере есть скрипт `zapret-wg-update`. Он:

1. ставит zapret на паузу (nfqws и правила nftables останавливаются);
2. обновляет адаптер через `git pull`;
3. заново скачивает `nfqws` и стратегии;
4. перезапускает zapret с обновлёнными компонентами.

```bash
# Рекомендованные (проверенные) версии из constants.sh адаптера
docker exec -it zapret-wg zapret-wg-update

# Последний nfqws и последние стратегии
docker exec -it zapret-wg zapret-wg-update --latest

# Передать параметры напрямую в download-deps адаптера
docker exec -it zapret-wg zapret-wg-update -z v72.9 -s main
```

Обновления сохраняются в writable-слое контейнера. Если удалить контейнер,
они пропадут — для постоянной версии пересоберите образ.

## Оболочка и диагностика

Внутри контейнера есть `bash`, `nano`, `less`, `ls`, `cd`, `curl`, `ping`,
`dig`, `tcpdump`, `nft`, `iptables`, `wg` и другие базовые утилиты.

```bash
docker exec -it zapret-wg bash
```

Полезные команды внутри:

```bash
wg show
nft list ruleset
nft list chain inet zapretunix post
pgrep -a nfqws
pgrep -a dnsproxy
curl -I https://discord.com
```

Логи контейнера:

```bash
docker logs -f zapret-wg
```

Healthcheck проверяет, что интерфейс `wg0` существует, `nfqws` запущен и
таблица `inet zapretunix` создана. Если задан `DNSPROXY_CONF`,
дополнительно проверяется процесс `dnsproxy`:

```bash
docker inspect --format '{{.State.Health.Status}}' zapret-wg
```

## Решение проблем

**`Cannot create WireGuard interface`**

Ядро хоста не поддерживает WireGuard или контейнеру не хватает прав:

```bash
sudo modprobe wireguard
# контейнер должен запускаться с --cap-add NET_ADMIN
```

**`Cannot detect the WAN interface`**

У контейнера нет маршрута по умолчанию. Проверьте сеть:

```bash
docker exec zapret-wg ip route show default
```

Контейнер должен быть подключён к сети со шлюзом по умолчанию (обычно bridge
с NAT).

**Клиенты подключаются, но интернета нет**

Проверьте внутри контейнера:

```bash
sysctl net.ipv4.ip_forward
nft list ruleset
nft list chain inet zapretunix post
iptables -t nat -S
```

Также проверьте, что на хосте/роутере проброшен UDP-порт и что firewall хоста
не блокирует форвардинг.

**`dnsproxy` не запускается**

Если `DNSPROXY_CONF` пуст, сервис намеренно не запускается. Задайте флаги
одной строкой, например:

```bash
-e DNSPROXY_CONF="-l 0.0.0.0 -p 53 -u https://dns.google/dns-query -b 1.1.1.1:53 --cache"
```

Проверьте, что флаги валидны (`docker logs zapret-wg`), и что dnsproxy
слушает нужный адрес/порт (`-l`/`--listen`, `-p`/`--port`).

**`dnsproxy exited with code ... address already in use`**

Порт 53 уже занят внутри контейнера или на хосте. На хосте его часто занимает
`systemd-resolved` — остановите его либо используйте `DNS_PORT=5353 ./run.sh`.
Проверить занятость порта:

```bash
ss -lunp | grep ':53 '
docker logs zapret-wg | grep -i dnsproxy
```

**DNS не работает у клиентов WireGuard**

Проверьте, что dnsproxy был запущен в момент генерации клиентского конфига
(тогда в `DNS` попадёт его IP) или что в клиентском конфиге вручную указан
рабочий DNS. Если dnsproxy запущен, в `DNS` должен быть адрес сервера
внутри туннеля (`10.13.13.1`) либо конкретный адрес из `-l/--listen`.
Проверка изнутри контейнера:

```bash
dig @127.0.0.1 example.com
dig @10.13.13.1 example.com
```

**DoH-апстрим всё ещё блокируется**

Проверьте в логах строку `dnsproxy DoH host(s) for zapret hostlists` —
домен апстрима должен попасть в extra-hostlist general-профиля. Если
выбранная стратегия не имеет general-профиля, будет предупреждение;
используйте другую стратегию или добавьте домен/IP в `ZAPRET_EXTRA_HOSTS`
(это поможет только при наличии general-профиля). Также можно сменить DoH
на другой (Cloudflare, AdGuard) во флагах `-u/--upstream`.

**`nfqws exited with code ...`**

Стратегия не подошла или файл стратегии повреждён. Посмотрите
`docker logs zapret-wg`, список стратегий и попробуйте другую. Для подробного
лога запустите контейнер с `-e ZAPRET_DEBUG=1`.

**После обновления что-то сломалось**

Пересоберите образ с нуля:

```bash
docker rm -f zapret-wg
docker build --no-cache -t zapret-wg:latest .
./run.sh
```

**Не запускайте `service.sh run` вручную при работающем контейнере**

Этот скрипт запускает второй экземпляр `nfqws` и может конфликтовать с
entrypoint. Для обновления используйте `zapret-wg-update`.

## Безопасность

- Приватные ключи WireGuard лежат в `config/wg0.conf` и `config/clients/` на
  хосте; каталог должен быть доступен только доверенным пользователям.
- Клиентские конфиги с приватными ключами выводятся в `docker logs` при каждом
  старте контейнера. Ограничьте доступ к логам Docker и не отправляйте их во
  внешние системы логирования.
- Наружу нужен только UDP-порт WireGuard и только если сервер должен быть
  доступен из интернета.
- Если публикуете DNS (`-p 53:53/udp`), контейнер становится открытым
  резолвером. Не открывайте этот порт в интернет или ограничьте его
  firewall'ом/списком доверенных сетей.
- Контейнер работает с `NET_ADMIN`; не давайте к нему доступ недоверенным
  пользователям.

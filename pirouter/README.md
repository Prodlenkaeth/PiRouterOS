# pirouter — VPN-роутер для Raspberry Pi 3 Model B

Превращает Raspberry Pi 3B в Wi-Fi-роутер с **kill-switch**, четырьмя VPN/прокси-движками
(**OpenVPN, L2TP/IPsec, VLESS, обычный Proxy**), **сменой MAC-адреса** для Wi-Fi и WAN,
изменяемым **LAN IP (по умолчанию `192.168.33.1`)** и **терминальной панелью управления
на whiptail**, которой ты полностью управляешь по SSH.

- **WAN (интернет входит):** кабель Ethernet → `eth0`
- **LAN (Wi-Fi раздаётся):** встроенный Wi-Fi → точка доступа `wlan0`

### Режим роутера: основной роутер или клиент (за твоим роутером)

В панели есть меню **Router mode** (пункт 2) с двумя вариантами:

- **`gateway` (основной роутер):** малина — твой главный роутер. Источник интернета
  (модем/провайдер) втыкается прямо в `eth0`.
- **`client` (за твоим основным роутером)** — *режим по умолчанию, твой случай:* у тебя
  уже есть основной роутер, и ты подключаешь малину к нему кабелем. Малина получает
  интернет от твоего роутера (двойной NAT — это нормально и даже полезно для kill-switch)
  и раздаёт **отдельный VPN-Wi-Fi**. Собственный Wi-Fi основного роутера продолжает
  работать как обычно.

Тебе **не нужно** ничего настраивать, чтобы клиентский режим заработал — воткни `eth0`
в свой роутер, и всё работает. **Единственное** требование: подсеть LAN малины
(`192.168.33.0/24` по умолчанию) **не должна совпадать** с подсетью основного роутера.
Панель проверяет это автоматически при выборе клиентского режима и предлагает перенести
малину на свободную подсеть (например `192.168.42.1`), если находит конфликт. В клиентском
режиме SSH также доступен из твоей основной сети, так что управлять малиной можно с любого
устройства дома.

> Примечание: это не готовый `.img`. Вместо этого ты один раз прошиваешь официальный
> Raspberry Pi OS Lite, а затем запускаешь одну команду установки. Итоговый результат
> идентичен кастомной прошивке, но собирать его гораздо надёжнее.

---

## 1. Прошивка Raspberry Pi OS Lite

Можно использовать **Balena Etcher**, ровно как ты и хотел:

1. Скачай **Raspberry Pi OS Lite (64-bit)** `.img.xz` с
   https://www.raspberrypi.com/software/operating-systems/
2. Открой **Balena Etcher** → *Flash from file* → выбери образ → выбери SD-карту → **Flash!**

### Включи SSH до первой загрузки (без монитора)
После прошивки вставь SD-карту заново, чтобы смонтировался небольшой раздел **`bootfs`**, затем:

- Создай в этом разделе пустой файл с именем `ssh` (без расширения) — это включает SSH.
- Создай в том же разделе файл `userconf.txt` с одной строкой:
  ```
  pi:$6$hashedpasswordhere
  ```
  Сгенерируй хеш на любом Linux/Mac: `echo 'mypassword' | openssl passwd -6 -stdin`
  (Или просто используй **Raspberry Pi Imager** вместо Etcher — там по значку шестерёнки
  можно задать имя пользователя, пароль и включить SSH без ручных файлов.)

Извлеки карту, вставь в малину, воткни **кабель Ethernet** в интернет и включи питание.

---

## 2. Скопируй проект на малину и установи

Узнай IP малины (в списке клиентов твоего роутера или попробуй `raspberrypi.local`),
затем со своего компьютера:

```bash
# скопировать всю папку на малину
scp -r pirouter pi@raspberrypi.local:~/

# зайти и установить
ssh pi@raspberrypi.local
cd pirouter
sudo bash install.sh
sudo reboot
```

Установщик подтянет hostapd, dnsmasq, openvpn, strongswan/xl2tpd, xray-core и панель
управления. Во время установки нужен интернет на `eth0`.

---

## 3. Подключение и настройка

После перезагрузки появится Wi-Fi-сеть:

- **SSID:** `PiRouter`   **Пароль:** `changeme123`

Подключись к ней (или оставайся в сети по Ethernet/LAN), затем открой панель управления:

```bash
ssh pi@192.168.33.1     # с устройства в Wi-Fi малины
sudo pirouter
```

Появится меню:

```
 1  Обзор статуса
 2  Режим роутера (основной / за роутером)
 3  Настройки Wi-Fi (SSID / пароль / канал)
 4  Сеть / IP роутера / DHCP
 5  VPN и Proxy (OpenVPN/L2TP/VLESS/Proxy)
 6  MAC-адрес (Wi-Fi / WAN)
 7  Kill-switch вкл/выкл
 8  Применить и перезапустить всё
 9  Перезагрузить Raspberry Pi
 0  Выход
```

**В первую очередь смени пароль Wi-Fi и LAN IP.**

---

## 4. Заметки по настройке VPN

| Движок   | Что ты указываешь (в меню)                                      |
|----------|-----------------------------------------------------------------|
| OpenVPN  | Загрузи свой `.ovpn` в `/etc/pirouter/openvpn/client.conf`, затем выбери *OpenVPN*. `scp client.ovpn pi@192.168.33.1:/etc/pirouter/openvpn/client.conf` |
| L2TP/IPsec | Адрес сервера, IPsec PSK, имя пользователя, пароль            |
| VLESS    | Вставь полную ссылку `vless://…`                                |
| Proxy    | socks5/http хост, порт, при необходимости логин/пароль          |

- **Kill-switch ВКЛ** (по умолчанию): если выбранный VPN-туннель упал, клиенты получают
  **вообще никакого интернета** — никаких утечек в WAN.
- **Kill-switch ВЫКЛ:** трафик идёт обычным путём через `eth0`.
- VLESS/Proxy используют прозрачное перенаправление TCP через Xray; DNS принудительно
  направляется через туннель, чтобы избежать утечек. (UDP/QUIC откатывается на TCP.)

---

## 5. Команды в терминале (для продвинутых)

Всё, что делает меню, доступно и через скрипты:

```bash
sudo pirouter-net status            # статус AP / DHCP / интерфейсов
sudo pirouter-vpn up vless          # запустить движок (openvpn|l2tp|vless|proxy)
sudo pirouter-vpn down              # отключить
sudo pirouter-killswitch on|off     # переключить kill-switch
sudo pirouter-mac set wan random    # сменить MAC WAN (wifi|wan  auto|random|MAC)
sudo pirouter-mac show
```

Конфигурация лежит в **`/etc/pirouter/pirouter.conf`**, логи — в `/var/log/pirouter.log`.

---

## Файлы

```
install.sh                              установщик в одну команду
files/etc/pirouter/pirouter.conf        конфигурация по умолчанию
files/usr/local/sbin/pirouter           панель управления whiptail (основной UI)
files/usr/local/sbin/pirouter-net       AP + DHCP + LAN + базовый запуск
files/usr/local/sbin/pirouter-vpn       движок OpenVPN / L2TP / VLESS / Proxy
files/usr/local/sbin/pirouter-killswitch  файрвол / NAT / kill-switch
files/usr/local/sbin/pirouter-mac       смена MAC (wifi + wan)
files/usr/local/lib/pirouter/common.sh  общие вспомогательные функции
files/usr/local/lib/pirouter/vless2json.py  ссылка vless:// → outbound Xray
files/etc/systemd/system/pirouter.service   применение конфига при загрузке
files/etc/systemd/system/xray.service        systemd-юнит Xray
```

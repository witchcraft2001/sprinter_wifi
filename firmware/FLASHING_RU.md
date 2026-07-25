# Прошивка SprinterESP: ESP-AT V2.2.2.0

[English version](FLASHING.md)

Рекомендуемый образ прошивки:

[`SprinterESP-AT-v2.2.2.0-runtime-flow-fix-full-2MB.bin`](SprinterESP-AT-v2.2.2.0-runtime-flow-fix-full-2MB.bin)

Ссылка для скачивания:
[GitHub-репозиторий Sprinter ESP Network Kit](https://github.com/witchcraft2001/sprinter_wifi/blob/main/firmware/SprinterESP-AT-v2.2.2.0-runtime-flow-fix-full-2MB.bin).

Это **полный образ объёмом 2 МБ**. Его нужно записывать с адреса `0x0`; не
смешивайте его с файлами от старых многокомпонентных выпусков ESP-AT.

## Подготовка

Схему подключения платы и вход в режим прошивки смотрите также в исходном
[документе по прошивке SprinterESP](https://github.com/romychs/SprinterESP):

- Используйте USB-UART/USB-TTL адаптер с уровнями 3,3 В, например на CH340 или
  CP210x.
- Подключите адаптер к разъёму `X2` / `ProgConn` платы Sprinter Wi-Fi так, как
  указано в документе: `TX -> TX`, `RX -> RX`, `GND -> GND`.
- Подайте на плату Sprinter Wi-Fi питание 5 В от слота Sprinter или через
  предусмотренную точку питания платы. Соблюдайте полярность.
- Войдите в загрузчик ESP: установите перемычку **J2 (Flash)**, удерживайте
  **SW1 + SW2**, отпустите **SW1 (Reset)**, через одну-две секунды отпустите
  **SW2 (Flash)**. После удачной прошивки снимите J2.

## macOS и Linux: esptool

При необходимости установите консольную утилиту Espressif:

```sh
python3 -m pip install --user esptool
```

Перед запуском команды переведите ESP в **режим программирования**: установите
J2, нажмите SW1+SW2, отпустите SW1, а через одну-две секунды — SW2 (полный
порядок действий приведён выше в разделе «Подготовка»). В этом режиме `esptool`
может записать новую прошивку в память ESP через USB-UART. Затем выполните
команду, заменив `<PORT>` и `<PATH-TO-BIN>` значениями для вашего компьютера.
В macOS имя порта может выглядеть как `/dev/cu.usbserial-0001`; в Linux обычно
используется `/dev/ttyUSB0` или `/dev/ttyACM0`.

```sh
esptool.py --chip esp8266 --port <PORT> --baud 115200 --before default_reset --after hard_reset write_flash --flash_mode dio --flash_freq 40m --flash_size 2MB 0x0 <PATH-TO-BIN>/SprinterESP-AT-v2.2.2.0-runtime-flow-fix-full-2MB.bin
```

Пример команды для прошивки:

```sh
esptool.py --chip esp8266 --port /dev/cu.usbserial-0001 --baud 115200 --before default_reset --after hard_reset write_flash --flash_mode dio --flash_freq 40m --flash_size 2MB 0x0 /Users/dmitry/dev/esp/esp-at/build/SprinterESP_v2.2.2.0/SprinterESP-AT-v2.2.2.0-runtime-flow-fix-full-2MB.bin
```

Имя последовательного порта и путь к образу приведены только для примера и
должны быть заменены на локальные.

## Windows: esptool

1. Установите Python 3; в установщике отметьте **Add Python to PATH**.
2. Откройте командную строку и установите esptool:

   ```bat
   py -m pip install esptool
   ```

3. Найдите порт USB-UART в «Диспетчере устройств», например `COM5`.
4. Переведите ESP в режим программирования описанным выше способом, чтобы
   `esptool` получил доступ к памяти ESP, и выполните:

   ```bat
   py -m esptool --chip esp8266 --port COM5 --baud 115200 --before default_reset --after hard_reset write_flash --flash_mode dio --flash_freq 40m --flash_size 2MB 0x0 C:\path\to\SprinterESP-AT-v2.2.2.0-runtime-flow-fix-full-2MB.bin
   ```

Замените `COM5` и путь к файлу своими значениями.

## Windows: Espressif Flash Download Tool

Это графический способ, описанный в [ESP-module-flashing.pdf](https://zxgit.org/romych/SprinterESP/src/branch/master/Docs/ESP-module-flashing.pdf).

1. Скачайте и распакуйте **Flash Download Tool** от Espressif:
   <https://www.espressif.com/en/support/download/other-tools>.
2. Запустите `flash_download_tool_x.x.x.exe`; установка не требуется.
3. Один раз выберите образ прошивки и укажите для него адрес `0x000000`.
   Установите `DIO`, `40 MHz` и `2 MB`, выберите COM-порт USB-UART адаптера.
4. Нажмите **Start**, затем переведите ESP в режим программирования с помощью
   J2, SW1 и SW2 по инструкции выше. В этом режиме программа может записать
   образ в память ESP.
5. Дождитесь надписи **FINISH**, снимите перемычку J2, перезапустите плату и
   запустите `NETPROBE` либо `WTERM` + `AT+GMR`, чтобы убедиться в обновлении.

Не отключайте питание и USB-UART адаптер во время стирания или записи flash.

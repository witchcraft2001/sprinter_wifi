# SprinterESP ESP-AT V2.2.2.0 flashing guide

[Русская версия](FLASHING_RU.md)

Recommended firmware image:

[`SprinterESP-AT-v2.2.2.0-runtime-flow-fix-full-2MB.bin`](SprinterESP-AT-v2.2.2.0-runtime-flow-fix-full-2MB.bin)

Mirror/download link:
[Sprinter ESP Network Kit on GitHub](https://github.com/witchcraft2001/sprinter_wifi/blob/main/firmware/SprinterESP-AT-v2.2.2.0-runtime-flow-fix-full-2MB.bin).

This is a **complete 2 MB image**. Flash it at address `0x0`; do not combine it
with files from an older multi-file ESP-AT release.

## Before starting

Follow the board connection and boot-mode procedure in the original
[SprinterESP flashing document](https://github.com/romychs/SprinterESP):

- Use a 3.3 V USB-UART/USB-TTL adapter (for example CH340 or CP210x).
- Connect the adapter to the Sprinter Wi-Fi board `X2` / `ProgConn` as shown in
  the document: `TX -> TX`, `RX -> RX`, `GND -> GND`.
- Power the Sprinter Wi-Fi board with 5 V from the Sprinter slot or the board's
  documented power point. Observe polarity.
- Enter ESP bootloader mode: fit jumper **J2 (Flash)**, hold **SW1 + SW2**,
  release **SW1 (Reset)**, then release **SW2 (Flash)** after one or two
  seconds. Remove J2 after a successful flash.

## macOS and Linux: esptool

Install Espressif's command-line tool if necessary:

```sh
python3 -m pip install --user esptool
```

Then run the following command after replacing `<PORT>` and `<PATH-TO-BIN>`
with values for your computer. On macOS a port can look like
`/dev/cu.usbserial-0001`; Linux often uses `/dev/ttyUSB0` or `/dev/ttyACM0`.

```sh
esptool.py --chip esp8266 --port <PORT> --baud 115200 --before default_reset --after hard_reset write_flash --flash_mode dio --flash_freq 40m --flash_size 2MB 0x0 <PATH-TO-BIN>/SprinterESP-AT-v2.2.2.0-runtime-flow-fix-full-2MB.bin
```

For example, the command used during this release was:

```sh
esptool.py --chip esp8266 --port /dev/cu.usbserial-0001 --baud 115200 --before default_reset --after hard_reset write_flash --flash_mode dio --flash_freq 40m --flash_size 2MB 0x0 /Users/user/dev/esp/esp-at/build/SprinterESP_v2.2.2.0/SprinterESP-AT-v2.2.2.0-runtime-flow-fix-full-2MB.bin
```

The serial-port name and the path to the image are examples only and must be
changed to match the local system.

## Windows: esptool

1. Install Python 3 and select **Add Python to PATH** in the installer.
2. Open Command Prompt and install esptool:

   ```bat
   py -m pip install esptool
   ```

3. Find the USB-UART port in Device Manager, for example `COM5`.
4. Put the board into bootloader mode as described above, then run:

   ```bat
   py -m esptool --chip esp8266 --port COM5 --baud 115200 --before default_reset --after hard_reset write_flash --flash_mode dio --flash_freq 40m --flash_size 2MB 0x0 C:\path\to\SprinterESP-AT-v2.2.2.0-runtime-flow-fix-full-2MB.bin
   ```

Replace `COM5` and the path with local values.

## Windows: Espressif Flash Download Tool

This is the graphical method described in [ESP-module-flashing.pdf](https://zxgit.org/romych/SprinterESP/src/branch/master/Docs/ESP-module-flashing.pdf).

1. Download and unpack **Flash Download Tool** from Espressif:
   <https://www.espressif.com/en/support/download/other-tools>.
2. Start `flash_download_tool_x.x.x.exe`; it does not require installation.
3. Select the firmware image once and set its flash address to `0x000000`.
   Select `DIO`, `40 MHz`, and `2 MB`; choose the COM port of the USB-UART
   adapter.
4. Click **Start**. Put the Sprinter Wi-Fi board into bootloader mode using J2,
   SW1, and SW2 as described above.
5. Wait for **FINISH**, remove jumper J2, power-cycle/reset the board, and run
   `NETPROBE` or `WTERM` + `AT+GMR` to confirm the new firmware.

Do not interrupt power or disconnect the UART adapter while erasing or writing
flash.

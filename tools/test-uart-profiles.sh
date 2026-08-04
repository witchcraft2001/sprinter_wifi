#!/bin/sh
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repo_root=$(CDPATH= cd -- "$script_dir/.." && pwd)
tmp_dir=$(mktemp -d "${TMPDIR:-/tmp}/sprinter-uart-profiles.XXXXXX")
trap 'rm -rf "$tmp_dir"' EXIT HUP INT TERM

assemble_ftp()
{
	profile=$1
	define=$2
	if [ -n "$define" ]; then
		set -- "$define"
	else
		set --
	fi
	sjasmplus --nologo --fullpath "$@" \
		-I "$repo_root/src/include" \
		-I "$repo_root/src/lib" \
		--lst="$tmp_dir/ftp-$profile.lst" \
		--raw="$tmp_dir/ftp-$profile.exe" \
		"$repo_root/src/apps/ftp.asm" >/dev/null
}

assemble_ftp universal ""
assemble_ftp 221 -DESP_AT_FORCE_221
assemble_ftp 222 -DESP_AT_FORCE_222

assemble_wget()
{
	profile=$1
	define=$2
	if [ -n "$define" ]; then
		set -- "$define"
	else
		set --
	fi
	sjasmplus --nologo --fullpath "$@" \
		-I "$repo_root/src/include" \
		-I "$repo_root/src/lib" \
		--lst="$tmp_dir/wget-$profile.lst" \
		--raw="$tmp_dir/wget-$profile.exe" \
		"$repo_root/src/apps/wget.asm" >/dev/null
}

assemble_wget universal ""
assemble_wget 221 -DESP_AT_FORCE_221
assemble_wget 222 -DESP_AT_FORCE_222

assemble_ntp()
{
	profile=$1
	define=$2
	if [ -n "$define" ]; then
		set -- "$define"
	else
		set --
	fi
	sjasmplus --nologo --fullpath "$@" \
		-I "$repo_root/src/include" \
		-I "$repo_root/src/lib" \
		--lst="$tmp_dir/ntp-$profile.lst" \
		--raw="$tmp_dir/ntp-$profile.exe" \
		"$repo_root/src/apps/ntp.asm" >/dev/null
}

assemble_ntp universal ""
assemble_ntp 221 -DESP_AT_FORCE_221
assemble_ntp 222 -DESP_AT_FORCE_222

assemble_tftp()
{
	profile=$1
	define=$2
	if [ -n "$define" ]; then
		set -- "$define"
	else
		set --
	fi
	sjasmplus --nologo --fullpath "$@" \
		-I "$repo_root/src/include" \
		-I "$repo_root/src/lib" \
		--lst="$tmp_dir/tftp-$profile.lst" \
		--raw="$tmp_dir/tftp-$profile.exe" \
		"$repo_root/src/apps/tftp.asm" >/dev/null
}

assemble_tftp universal ""
assemble_tftp 221 -DESP_AT_FORCE_221
assemble_tftp 222 -DESP_AT_FORCE_222

assemble_wterm()
{
	sjasmplus --nologo --fullpath \
		-I "$repo_root/src/include" \
		-I "$repo_root/src/lib" \
		--lst="$tmp_dir/wterm.lst" \
		--raw="$tmp_dir/wterm.exe" \
		"$repo_root/src/apps/wterm.asm" >/dev/null
}

assemble_wterm

# UNETESP.DLL is a UNET backend client too. It pins ESP-AT 2.2.2 + the complete
# trigger-4 receive path in-source; sprinter-mkdll only wraps these bytes in the L1
# header/relocation map, so assembling the source straight and grepping the raw
# image is a faithful check of what ships. NETUP owns ESP UART negotiation, so
# the DLL must never carry an AT+UART_CUR command.
assemble_unetesp()
{
	sjasmplus --nologo --fullpath \
		-I "$repo_root/src/include" \
		-I "$repo_root/src/lib" \
		--lst="$tmp_dir/unetesp.lst" \
		--raw="$tmp_dir/unetesp.bin" \
		"$repo_root/src/dll/unetesp.asm" >/dev/null
}

assemble_unetesp

if grep -a -q 'AT+UART_CUR=' "$tmp_dir/unetesp.bin"; then
	echo "UNETESP.DLL unexpectedly contains an ESP UART reconfiguration command" >&2
	exit 1
fi
# The complete 2.2.2 DLL path uses trigger 4 from command replies through +IPD;
# queued bytes therefore never cross a trigger-mode transition.
grep -Eq '1E 43[[:space:]]+LD[[:space:]]+E,FCR_TR4 \| FCR_RESET_RX \| FCR_FIFO' \
	"$tmp_dir/unetesp.lst"
if grep -Eq '1E 83[[:space:]]+LD[[:space:]]+E,FCR_TR8 \| FCR_RESET_RX \| FCR_FIFO' \
	"$tmp_dir/unetesp.lst"; then
	echo "UNETESP.DLL unexpectedly compiles trigger 8 (should be complete 2.2.2 TR4)" >&2
	exit 1
fi
# Two-channel backend: it must drive AT+CIPMUX=1 and restore AT+CIPMUX=0, and it
# must stay on the active +IPD receive path (no ESP passive-receive commands).
if ! grep -a -q 'AT+CIPMUX=1' "$tmp_dir/unetesp.bin"; then
	echo "UNETESP.DLL is missing the multi-connection command AT+CIPMUX=1" >&2
	exit 1
fi
if ! grep -a -q 'AT+CIPMUX=0' "$tmp_dir/unetesp.bin"; then
	echo "UNETESP.DLL cannot restore single-connection mode (AT+CIPMUX=0)" >&2
	exit 1
fi
if grep -a -q 'AT+CIPRECV' "$tmp_dir/unetesp.bin"; then
	echo "UNETESP.DLL unexpectedly contains an ESP passive-receive command" >&2
	exit 1
fi

# Universal FTP deliberately keeps the field-proven active receive transport:
# trigger 8 and explicit RTS guards. NETUP alone configures the ESP UART;
# clients must not contain an AT+UART_CUR command.
grep -Eq '1E 83[[:space:]]+LD[[:space:]]+E,FCR_TR8 \| FCR_RESET_RX \| FCR_FIFO' \
	"$tmp_dir/ftp-universal.lst"
if grep -a -q 'AT+UART_CUR=' "$tmp_dir/ftp-universal.exe"; then
	echo "FTP unexpectedly contains an ESP UART reconfiguration command" >&2
	exit 1
fi

# UART_EMPTY_RS is the only place using these exact FCR expressions. Verify
# emitted immediate operands too: trigger 8 + RX reset + FIFO = 0x83,
# trigger 4 + RX reset + FIFO = 0x43.
grep -Eq '1E 83[[:space:]]+LD[[:space:]]+E,FCR_TR8 \| FCR_RESET_RX \| FCR_FIFO' \
	"$tmp_dir/ftp-221.lst"
grep -Eq '1E 43[[:space:]]+LD[[:space:]]+E,FCR_TR4 \| FCR_RESET_RX \| FCR_FIFO' \
	"$tmp_dir/ftp-222.lst"

if grep -Eq '1E 43[[:space:]]+LD[[:space:]]+E,FCR_TR4 \| FCR_RESET_RX \| FCR_FIFO' \
	"$tmp_dir/ftp-221.lst"; then
	echo "ESP-AT 2.2.1 command path unexpectedly contains active trigger 4" >&2
	exit 1
fi
if grep -Eq '1E 83[[:space:]]+LD[[:space:]]+E,FCR_TR8 \| FCR_RESET_RX \| FCR_FIFO' \
	"$tmp_dir/ftp-222.lst"; then
	echo "ESP-AT 2.2.2 command path unexpectedly contains active trigger 8" >&2
	exit 1
fi

# WGET follows the same streaming-client UART split as FTP. It additionally
# retains the field-working 60-second DNS/TCP open budget for external hosts.
grep -Eq '1E 83[[:space:]]+LD[[:space:]]+E,FCR_TR8 \| FCR_RESET_RX \| FCR_FIFO' \
	"$tmp_dir/wget-universal.lst"
if grep -a -q 'AT+UART_CUR=' "$tmp_dir/wget-universal.exe"; then
	echo "WGET unexpectedly contains an ESP UART reconfiguration command" >&2
	exit 1
fi
grep -Eq '01 60 EA[[:space:]]+LD[[:space:]]+BC,TCP_OPEN_TIMEOUT' \
	"$tmp_dir/wget-universal.lst"
grep -Eq '1E 83[[:space:]]+LD[[:space:]]+E,FCR_TR8 \| FCR_RESET_RX \| FCR_FIFO' \
	"$tmp_dir/wget-221.lst"
grep -Eq '1E 43[[:space:]]+LD[[:space:]]+E,FCR_TR4 \| FCR_RESET_RX \| FCR_FIFO' \
	"$tmp_dir/wget-222.lst"

# NTP uses the fixed-peer minimal UDP command on both firmware profiles and,
# like every client, must leave ESP-side UART settings untouched.
grep -Eq 'CALL[[:space:]]+UDP.OPEN_FIXED' "$tmp_dir/ntp-universal.lst"
grep -Eq 'CALL[[:space:]]+UDP.SEND_BUFFER_NO_WAIT' "$tmp_dir/ntp-universal.lst"
if grep -a -q 'AT+UART_CUR=' "$tmp_dir/ntp-universal.exe"; then
	echo "NTP unexpectedly contains an ESP UART reconfiguration command" >&2
	exit 1
fi
grep -Eq '1E 83[[:space:]]+LD[[:space:]]+E,FCR_TR8 \| FCR_RESET_RX \| FCR_FIFO' \
	"$tmp_dir/ntp-universal.lst"
if grep -Eq '1E 43[[:space:]]+LD[[:space:]]+E,FCR_TR4 \| FCR_RESET_RX \| FCR_FIFO' \
	"$tmp_dir/ntp-universal.lst"; then
	echo "Universal NTP unexpectedly contains the four-byte-stall trigger" >&2
	exit 1
fi
grep -Eq '1E 83[[:space:]]+LD[[:space:]]+E,FCR_TR8 \| FCR_RESET_RX \| FCR_FIFO' \
	"$tmp_dir/ntp-221.lst"
grep -Eq '1E 43[[:space:]]+LD[[:space:]]+E,FCR_TR4 \| FCR_RESET_RX \| FCR_FIFO' \
	"$tmp_dir/ntp-222.lst"

# TFTP shares the fast UDP request/reply hazard: its send path must not throw
# away an early DATA/ACK +IPD while it waits for SEND OK. Universal builds keep
# the stable trigger-8 transport; forced 2.2.2 keeps its trigger-4 experiment.
grep -Eq 'JP[[:space:]]+UDP.SEND_BUFFER_NO_WAIT' "$tmp_dir/tftp-universal.lst"
grep -Eq '1E 83[[:space:]]+LD[[:space:]]+E,FCR_TR8 \| FCR_RESET_RX \| FCR_FIFO' \
	"$tmp_dir/tftp-universal.lst"
grep -Eq '1E 83[[:space:]]+LD[[:space:]]+E,FCR_TR8 \| FCR_RESET_RX \| FCR_FIFO' \
	"$tmp_dir/tftp-221.lst"
grep -Eq '1E 43[[:space:]]+LD[[:space:]]+E,FCR_TR4 \| FCR_RESET_RX \| FCR_FIFO' \
	"$tmp_dir/tftp-222.lst"

# WTERM attaches at NET_BAUD; it must neither reset ESP nor force its UART
# back to 115200 behind NETUP's published session contract.
grep -Eq 'CALL[[:space:]]+WCOMMON.APPLY_NET_BAUD' "$tmp_dir/wterm.lst"
grep -Eq 'CALL[[:space:]]+WCOMMON.REQUIRE_NET_UP' "$tmp_dir/wterm.lst"
grep -Eq 'CALL[[:space:]]+WCOMMON.SYNC_ESP_COMMAND' "$tmp_dir/wterm.lst"
if grep -Eq 'CALL[[:space:]]+WIFI.ESP_RESET' "$tmp_dir/wterm.lst"; then
	echo "WTERM unexpectedly resets ESP instead of attaching to NETUP session" >&2
	exit 1
fi
if grep -a -q 'AT+UART_CUR=' "$tmp_dir/wterm.exe"; then
	echo "WTERM unexpectedly contains an ESP UART reconfiguration command" >&2
	exit 1
fi

echo "UART profiles and FTP/WGET/NTP/TFTP/WTERM/UNETESP compatibility paths: OK"

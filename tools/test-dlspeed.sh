#!/bin/sh
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repo_root=$(CDPATH= cd -- "$script_dir/.." && pwd)
tmp_dir=$(mktemp -d "${TMPDIR:-/tmp}/sprinter-dlspeed.XXXXXX")
trap 'rm -rf "$tmp_dir"' EXIT HUP INT TERM

run_vector()
{
	name=$1
	source=$2
	sjasmplus --nologo --fullpath \
		-I "$repo_root/src/include" -I "$repo_root/src/lib" \
		--sym="$tmp_dir/$name.sym" --raw="$tmp_dir/$name.bin" "$source" >/dev/null
	end_addr=$(awk '/^TEST_DONE:/ {sub(/^0x0*/, "", $3); print $3}' "$tmp_dir/$name.sym")
	test -n "$end_addr"
	z88dk-ticks -l 16384 -pc 4000 -end "$end_addr" -output "$tmp_dir/$name.ram" \
		"$tmp_dir/$name.bin" >/dev/null
	result=$(od -An -tu1 -j 49152 -N 1 "$tmp_dir/$name.ram" | tr -d ' ')
	if [ "$result" != 0 ]; then
		echo "DLSPEED $name vector mismatch" >&2
		exit 1
	fi
}

run_vector http "$script_dir/dlspeed_http_vectors.asm"
run_vector time "$script_dir/dlspeed_time_vectors.asm"

sjasmplus --nologo --fullpath \
	-I "$repo_root/src/include" -I "$repo_root/src/lib" \
	--sym="$tmp_dir/request.sym" --raw="$tmp_dir/request.bin" \
	"$script_dir/dlspeed_request_vectors.asm" >/dev/null
request_start=$(awk '/^DLSPEED_REQUEST_VECTORS\.TEST_START:/ {sub(/^0x0*/, "", $3); print $3}' "$tmp_dir/request.sym")
request_end=$(awk '/^DLSPEED_REQUEST_VECTORS\.TEST_DONE:/ {sub(/^0x0*/, "", $3); print $3}' "$tmp_dir/request.sym")
test -n "$request_start"
test -n "$request_end"
z88dk-ticks -l 16128 -pc "$request_start" -end "$request_end" \
	-output "$tmp_dir/request.ram" "$tmp_dir/request.bin" >/dev/null
request_result=$(od -An -tu1 -j 49152 -N 1 "$tmp_dir/request.ram" | tr -d ' ')
if [ "$request_result" != 0 ]; then
	echo "DLSPEED request vector mismatch: case $request_result" >&2
	exit 1
fi

assemble_profile()
{
	profile=$1
	define=$2
	if [ -n "$define" ]; then set -- "$define"; else set --; fi
	sjasmplus --nologo --fullpath "$@" \
		-I "$repo_root/src/include" -I "$repo_root/src/lib" \
		--lst="$tmp_dir/dlspeed-$profile.lst" --raw="$tmp_dir/dlspeed-$profile.exe" \
		"$repo_root/src/apps/dlspeed.asm" >/dev/null
}

assemble_profile universal ""
assemble_profile 221 -DESP_AT_FORCE_221
assemble_profile 222 -DESP_AT_FORCE_222

grep -Eq '1E 83[[:space:]]+LD[[:space:]]+E,FCR_TR8 \| FCR_RESET_RX \| FCR_FIFO' "$tmp_dir/dlspeed-universal.lst"
grep -Eq '1E 83[[:space:]]+LD[[:space:]]+E,FCR_TR8 \| FCR_RESET_RX \| FCR_FIFO' "$tmp_dir/dlspeed-221.lst"
grep -Eq '1E 43[[:space:]]+LD[[:space:]]+E,FCR_TR4 \| FCR_RESET_RX \| FCR_FIFO' "$tmp_dir/dlspeed-222.lst"
# A LAN diagnostic must use the bounded 20-second connect budget, not WGET's
# external-host 60-second profile.
grep -Eq '01 20 4E[[:space:]]+LD[[:space:]]+BC,TCP_OPEN_TIMEOUT' "$tmp_dir/dlspeed-universal.lst"

for image in "$tmp_dir"/dlspeed-*.exe; do
	if grep -a -q 'AT+UART_CUR=' "$image"; then
		echo "DLSPEED unexpectedly contains AT+UART_CUR" >&2
		exit 1
	fi
	if grep -a -q 'AT+CIPRECV' "$image"; then
		echo "DLSPEED unexpectedly contains passive receive commands" >&2
		exit 1
	fi
	grep -a -q 'Accept-Encoding: identity' "$image"
	grep -a -q 'Connection: keep-alive' "$image"
done

if grep -Eq 'CALL[[:space:]]+WIFI\.ESP_RESET' "$tmp_dir"/dlspeed-*.lst; then
	echo "DLSPEED unexpectedly resets the ESP" >&2
	exit 1
fi
grep -a -q 'ESP-AT 2.2.1' "$tmp_dir/dlspeed-221.exe"
grep -a -q 'ESP-AT 2.2.2' "$tmp_dir/dlspeed-222.exe"

if grep -qi 'dlspeed' "$repo_root/tools/artifacts.sh"; then
	echo "DLSPEED must remain outside the distribution manifest" >&2
	exit 1
fi

# RECEIVE_BODY reports success only after STOP; the caller closes the socket
# after RECEIVE_BODY returns. Keep this invariant explicit in the regression
# check because it is the measurement boundary the utility exists to enforce.
grep -A8 'CALL[[:space:]]*DHTTP.CONSUME' "$repo_root/src/apps/dlspeed.asm" | \
	grep -q 'CALL[[:space:]]*TPUT.STOP'
if grep -Eq 'CALL[[:space:]]+TCP\.CLOSE' "$repo_root/src/apps/dlspeed.asm"; then
	echo "DLSPEED cleanup must not block waiting behind a +IPD backlog" >&2
	exit 1
fi
test "$(grep -Ec 'JP[[:space:]]+TCP\.OPEN' "$repo_root/src/apps/dlspeed.asm")" -eq 1
grep -Eq 'JP[[:space:]]+WIFI\.UART_TX_STRING' "$repo_root/src/apps/dlspeed.asm"

python3 "$script_dir/test-dlspeed-server.py"
echo "DLSPEED timing, HTTP and UART-profile vectors: OK"

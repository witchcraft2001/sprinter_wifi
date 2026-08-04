#!/bin/sh
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repo_root=$(CDPATH= cd -- "$script_dir/.." && pwd)
tmp_base=${TMPDIR:-/tmp}/sprinter-libman-vectors
raw_file=$tmp_base.bin
sym_file=$tmp_base.sym
ram_file=$tmp_base.ram
l1_raw_file=$tmp_base-l1.bin
l1_sym_file=$tmp_base-l1.sym
l1_ram_file=$tmp_base-l1.ram

sjasmplus --nologo --fullpath \
  -I "$repo_root/src/include" \
  -I "$repo_root/src/lib" \
  --sym="$sym_file" --raw="$raw_file" "$script_dir/libman_call_vectors.asm"

end_addr=$(awk '/^TEST_DONE:/ {sub(/^0x0*/, "", $3); print $3}' "$sym_file")
if [ -z "$end_addr" ]; then
  echo "Could not find TEST_DONE in $sym_file" >&2
  exit 1
fi

# The raw image begins at ORG 0x0010. z88dk-ticks parses -l as decimal and
# -pc/-end as hexadecimal.
z88dk-ticks -l 16 -pc 0100 -end "$end_addr" -output "$ram_file" \
  "$raw_file" >/dev/null

result=$(od -An -tu1 -j 49408 -N 1 "$ram_file" | tr -d ' ')
if [ "$result" != 0 ]; then
  echo "libman SETWIN/INIT compatibility vector mismatch" >&2
  exit 1
fi

echo "libman SETWIN/INIT compatibility vector: OK"

dll_file=$repo_root/build/UNETESP.DLL
if [ ! -f "$dll_file" ]; then
  echo "Could not find $dll_file; run make build first" >&2
  exit 1
fi

# l_load must rebuild IY from the staged L1 header after its DSS memory calls.
# Carrying the earlier value across GETMEM/SETWIN is unsafe on real DSS and can
# corrupt the relocation pass before INIT (observed by the shell as error #27).
reloc_setup=$(sed -n '/pop.*bc.*новый адрес кода/,/call.*nz,remake/p' "$repo_root/src/lib/libman13.asm")
if ! printf '%s\n' "$reloc_setup" | grep -Eq 'ld[[:space:]]+hl,0C004h'; then
  echo "libman l_load does not rebuild the L1 relocation pointer after DSS calls" >&2
  exit 1
fi
echo "libman l_load relocation-pointer rebuild: OK"

# L1 code_size is little-endian at header bytes 4..5.
set -- $(od -An -tu1 -j 4 -N 2 "$dll_file")
dll_code_size=$(($1 + ($2 * 256)))

sjasmplus --nologo --fullpath \
  -D"DLL_CODE_SIZE=$dll_code_size" \
  -I "$repo_root/src/include" \
  -I "$repo_root/src/lib" \
  --sym="$l1_sym_file" --raw="$l1_raw_file" "$script_dir/libman_l1_vectors.asm"

l1_end_addr=$(awk '/^TEST_DONE:/ {sub(/^0x0*/, "", $3); print $3}' "$l1_sym_file")
if [ -z "$l1_end_addr" ]; then
  echo "Could not find TEST_DONE in $l1_sym_file" >&2
  exit 1
fi

z88dk-ticks -l 16 -pc 0100 -end "$l1_end_addr" -output "$l1_ram_file" \
  "$l1_raw_file" >/dev/null

l1_result=$(od -An -tu1 -j 28672 -N 1 "$l1_ram_file" | tr -d ' ')
if [ "$l1_result" != 0 ]; then
  echo "libman real L1 relocation/GETCAPS vector mismatch" >&2
  exit 1
fi

echo "libman real L1 relocation/GETCAPS vector: OK"

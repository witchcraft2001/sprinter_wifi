#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "$0")" && pwd)"
repo_root="$(cd "$script_dir/.." && pwd)"

source "$script_dir/artifacts.sh"

# Default builds use the common ESP-AT 2.2.1/2.2.2 subset. A known-firmware
# diagnostic build may target one dialect, e.g. ESP_AT_PROFILE=2.2.2 make build.
asm_profile=()
case "${ESP_AT_PROFILE:-}" in
  "") ;;
  2.2.1) asm_profile=(-DESP_AT_FORCE_221) ;;
  2.2.2) asm_profile=(-DESP_AT_FORCE_222) ;;
  *)
    echo "Error: ESP_AT_PROFILE must be 2.2.1 or 2.2.2 (or unset)" >&2
    exit 1
    ;;
esac

if [ "${#BUILD_APPS[@]}" -eq 0 ]; then
  echo "No DSS applications are listed in tools/artifacts.sh yet."
  exit 0
fi

if ! command -v sjasmplus >/dev/null 2>&1; then
  echo "Error: sjasmplus is not installed or not in PATH" >&2
  exit 1
fi

mkdir -p "$repo_root/build"

built=0
for app in "${BUILD_APPS[@]}"; do
  src="$repo_root/src/apps/$app.asm"
  upper="$(printf '%s' "$app" | tr '[:lower:]' '[:upper:]')"
  exe="$repo_root/build/$upper.EXE"
  lst="$repo_root/build/$upper.lst"

  if [ ! -f "$src" ]; then
    echo "Warning: $src not found, skipping $upper.EXE" >&2
    continue
  fi

  sjasmplus --nologo --fullpath \
    "${asm_profile[@]}" \
    -I "$repo_root/src/include" \
    -I "$repo_root/src/lib" \
    --lst="$lst" --raw="$exe" "$src"
  echo "Built $exe"
  built=$((built + 1))
done

if [ "$built" -eq 0 ]; then
  echo "No DSS applications were built. Add sources under src/apps/ and list them in tools/artifacts.sh."
fi

# --- libman 1.3 / L1 DLL libraries (built with sprinter-mkdll) ---------------
# The relocatable L1 container and its 32-byte header are produced by
# sprinter-mkdll (the libman builder), which runs sjasmplus twice and diffs the
# passes to build the relocation bitmap. Prefer an installed console script,
# else run the module straight from the libman source tree. Missing tool is a
# non-fatal skip (the repo stays buildable without libman checked out).
if [ "${#BUILD_DLLS[@]}" -gt 0 ]; then
  mkdll_cmd=()
  if command -v sprinter-mkdll >/dev/null 2>&1; then
    mkdll_cmd=(sprinter-mkdll)
  else
    libman_src="${UNET_LIBMAN_SRC:-$repo_root/../../sources/libman/src}"
    if [ -f "$libman_src/sprinter_mkdll/cli.py" ]; then
      mkdll_cmd=(env "PYTHONPATH=$libman_src" python3 -m sprinter_mkdll.cli)
    fi
  fi

  if [ "${#mkdll_cmd[@]}" -eq 0 ]; then
    echo "Warning: sprinter-mkdll not found (install libman or set UNET_LIBMAN_SRC); skipping DLL build" >&2
  else
    dll_version="$(cut -d. -f1,2 < "$repo_root/VERSION" 2>/dev/null || echo 0.1)"
    for dll in "${BUILD_DLLS[@]}"; do
      src="$repo_root/src/dll/$dll.asm"
      upper="$(printf '%s' "$dll" | tr '[:lower:]' '[:upper:]')"
      out="$repo_root/build/$upper.DLL"

      if [ ! -f "$src" ]; then
        echo "Warning: $src not found, skipping $upper.DLL" >&2
        continue
      fi

      case "$dll" in
        unetesp) dll_name="UNET ESP 2.2.2" ;;
        unetrtl) dll_name="UNET RTL" ;;
        *)       dll_name="$upper" ;;
      esac

      # The UNET DLL pins its own firmware profile in-source (unetesp.asm
      # DEFINEs ESP_AT_FORCE_222 + WIFI_STABLE_ACTIVE_RX for a 2.2.2-only,
      # trigger-8 build). Do NOT forward the EXE ESP_AT_PROFILE flag to the
      # DLL: a -DESP_AT_FORCE_221 would collide with the in-source 2.2.2 pin.
      dll_assembler=(--assembler sjasmplus)

      "${mkdll_cmd[@]}" build "$src" \
        --format l1 --target 1.3 "${dll_assembler[@]}" \
        -I "$repo_root/src/include" -I "$repo_root/src/lib" \
        --name "$dll_name" --version "$dll_version" --no-compress -o "$out"
      "${mkdll_cmd[@]}" verify "$out" --target 1.3
      echo "Built $out"
    done
  fi
fi

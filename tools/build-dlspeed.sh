#!/bin/sh
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repo_root=$(CDPATH= cd -- "$script_dir/.." && pwd)

case ${ESP_AT_PROFILE:-} in
	"") set -- ;;
	2.2.1) set -- -DESP_AT_FORCE_221 ;;
	2.2.2) set -- -DESP_AT_FORCE_222 ;;
	*)
		echo "Error: ESP_AT_PROFILE must be 2.2.1 or 2.2.2 (or unset)" >&2
		exit 1
		;;
esac

mkdir -p "$repo_root/build"
sjasmplus --nologo --fullpath "$@" \
	-I "$repo_root/src/include" \
	-I "$repo_root/src/lib" \
	--lst="$repo_root/build/DLSPEED.lst" \
	--raw="$repo_root/build/DLSPEED.EXE" \
	"$repo_root/src/apps/dlspeed.asm"
echo "Built $repo_root/build/DLSPEED.EXE (diagnostic tool, not packaged)"

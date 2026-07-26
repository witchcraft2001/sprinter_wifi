#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "$0")" && pwd)"
repo_root="$(cd "$script_dir/.." && pwd)"

source "$script_dir/artifacts.sh"

if ! command -v zip >/dev/null 2>&1; then
  echo "Error: zip is not installed or not in PATH" >&2
  exit 1
fi

if [ "${#DIST_DOC_CP866_FILES[@]}" -gt 0 ] && ! command -v iconv >/dev/null 2>&1; then
  echo "Error: iconv is required to encode CP866 docs but was not found" >&2
  exit 1
fi

"$script_dir/build.sh"

package_root="$repo_root/build/package/$DIST_NAME"
version_file="$repo_root/VERSION"

if [ ! -f "$version_file" ]; then
  echo "Error: VERSION file not found" >&2
  exit 1
fi

package_version="$(tr -d '\r\n' < "$version_file")"
if ! [[ "$package_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "Error: VERSION must use major.minor.patch format, got: $package_version" >&2
  exit 1
fi

zip_path="$repo_root/distr/sprinter-esp_v.$package_version.zip"

mkdir -p "$repo_root/distr" "$repo_root/build/package"
rm -f "$repo_root/distr/$DIST_NAME.zip"
rm -rf "$package_root"
mkdir -p "$package_root"

copy_optional_file() {
  local rel_path="$1"
  local src="$repo_root/$rel_path"

  if [ ! -f "$src" ]; then
    echo "Warning: $rel_path not found, skipping" >&2
    return
  fi

  mkdir -p "$package_root/$(dirname "$rel_path")"
  cp "$src" "$package_root/$rel_path"
}

is_zip_excluded_app() {
  local app="$1"
  local excluded

  for excluded in "${ZIP_EXCLUDE_APPS[@]}"; do
    if [ "$app" = "$excluded" ]; then
      return 0
    fi
  done

  return 1
}

is_zip_excluded_dll() {
  local dll="$1"
  local excluded

  # Length guard: an empty array expansion is an error under `set -u` on
  # macOS bash 3.2, so bail out before iterating an empty exclusion list.
  if [ "${#ZIP_EXCLUDE_DLLS[@]}" -eq 0 ]; then
    return 1
  fi

  for excluded in "${ZIP_EXCLUDE_DLLS[@]}"; do
    if [ "$dll" = "$excluded" ]; then
      return 0
    fi
  done

  return 1
}

for app in "${BUILD_APPS[@]}"; do
  if is_zip_excluded_app "$app"; then
    continue
  fi

  upper="$(printf '%s' "$app" | tr '[:lower:]' '[:upper:]')"
  exe="$repo_root/build/$upper.EXE"
  if [ -f "$exe" ]; then
    cp "$exe" "$package_root/$upper.EXE"
  else
    echo "Warning: build/$upper.EXE not found, skipping" >&2
  fi
done

for dll in "${BUILD_DLLS[@]}"; do
  if is_zip_excluded_dll "$dll"; then
    continue
  fi

  upper="$(printf '%s' "$dll" | tr '[:lower:]' '[:upper:]')"
  dll_path="$repo_root/build/$upper.DLL"
  if [ -f "$dll_path" ]; then
    cp "$dll_path" "$package_root/$upper.DLL"
  else
    echo "Warning: build/$upper.DLL not found, skipping" >&2
  fi
done

for rel_path in "${DIST_DOC_FILES[@]}"; do
  copy_optional_file "$rel_path"
done

# CP866-encoded docs: convert UTF-8 source -> CP866 in place of a verbatim copy.
for rel_path in "${DIST_DOC_CP866_FILES[@]}"; do
  src="$repo_root/$rel_path"
  if [ ! -f "$src" ]; then
    echo "Warning: $rel_path not found, skipping" >&2
    continue
  fi
  mkdir -p "$package_root/$(dirname "$rel_path")"
  iconv -f UTF-8 -t CP866 "$src" > "$package_root/$rel_path"
done

for rel_path in "${DIST_CONFIG_FILES[@]}"; do
  copy_optional_file "$rel_path"
done

for rel_path in "${DIST_EXTRA_FILES[@]}"; do
  copy_optional_file "$rel_path"
done

while IFS= read -r -d '' entry; do
  rel_path="${entry#$package_root/}"
  IFS=/ read -r -a path_parts <<< "$rel_path"
  for part in "${path_parts[@]}"; do
    upper_part="$(printf '%s' "$part" | tr '[:lower:]' '[:upper:]')"
    if ! [[ "$upper_part" =~ ^[A-Z0-9_]{1,8}(\.[A-Z0-9_]{1,3})?$ ]]; then
      echo "Error: ZIP distribution name is not 8.3: $rel_path" >&2
      exit 1
    fi
  done
done < <(find "$package_root" -mindepth 1 -print0)

rm -f "$zip_path"
cd "$package_root"
zip -qr "$zip_path" ./*

echo "Created $zip_path"

#!/usr/bin/env bash
set -euo pipefail
# This script runs inside the cloned PonWrt source tree, after feeds install.
# Keep NAND/UBI layout untouched; only add runtime packages here.
: > ./custom-package-commits.tsv
record_commit() {
  printf '%s\t%s\n' "$1" "$(git -C "$2" rev-parse HEAD)" >> ./custom-package-commits.tsv
}
remove_matches() {
  local pattern="$1"
  find ./package ./feeds/luci ./feeds/packages \
    -maxdepth 4 -type d -iname "*${pattern}*" 2>/dev/null \
    -print -exec rm -rf {} + || true
}
clone_direct() {
  local target="$1"
  local repo="$2"
  local branch="$3"
  remove_matches "$target"
  git clone --depth=1 --single-branch --branch "$branch" \
    "https://github.com/${repo}.git" "./package/${target}"
  record_commit "$repo" "./package/${target}"
}
import_nested_luci_app() {
  local pkg="$1"
  local repo="$2"
  local branch="$3"
  local tmp src
  tmp="$(mktemp -d)"
  remove_matches "$pkg"
  git clone --depth=1 --single-branch --branch "$branch" \
    "https://github.com/${repo}.git" "$tmp/src"
  src="$(find "$tmp/src" -maxdepth 3 -type d -name "$pkg" | head -n1)"
  if [ -z "$src" ] || [ ! -f "$src/Makefile" ]; then
    echo "ERROR: $pkg/Makefile not found in ${repo}" >&2
    exit 1
  fi
  cp -a "$src" "./package/${pkg}"
  if grep -q 'include ../../luci.mk' "./package/${pkg}/Makefile" 2>/dev/null; then
    sed -i 's|include ../../luci.mk|include $(TOPDIR)/feeds/luci/luci.mk|' \
      "./package/${pkg}/Makefile"
  fi
  record_commit "$repo" "$tmp/src"
  rm -rf "$tmp"
}
import_footstrap() {
  local tmp
  tmp="$(mktemp -d)"
  remove_matches "footstrap"
  git clone --depth=1 --single-branch --branch main \
    https://github.com/VizzleTF/luci-theme-footstrap.git "$tmp/footstrap"
  if [ ! -f "$tmp/footstrap/luci-theme-footstrap/Makefile" ]; then
    echo "ERROR: luci-theme-footstrap Makefile not found"
    exit 1
  fi
  cp -a "$tmp/footstrap/luci-theme-footstrap" ./package/luci-theme-footstrap
  record_commit VizzleTF/luci-theme-footstrap "$tmp/footstrap"
  rm -rf "$tmp"
}
import_openclash() {
  local tmp
  tmp="$(mktemp -d)"
  remove_matches "openclash"
  git clone --depth=1 --single-branch --branch dev \
    https://github.com/vernesong/OpenClash.git "$tmp/OpenClash"
  local src
  src="$(find "$tmp/OpenClash" -maxdepth 3 -type d -name 'luci-app-openclash' | head -n1)"
  if [ -z "$src" ]; then
    echo "ERROR: luci-app-openclash directory not found in vernesong/OpenClash"
    exit 1
  fi
  cp -a "$src" ./package/luci-app-openclash
  record_commit vernesong/OpenClash "$tmp/OpenClash"
  rm -rf "$tmp"
}
import_viking_packages() {
  local tmp name
  tmp="$(mktemp -d)"
  remove_matches "gecoosac"
  remove_matches "luci-app-wolplus"
  remove_matches "luci-app-wolultra"
  remove_matches "luci-app-timewol"
  rm -rf ./package/viking-packages
  git clone --depth=1 --single-branch --branch main --filter=blob:none --sparse \
    https://github.com/VIKINGYFY/packages.git "$tmp/packages"
  git -C "$tmp/packages" sparse-checkout set \
    gecoosac luci-app-gecoosac luci-app-wolultra
  for name in gecoosac luci-app-gecoosac luci-app-wolultra; do
    if [ ! -f "$tmp/packages/$name/Makefile" ]; then
      echo "ERROR: VIKING package is missing $name/Makefile" >&2
      exit 1
    fi
  done
  mkdir -p ./package/viking-packages
  for name in gecoosac luci-app-gecoosac luci-app-wolultra; do
    cp -a "$tmp/packages/$name" "./package/viking-packages/$name"
  done
  record_commit VIKINGYFY/packages "$tmp/packages"
  rm -rf "$tmp"
}
import_autoreboot() {
  local tmp
  tmp="$(mktemp -d)"
  remove_matches "luci-app-autoreboot"
  git clone --depth=1 --filter=blob:none --sparse \
    https://github.com/immortalwrt/luci.git "$tmp/luci"
  git -C "$tmp/luci" sparse-checkout set applications/luci-app-autoreboot
  cp -a "$tmp/luci/applications/luci-app-autoreboot" ./package/luci-app-autoreboot
  sed -i 's|include ../../luci.mk|include $(TOPDIR)/feeds/luci/luci.mk|' \
    ./package/luci-app-autoreboot/Makefile
  record_commit immortalwrt/luci-autoreboot "$tmp/luci"
  rm -rf "$tmp"
}
import_airoha_npu() {
  local repo="rchen14b/luci-app-airoha-npu"
  local revision="14521b8414da1e98517a295d8ec267087c7dde8e"
  local dest="./package/luci-app-airoha-npu"
  local required
  remove_matches "luci-app-airoha-npu"
  git init -q "$dest"
  git -C "$dest" remote add origin "https://github.com/${repo}.git"
  if [ "$(git -C "$dest" remote get-url origin)" != "https://github.com/${repo}.git" ]; then
    echo "ERROR: wrong Airoha NPU origin; expected https://github.com/${repo}.git" >&2
    exit 1
  fi
  git -C "$dest" fetch --depth=1 origin "$revision"
  git -C "$dest" -c advice.detachedHead=false checkout --detach FETCH_HEAD
  for required in \
    Makefile \
    htdocs/luci-static/resources/view/airoha_npu/status.js \

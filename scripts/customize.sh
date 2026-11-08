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
    root/usr/libexec/rpcd/luci.airoha_npu \
    root/usr/share/luci/menu.d/luci-app-airoha-npu.json \
    root/usr/share/rpcd/acl.d/luci-app-airoha-npu.json; do
    if [ ! -f "$dest/$required" ]; then
      echo "ERROR: pinned Airoha NPU package is missing $required" >&2
      exit 1
    fi
  done
  if ! grep -Fq 'include $(TOPDIR)/feeds/luci/luci.mk' "$dest/Makefile"; then
    echo "ERROR: pinned Airoha NPU package Makefile is not feed-compatible" >&2
    exit 1
  fi
  rm -rf -- "$dest/luci-app-airoha-npu"
  record_commit "$repo" "$dest"
}
import_passwall() {
  echo "Importing official Passwall..."
  rm -rf \
    feeds/packages/net/xray-core \
    feeds/packages/net/v2ray-geodata \
    feeds/packages/net/sing-box \
    feeds/packages/net/chinadns-ng \
    feeds/packages/net/dns2socks \
    feeds/packages/net/hysteria \
    feeds/packages/net/ipt2socks \
    feeds/packages/net/microsocks \
    feeds/packages/net/naiveproxy \
    feeds/packages/net/shadowsocks-rust \
    feeds/packages/net/shadowsocksr-libev \
    feeds/packages/net/simple-obfs \
    feeds/packages/net/tcping \
    feeds/packages/net/v2ray-plugin \
    feeds/packages/net/xray-plugin \
    feeds/packages/net/geoview \
    feeds/packages/net/shadow-tls \
    package/feeds/packages/xray-core \
    package/feeds/packages/v2ray-geodata \
    package/feeds/packages/sing-box \
    package/feeds/packages/chinadns-ng \
    package/feeds/packages/dns2socks \
    package/feeds/packages/hysteria \
    package/feeds/packages/ipt2socks \
    package/feeds/packages/microsocks \
    package/feeds/packages/naiveproxy \
    package/feeds/packages/shadowsocks-rust \
    package/feeds/packages/shadowsocksr-libev \
    package/feeds/packages/simple-obfs \
    package/feeds/packages/tcping \
    package/feeds/packages/v2ray-plugin \
    package/feeds/packages/xray-plugin \
    package/feeds/packages/geoview \
    package/feeds/packages/shadow-tls \
    feeds/luci/applications/luci-app-passwall \
    package/feeds/luci/luci-app-passwall \
    package/luci-app-passwall \
    package/passwall-luci \
    package/passwall-packages \
    2>/dev/null || true
  git clone --depth=1 --single-branch --branch main \
    https://github.com/Openwrt-Passwall/openwrt-passwall-packages.git \
    ./package/passwall-packages
  git clone --depth=1 --single-branch --branch main \
    https://github.com/Openwrt-Passwall/openwrt-passwall.git \
    ./package/passwall-luci
  if [ ! -f ./package/passwall-packages/Makefile ] \
    && [ -z "$(find ./package/passwall-packages -maxdepth 2 -name Makefile | head -n1)" ]; then
    echo "ERROR: passwall-packages looks empty or invalid" >&2
    exit 1
  fi
  if [ ! -f ./package/passwall-luci/luci-app-passwall/Makefile ] \
    && [ ! -f ./package/passwall-luci/Makefile ]; then
    echo "ERROR: passwall-luci does not contain luci-app-passwall Makefile" >&2
    exit 1
  fi
  record_commit Openwrt-Passwall/openwrt-passwall-packages ./package/passwall-packages
  record_commit Openwrt-Passwall/openwrt-passwall ./package/passwall-luci
  echo "Official Passwall import completed."
}
import_3proxy() {
  echo "Importing 3proxy for luci-app-3cat..."
  remove_matches "3proxy"
  local tmp
  tmp="$(mktemp -d)"
  git clone --depth=1 --filter=blob:none --sparse \
    https://github.com/immortalwrt/packages.git "$tmp/packages"
  git -C "$tmp/packages" sparse-checkout set net/3proxy
  if [ ! -f "$tmp/packages/net/3proxy/Makefile" ]; then
    echo "ERROR: immortalwrt/packages missing net/3proxy/Makefile" >&2
    exit 1
  fi
  mkdir -p ./package
  cp -a "$tmp/packages/net/3proxy" ./package/3proxy
  record_commit immortalwrt/packages-3proxy "$tmp/packages"
  rm -rf "$tmp"
  echo "3proxy import completed."
}
import_istore() {
  echo "Importing iStore (luci-app-store)..."
  remove_matches "luci-app-store"
  remove_matches "luci-lib-taskd"
  remove_matches "luci-lib-xterm"
  remove_matches "taskd"
  local tmp
  tmp="$(mktemp -d)"
  git clone --depth=1 --single-branch --branch main \
    https://github.com/istoreos/istore.git "$tmp/istore"
  for name in luci-app-store luci-lib-taskd luci-lib-xterm taskd; do
    if [ ! -f "$tmp/istore/luci/$name/Makefile" ]; then
      echo "ERROR: istore missing luci/$name/Makefile" >&2
      exit 1
    fi
    cp -a "$tmp/istore/luci/$name" "./package/$name"
  done
  record_commit istoreos/istore "$tmp/istore"
  rm -rf "$tmp"
  echo "iStore import completed."
}
import_minigate() {
  echo "Importing minigate..."
  clone_direct "minigate" "tpxcer/minigate" "main"
  if [ ! -f ./package/minigate/Makefile ]; then
    echo "ERROR: package/minigate/Makefile missing after clone" >&2
    exit 1
  fi
  sed -i \
    -e 's/+nginx-ssl //g' \
    -e 's/+nginx-mod-stream //g' \
    ./package/minigate/Makefile
  if grep -qE 'nginx-ssl|nginx-mod-stream' ./package/minigate/Makefile; then
    echo "WARNING: minigate Makefile still references nginx-*; check DEPENDS" >&2
  fi
  echo "minigate import completed (nginx hard-deps removed)."
}
import_istorex() {
  echo "Importing iStoreX (quickstart + luci-app-quickstart + luci-app-istorex)..."
  remove_matches "luci-app-istorex"
  remove_matches "luci-app-quickstart"
  remove_matches "quickstart"
  local tmp name
  tmp="$(mktemp -d)"
  git clone --depth=1 --single-branch --branch main --filter=blob:none --sparse \
    https://github.com/kenzok8/small-package.git "$tmp/smp"
  git -C "$tmp/smp" sparse-checkout set \
    quickstart luci-app-quickstart luci-app-istorex
  for name in quickstart luci-app-quickstart luci-app-istorex; do
    if [ ! -f "$tmp/smp/$name/Makefile" ]; then
      echo "ERROR: kenzok8/small-package missing $name/Makefile" >&2
      exit 1
    fi
    cp -a "$tmp/smp/$name" "./package/$name"
  done
  for name in luci-app-quickstart luci-app-istorex; do
    if grep -q 'include ../../luci.mk' "./package/$name/Makefile" 2>/dev/null; then
      sed -i 's|include ../../luci.mk|include $(TOPDIR)/feeds/luci/luci.mk|' \
        "./package/$name/Makefile"
    fi
  done
  record_commit kenzok8/small-package-istorex "$tmp/smp"
  rm -rf "$tmp"
  echo "iStoreX import completed."
}

# Break luci-app-fwknopd <-> fwknopd <-> FWKNOPD_GPG / gnupg2 Kconfig cycles
patch_fwknop_kconfig_cycle() {
  local f
  echo "Patching fwknop Kconfig cycle..."
  for f in \
    feeds/packages/net/fwknop/Config.in \
    package/feeds/packages/fwknop/Config.in
  do
    [ -f "$f" ] || continue
    sed -i 's/depends on PACKAGE_fwknopd || PACKAGE_fwknop//' "$f"
    sed -i 's/depends on PACKAGE_fwknopd//' "$f"
    sed -i 's/select PACKAGE_gnupg2//' "$f"
    sed -i 's/select PACKAGE_gnupg//' "$f"
    echo "  patched $f"
  done
  for f in \
    feeds/luci/applications/luci-app-fwknopd/Makefile \
    package/feeds/luci/luci-app-fwknopd/Makefile
  do
    [ -f "$f" ] || continue
    sed -i 's/+FWKNOPD_GPG//g' "$f"
    sed -i 's/+gnupg2//g' "$f"
    sed -i 's/+gnupg//g' "$f"
    echo "  patched $f"
  done
}

echo "Importing third-party packages used by the GENERAL package set..."
import_openclash
clone_direct "luci-app-lucky" "sirpdboy/luci-app-lucky" "main"
import_viking_packages
import_airoha_npu
import_footstrap
import_autoreboot
import_passwall
import_3proxy
# Extra apps for OpenWrt 25
import_nested_luci_app "luci-app-taskplan" "sirpdboy/luci-app-taskplan" "main"
import_nested_luci_app "luci-app-run" "wukongdaily/luci-app-run" "master"
import_minigate
import_istore
import_istorex
python3 "$(dirname "$0")/integrate-temperature.py" .
if [ -L ./package/feeds/packages/squeezelite ]; then
  rm ./package/feeds/packages/squeezelite
fi

# Must run before adjust-feed-packages / tmp regeneration
patch_fwknop_kconfig_cycle

# Not used in general-packages; drop from Kconfig to avoid gnupg2/libfko cycles
rm -f package/feeds/luci/luci-app-fwknopd 2>/dev/null || true

python3 "$(dirname "$0")/adjust-feed-packages.py" .
rm -rf ./tmp
echo "Third-party package import completed."

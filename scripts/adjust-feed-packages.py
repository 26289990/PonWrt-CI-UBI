#!/usr/bin/env python3
"""Fix feed-only metadata incompatibilities in the Airoha headless firmware build.

Use only exact, known upstream metadata patterns. Never hide missing packages.
"""
import hashlib
import pathlib
import re
import sys

MPD_LINK = pathlib.Path("package/feeds/packages/mpd")
LIBEVDEV_MAKEFILE = pathlib.Path("feeds/packages/libs/libevdev/Makefile")
INPUT_FEATURE = "  DEPENDS:=input-support"
PATCHED_FEATURE = "  # This package is also needed by libudev-zero for USB enumeration.\n  # Airoha has no OpenWrt input-support target feature; libevdev is userspace.\n  DEPENDS:="
MINIUPNPD = pathlib.Path("feeds/packages/net/miniupnpd")
MINIUPNPD_BACKPORTS = {
    "020-descr-filter-fix.patch": "4e0f8ddf58cb130044a5f3b92bdf3a8859f8c15e0edbcbcb2b8df42f99e41da1",
    "030-allow-private-fix.patch": "c667bfaa2f1028d1dc44547d4dd4302891799fc0de271a17618eff537b1a2339",
}
MINIUPNPD_LOGGING_PATCH = "040-improve-logging.patch"
MINIUPNPD_LOGGING_SHA256 = "aad6802ab9d01ecea2c143d7495644b714e171552434049f8669d4f28611bcba"
MINIUPNPD_LOGGING_REFRESH = pathlib.Path(__file__).resolve().parent.parent / "config/miniupnpd/040-improve-logging-2.3.11.patch"


def adjust_miniupnpd(source):
    package = pathlib.Path(source) / MINIUPNPD
    makefile = package / "Makefile"
    if not makefile.exists():
        return
    version = re.search(r"^PKG_VERSION:=(\S+)\s*$", makefile.read_text(), re.M)
    if not version or version[1] != "2.3.11":
        return
    # Verify every affected file before editing; unknown feed revisions need review.
    obsolete = []
    for name, checksum in MINIUPNPD_BACKPORTS.items():
        patch = package / "patches" / name
        if patch.exists():
            if hashlib.sha256(patch.read_bytes()).hexdigest() != checksum:
                raise ValueError(f"Unrecognized miniupnpd patch: {name}")
            obsolete.append(patch)
    logging = package / "patches" / MINIUPNPD_LOGGING_PATCH
    refreshed = MINIUPNPD_LOGGING_REFRESH.read_bytes()
    if logging.exists() and logging.read_bytes() != refreshed:
        if hashlib.sha256(logging.read_bytes()).hexdigest() != MINIUPNPD_LOGGING_SHA256:
            raise ValueError("Unrecognized miniupnpd logging patch")
        logging.write_bytes(refreshed)
    # 2.3.11 includes both parser/private-address fixes. Retain upstream security
    # fixes, source hash, UPnP compatibility patches and refreshed logging behavior.
    for patch in obsolete:
        patch.unlink()
    print("miniupnpd 2.3.11: omitted merged backports and refreshed logging patch")


def adjust(source):
    source = pathlib.Path(source)
    adjust_miniupnpd(source)
    mpd = source / MPD_LINK
    if mpd.is_symlink():
        # Unselected audio package causes PACKAGE_mpd-full -> itself in Kconfig.
        mpd.unlink()
    elif mpd.exists():
        raise ValueError(f"Refusing to remove non-feed package: {mpd}")

    path = source / LIBEVDEV_MAKEFILE
    text = path.read_text()
    if text.count(INPUT_FEATURE) == 1 and PATCHED_FEATURE not in text:
        text = text.replace(INPUT_FEATURE, PATCHED_FEATURE, 1)
        path.write_text(text)
    elif text.count(PATCHED_FEATURE) == 1:
        pass  # Rerunning customization must be idempotent.
    elif "DEPENDS:=input-support" in text:
        raise ValueError("Upstream libevdev input-support dependency changed")
    else:
        print("libevdev no longer depends on input-support; no patch needed")
    print("Applied headless Airoha feed compatibility adjustments.")


if __name__ == "__main__":
    if len(sys.argv) != 2:
        raise SystemExit("Usage: adjust-feed-packages.py PONWRT_SOURCE")
    adjust(sys.argv[1])

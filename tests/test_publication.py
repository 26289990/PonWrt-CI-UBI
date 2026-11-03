#!/usr/bin/env python3
"""Regression checks for device coverage, identity and actual image packages."""
import hashlib
import importlib.util
import io
import json
import pathlib
import shutil
import subprocess
import sys
import tarfile
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "scripts"))
from devices import config_fragment, required_packages
from image_packages import image_packages, rootfs_from_fit, rootfs_from_tar
from validate import validate_config, validate_profile

spec = importlib.util.spec_from_file_location("release_notes", ROOT / "scripts/release-notes.py")
release_module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(release_module)

CATALOG = {
    "source_commit": "a" * 40,
    "targets": {"an7581": ["nokia_xg-040g-md-ubi", "znxt_zn504xg-d"],
                "an7583": ["nokia_xg-040g-mf", "nokia_xg-040g-mf-ubi"]},
    "profile_count": 4,
}

# Always pick a package that remains in required-packages.txt after optional
# apps (openclash/lucky/wolultra/...) were removed from the mandatory list.
REQUIRED_APP = "luci-app-airoha-npu"


class ConfigChecks(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.path = pathlib.Path(self.tmp.name) / ".config"
        self.config = config_fragment(CATALOG, "an7581") + "\n".join([
            "CONFIG_TARGET_ROOTFS_SQUASHFS=y", "CONFIG_TARGET_ROOTFS_INITRAMFS=y",
            "CONFIG_JSON_OVERVIEW_IMAGE_INFO=y", "CONFIG_LUCI_LANG_zh_Hans=y",
            "CONFIG_PACKAGE_fitblk=y",
        ] + [f"CONFIG_PACKAGE_{p}=y" for p in required_packages("an7581")]) + "\n"

    def validate(self, config):
        self.path.write_text(config)
        return validate_config(self.path, "an7581", CATALOG)

    def test_per_device_fitblk_module_is_allowed(self):
        self.assertEqual([], self.validate(self.config.replace(
            "CONFIG_PACKAGE_fitblk=y", "CONFIG_PACKAGE_fitblk=m")))

    def test_missing_profile_is_rejected(self):
        self.assertTrue(self.validate(self.config.replace(
            "CONFIG_TARGET_DEVICE_airoha_an7581_DEVICE_znxt_zn504xg-d=y", "")))

    def test_additional_profile_is_rejected(self):
        self.assertTrue(self.validate(self.config +
            "CONFIG_TARGET_DEVICE_airoha_an7581_DEVICE_unknown=y\n"))

    def test_required_application_cannot_be_module_only(self):
        self.assertTrue(self.validate(self.config.replace(
            f"CONFIG_PACKAGE_{REQUIRED_APP}=y", f"CONFIG_PACKAGE_{REQUIRED_APP}=m")))

    def test_wrong_soc_firmware_is_rejected(self):
        self.assertTrue(self.validate(self.config.replace(
            "CONFIG_PACKAGE_airoha-en7581-npu-firmware=y",
            "CONFIG_PACKAGE_airoha-an7583-npu-firmware=y")))


class IdentityChecks(unittest.TestCase):
    def setUp(self):
        self.profile = "znxt_zn504xg-d"
        self.meta = {"version": {"board": self.profile, "target": "airoha/an7581"},
                     "supported_devices": ["znxt,zn504xg-d"]}
        self.info = {"supported_devices": ["znxt,zn504xg-d"],
                     "device_packages": ["kmod-device-radio", "-obsolete-radio"]}
        self.packages = dict.fromkeys(required_packages("an7581") + ["kmod-device-radio"], "1")

    def validate(self):
        return validate_profile(self.meta, self.info, self.profile, "an7581", self.packages)

    def test_matching_profile(self):
        self.assertEqual([], self.validate())

    def test_same_soc_wrong_board_is_rejected(self):
        self.meta["version"]["board"] = "nokia_xg-040g-md-ubi"
        self.assertTrue(self.validate())

    def test_wrong_supported_devices_is_rejected(self):
        self.meta["supported_devices"] = ["nokia,xg-040g-md-ubi"]
        self.assertTrue(self.validate())

    def test_hardware_dependency_must_be_in_actual_rootfs(self):
        del self.packages["kmod-device-radio"]
        self.assertTrue(self.validate())

    def test_missing_required_application_is_rejected(self):
        del self.packages[REQUIRED_APP]
        self.assertTrue(self.validate())


@unittest.skipUnless(all(shutil.which(x) for x in ["mksquashfs", "unsquashfs", "dtc", "fdtget"]),
                     "squashfs-tools and device-tree-compiler are required")
class ImageExtractionChecks(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = pathlib.Path(self.tmp.name)
        db = self.root / "fs/lib/apk/db/installed"
        db.parent.mkdir(parents=True)
        db.write_text(f"P:{REQUIRED_APP}\nV:0.47\n\nP:kmod-device-radio\nV:6.12\n\n")
        self.squashfs = self.root / "rootfs"
        subprocess.run(["mksquashfs", str(self.root / "fs"), str(self.squashfs),
                        "-noappend", "-processors", "1", "-comp", "gzip"],
                       check=True, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
        self.data = self.squashfs.read_bytes()

    def fit(self, position=4096):
        dts = self.root / "image.dts"
        dts.write_text('/dts-v1/; / { images { kernel-1 { type = "kernel"; }; '
                       'rootfs-1 { type = "filesystem"; data-position = <'
                       + str(position) + '>; data-size = <' + str(len(self.data))
                       + '>; }; }; };')
        dtb = self.root / "image.dtb"
        subprocess.run(["dtc", "-I", "dts", "-O", "dtb", "-o", str(dtb), str(dts)],
                       check=True, stderr=subprocess.PIPE)
        image = self.root / "firmware.itb"
        header = dtb.read_bytes()
        image.write_bytes(header + b"\0" * (4096 - len(header)) + self.data)
        return image

    def test_fit_reads_real_installed_database(self):
        self.assertEqual({REQUIRED_APP: "0.47", "kmod-device-radio": "6.12"},
                         image_packages(self.fit()))

    def test_out_of_bounds_fit_is_rejected(self):
        with self.assertRaises(ValueError):
            rootfs_from_fit(self.fit(position=1000000))

    def test_legacy_tar_reads_same_database(self):
        image = self.root / "sysupgrade.bin"
        with tarfile.open(image, "w") as tar:
            info = tarfile.TarInfo("sysupgrade-nokia_xg-040g-mf/root")
            info.size = len(self.data)
            tar.addfile(info, io.BytesIO(self.data))
        with image.open("ab") as stream:
            stream.write(b"fwtool-metadata-footer")
        self.assertEqual("0.47", image_packages(image)[REQUIRED_APP])

    def test_duplicate_tar_roots_are_rejected(self):
        image = self.root / "duplicate.bin"
        with tarfile.open(image, "w") as tar:
            for device in ["board-a", "board-b"]:
                info = tarfile.TarInfo(device + "/root")
                info.size = len(self.data)
                tar.addfile(info, io.BytesIO(self.data))
        with self.assertRaises(ValueError):
            rootfs_from_tar(image)


class ReleaseChecks(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.output = pathlib.Path(self.tmp.name)
        self.summaries = {}
        for soc, profiles in CATALOG["targets"].items():
            records = []
            for profile in profiles:
                images = []
                for kind in ["sysupgrade", "initramfs-recovery"]:
                    name = profile + "-" + kind + ".bin"
                    data = name.encode()
                    (self.output / name).write_bytes(data)
                    images.append({"name": name, "size": len(data),
                                   "sha256": hashlib.sha256(data).hexdigest()})
                records.append({"profile": profile, "sysupgrade": images[0]["name"],
                                "recovery": [images[1]["name"]], "images": images})
            self.summaries[soc] = {"target": "airoha/" + soc, "profiles": records,
                                   "source_commit": CATALOG["source_commit"]}
        self.save()

    def save(self):
        for soc, summary in self.summaries.items():
            name = f"{soc}-build-summary.json"
            (self.output / name).write_text(json.dumps(summary))
            files = [name] + [x["name"] for item in summary["profiles"] for x in item["images"]]
            (self.output / f"SHA256SUMS-{soc}").write_text("".join(
                hashlib.sha256((self.output / f).read_bytes()).hexdigest() + "  " + f + "\n"
                for f in files))

    def test_complete_release(self):
        notes = release_module.release_notes(self.output, CATALOG)
        self.assertIn("znxt_zn504xg-d", notes)
        self.assertIn("nokia_xg-040g-mf-ubi", notes)

    def test_missing_profile_blocks_release(self):
        self.summaries["an7583"]["profiles"].pop()
        self.save()
        with self.assertRaises(ValueError):
            release_module.release_notes(self.output, CATALOG)

    def test_duplicate_profile_blocks_release(self):
        self.summaries["an7583"]["profiles"].append(
            self.summaries["an7583"]["profiles"][0])
        self.save()
        with self.assertRaises(ValueError):
            release_module.release_notes(self.output, CATALOG)

    def test_different_source_commit_blocks_release(self):
        self.summaries["an7583"]["source_commit"] = "b" * 40
        self.save()
        with self.assertRaises(ValueError):
            release_module.release_notes(self.output, CATALOG)

    def test_corrupt_downloaded_artifact_blocks_release(self):
        (self.output / "znxt_zn504xg-d-sysupgrade.bin").write_bytes(b"truncated")
        with self.assertRaises(ValueError):
            release_module.release_notes(self.output, CATALOG)


if __name__ == "__main__":
    unittest.main()

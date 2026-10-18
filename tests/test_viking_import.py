"""Keep unrelated VIKING packages out of the selected runtime import."""
import os
import pathlib
import subprocess
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parent.parent
SELECTED = {"gecoosac", "luci-app-gecoosac", "luci-app-wolultra"}


class VikingImportChecks(unittest.TestCase):
    def test_import_copies_selected_apps_and_runtime_without_other_overrides(self):
        with tempfile.TemporaryDirectory() as tmp:
            source = pathlib.Path(tmp)
            fixture = source / "upstream"
            for name in SELECTED | {"luci-app-homeproxy", "sing-box", "axonhub"}:
                package = fixture / name
                package.mkdir(parents=True)
                (package / "Makefile").write_text("fixture " + name + "\n")
            fakebin = source / "bin"
            fakebin.mkdir()
            git = fakebin / "git"
            git.write_text("""#!/usr/bin/env python3
import os, pathlib, shutil, sys
args = sys.argv[1:]
if args[0] == 'clone':
    shutil.copytree(os.environ['VIKING_FIXTURE'], args[-1])
elif args[0] == '-C' and args[2:] == ['rev-parse', 'HEAD']:
    print('a' * 40)
elif args[0] == '-C' and args[2:4] == ['sparse-checkout', 'set']:
    pass
else:
    raise SystemExit('Unexpected git invocation: ' + repr(args))
""")
            git.chmod(0o755)
            script = (ROOT / "scripts/customize.sh").read_text()
            definitions = script.split('\necho "Importing third-party packages', 1)[0]
            env = dict(os.environ, PATH=str(fakebin) + os.pathsep + os.environ["PATH"],
                       VIKING_FIXTURE=str(fixture))
            subprocess.run(["bash", "-eu"], input=definitions + "\nimport_viking_packages\n",
                           text=True, cwd=source, env=env, check=True,
                           stdout=subprocess.PIPE, stderr=subprocess.PIPE)
            imported = source / "package/viking-packages"
            self.assertEqual(SELECTED, {path.name for path in imported.iterdir()})
            for name in SELECTED:
                self.assertEqual("fixture " + name + "\n", (imported / name / "Makefile").read_text())
            self.assertIn("VIKINGYFY/packages\t" + "a" * 40,
                          (source / "custom-package-commits.tsv").read_text())

    def test_live_source_contains_only_selected_viking_packages(self):
        path = os.environ.get("PONWRT_TEST_SOURCE")
        if not path:
            self.skipTest("Fetched PonWrt source required")
        imported = pathlib.Path(path) / "package/viking-packages"
        self.assertEqual(SELECTED, {entry.name for entry in imported.iterdir()})
        for name in SELECTED:
            self.assertTrue((imported / name / "Makefile").is_file())


if __name__ == "__main__":
    unittest.main()

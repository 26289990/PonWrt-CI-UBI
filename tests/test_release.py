"""Exercise release references with a real local Git remote and a recording gh."""
import json
import os
import pathlib
import subprocess
import tempfile
import unittest

SCRIPT = pathlib.Path(__file__).resolve().parents[1] / "scripts/release.sh"


class ReleaseReferenceChecks(unittest.TestCase):
    def setUp(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.root = pathlib.Path(tmp.name)
        self.remote = self.root / "remote.git"
        self.repo = self.root / "checkout"
        self.repo.mkdir()
        self.git("init", "--bare", str(self.remote))
        self.git("init", "-b", "main")
        self.git("config", "user.name", "Release test")
        self.git("config", "user.email", "test@example.invalid")
        self.git("remote", "add", "origin", str(self.remote))
        self.sha = self.commit("build commit")
        self.git("push", "origin", "main")
        self.tag = "ponwrt-r26-39088937482"
        self.output = self.root / "step-output"
        bin_dir = self.root / "bin"
        bin_dir.mkdir()
        gh = bin_dir / "gh"
        gh.write_text("#!/usr/bin/env python3\nimport json, os, pathlib, sys\n"
                      "pathlib.Path(os.environ['GH_CALL']).write_text(json.dumps(sys.argv[1:]))\n")
        gh.chmod(0o755)
        self.env = dict(os.environ, GITHUB_SHA=self.sha, GITHUB_RUN_NUMBER="26",
                        GITHUB_RUN_ID="39088937482", GITHUB_REPOSITORY="owner/repo",
                        GITHUB_OUTPUT=str(self.output), RELEASE_TAG=self.tag,
                        GH_CALL=str(self.root / "gh-call.json"),
                        PATH=str(bin_dir) + os.pathsep + os.environ["PATH"])
        (self.repo / "output").mkdir()
        (self.repo / "output/firmware.bin").write_bytes(b"validated firmware")

    def git(self, *args):
        return subprocess.run(["git", *args], cwd=self.repo, check=True,
                              capture_output=True, text=True).stdout.strip()

    def commit(self, message):
        self.git("commit", "--allow-empty", "-m", message)
        return self.git("rev-parse", "HEAD")

    def release(self, mode, success=True):
        result = subprocess.run(["bash", str(SCRIPT), mode], cwd=self.repo,
                                env=self.env, capture_output=True, text=True)
        self.assertEqual(result.returncode == 0, success, result.stdout + result.stderr)
        return result

    def remote_tag(self):
        return self.git("ls-remote", "--refs", "origin", "refs/tags/" + self.tag)

    def test_pin_survives_branch_update_and_prepare_retry(self):
        self.release("prepare")
        newer = self.commit("later workflow change")
        self.git("push", "origin", "main")
        self.assertNotEqual(newer, self.sha)
        self.release("prepare")
        self.assertEqual(self.remote_tag(), self.sha + "\trefs/tags/" + self.tag)
        self.assertEqual(self.output.read_text().splitlines(),
                         ["release_tag=" + self.tag] * 2)
        self.release("publish")
        args = json.loads((self.root / "gh-call.json").read_text())
        self.assertEqual(args[:4], ["release", "create", self.tag, "output/firmware.bin"])
        self.assertIn("--verify-tag", args)
        self.assertNotIn("--target", args)

    def test_prepare_rejects_existing_tag_for_another_commit(self):
        newer = self.commit("another build")
        self.git("push", "origin", newer + ":refs/tags/" + self.tag)
        self.release("prepare", success=False)
        self.assertEqual(self.remote_tag(), newer + "\trefs/tags/" + self.tag)
        self.assertFalse(self.output.exists())

    def test_publish_cannot_create_a_missing_tag(self):
        self.release("publish", success=False)
        self.assertEqual(self.remote_tag(), "")
        self.assertFalse((self.root / "gh-call.json").exists())

    def test_publish_rejects_changed_tag(self):
        self.release("prepare")
        newer = self.commit("other commit")
        self.git("push", "--force", "origin", newer + ":refs/tags/" + self.tag)
        self.release("publish", success=False)
        self.assertFalse((self.root / "gh-call.json").exists())

    def test_publish_rejects_another_runs_output(self):
        self.release("prepare")
        self.env["RELEASE_TAG"] = "ponwrt-r25-1"
        self.release("publish", success=False)
        self.assertFalse((self.root / "gh-call.json").exists())


if __name__ == "__main__":
    unittest.main()

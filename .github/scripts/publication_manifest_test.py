#!/usr/bin/env python3
"""Synthetic datasets and stubbed Actions metadata; no network or publication."""

import copy
import importlib.util
import json
import os
import subprocess
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

HERE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location("publication_manifest", HERE / "publication_manifest.py")
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class PublicationManifestTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="publication-manifest-test-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        previous = Path.cwd()
        os.chdir(self.root)
        self.addCleanup(os.chdir, previous)
        self.environment = patch.dict(os.environ, {
            "GITHUB_ACTIONS": "true", "GITHUB_REPOSITORY": "ammitto/data",
            "PUBLICATION_DEFAULT_BRANCH": "main", "GITHUB_REF": "refs/heads/main",
            "GITHUB_EVENT_NAME": "schedule", "GITHUB_RUN_ID": "123", "GITHUB_RUN_ATTEMPT": "2",
            "GITHUB_OUTPUT": str(self.root / "outputs"),
        })
        self.environment.start()
        self.addCleanup(self.environment.stop)
        self.git("init", "-q")
        self.git("config", "user.name", "Fixture")
        self.git("config", "user.email", "fixture@example.test")
        Path("README").write_text("fixture\n")
        self.git("add", "README")
        self.git("commit", "-qm", "initial")
        self.base = self.git("rev-parse", "HEAD")
        Path("api/v1/sources").mkdir(parents=True)
        Path("api/v1/stats.json").write_text('{"entities": 1}\n')
        Path(".gitignore").write_text("\n".join(str(path) for path in module.ASSETS.values()) + "\n")
        self.git("add", "api", ".gitignore")
        self.git("update-index", "--add", "--cacheinfo", f"160000,{self.base},sources/data-uk")
        self.git("commit", "-qm", "accepted dataset")
        self.accepted = self.git("rev-parse", "HEAD")
        for name, path in module.ASSETS.items():
            path.write_text("synthetic aggregate " + name + "\n")
        Path("api/v1/stats.json").write_text('{"entities": 2}\n')
        # An actual nested source repository ensures staging keeps a gitlink.
        Path("sources/data-uk").mkdir(parents=True)
        self.git("clone", "-q", "--no-hardlinks", str(self.root), "sources/data-uk/clone")
        # Use the clone as a direct source root, without removing any external work.
        for item in (Path("sources/data-uk/clone")).iterdir():
            item.rename(Path("sources/data-uk") / item.name)
        Path("sources/data-uk/clone").rmdir()

    def git(self, *args):
        return subprocess.run(["git", *args], check=True, capture_output=True, text=True).stdout.strip()

    def prepare(self):
        artifact = self.root / "artifact"
        module.prepare(artifact)
        return module.read_manifest(module.MANIFEST), artifact

    def run_metadata(self):
        return {"id": 123, "run_attempt": 2, "repository": {"full_name": "ammitto/data"},
                "head_repository": {"full_name": "ammitto/data"}, "head_branch": "main",
                "path": ".github/workflows/harmonize.yml", "event": "schedule",
                "status": "completed", "conclusion": "success", "head_sha": self.base}

    def test_prepare_preserves_index_and_binds_four_assets_and_manifest(self):
        before = self.git("write-tree")
        manifest, artifact = self.prepare()
        self.assertEqual(self.git("write-tree"), before)
        self.assertEqual(manifest["artifact_name"], "harmonized-aggregates-123-2")
        self.assertEqual(set(path.name for path in artifact.iterdir()), set(module.ASSETS) | {"manifest.json"})
        module.verify_artifact(manifest, artifact)
        self.git("add", "api", ".publication", "sources")
        self.git("commit", "-qm", "accept proposed data")
        self.assertEqual(module.dataset_trees("HEAD"), {k: manifest[k] for k in ("api_tree", "sources_tree")})

    def test_no_dataset_change_does_not_replace_accepted_manifest(self):
        Path("api/v1/stats.json").write_text('{"entities": 1}\n')
        self.git("update-index", "--cacheinfo", f"160000,{self.accepted},sources/data-uk")
        self.git("commit", "-qm", "match pinned source")
        previous, _ = self.prepare()
        accepted_bytes = module.MANIFEST.read_bytes()
        self.git("add", ".publication")
        self.git("commit", "-qm", "accept initial manifest")
        artifact = self.root / "unchanged-artifact"
        with patch.object(module, "verify_run", return_value=True):
            module.prepare(artifact)
        self.assertEqual(module.MANIFEST.read_bytes(), accepted_bytes)
        self.assertFalse(artifact.exists())
        self.assertIn("changed=false", Path("outputs").read_text())

    def test_legacy_dataset_gets_manifest_and_aggregate_only_changes_get_proposal(self):
        Path("api/v1/stats.json").write_text('{"entities": 1}\n')
        self.git("update-index", "--cacheinfo", f"160000,{self.accepted},sources/data-uk")
        self.git("commit", "-qm", "match pinned source")
        manifest, _ = self.prepare()
        self.assertTrue(module.MANIFEST.exists())
        self.git("add", ".publication")
        self.git("commit", "-qm", "accept initial manifest")
        module.ASSETS["all.ttl"].write_text("changed aggregate without tracked dataset edits\n")
        module.prepare(self.root / "changed-artifact")
        updated = module.read_manifest(module.MANIFEST)
        self.assertEqual(updated["api_tree"], manifest["api_tree"])
        self.assertNotEqual(updated["assets"], manifest["assets"])

    def test_unsuccessful_prior_generation_cannot_be_reused_as_noop(self):
        self.accept_proposal()
        os.environ["GITHUB_RUN_ATTEMPT"] = "3"
        with patch.object(module, "verify_run", return_value=False):
            module.prepare(self.root / "retry-artifact")
        self.assertTrue((self.root / "retry-artifact/manifest.json").exists())
        self.assertEqual(module.read_manifest(module.MANIFEST)["artifact_name"], "harmonized-aggregates-123-3")

    def test_changed_assets_and_replaced_manifest_fail_closed(self):
        manifest, artifact = self.prepare()
        for name in module.ASSETS:
            target = artifact / name
            original = target.read_bytes()
            target.write_bytes(b"x" * len(original))
            with self.assertRaisesRegex(ValueError, "mismatch"):
                module.verify_artifact(manifest, artifact)
            target.write_bytes(original)
        target = artifact / "manifest.json"
        target.write_text(target.read_text() + " ")
        with self.assertRaisesRegex(ValueError, "differs"):
            module.verify_artifact(manifest, artifact)

    def test_extra_missing_or_symlink_assets_are_rejected(self):
        manifest, artifact = self.prepare()
        extra = artifact / "untrusted.py"
        extra.write_text("raise RuntimeError('must never execute')")
        with self.assertRaises(ValueError):
            module.verify_artifact(manifest, artifact)
        extra.unlink()
        target = artifact / "all.jsonld"
        original = target.read_bytes()
        target.unlink()
        with self.assertRaises(ValueError):
            module.verify_artifact(manifest, artifact)
        elsewhere = self.root / "elsewhere"
        elsewhere.write_bytes(original)
        target.symlink_to(elsewhere)
        with self.assertRaisesRegex(ValueError, "regular"):
            module.verify_artifact(manifest, artifact)

    def test_unknown_schema_fields_paths_and_boolean_sizes_are_refused(self):
        manifest, _ = self.prepare()
        for change in (lambda m: m.update(schema="unknown"),
                       lambda m: m.update(extra="unknown"),
                       lambda m: m["assets"].update({"../escape": m["assets"].pop("all.ttl")}),
                       lambda m: m["assets"]["all.ttl"].update(size=True)):
            broken = copy.deepcopy(manifest)
            change(broken)
            module.MANIFEST.write_text(json.dumps(broken))
            with self.assertRaises(ValueError):
                module.read_manifest(module.MANIFEST)

    def test_provenance_rejects_wrong_repo_workflow_event_attempt_branch_and_state(self):
        manifest, _ = self.prepare()
        for key, value in (("path", ".github/workflows/untrusted.yml"),
                           ("event", "pull_request"), ("head_branch", "proposal"),
                           ("run_attempt", 3), ("status", "in_progress"),
                           ("conclusion", "failure"), ("head_sha", "bad"),
                           ("repository", {"full_name": "attacker/data"}),
                           ("head_repository", {"full_name": "attacker/data"})):
            with self.subTest(key=key):
                metadata = self.run_metadata()
                metadata[key] = value
                with patch.object(module, "command", return_value=json.dumps(metadata)):
                    with self.assertRaises(ValueError):
                        module.verify_run(manifest, "ammitto/data", "main")

    def test_successful_provenance_checks_exact_attempt_and_ancestry(self):
        manifest, _ = self.prepare()
        with patch.object(module, "command", return_value=json.dumps(self.run_metadata())) as command:
            module.verify_run(manifest, "ammitto/data", "main")
        self.assertIn("attempts/2", command.call_args_list[0].args[-1])
        self.assertEqual(command.call_args_list[1].args,
                         ("git", "merge-base", "--is-ancestor", self.base, "HEAD"))

    def test_api_failure_propagates_before_download(self):
        manifest, _ = self.prepare()
        with patch.object(module, "command", side_effect=subprocess.CalledProcessError(1, ["gh"])):
            with self.assertRaises(subprocess.CalledProcessError):
                module.verify_run(manifest, "ammitto/data", "main")

    def accept_proposal(self):
        manifest, artifact = self.prepare()
        self.git("add", "api", "sources", ".publication")
        self.git("commit", "-qm", "merge accepted proposal")
        os.environ.update(GITHUB_EVENT_NAME="push", GITHUB_SHA=self.git("rev-parse", "HEAD"))
        return manifest, artifact

    def test_download_checks_trusted_metadata_and_complete_artifact(self):
        _, artifact = self.accept_proposal()
        original = module.command
        calls = []

        def command(*args, **kwargs):
            if args[0] != "gh":
                return original(*args, **kwargs)
            calls.append(args)
            if args[1] == "api":
                return json.dumps(self.run_metadata())
            self.assertEqual(args[1:3], ("run", "download"))
            target = Path(args[-1])
            for source in artifact.iterdir():
                (target / source.name).write_bytes(source.read_bytes())
            return ""

        with patch.object(module, "command", side_effect=command):
            module.download(self.root / "download")
        self.assertEqual(len(calls), 2)
        self.assertIn("attempts/2", calls[0][-1])
        self.assertIn("harmonized-aggregates-123-2", calls[1])

    def test_wrong_event_sha_or_dataset_tree_never_downloads(self):
        self.accept_proposal()
        valid_sha = os.environ["GITHUB_SHA"]
        for event, sha in (("schedule", valid_sha), ("push", self.base)):
            with patch.dict(os.environ, GITHUB_EVENT_NAME=event, GITHUB_SHA=sha):
                with patch.object(module, "verify_run") as verify:
                    with self.assertRaisesRegex(ValueError, "exact accepted"):
                        module.download(self.root / "download")
                    verify.assert_not_called()
        Path("api/v1/stats.json").write_text("another accepted tree")
        self.git("add", "api/v1/stats.json")
        self.git("commit", "-qm", "change data without corresponding manifest")
        os.environ["GITHUB_SHA"] = self.git("rev-parse", "HEAD")
        with patch.object(module, "verify_run") as verify:
            with self.assertRaisesRegex(ValueError, "dataset trees"):
                module.download(self.root / "download")
            verify.assert_not_called()

    def test_dirty_dataset_and_unrelated_generation_ancestry_are_refused(self):
        manifest, _ = self.accept_proposal()
        Path("api/v1/stats.json").write_text("dirty checkout")
        with patch.object(module, "verify_run") as verify:
            with self.assertRaisesRegex(ValueError, "modified"):
                module.download(self.root / "download")
            verify.assert_not_called()
        metadata = self.run_metadata()
        metadata["head_sha"] = "f" * 40
        original = module.command

        def command(*args, **kwargs):
            return json.dumps(metadata) if args[0] == "gh" else original(*args, **kwargs)

        with patch.object(module, "command", side_effect=command):
            with self.assertRaises(subprocess.CalledProcessError):
                module.verify_run(manifest, "ammitto/data", "main")

    def test_untrusted_context_and_staged_changes_are_refused(self):
        for event, ref in (("pull_request", "refs/heads/main"), ("schedule", "refs/heads/proposal")):
            with patch.dict(os.environ, GITHUB_EVENT_NAME=event, GITHUB_REF=ref):
                with self.assertRaises(ValueError):
                    module.prepare(self.root / "artifact")
        self.git("add", "api/v1/stats.json")
        with self.assertRaisesRegex(ValueError, "staged"):
            module.prepare(self.root / "artifact")

    def test_publisher_workflow_never_releases_an_unmerged_proposal(self):
        workflows = HERE.parent / "workflows"
        generation = (workflows / "harmonize.yml").read_text()
        accepted = (workflows / "publish-accepted.yml").read_text()
        self.assertIn("generated_data_pr.py", generation)
        self.assertNotIn("git push", generation)
        self.assertNotIn("run: >-\n          .github/scripts/publish_aggregates.sh", generation)
        self.assertIn(".publication/manifest.json", accepted)
        self.assertIn("ref: ${{ github.sha }}", accepted)
        self.assertLess(accepted.index("publication_manifest.py download"), accepted.index("publish_aggregates.sh"))
        self.assertLess(accepted.index("publish_aggregates.sh"), accepted.index("gh workflow run deploy.yml"))


if __name__ == "__main__":
    unittest.main()

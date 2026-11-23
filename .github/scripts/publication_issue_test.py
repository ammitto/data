#!/usr/bin/env python3
"""Offline gh fixtures: no repository API or issue mutation is possible."""

import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
SCRIPT = HERE / "publication_issue.py"
MARKER = "<!-- publication-outage:v1 -->"
SIGNATURE = "<!-- publication-outage-signature: "


class PublicationIssueTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="publication-issue-test-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        (self.root / "bin").mkdir()
        stub = self.root / "bin/gh"
        stub.write_text("""#!/usr/bin/env python3
import json, os, sys
from pathlib import Path
root = Path(os.environ['FIXTURE_ROOT'])
args = sys.argv[1:]
with (root / 'calls').open('a') as log:
    log.write(json.dumps(args) + '\\n')
if '--body-file' in args:
    (root / 'body').write_text(Path(args[args.index('--body-file') + 1]).read_text())
if os.environ.get('FAIL_COMMAND') == args[0]:
    sys.exit(9)
if args[0] == 'api':
    print((root / 'issues').read_text())
""")
        stub.chmod(0o755)
        self.env = {**os.environ, "FIXTURE_ROOT": str(self.root),
                    "PATH": str(self.root / "bin") + os.pathsep + os.environ["PATH"],
                    "GITHUB_REPOSITORY": "ammitto/data", "GITHUB_ACTIONS": "false",
                    "PUBLICATION_ALLOW_ISSUE_WRITE": "1"}
        self.issues([])

    def issues(self, issues, extra_pages=None):
        (self.root / "issues").write_text(json.dumps([issues] + (extra_pages or [])))

    def tracked(self, signature, number=123):
        return {"number": number, "body": MARKER + "\n" + SIGNATURE + signature + " -->\n"}

    def run_helper(self, harmonize="success", commit="success", release="success",
                   dispatch="success", extra=()):
        (self.root / "calls").write_text("")
        args = [sys.executable, str(SCRIPT), "https://github.com/ammitto/data/actions/runs/1"]
        for name, value in (("harmonize", harmonize), ("commit", commit),
                            ("release", release), ("dispatch", dispatch)):
            args += ["--" + name, value]
        result = subprocess.run(args + list(extra), env=self.env, text=True, capture_output=True)
        calls = [json.loads(line) for line in (self.root / "calls").read_text().splitlines()]
        return result, calls

    def writes(self, calls):
        return [call for call in calls if call[0] == "issue"]

    def test_each_publication_failure_opens_separate_issue(self):
        for stage in ("commit", "release", "dispatch"):
            with self.subTest(stage=stage):
                outcomes = dict(commit="success", release="success", dispatch="success")
                stages = list(outcomes)
                outcomes[stage] = "failure"
                for later in stages[stages.index(stage) + 1:]:
                    outcomes[later] = "skipped"
                result, calls = self.run_helper(**outcomes)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual([call[1] for call in self.writes(calls)], ["create"])
                self.assertIn(f"{stage}=failure", (self.root / "body").read_text())
                self.assertIn(MARKER, (self.root / "body").read_text())

    def test_healthy_and_no_change_commit_do_not_open_issue(self):
        for commit in ("success", "skipped"):
            result, calls = self.run_helper(commit=commit)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(self.writes(calls), [])

    def test_harmonize_failure_or_skip_cannot_close_existing_outage(self):
        self.issues([self.tracked("commit=failure;release=skipped;dispatch=skipped")])
        for harmonize in ("failure", "skipped", "cancelled"):
            result, calls = self.run_helper(harmonize=harmonize)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(calls, [])

    def test_unchanged_failure_is_quiet(self):
        self.issues([self.tracked("commit=failure;release=skipped;dispatch=skipped")])
        result, calls = self.run_helper(commit="failure", release="skipped", dispatch="skipped")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.writes(calls), [])

    def test_changed_failure_comments_and_updates_same_issue(self):
        self.issues([self.tracked("commit=failure;release=skipped;dispatch=skipped")])
        result, calls = self.run_helper(release="failure", dispatch="skipped")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual([call[1:3] for call in self.writes(calls)], [["comment", "123"], ["edit", "123"]])

    def test_complete_recovery_closes_only_marker_issue_on_later_page(self):
        self.issues([{"number": 1, "body": "human issue"}],
                    [[self.tracked("commit=success;release=failure;dispatch=skipped")]])
        result, calls = self.run_helper(commit="skipped")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual([call[1:3] for call in self.writes(calls)], [["comment", "123"], ["close", "123"]])

    def test_legacy_human_and_pull_request_markers_are_not_adopted(self):
        fake_pr = self.tracked("old", 99)
        fake_pr["pull_request"] = {}
        self.issues([{"number": 1, "body": "publication failed"},
                     {"number": 2, "body": "<!-- harmonization-outage:v1 -->\n"}, fake_pr])
        result, calls = self.run_helper(dispatch="failure")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual([call[1] for call in self.writes(calls)], ["create"])

    def test_duplicate_marker_issues_fail_closed(self):
        self.issues([self.tracked("old"), self.tracked("old", 124)])
        result, calls = self.run_helper()
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.writes(calls), [])

    def test_api_and_issue_write_errors_propagate(self):
        for command in ("api", "issue"):
            self.env["FAIL_COMMAND"] = command
            result, _ = self.run_helper(dispatch="failure")
            self.assertNotEqual(result.returncode, 0)

    def test_unknown_status_and_arguments_are_refused_before_api(self):
        for kwargs in ({"release": "unknown"}, {"dispatch": ""}, {"extra": ("--surprise", "yes")}):
            result, calls = self.run_helper(**kwargs)
            self.assertNotEqual(result.returncode, 0)
            self.assertEqual(calls, [])

    def test_malformed_api_shape_and_marker_are_refused(self):
        for fixture in ({}, [[{"number": 123, "body": MARKER + "\nmissing signature"}]]):
            (self.root / "issues").write_text(json.dumps(fixture))
            result, calls = self.run_helper()
            self.assertNotEqual(result.returncode, 0)
            self.assertEqual(self.writes(calls), [])

    def test_outside_actions_requires_explicit_override(self):
        self.env.pop("PUBLICATION_ALLOW_ISSUE_WRITE")
        result, calls = self.run_helper()
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(calls, [])

    def test_actions_only_allows_default_branch_even_with_override(self):
        self.env.update(GITHUB_ACTIONS="true", PUBLICATION_DEFAULT_BRANCH="main",
                        GITHUB_EVENT_NAME="workflow_dispatch", GITHUB_REF="refs/heads/fix")
        result, calls = self.run_helper()
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(calls, [])
        self.env.update(GITHUB_REF="refs/heads/main", GITHUB_EVENT_NAME="pull_request_target")
        result, calls = self.run_helper()
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(calls, [])
        self.env["GITHUB_EVENT_NAME"] = "schedule"
        result, _ = self.run_helper()
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_workflow_connects_all_outcomes_and_self_tests(self):
        workflow = ((HERE.parent / "workflows/harmonize.yml").read_text()
                    + (HERE.parent / "workflows/publish-accepted.yml").read_text())
        for step in ("harmonize", "commit_data", "publish_aggregates", "deploy_website"):
            self.assertIn("id: " + step, workflow)
            self.assertIn(f"steps.{step}.outcome", workflow)
        self.assertIn("github.event.repository.default_branch", workflow)
        self.assertIn("steps.publication_selftest.outcome == 'success'", workflow)
        for workflow_name in ("harmonize.yml", "self-tests.yml"):
            text = (HERE.parent / "workflows" / workflow_name).read_text()
            self.assertIn("python3 .github/scripts/publication_issue_test.py", text)

    def test_proposal_waits_for_merge_and_never_closes_existing_outage(self):
        self.issues([self.tracked("commit=failure;release=skipped;dispatch=skipped")])
        result, calls = self.run_helper(
            release="skipped", dispatch="skipped",
            extra=("--phase", "proposal", "--pending-pr", "https://github.com/ammitto/data/pull/3"))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual([call[1] for call in self.writes(calls)], ["comment", "edit"])
        self.assertIn("pending:https://github.com/ammitto/data/pull/3", (self.root / "body").read_text())
        self.assertIn("Awaiting merge", (self.root / "body").read_text())

    def test_no_change_generation_does_not_infer_publication_recovery(self):
        self.issues([self.tracked("commit=failure;release=skipped;dispatch=skipped")])
        result, calls = self.run_helper(
            release="skipped", dispatch="skipped", extra=("--phase", "proposal"))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(calls, [])

    def test_same_pending_proposal_is_quiet_and_wrong_repo_is_refused(self):
        url = "https://github.com/ammitto/data/pull/3"
        self.issues([self.tracked("pending:" + url)])
        result, calls = self.run_helper(
            release="skipped", dispatch="skipped", extra=("--phase", "proposal", "--pending-pr", url))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.writes(calls), [])
        result, calls = self.run_helper(extra=("--phase", "proposal", "--pending-pr",
                                               "https://github.com/attacker/data/pull/3"))
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(calls, [])


if __name__ == "__main__":
    unittest.main()

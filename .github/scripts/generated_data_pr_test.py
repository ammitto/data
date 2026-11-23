#!/usr/bin/env python3
"""Offline integration tests: protected bare remote and a local-only GitHub fake."""

import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest


HELPER = Path(__file__).with_name("generated_data_pr.py").resolve()
MARKER = "<!-- ammitto-generated-data:v1 -->"
BOT = "github-actions[bot]"
EMAIL = "41898282+github-actions[bot]@users.noreply.github.com"

FAKE_GH = r'''#!/usr/bin/env python3
import json, os, subprocess, sys
from pathlib import Path
from urllib.parse import urlsplit, parse_qs

args = sys.argv[1:]
assert args[0] == 'api', 'only API fixtures supported'
endpoint = args[1]
with open(os.environ['FAKE_LOG'], 'a') as f: f.write(json.dumps(args) + '\n')
if os.environ.get('FAKE_GH_FAIL') and os.environ['FAKE_GH_FAIL'] in endpoint:
    sys.exit(9)
statepath = Path(os.environ['FAKE_STATE'])
state = json.loads(statepath.read_text())
remote = os.environ['FAKE_REMOTE']
def git(*argv):
    return subprocess.check_output(['git', '--git-dir', remote, *argv]).decode().strip()
def head(branch): return git('rev-parse', 'refs/heads/' + branch)
def materialize(pr):
    result = dict(pr)
    result['head'] = dict(result['head'])
    result['base'] = dict(result['base'])
    if pr.get('state') == 'open':
        result['head']['sha'] = head(result['head']['ref'])
        result['base']['sha'] = head('main')
    files = git('diff', '--name-only', '--no-renames', result['base']['sha'] + '...' + result['head']['sha']).splitlines()
    if pr.get('extra_file'): files.append(pr['extra_file'])
    result['changed_files'] = len(files)
    return result, files
url = urlsplit(endpoint)
parts = url.path.split('/')
if len(parts) == 4 and parts[3] == 'pulls':
    if '--method' in args:
        if os.environ.get('FAKE_GH_FAIL_CREATE'): sys.exit(8)
        assert args[args.index('--method') + 1] == 'POST'
        fields = dict(args[i + 1].split('=', 1) for i, a in enumerate(args) if a == '-f')
        number = len(state['prs']) + 1
        pr = {'number':number, 'state':'open', 'body':fields['body'],
              'base':{'ref':fields['base'], 'repo':{'full_name':'fixture/test'}, 'sha':head('main')},
              'head':{'ref':fields['head'], 'repo':{'full_name':'fixture/test'}, 'sha':head(fields['head'])},
              'merged_at':None}
        state['prs'].append(pr); statepath.write_text(json.dumps(state))
        print(json.dumps(materialize(pr)[0])); sys.exit(0)
    q = parse_qs(url.query)
    selected = [pr for pr in state['prs'] if pr['state'] == q['state'][0]
                and ('head' not in q or pr['head']['ref'] == q['head'][0].split(':')[1])]
    result = [materialize(pr)[0] for pr in selected]
    print(json.dumps([result] if '--slurp' in args else result)); sys.exit(0)
if len(parts) >= 5 and parts[3] == 'pulls':
    pr = next(pr for pr in state['prs'] if pr['number'] == int(parts[4]))
    result, files = materialize(pr)
    if len(parts) == 6 and parts[5] == 'files':
        result = [{'filename':p} for p in files]
        if '--slurp' in args: result = [result]
    elif len(parts) != 5: raise AssertionError('unapproved API')
    print(json.dumps(result)); sys.exit(0)
raise AssertionError('unapproved API: ' + endpoint)
'''


class ProposalTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="proposal-test-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.remote = self.root / "remote.git"
        self.repo = self.root / "checkout"
        self.env = os.environ.copy()
        self.env.update(GIT_CONFIG_NOSYSTEM="1", GIT_CONFIG_GLOBAL="/dev/null",
                        GIT_AUTHOR_NAME="fixture", GIT_AUTHOR_EMAIL="fixture@example.test",
                        GIT_COMMITTER_NAME="fixture", GIT_COMMITTER_EMAIL="fixture@example.test")
        self.command("git", "init", "--bare", str(self.remote), cwd=self.root)
        self.command("git", "init", "-b", "main", str(self.repo), cwd=self.root)
        (self.repo / "processed").mkdir()
        (self.repo / "processed/data.yaml").write_text("version: old\n")
        (self.repo / "README.md").write_text("accepted readme\n")
        self.git("add", "processed", "README.md")
        self.git("commit", "-m", "initial accepted data")
        self.git("remote", "add", "origin", str(self.remote))
        self.git("push", "origin", "main")
        self.main_head = self.git("rev-parse", "HEAD").stdout.strip()
        hook = self.remote / "hooks/pre-receive"
        hook.write_text("#!/bin/sh\nwhile read old new ref; do\n"
                        "  if [ \"$ref\" = refs/heads/main ]; then exit 1; fi\ndone\n")
        hook.chmod(0o755)
        fake = self.root / "bin"
        fake.mkdir()
        (fake / "gh").write_text(FAKE_GH)
        (fake / "gh").chmod(0o755)
        self.state = self.root / "state.json"
        self.state.write_text('{"prs": []}')
        self.env.update(PATH=str(fake) + os.pathsep + self.env["PATH"],
                        GITHUB_REPOSITORY="fixture/test", PUBLICATION_DEFAULT_BRANCH="main",
                        GITHUB_RUN_ID="12345", GH_TOKEN="fixture-token",
                        AMMITTO_PUBLICATION_LOCAL_TEST="1", GITHUB_ACTIONS="false",
                        FAKE_STATE=str(self.state), FAKE_REMOTE=str(self.remote),
                        FAKE_LOG=str(self.root / "gh.log"),
                        GITHUB_OUTPUT=str(self.root / "output"),
                        GITHUB_STEP_SUMMARY=str(self.root / "summary"))

    def command(self, *args, cwd=None, check=True, env=None):
        p = subprocess.run(args, cwd=cwd or self.repo, env=env or self.env,
                           text=True, capture_output=True)
        if check and p.returncode:
            self.fail(f"{args[0]} failed: {p.stderr}")
        return p

    def git(self, *args, **kwargs):
        return self.command("git", *args, **kwargs)

    def proposal(self, *, check=True, extra=(), env=None):
        return self.command("python3", str(HELPER), "--branch", "automation/data-refresh",
                            "--title", "chore: update fixture sanctions data",
                            "--path", "processed", *extra, check=check, env=env)

    def change(self, text="version: new\n"):
        (self.repo / "processed/data.yaml").write_text(text)

    def remote_value(self, revision):
        return self.git("--git-dir", str(self.remote), "rev-parse", revision).stdout.strip()

    def state_data(self):
        return json.loads(self.state.read_text())

    def mutate_pr(self, **fields):
        state = self.state_data()
        state["prs"][0].update(fields)
        self.state.write_text(json.dumps(state))

    def accept_local_commit(self, path, content):
        (self.repo / path).write_text(content)
        self.git("add", "--", path)
        self.git("commit", "-m", "accepted main change")
        # Fixture simulates a separately accepted protected-branch commit.
        # Transfer its objects without bypassing the fixture's protected-main
        # receive hook. Only the bare-remote owner then moves accepted main.
        self.git("push", "origin", "HEAD:refs/heads/fixture/accepted-main")
        self.git("--git-dir", str(self.remote), "update-ref", "refs/heads/main",
                 self.git("rev-parse", "HEAD").stdout.strip())

    def test_protects_main_and_preserves_callers_index(self):
        self.change()
        before = self.git("status", "--porcelain").stdout
        self.proposal()
        self.assertEqual(self.remote_value("main"), self.main_head)
        self.assertEqual(self.git("status", "--porcelain").stdout, before)
        self.assertEqual(self.git("diff", "--cached").stdout, "")
        head = self.remote_value("automation/data-refresh")
        self.assertEqual(self.git("show", "-s", "--format=%an%n%ae", head).stdout.strip(), BOT + "\n" + EMAIL)
        self.assertEqual(self.git("show", head + ":processed/data.yaml").stdout, "version: new\n")
        self.assertIn("changed=true", (self.root / "output").read_text())
        self.assertIn("awaiting merge", (self.root / "summary").read_text())
        self.assertEqual(len(self.state_data()["prs"]), 1)
        rejected = self.git("push", "origin", head + ":refs/heads/main", check=False)
        self.assertNotEqual(rejected.returncode, 0)

    def test_no_changes_do_not_push_or_create_pr(self):
        self.proposal()
        self.assertEqual(self.state_data()["prs"], [])
        self.assertIn("changed=false", (self.root / "output").read_text())
        self.assertEqual(self.git("ls-remote", "--heads", "origin").stdout.count("\n"), 1)

    def test_updates_owned_proposal_by_fast_forward(self):
        self.change(); self.proposal()
        first = self.remote_value("automation/data-refresh")
        self.change("version: newer\n"); self.proposal()
        second = self.remote_value("automation/data-refresh")
        self.assertNotEqual(first, second)
        self.git("merge-base", "--is-ancestor", first, second)
        self.assertEqual(len(self.state_data()["prs"]), 1)

    def test_no_change_preserves_pending_pr_link(self):
        self.change(); self.proposal()
        head = self.remote_value("automation/data-refresh")
        self.proposal()
        self.assertEqual(self.remote_value("automation/data-refresh"), head)
        self.assertIn("changed=false\nproposal_head=" + head + "\npr_url=https://github.com/fixture/test/pull/1", (self.root / "output").read_text())

    def test_withdrawn_snapshot_removes_stale_pending_changes(self):
        self.change(); self.proposal()
        previous = self.remote_value("automation/data-refresh")
        self.change("version: old\n"); self.proposal()
        head = self.remote_value("automation/data-refresh")
        self.assertNotEqual(previous, head)
        self.git("merge-base", "--is-ancestor", previous, head)
        self.assertEqual(self.git("show", head + ":processed/data.yaml").stdout, "version: old\n")
        self.assertEqual(self.remote_value("main"), self.main_head)
        self.assertEqual(len(self.state_data()["prs"]), 1)
        self.assertEqual(self.state_data()["prs"][0]["state"], "open")
        self.assertIn("changed=true\nproposal_head=" + head, (self.root / "output").read_text())

    def test_updates_preserve_accepted_non_generated_changes(self):
        self.change(); self.proposal()
        first = self.remote_value("automation/data-refresh")
        self.accept_local_commit("README.md", "new accepted documentation\n")
        self.change("version: newest\n"); self.proposal()
        head = self.remote_value("automation/data-refresh")
        self.assertEqual(self.git("show", head + ":README.md").stdout, "new accepted documentation\n")
        self.git("merge-base", "--is-ancestor", first, head)
        self.git("merge-base", "--is-ancestor", "HEAD", head)

    def test_overlapping_accepted_edits_fail_without_overwrite(self):
        self.change(); self.proposal()
        before = self.remote_value("automation/data-refresh")
        self.accept_local_commit("processed/data.yaml", "version: human\n")
        self.change("version: newer\n")
        self.assertNotEqual(self.proposal(check=False).returncode, 0)
        self.assertEqual(self.remote_value("automation/data-refresh"), before)
        self.assertEqual((self.repo / "processed/data.yaml").read_text(), "version: newer\n")

    def test_staged_changes_rejected(self):
        self.change(); self.git("add", "processed/data.yaml")
        self.assertNotEqual(self.proposal(check=False).returncode, 0)
        self.assertNotEqual(self.git("diff", "--cached").stdout, "")

    def test_out_of_scope_untracked_and_modified_rejected(self):
        self.change(); (self.repo / "notes.txt").write_text("human notes\n")
        self.assertNotEqual(self.proposal(check=False).returncode, 0)
        (self.repo / "notes.txt").unlink()
        (self.repo / "README.md").write_text("uncommitted human work\n")
        self.assertNotEqual(self.proposal(check=False).returncode, 0)

    def test_untrusted_event_rejected(self):
        env = self.env.copy()
        env.update(GITHUB_ACTIONS="true", GITHUB_REF="refs/pull/1/merge", GITHUB_EVENT_NAME="pull_request")
        self.change()
        self.assertNotEqual(self.proposal(check=False, env=env).returncode, 0)
        self.assertFalse((self.root / "gh.log").exists())

    def test_missing_token_rejected(self):
        env = self.env.copy(); env.pop("GH_TOKEN")
        self.change()
        self.assertNotEqual(self.proposal(check=False, env=env).returncode, 0)

    def test_unapproved_paths_and_default_branch_rejected(self):
        self.change()
        self.assertNotEqual(self.proposal(check=False, extra=("--path", ".github")).returncode, 0)
        self.assertNotEqual(self.proposal(check=False, extra=("--branch", "main")).returncode, 0)

    def test_existing_human_branch_is_not_adopted(self):
        self.git("push", "origin", "HEAD:refs/heads/automation/data-refresh")
        self.change()
        self.assertNotEqual(self.proposal(check=False).returncode, 0)
        self.assertEqual(self.remote_value("automation/data-refresh"), self.main_head)

    def test_pr_ownership_marker_is_required(self):
        self.change(); self.proposal(); self.mutate_pr(body="human proposal")
        self.change("version: newest\n")
        self.assertNotEqual(self.proposal(check=False).returncode, 0)

    def test_pr_repository_identity_is_required(self):
        self.change(); self.proposal()
        state = self.state_data(); state["prs"][0]["head"]["repo"]["full_name"] = "human/fork"
        self.state.write_text(json.dumps(state))
        self.assertNotEqual(self.proposal(check=False).returncode, 0)

    def test_human_commit_on_owned_branch_is_rejected(self):
        self.change(); self.proposal()
        self.git("fetch", "origin", "automation/data-refresh")
        tree = self.git("rev-parse", "FETCH_HEAD^{tree}").stdout.strip()
        sha = self.git("commit-tree", tree, "-p", "FETCH_HEAD", "-m", "human edit").stdout.strip()
        self.git("push", "origin", sha + ":refs/heads/automation/data-refresh")
        self.change("version: newest\n")
        self.assertNotEqual(self.proposal(check=False).returncode, 0)

    def test_out_of_scope_pr_file_listing_is_rejected(self):
        self.change(); self.proposal(); self.mutate_pr(extra_file="README.md")
        self.change("version: newest\n")
        self.assertNotEqual(self.proposal(check=False).returncode, 0)

    def test_merged_owned_branch_can_be_reused_without_force(self):
        self.change(); self.proposal()
        head = self.remote_value("automation/data-refresh")
        self.mutate_pr(state="closed", merged_at="2026-11-23T00:00:00Z")
        self.git("--git-dir", str(self.remote), "update-ref", "refs/heads/main", head)
        self.git("fetch", "origin", "main")
        # Everything here is a disposable fixture, not the caller's checkout.
        self.git("reset", "--hard", "FETCH_HEAD")
        self.change("version: newest\n"); self.proposal()
        self.git("merge-base", "--is-ancestor", head, self.remote_value("automation/data-refresh"))
        self.assertEqual(self.state_data()["prs"][1]["head"]["ref"], "automation/data-refresh")

    def test_closed_unmerged_proposal_uses_one_owned_suffix(self):
        self.change(); self.proposal(); self.mutate_pr(state="closed")
        self.change("version: newer\n"); self.proposal()
        self.assertEqual(len(self.state_data()["prs"]), 2)
        self.assertEqual(self.state_data()["prs"][1]["head"]["ref"], "automation/data-refresh-12345")
        env = self.env.copy(); env["GITHUB_RUN_ID"] = "12346"
        self.change("version: latest\n"); self.proposal(env=env)
        self.assertEqual(len(self.state_data()["prs"]), 2)

    def test_api_failure_propagates_without_main_update(self):
        env = self.env.copy(); env["FAKE_GH_FAIL"] = "/pulls"
        self.change()
        self.assertNotEqual(self.proposal(check=False, env=env).returncode, 0)
        self.assertEqual(self.remote_value("main"), self.main_head)

    def test_pr_creation_failure_leaves_main_untouched(self):
        env = self.env.copy(); env["FAKE_GH_FAIL_CREATE"] = "1"
        self.change()
        self.assertNotEqual(self.proposal(check=False, env=env).returncode, 0)
        self.assertEqual(self.remote_value("main"), self.main_head)
        self.assertEqual(self.state_data()["prs"], [])
        # An orphan is not silently adopted on the next run.
        self.assertNotEqual(self.proposal(check=False).returncode, 0)

    def test_deletions_and_new_files_are_scoped(self):
        (self.repo / "processed/data.yaml").unlink()
        (self.repo / "processed/new.yaml").write_text("new record\n")
        self.proposal()
        head = self.remote_value("automation/data-refresh")
        self.assertNotEqual(self.git("cat-file", "-e", head + ":processed/data.yaml", check=False).returncode, 0)
        self.assertEqual(self.git("show", head + ":processed/new.yaml").stdout, "new record\n")


if __name__ == "__main__":
    unittest.main(verbosity=2)

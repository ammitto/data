#!/usr/bin/env python3
"""Track publication independently of the harmonizer's source-quality report."""

import argparse
import json
import os
import re
import subprocess
import sys
import tempfile
from pathlib import Path

MARKER = "<!-- publication-outage:v1 -->"
SIGNATURE = "<!-- publication-outage-signature: "
STAGES = ("harmonize", "commit", "release", "dispatch")
OUTCOMES = ("success", "failure", "skipped", "cancelled")


def gh(*args):
    return subprocess.run(
        ["gh", *args], check=True, text=True, capture_output=True
    ).stdout


def reconcile(repo, outcomes, run_url, phase="publication", pending_pr=""):
    if outcomes["harmonize"] != "success":
        print("harmonization did not succeed; publication recovery is unknown")
        return
    healthy = (
        outcomes["commit"] in ("success", "skipped")
        and outcomes["release"] == "success"
        and outcomes["dispatch"] == "success"
    )
    if phase == "proposal" and outcomes["commit"] == "success":
        if not pending_pr:
            print("no dataset changes or pending proposal; publication recovery is not inferred")
            return
        if not re.fullmatch(re.escape(f"https://github.com/{repo}/pull/") + r"[1-9][0-9]*", pending_pr):
            raise ValueError("pending proposal URL belongs to another repository")
        healthy = False
        signature = "pending:" + pending_pr
        summary = os.environ.get("GITHUB_STEP_SUMMARY")
        if summary:
            with open(summary, "a") as stream:
                stream.write(f"Publication awaits merge: {pending_pr}\n")
    else:
        signature = "healthy" if healthy else ";".join(
            f"{stage}={outcomes[stage]}" for stage in STAGES[1:]
        )
    pages = json.loads(gh(
        "api", "--paginate", "--slurp",
        f"repos/{repo}/issues?state=open&labels=automation&per_page=100",
    ))
    if not isinstance(pages, list) or any(not isinstance(p, list) for p in pages):
        raise ValueError("expected paginated issue arrays")
    issues = [issue for page in pages for issue in page]
    tracked = [issue for issue in issues if "pull_request" not in issue
               and (issue.get("body") or "").startswith(MARKER + "\n")]
    if len(tracked) > 1:
        raise ValueError("multiple publication tracking issues; refusing to choose")
    issue = tracked[0] if tracked else None
    if issue:
        old = [line for line in issue["body"].splitlines()
               if line.startswith(SIGNATURE) and line.endswith(" -->")]
        if len(old) != 1:
            raise ValueError("invalid publication tracking signature")
        if old[0] == SIGNATURE + signature + " -->":
            print("publication state unchanged; staying quiet")
            return
    elif healthy:
        print("publication healthy; no open tracking issue")
        return

    if healthy:
        gh("issue", "comment", str(issue["number"]), "--repo", repo,
           "--body", f"Recovered: data publication and website deployment dispatch succeeded in {run_url}.")
        gh("issue", "close", str(issue["number"]), "--repo", repo)
        print("publication recovered; closed tracking issue")
        return

    body = (
        f"{MARKER}\n{SIGNATURE}{signature} -->\n\n"
        "Generated data has not completed publication. This issue "
        "tracks publication separately from source-quality failures and closes "
        "after a complete publication and deployment dispatch.\n\n"
        f"Latest observed run: {run_url}\n\n"
        + (f"Awaiting merge: {pending_pr}\n\n" if signature.startswith("pending:") else "")
        + "| Stage | Outcome |\n| --- | --- |\n"
        + "".join(f"| {stage} | {outcomes[stage]} |\n" for stage in STAGES[1:])
    )
    # Body files avoid quoting/length surprises in CLI arguments.
    with tempfile.TemporaryDirectory(prefix="publication-issue-") as directory:
        body_file = Path(directory) / "body.md"
        body_file.write_text(body)
        if issue:
            gh("issue", "comment", str(issue["number"]), "--repo", repo,
               "--body-file", str(body_file))
            gh("issue", "edit", str(issue["number"]), "--repo", repo,
               "--body-file", str(body_file))
        else:
            gh("issue", "create", "--repo", repo, "--title",
               "Data publication awaits merge" if signature.startswith("pending:") else "Data publication is failing", "--label", "automation",
               "--body-file", str(body_file))
    print("recorded publication outage")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("run_url")
    parser.add_argument("--phase", choices=("publication", "proposal"), default="publication")
    parser.add_argument("--pending-pr", default="")
    for stage in STAGES:
        parser.add_argument("--" + stage, required=True, choices=OUTCOMES)
    args = parser.parse_args()
    repo = os.environ.get("GITHUB_REPOSITORY", "")
    if not repo or len(repo.split("/")) != 2:
        raise ValueError("GITHUB_REPOSITORY must name owner/repo")
    if os.environ.get("GITHUB_ACTIONS") == "true":
        default = os.environ.get("PUBLICATION_DEFAULT_BRANCH", "")
        if (not default or os.environ.get("GITHUB_REF") != "refs/heads/" + default
                or os.environ.get("GITHUB_EVENT_NAME", "").startswith("pull_request")):
            raise ValueError("publication issue writes require the default branch")
    elif os.environ.get("PUBLICATION_ALLOW_ISSUE_WRITE") != "1":
        raise ValueError("refusing issue writes outside GitHub Actions")
    reconcile(repo, {stage: getattr(args, stage) for stage in STAGES}, args.run_url,
              args.phase, args.pending_pr)


if __name__ == "__main__":
    try:
        main()
    except (ValueError, KeyError, TypeError, subprocess.CalledProcessError) as error:
        print(f"publication issue reconciliation failed: {error}", file=sys.stderr)
        sys.exit(1)

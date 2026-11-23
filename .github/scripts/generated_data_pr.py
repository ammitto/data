#!/usr/bin/env python3
"""Propose generated data without writing the protected default branch."""

import argparse
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile


MARKER = "<!-- ammitto-generated-data:v1 -->"
TRAILER = "Ammitto-Generated-Data: v1"
BOT = "github-actions[bot]"
EMAIL = "41898282+github-actions[bot]@users.noreply.github.com"
ALLOWED = {"processed", "api", "sources", ".publication"}


class PublicationError(Exception):
    pass


def run(args, *, env=None, data=None, allowed=(0,)):
    result = subprocess.run(args, input=data, stdout=subprocess.PIPE,
                            stderr=subprocess.PIPE, env=env)
    if result.returncode not in allowed:
        # Do not echo commands, URLs, or stderr that might contain credentials.
        operation = args[1] if args[0] == "git" else "api"
        raise PublicationError(f"{args[0]} {operation} operation failed (exit {result.returncode})")
    return result


def git(*args, env=None, data=None, allowed=(0,)):
    return run(["git", *args], env=env, data=data, allowed=allowed)


def value(*args):
    return git(*args).stdout.decode().strip()


def gh(endpoint, *, fields=None, pages=False):
    args = ["gh", "api", endpoint]
    if pages:
        args += ["--paginate", "--slurp"]
    if fields is not None:
        args += ["--method", "POST"]
        for key, val in fields.items():
            args += ["-f", f"{key}={val}"]
    try:
        return json.loads(run(args).stdout)
    except (ValueError, UnicodeError) as error:
        raise PublicationError("GitHub returned invalid JSON") from error


def scoped(path, paths):
    return any(path == prefix or path.startswith(prefix + "/") for prefix in paths)


def paths_from(data):
    return [p.decode() for p in data.split(b"\0") if p]


def ancestor(older, newer):
    return git("merge-base", "--is-ancestor", older, newer,
               allowed=(0, 1)).returncode == 0


def remote_head(branch):
    lines = value("ls-remote", "--heads", "origin", "refs/heads/" + branch)
    if not lines:
        return None
    rows = lines.splitlines()
    if len(rows) != 1 or rows[0].split()[1] != "refs/heads/" + branch:
        raise PublicationError("Ambiguous remote branch")
    sha = rows[0].split()[0]
    if not re.fullmatch(r"[0-9a-f]{40}", sha):
        raise PublicationError("Invalid remote head")
    git("fetch", "--no-tags", "origin", "refs/heads/" + branch)
    if value("rev-parse", "FETCH_HEAD") != sha:
        raise PublicationError("Remote branch changed while being read; retry")
    return sha


def validate_pr(pr, repo, branch, default, paths, tip):
    if (pr.get("base", {}).get("ref") != default
            or pr.get("base", {}).get("repo", {}).get("full_name") != repo
            or pr.get("head", {}).get("ref") != branch
            or pr.get("head", {}).get("repo", {}).get("full_name") != repo
            or pr.get("head", {}).get("sha") != tip
            or (pr.get("body") or "").splitlines().count(MARKER) != 1):
        raise PublicationError("Proposal identity or ownership does not match")
    number = pr.get("number")
    if not isinstance(number, int) or isinstance(number, bool) or number < 1:
        raise PublicationError("Invalid proposal number")
    detail = gh(f"repos/{repo}/pulls/{number}")
    # Re-check the load-bearing identity, not incidental mutable repository
    # counters nested in the list/detail API representations.
    if (detail.get("number") != number
            or detail.get("body") != pr.get("body")
            or any(detail.get(side, {}).get("ref") != pr[side]["ref"]
                   or detail.get(side, {}).get("sha") != pr[side].get("sha")
                   or detail.get(side, {}).get("repo", {}).get("full_name") != repo
                   for side in ("base", "head"))):
        raise PublicationError("Proposal changed while being read; retry")
    pages = gh(f"repos/{repo}/pulls/{number}/files", pages=True)
    if not isinstance(pages, list) or any(not isinstance(page, list) for page in pages):
        raise PublicationError("Invalid proposal file listing")
    files = [item for page in pages for item in page]
    if detail.get("changed_files") != len(files) or len(files) >= 3000:
        raise PublicationError("Incomplete proposal file listing")
    for item in files:
        if not isinstance(item, dict) or not scoped(item.get("filename", ""), paths):
            raise PublicationError("Proposal contains changes outside generated paths")
        if item.get("previous_filename") and not scoped(item["previous_filename"], paths):
            raise PublicationError("Proposal renames a file outside generated paths")
    return f"https://github.com/{repo}/pull/{number}"


def owned_commits(default_head, tip, paths):
    changed = paths_from(git("diff", "--name-only", "--no-renames", "-z",
                            default_head + "..." + tip).stdout)
    if any(not scoped(path, paths) for path in changed):
        raise PublicationError("Proposal branch changes non-generated paths")
    commits = value("rev-list", default_head + ".." + tip).splitlines()
    for sha in commits:
        fields = value("show", "-s", "--format=%an%n%ae%n%cn%n%ce%n%B", sha).splitlines()
        if fields[:4] != [BOT, EMAIL, BOT, EMAIL] or TRAILER not in fields[4:]:
            raise PublicationError("Proposal contains an unexpected commit; refusing to overwrite")


def commit(tree, parents, title, env):
    args = ["commit-tree", tree]
    for parent in parents:
        args += ["-p", parent]
    return git(*args, "-m", title + "\n\n" + TRAILER, env=env).stdout.decode().strip()


def output(changed, head="", url=""):
    values = f"changed={'true' if changed else 'false'}\nproposal_head={head}\npr_url={url}\n"
    if os.environ.get("GITHUB_OUTPUT"):
        with open(os.environ["GITHUB_OUTPUT"], "a", encoding="utf-8") as stream:
            stream.write(values)
    if url:
        message = f"Generated data proposal awaiting merge: {url}"
        if os.environ.get("GITHUB_STEP_SUMMARY"):
            with open(os.environ["GITHUB_STEP_SUMMARY"], "a", encoding="utf-8") as stream:
                stream.write("\n" + message + "\nPublication remains pending until this proposal is merged.\n")
        print(message)
    else:
        print("No generated data changes to propose.")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--branch", required=True)
    parser.add_argument("--title", required=True)
    parser.add_argument("--path", action="append", required=True, dest="paths")
    args = parser.parse_args()
    paths = sorted(set(args.paths))
    if not paths or not set(paths) <= ALLOWED or ("processed" in paths and len(paths) != 1):
        raise PublicationError("Unapproved generated path scope")
    default = os.environ.get("PUBLICATION_DEFAULT_BRANCH", "")
    repo = os.environ.get("GITHUB_REPOSITORY", "")
    if not re.fullmatch(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+", repo):
        raise PublicationError("Missing or invalid repository identity")
    if not default or args.branch == default or not args.branch.startswith("automation/"):
        raise PublicationError("Proposal must use a distinct automation branch")
    git("check-ref-format", "--branch", default)
    git("check-ref-format", "--branch", args.branch)
    if not args.title.strip() or "\n" in args.title or "\r" in args.title:
        raise PublicationError("Invalid proposal title")
    origin = value("remote", "get-url", "origin")
    local_test = (os.environ.get("AMMITTO_PUBLICATION_LOCAL_TEST") == "1"
                  and os.environ.get("GITHUB_ACTIONS") != "true"
                  and Path(origin).is_absolute() and Path(origin).is_dir())
    if not local_test:
        trusted = (os.environ.get("GITHUB_ACTIONS") == "true"
                   and os.environ.get("GITHUB_REF") == "refs/heads/" + default
                   and os.environ.get("GITHUB_EVENT_NAME") in {"schedule", "workflow_dispatch", "push"})
        if not trusted:
            raise PublicationError("Publication requires a trusted default-branch event")
        if origin.removesuffix(".git") not in {
                "https://github.com/" + repo, "git@github.com:" + repo,
                "ssh://git@github.com/" + repo}:
            raise PublicationError("Origin does not match the workflow repository")
    if not os.environ.get("GH_TOKEN"):
        raise PublicationError("Publication token is unavailable")
    if git("diff", "--cached", "--quiet", allowed=(0, 1)).returncode:
        raise PublicationError("Index already contains staged changes")
    dirty = paths_from(git("diff", "--name-only", "--no-renames", "-z").stdout)
    dirty += paths_from(git("ls-files", "--others", "--exclude-standard", "-z").stdout)
    if any(not scoped(path, paths) for path in dirty):
        raise PublicationError("Working tree contains changes outside generated paths")
    default_head = remote_head(default)
    if default_head is None or value("rev-parse", "HEAD") != default_head:
        raise PublicationError("Generation checkout is not the current accepted default head; retry")
    env = os.environ.copy()
    env.update(GIT_AUTHOR_NAME=BOT, GIT_AUTHOR_EMAIL=EMAIL,
               GIT_COMMITTER_NAME=BOT, GIT_COMMITTER_EMAIL=EMAIL)
    branch = args.branch
    owner = repo.split("/")[0]
    pages = gh(f"repos/{repo}/pulls?state=open&base={default}&per_page=100", pages=True)
    if not isinstance(pages, list) or any(not isinstance(page, list) for page in pages):
        raise PublicationError("Invalid live proposal listing")
    family = re.compile(re.escape(branch) + r"(?:-[0-9]+)?")
    prs = [pr for page in pages for pr in page
           if isinstance(pr, dict) and family.fullmatch(pr.get("head", {}).get("ref", ""))]
    if len(prs) > 1:
        raise PublicationError("Ambiguous live proposal")
    if prs:
        branch = prs[0]["head"]["ref"]
    tip = remote_head(branch)
    url = ""
    if prs:
        if tip is None:
            raise PublicationError("Proposal branch is missing")
        url = validate_pr(prs[0], repo, branch, default, paths, tip)
        owned_commits(default_head, tip, paths)
    elif tip:
        history = gh(f"repos/{repo}/pulls?state=closed&head={owner}:{branch}&base={default}&per_page=100")
        if not isinstance(history, list) or not history:
            raise PublicationError("Existing branch has no owned proposal; refusing collision")
        previous = next((pr for pr in history if pr.get("head", {}).get("sha") == tip), None)
        if previous is None:
            raise PublicationError("Existing branch has unexpected changes")
        validate_pr(previous, repo, branch, default, paths, tip)
        if not (previous.get("merged_at") and ancestor(tip, default_head)):
            run_id = os.environ.get("GITHUB_RUN_ID", "")
            if not re.fullmatch(r"[0-9]+", run_id):
                raise PublicationError("A numeric run identity is required for a fresh proposal branch")
            branch += "-" + run_id
            if remote_head(branch):
                raise PublicationError("Fresh proposal branch already exists")
        tip = None
    with tempfile.TemporaryDirectory(prefix="ammitto-proposal-") as temp:
        index_env = env.copy()
        index_env["GIT_INDEX_FILE"] = str(Path(temp) / "index")
        git("read-tree", default_head, env=index_env)
        present = [path for path in paths if Path(path).exists()
                   or git("ls-tree", default_head, "--", path).stdout]
        if present:
            git("add", "-A", "--", *present, env=index_env)
        generated = git("write-tree", env=index_env).stdout.decode().strip()
        if not tip and git("diff", "--quiet", default_head, generated, "--", *paths,
                           allowed=(0, 1)).returncode == 0:
            output(False)
            return
        parent = default_head
        if tip:
            parent = tip
            if not ancestor(default_head, tip):
                if ancestor(tip, default_head):
                    parent = default_head
                else:
                    # Three-tree index merge works on the supported Git 2.34
                    # baseline. Overlapping changes remain unmerged and make
                    # write-tree fail rather than discarding either side.
                    merge_base = value("merge-base", tip, default_head)
                    # read-tree's merge requires a clean index matching the
                    # proposal. The generated snapshot was captured above in
                    # this same private index, so reset it before merging.
                    git("read-tree", tip, env=index_env)
                    git("read-tree", "-i", "-m", merge_base, tip, default_head, env=index_env)
                    merged = git("write-tree", env=index_env).stdout.decode().strip()
                    parent = commit(merged, [tip, default_head], "Merge accepted default-branch changes", env)
        git("read-tree", parent, env=index_env)
        # This removes entries only from our temporary index. A proposed
        # version can differ from both HEAD and the caller's regenerated file,
        # so the cached removal must explicitly permit that difference.
        git("rm", "--cached", "-r", "--force", "--ignore-unmatch", "--", *paths, env=index_env)
        entries = git("ls-tree", "-r", "-z", "--full-tree", generated, "--", *paths).stdout
        git("update-index", "-z", "--index-info", env=index_env, data=entries)
        tree = git("write-tree", env=index_env).stdout.decode().strip()
        head = parent if tree == value("rev-parse", parent + "^{tree}") else commit(tree, [parent], args.title, env)
        changed = tip != head
        if changed:
            git("push", "origin", head + ":refs/heads/" + branch)
        if not url:
            result = gh(f"repos/{repo}/pulls", fields={
                "title": args.title, "head": branch, "base": default,
                "body": MARKER + "\n\nGenerated data only. Publication is pending until this pull request is merged.\n"})
            if (not isinstance(result, dict) or type(result.get("number")) is not int
                    or result["number"] < 1):
                raise PublicationError("GitHub did not return a proposal identity")
            url = f"https://github.com/{repo}/pull/{result['number']}"
        output(changed, head, url)


if __name__ == "__main__":
    try:
        main()
    except (PublicationError, OSError, UnicodeError) as error:
        print(f"::error::{error}", file=sys.stderr)
        sys.exit(1)

#!/usr/bin/env python3
"""Bind immutable aggregate bytes to the dataset later accepted through a PR."""

import argparse
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

SCHEMA = "ammitto-publication/v1"
MANIFEST = Path(".publication/manifest.json")
ASSETS = {
    "all.jsonld": Path("api/v1/all.jsonld"),
    "all.ttl": Path("api/v1/all.ttl"),
    "ru.jsonld": Path("api/v1/sources/ru.jsonld"),
    "ru.ttl": Path("api/v1/sources/ru.ttl"),
}


def command(*args, env=None):
    return subprocess.run(args, env=env, check=True, capture_output=True, text=True).stdout.strip()


def git(*args, env=None):
    return command("git", *args, env=env)


def digest(path):
    if path.is_symlink() or not path.is_file():
        raise ValueError(f"not a regular aggregate: {path}")
    size = path.stat().st_size
    if not 0 < size < 2 * 1024 ** 3:
        raise ValueError(f"aggregate outside release size limits: {path}")
    value = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            value.update(block)
    return {"sha256": value.hexdigest(), "size": size}


def trusted_context():
    repo = os.environ.get("GITHUB_REPOSITORY", "")
    default = os.environ.get("PUBLICATION_DEFAULT_BRANCH", "")
    event = os.environ.get("GITHUB_EVENT_NAME", "")
    if (os.environ.get("GITHUB_ACTIONS") != "true" or not default
            or os.environ.get("GITHUB_REF") != "refs/heads/" + default
            or event not in ("push", "schedule", "workflow_dispatch")
            or not re.fullmatch(r"[\w.-]+/[\w.-]+", repo)):
        raise ValueError("publication requires a trusted default-branch event")
    return repo, default


def output(**values):
    path = os.environ.get("GITHUB_OUTPUT")
    if path:
        with open(path, "a") as stream:
            for key, value in values.items():
                stream.write(f"{key}={value}\n")


def dataset_trees(tree):
    result = {name + "_tree": git("rev-parse", f"{tree}:{name}") for name in ("api", "sources")}
    entries = git("ls-tree", f"{tree}:sources").splitlines()
    if not entries or any(not line.startswith("160000 commit ") for line in entries):
        raise ValueError("sources must contain only pinned repository gitlinks")
    return result


def prepare(artifact_dir):
    repo, default = trusted_context()
    run_id = os.environ.get("GITHUB_RUN_ID", "")
    run_attempt = os.environ.get("GITHUB_RUN_ATTEMPT", "")
    if not re.fullmatch(r"[1-9][0-9]*", run_id) or not re.fullmatch(r"[1-9][0-9]*", run_attempt):
        raise ValueError("invalid generation run ID")
    if git("diff", "--cached", "--name-only"):
        raise ValueError("generation must not inherit staged changes")
    with tempfile.TemporaryDirectory(prefix="publication-index-") as directory:
        env = {**os.environ, "GIT_INDEX_FILE": str(Path(directory) / "index")}
        git("read-tree", "HEAD", env=env)
        git("add", "-A", "--", "api", "sources", env=env)
        tree = git("write-tree", env=env)
        trees = dataset_trees(tree)
    assets = {name: digest(path) for name, path in ASSETS.items()}
    if MANIFEST.exists():
        previous = read_manifest(MANIFEST)
        if (trees == dataset_trees("HEAD")
                and {k: previous[k] for k in trees} == trees
                and previous["assets"] == assets
                and verify_run(previous, repo, default, require_success=False)):
            output(changed="false")
            return
    manifest = {"schema": SCHEMA, "repository": repo, "run_id": run_id, "run_attempt": run_attempt,
                "artifact_name": f"harmonized-aggregates-{run_id}-{run_attempt}", **trees,
                "assets": assets}
    artifact_dir.mkdir(parents=True, exist_ok=False)
    for name, path in ASSETS.items():
        shutil.copyfile(path, artifact_dir / name)
    if MANIFEST.parent.is_symlink():
        raise ValueError("publication metadata directory must not be a symlink")
    MANIFEST.parent.mkdir(exist_ok=True)
    MANIFEST.write_text(json.dumps(manifest, sort_keys=True, indent=2) + "\n")
    shutil.copyfile(MANIFEST, artifact_dir / "manifest.json")
    output(changed="true", artifact_name=manifest["artifact_name"])


def read_manifest(path):
    if path.is_symlink():
        raise ValueError("manifest must not be a symlink")
    data = json.loads(path.read_text())
    if not isinstance(data, dict) or set(data) != {
            "schema", "repository", "run_id", "run_attempt", "artifact_name", "api_tree", "sources_tree", "assets"}:
        raise ValueError("unknown publication manifest fields")
    if (data["schema"] != SCHEMA or not isinstance(data["run_id"], str)
            or not re.fullmatch(r"[1-9][0-9]*", data["run_id"])
            or not isinstance(data["run_attempt"], str)
            or not re.fullmatch(r"[1-9][0-9]*", data["run_attempt"])
            or data["artifact_name"] != f"harmonized-aggregates-{data['run_id']}-{data['run_attempt']}"
            or not all(isinstance(data[k], str) and re.fullmatch(r"[0-9a-f]{40}", data[k])
                       for k in ("api_tree", "sources_tree"))
            or not isinstance(data["assets"], dict) or set(data["assets"]) != set(ASSETS)):
        raise ValueError("invalid publication manifest")
    for asset in data["assets"].values():
        if (not isinstance(asset, dict) or set(asset) != {"sha256", "size"}
                or not isinstance(asset["sha256"], str)
                or not re.fullmatch(r"[0-9a-f]{64}", asset["sha256"])
                or type(asset["size"]) is not int or not 0 < asset["size"] < 2 * 1024 ** 3):
            raise ValueError("invalid aggregate digest or size")
    return data


def verify_run(manifest, repo, default, require_success=True):
    if manifest["repository"] != repo:
        raise ValueError("manifest belongs to another repository")
    run = json.loads(command("gh", "api", f"repos/{repo}/actions/runs/{manifest['run_id']}/attempts/{manifest['run_attempt']}"))
    if (str(run["id"]) != manifest["run_id"] or str(run["run_attempt"]) != manifest["run_attempt"]
            or run["repository"]["full_name"] != repo
            or run["head_repository"]["full_name"] != repo or run["head_branch"] != default
            or run["path"] != ".github/workflows/harmonize.yml"
            or run["event"] not in ("push", "schedule", "workflow_dispatch")
            or not re.fullmatch(r"[0-9a-f]{40}", run["head_sha"])):
        raise ValueError("artifact was not generated by a successful trusted harmonizer run")
    git("merge-base", "--is-ancestor", run["head_sha"], "HEAD")
    succeeded = run["status"] == "completed" and run["conclusion"] == "success"
    if require_success and not succeeded:
        raise ValueError("generation attempt did not complete successfully")
    return succeeded


def verify_artifact(manifest, artifact_dir):
    if artifact_dir.is_symlink() or not artifact_dir.is_dir():
        raise ValueError("artifact directory is not a regular directory")
    if set(path.name for path in artifact_dir.iterdir()) != set(ASSETS) | {"manifest.json"}:
        raise ValueError("artifact must contain exactly four aggregates and its manifest")
    artifact_manifest = artifact_dir / "manifest.json"
    if artifact_manifest.is_symlink() or artifact_manifest.read_bytes() != MANIFEST.read_bytes():
        raise ValueError("artifact manifest differs from the accepted manifest")
    for name, expected in manifest["assets"].items():
        if digest(artifact_dir / name) != expected:
            raise ValueError(f"artifact digest/size mismatch: {name}")


def download(artifact_dir):
    repo, default = trusted_context()
    if os.environ.get("GITHUB_EVENT_NAME") != "push" or git("rev-parse", "HEAD") != os.environ.get("GITHUB_SHA"):
        raise ValueError("publisher must check out the exact accepted push SHA")
    manifest = read_manifest(MANIFEST)
    if {k: manifest[k] for k in ("api_tree", "sources_tree")} != dataset_trees("HEAD"):
        raise ValueError("accepted dataset trees differ from the generation manifest")
    if git("diff", "HEAD", "--", "api", "sources", str(MANIFEST)):
        raise ValueError("accepted checkout has modified publication inputs")
    verify_run(manifest, repo, default)
    artifact_dir.mkdir(parents=True, exist_ok=False)
    command("gh", "run", "download", manifest["run_id"], "--repo", repo,
            "--name", manifest["artifact_name"], "--dir", str(artifact_dir))
    verify_artifact(manifest, artifact_dir)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("operation", choices=("prepare", "download"))
    parser.add_argument("--artifact-dir", type=Path, required=True)
    args = parser.parse_args()
    {"prepare": prepare, "download": download}[args.operation](args.artifact_dir)


if __name__ == "__main__":
    try:
        main()
    except (ValueError, KeyError, TypeError, OSError, subprocess.CalledProcessError) as error:
        print(f"publication manifest failed: {error}", file=sys.stderr)
        sys.exit(1)

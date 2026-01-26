#!/usr/bin/env python3
"""Release helper for SSH App TestFlight tags."""

from __future__ import annotations

import argparse
import pathlib
import re
import subprocess
import sys
from dataclasses import dataclass


PROJECT_FILE = pathlib.Path("SSHApp.xcodeproj/project.pbxproj")
SEMVER_RE = re.compile(r"^\d+\.\d+\.\d+$")
MARKETING_VERSION_RE = re.compile(r"(MARKETING_VERSION = )\d+\.\d+\.\d+(;)")


class ReleaseError(Exception):
    """A release precondition or operation failed."""


@dataclass(frozen=True)
class ReleasePlan:
    current_version: str
    new_version: str
    tag: str


def run(
    repo_root: pathlib.Path,
    *args: str,
    capture_output: bool = False,
) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        list(args),
        cwd=repo_root,
        check=True,
        text=True,
        stdout=subprocess.PIPE if capture_output else None,
        stderr=subprocess.PIPE if capture_output else None,
    )


def git(repo_root: pathlib.Path, *args: str, capture_output: bool = False) -> subprocess.CompletedProcess[str]:
    return run(repo_root, "git", *args, capture_output=capture_output)


def git_output(repo_root: pathlib.Path, *args: str) -> str:
    return git(repo_root, *args, capture_output=True).stdout


def has_staged_changes(root: pathlib.Path) -> bool:
    try:
        run(root, "git", "diff", "--cached", "--quiet")
    except subprocess.CalledProcessError as err:
        if err.returncode == 1:
            return True
        raise ReleaseError("failed to inspect staged git changes") from err
    return False


def repo_root() -> pathlib.Path:
    try:
        output = git_output(pathlib.Path.cwd(), "rev-parse", "--show-toplevel")
    except subprocess.CalledProcessError as err:
        raise ReleaseError("must be run from inside a git repository") from err
    return pathlib.Path(output.strip())


def parse_semver(version: str) -> tuple[int, int, int]:
    if version.startswith("v"):
        version = version[1:]
    if not SEMVER_RE.match(version):
        raise ReleaseError(f"invalid version {version!r}; expected X.Y.Z")
    major, minor, patch = version.split(".")
    return int(major), int(minor), int(patch)


def is_explicit_version(version: str) -> bool:
    return SEMVER_RE.match(version) is not None


def current_version(root: pathlib.Path) -> str:
    output = git_output(root, "tag", "-l", "--sort=-version:refname", "v[0-9]*.[0-9]*.[0-9]*")
    line = output.strip().splitlines()[0] if output.strip() else ""
    return line


def resolve_version(root: pathlib.Path, version_arg: str) -> str:
    if version_arg.startswith("v"):
        raise ReleaseError("VERSION must not start with 'v'; use X.Y.Z, patch, minor, or major")

    if is_explicit_version(version_arg):
        return version_arg

    if version_arg not in {"patch", "minor", "major"}:
        raise ReleaseError("VERSION must be patch, minor, major, or an explicit X.Y.Z")

    base = current_version(root) or "v0.0.0"
    major, minor, patch = parse_semver(base)

    if version_arg == "major":
        major += 1
        minor = 0
        patch = 0
    elif version_arg == "minor":
        minor += 1
        patch = 0
    else:
        patch += 1

    return f"{major}.{minor}.{patch}"


def build_plan(root: pathlib.Path, version_arg: str) -> ReleasePlan:
    current = current_version(root) or "v0.0.0"
    new = resolve_version(root, version_arg)
    tag = f"v{new}"

    if git_output(root, "tag", "-l", tag).strip():
        raise ReleaseError(f"tag already exists: {tag}")

    return ReleasePlan(current_version=current, new_version=new, tag=tag)


def ensure_clean_worktree(root: pathlib.Path) -> None:
    status = git_output(root, "status", "--porcelain")
    if status.strip():
        raise ReleaseError("working directory is not clean; commit or stash changes first")


def ensure_head_on_origin_main(root: pathlib.Path) -> None:
    try:
        git(root, "fetch", "origin", "main")
    except subprocess.CalledProcessError as err:
        raise ReleaseError("failed to fetch origin/main before pushing release tag") from err

    try:
        run(root, "git", "merge-base", "--is-ancestor", "HEAD", "origin/main")
    except subprocess.CalledProcessError as err:
        if err.returncode == 1:
            raise ReleaseError("release commit must be present on origin/main before pushing a release tag") from err
        raise ReleaseError("failed to verify release commit ancestry against origin/main") from err


def marketing_version_update(root: pathlib.Path, version: str) -> tuple[int, bool, str]:
    project_file = root / PROJECT_FILE
    if not project_file.exists():
        raise ReleaseError(f"missing iOS project file: {PROJECT_FILE}")

    original = project_file.read_text()
    updated, count = MARKETING_VERSION_RE.subn(rf"\g<1>{version}\2", original)
    if count == 0:
        raise ReleaseError(f"no three-part MARKETING_VERSION entries found in {PROJECT_FILE}")

    return count, updated != original, updated


def update_marketing_version(root: pathlib.Path, version: str) -> int:
    project_file = root / PROJECT_FILE
    count, _, updated = marketing_version_update(root, version)
    project_file.write_text(updated)
    return count


def print_plan(plan: ReleasePlan) -> None:
    print(f"Bumping SSH App: {plan.current_version} -> v{plan.new_version}")
    print(f"iOS project: {PROJECT_FILE} MARKETING_VERSION -> {plan.new_version}")
    print(f"Tag: {plan.tag}")


def create_release(root: pathlib.Path, version_arg: str, dry_run: bool, push: bool) -> None:
    plan = build_plan(root, version_arg)
    print_plan(plan)

    if dry_run:
        _, changed, _ = marketing_version_update(root, plan.new_version)
        print("[dry-run] No files, commits, tags, or remotes were changed.")
        if changed:
            print(f"[dry-run] Would update {PROJECT_FILE}.")
            print(f"[dry-run] Would commit: chore(release): bump version to v{plan.new_version}")
        else:
            print(f"[dry-run] {PROJECT_FILE} already matches v{plan.new_version}; no version commit needed.")
        print(f"[dry-run] Would create annotated tag: {plan.tag}")
        if push:
            print("[dry-run] Would verify HEAD is present on origin/main before pushing the tag.")
            print(f"[dry-run] Would push: {plan.tag}")
        return

    ensure_clean_worktree(root)

    count = update_marketing_version(root, plan.new_version)
    git(root, "add", str(PROJECT_FILE))
    committed = False
    if has_staged_changes(root):
        git(root, "commit", "-m", f"chore(release): bump version to v{plan.new_version}")
        committed = True
        print(f"Committed MARKETING_VERSION update ({count} entries).")
    else:
        print("MARKETING_VERSION already matched; no version commit needed.")

    if push:
        if committed:
            git(root, "push")
        ensure_head_on_origin_main(root)

    git(root, "tag", "-a", plan.tag, "-m", f"SSH App v{plan.new_version}")
    print(f"Created tag: {plan.tag}")

    if push:
        git(root, "push", "origin", plan.tag)
        print(f"Pushed tag: {plan.tag}")
        return

    print()
    print("To trigger the TestFlight release:")
    if committed:
        print("  git push")
    print(f"  git push origin {plan.tag}")


def list_versions(root: pathlib.Path) -> None:
    print("Current release tag:")
    print()
    print(f"  {current_version(root) or '(no tags)'}")


def parser() -> argparse.ArgumentParser:
    root_parser = argparse.ArgumentParser(description="Release SSH App to TestFlight.")
    subparsers = root_parser.add_subparsers(dest="command", required=True)

    subparsers.add_parser("list", help="List the current release tag.")

    release_parser = subparsers.add_parser("release", help="Create a release tag.")
    release_parser.add_argument("--version", required=True)
    release_parser.add_argument("--dry-run", action="store_true")
    release_parser.add_argument("--push", action="store_true", help="Push the release tag after creating it.")

    return root_parser


def main() -> int:
    args = parser().parse_args()
    try:
        root = repo_root()
        if args.command == "list":
            list_versions(root)
        elif args.command == "release":
            create_release(
                root=root,
                version_arg=args.version,
                dry_run=args.dry_run,
                push=args.push,
            )
        else:
            raise ReleaseError(f"unknown command: {args.command}")
    except ReleaseError as err:
        print(f"Error: {err}", file=sys.stderr)
        return 1
    except subprocess.CalledProcessError as err:
        print(f"Error: command failed: {' '.join(err.cmd)}", file=sys.stderr)
        if err.stdout:
            print(err.stdout, file=sys.stderr)
        if err.stderr:
            print(err.stderr, file=sys.stderr)
        return err.returncode or 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

#!/usr/bin/env python3
"""Build the isolated, pinned VT experiment. Never modifies vendor/ or Frameworks/."""
import hashlib
import fcntl
import json
import os
from pathlib import Path
import platform
import re
import shutil
import subprocess
import tempfile
import urllib.request

ROOT = Path(__file__).resolve().parents[1]
WORK = ROOT / ".build/ghostty-vt"
LOCK_PATH = ROOT / "vendor/libghostty-vt/native-lock.json"
GHOSTTY_SUBMODULE = "vendor/ghostty"
GHOSTTY_SOURCE = ROOT / GHOSTTY_SUBMODULE
PATCH_ROOT = ROOT / "vendor/libghostty-vt/patches"


def sha256(path):
    digest = hashlib.sha256()
    with Path(path).open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def output(*args):
    return subprocess.check_output(args, text=True).strip()


def download(url, checksum, name):
    path = WORK / "downloads" / name
    path.parent.mkdir(parents=True, exist_ok=True)
    if path.exists() and sha256(path) == checksum:
        return path
    partial = path.with_suffix(".download")
    print(f"Downloading {url}", flush=True)
    with urllib.request.urlopen(url, timeout=120) as response, partial.open("wb") as stream:
        shutil.copyfileobj(response, stream)
    if sha256(partial) != checksum:
        raise RuntimeError(f"Checksum mismatch for {url}")
    partial.replace(path)
    return path


def gitlink_revision(root=ROOT, path=GHOSTTY_SUBMODULE):
    """The commit the superproject index pins; `git submodule update` checks it out."""
    entry = subprocess.run(["git", "-C", str(root), "ls-files", "--stage", "--", path],
                           capture_output=True, text=True).stdout.split()
    if len(entry) < 4 or entry[0] != "160000":
        raise RuntimeError(f"{path} is not a git submodule gitlink in {root}")
    return entry[1]


def verify_ghostty_source(revision, source=GHOSTTY_SOURCE, root=ROOT, path=GHOSTTY_SUBMODULE):
    """Fail closed unless the lock, gitlink and pristine submodule checkout agree."""
    if not re.fullmatch(r"[0-9a-f]{40}", revision):
        raise RuntimeError(f"ghostty_revision must be a full commit SHA, got {revision!r}")
    gitlink = gitlink_revision(root, path)
    if gitlink != revision:
        raise RuntimeError(f"{path} gitlink is {gitlink}; native-lock.json pins {revision}")
    head = subprocess.run(["git", "-C", str(source), "rev-parse", "HEAD"],
                          capture_output=True, text=True)
    if head.returncode != 0 or head.stdout.strip() != revision:
        actual = head.stdout.strip() or "uninitialized"
        raise RuntimeError(f"{path} is at {actual}; expected {revision}. Run: git submodule update --init {path}")
    status = subprocess.run(["git", "-C", str(source), "status", "--porcelain",
                             "--untracked-files=all", "--ignored"],
                            capture_output=True, text=True, check=True).stdout
    if status:
        raise RuntimeError(f"{path} contains modified or untracked files; native builds require "
                           f"pristine pinned sources:\n{status}")


def export_ghostty_source(revision, destination, source=GHOSTTY_SOURCE):
    """Export exactly the pinned commit's tree (like GitHub's archive) without .git metadata."""
    archive = subprocess.Popen(["git", "-C", str(source), "archive", "--format=tar", revision],
                               stdout=subprocess.PIPE)
    extract = subprocess.run(["tar", "-xf", "-", "-C", str(destination)], stdin=archive.stdout)
    archive.stdout.close()
    if archive.wait() != 0 or extract.returncode != 0:
        raise RuntimeError(f"Failed to export {revision} from {source}")


def fingerprint(inputs):
    return hashlib.sha256(json.dumps(inputs, sort_keys=True).encode()).hexdigest()


def ghostty_version(source):
    """Use the exported source version, never the enclosing app repository's tags."""
    version_file = source / "VERSION"
    if version_file.is_file():
        return version_file.read_text().strip()
    match = re.search(r'^\s*\.version\s*=\s*"([^"]+)"',
                      (source / "build.zig.zon").read_text(), re.M)
    if not match:
        raise RuntimeError("Missing Ghostty version in build.zig.zon")
    return match.group(1)


def patch_inputs():
    patches = {path.name: sha256(path) for path in sorted(PATCH_ROOT.glob("*.patch"))}
    # The app's VT bridge requires the patched API; an empty or missing patch
    # directory must never silently build unpatched upstream sources.
    if not patches:
        raise RuntimeError(f"No VT patches found in {PATCH_ROOT}; refusing to build unpatched libghostty-vt")
    return patches


def apply_patches(source, patches):
    for name, checksum in patches.items():
        path = PATCH_ROOT / name
        if sha256(path) != checksum:
            raise RuntimeError(f"VT patch changed during build: {name}")
        subprocess.run(["/usr/bin/patch", "--batch", "--forward", "--fuzz=0", "-p1", "-i", str(path)],
                       cwd=source, check=True)


def valid_cache(destination, inputs):
    try:
        manifest = json.loads((destination / "provenance.json").read_text())
        required = {"iphoneos/libghostty-vt.a", "iphonesimulator/libghostty-vt.a", "include/ghostty/vt.h"}
        return required.issubset(manifest["artifacts"]) and manifest["inputs"] == inputs and all(
            (destination / path).is_file() and sha256(destination / path) == digest
            for path, digest in manifest["artifacts"].items()
        ) and bool(manifest["artifacts"])
    except (OSError, ValueError, KeyError):
        return False


def native_build_environment():
    environment = os.environ.copy()
    cache = WORK / "zig-cache"
    # Zig's ZIP dependency fetcher creates files under global-cache/tmp
    # without creating the parent first. Fresh CI caches need it explicitly.
    (cache / "tmp").mkdir(parents=True, exist_ok=True)
    environment["ZIG_GLOBAL_CACHE_DIR"] = str(cache)
    return environment


def main():
    if platform.system() != "Darwin" or platform.machine() != "arm64":
        raise SystemExit("The libghostty-vt build requires an Apple silicon Mac with Xcode.")
    lock = json.loads(LOCK_PATH.read_text())
    verify_ghostty_source(lock["ghostty_revision"])
    sdks = {}
    for sdk in ("iphoneos", "iphonesimulator"):
        sdk_path = output("xcrun", "--sdk", sdk, "--show-sdk-path")
        sdks[sdk] = {
            "path": sdk_path,
            "version": output("xcrun", "--sdk", sdk, "--show-sdk-version"),
            "settings_sha256": sha256(Path(sdk_path) / "SDKSettings.json"),
        }
    inputs = {
        "lock": lock,
        "recipe_sha256": sha256(__file__),
        "patches": patch_inputs(),
        "xcode": output("xcodebuild", "-version"),
        "developer_dir": output("xcode-select", "-p"),
        "sdks": sdks,
    }
    destination = WORK / "native"
    if valid_cache(destination, inputs):
        print(f"Verified VT artifact cache: {destination}")
        return

    zig_archive = download(lock["zig_url"], lock["zig_sha256"], "zig-0.16.0.tar.xz")

    # Each cache miss starts with a clean export of the pinned submodule commit.
    # Zig's content-addressed dependency/compiler caches can still be reused.
    with tempfile.TemporaryDirectory(prefix="native-build-", dir=WORK) as temporary:
        staging = Path(temporary)
        toolchain = staging / "toolchain"
        toolchain.mkdir()
        subprocess.run(["tar", "-xf", str(zig_archive), "--strip-components=1", "-C", str(toolchain)], check=True)
        zig = toolchain / "zig"
        if output(str(zig), "version") != lock["zig_version"]:
            raise RuntimeError("Unexpected Zig version")
        source = staging / "source"
        source.mkdir()
        export_ghostty_source(lock["ghostty_revision"], source)
        apply_patches(source, inputs["patches"])
        version = ghostty_version(source)
        result = staging / "result"
        result.mkdir()
        environment = native_build_environment()
        for sdk, abi in (("iphoneos", ""), ("iphonesimulator", "-simulator")):
            prefix = staging / sdk
            args = [str(zig), "build", "-Demit-lib-vt=true", "-Demit-xcframework=false",
                    f"-Dversion-string={version}",
                    f"-Dtarget=aarch64-ios.{lock['deployment_target']}{abi}",
                    f"-Dcpu={lock['cpu']}", f"-Doptimize={lock['optimization']}",
                    "--prefix", str(prefix)]
            print(f"Building {sdk} (arm64, iOS {lock['deployment_target']}, {lock['cpu']})", flush=True)
            subprocess.run(args, cwd=source, env=environment, check=True)
            artifact_dir = result / sdk
            artifact_dir.mkdir()
            archive = artifact_dir / "libghostty-vt.a"
            shutil.copy2(prefix / "lib/libghostty-vt.a", archive)
            # Save every object's platform/minimum-OS load command for audit.
            load_commands = output("xcrun", "otool", "-l", str(archive))
            (artifact_dir / "macho-load-commands.txt").write_text(load_commands)
            platform_id = "2" if sdk == "iphoneos" else "7"
            platforms = re.findall(r"^\s+platform (\S+)", load_commands, re.M)
            minimums = re.findall(r"^\s+minos (\S+)", load_commands, re.M)
            if not platforms or set(platforms) != {platform_id} or set(minimums) != {lock["deployment_target"]}:
                raise RuntimeError(f"Unexpected {sdk} Mach-O platforms/minimums: {set(platforms)}, {set(minimums)}")
            if output("xcrun", "lipo", "-archs", str(archive)) != "arm64":
                raise RuntimeError(f"Unexpected {sdk} architecture")
        shutil.copytree(source / "include/ghostty", result / "include/ghostty")
        shutil.copy2(source / "LICENSE", result / "GHOSTTY-LICENSE")
        artifacts = {str(p.relative_to(result)): sha256(p) for p in sorted(result.rglob("*")) if p.is_file()}
        (result / "provenance.json").write_text(json.dumps({
            "fingerprint": fingerprint(inputs), "inputs": inputs, "artifacts": artifacts,
        }, indent=2) + "\n")
        if destination.exists():
            shutil.rmtree(destination)
        shutil.move(result, destination)
    print(f"Built and verified VT device/simulator slices: {destination}")


if __name__ == "__main__":
    WORK.mkdir(parents=True, exist_ok=True)
    # Device and simulator Xcode builds share the same verified output pair.
    with (WORK / "build.lock").open("a") as build_lock:
        fcntl.flock(build_lock.fileno(), fcntl.LOCK_EX)
        main()

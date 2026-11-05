#!/bin/bash
set -euo pipefail
project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
exec python3 - "${project_root}" "$@" <<'PY'
"""Install only this project's generated bundle; never launches or stops an app."""
import argparse
import ctypes
import hashlib
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys
import tempfile

project = Path(sys.argv[1])
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--destination", type=Path, default=Path.home() / "Applications/Bazer.app")
parser.add_argument("--dry-run", action="store_true", help="validate paths/hash/running-process guards without writing")
parser.add_argument("--replace", action="store_true", help="explicit replacement; requires expected existing binary hash")
parser.add_argument("--expected-existing-sha256", help="known hash of the previously installed binary")
args = parser.parse_args(sys.argv[2:])
source = project / "build/Bazer.app"
destination = args.destination.expanduser()
identifier = "local.karl.Bazer"

def digest(path):
    value = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            value.update(block)
    return value.hexdigest()

def validate_bundle(bundle):
    if bundle.is_symlink() or not bundle.is_dir():
        raise ValueError(f"not a regular app bundle: {bundle}")
    with (bundle / "Contents/Info.plist").open("rb") as stream:
        info = plistlib.load(stream)
    if info.get("CFBundleIdentifier") != identifier or info.get("CFBundleExecutable") != "BazerApp":
        raise ValueError(f"unexpected bundle identity: {bundle}")
    binary = bundle / "Contents/MacOS/BazerApp"
    if binary.is_symlink() or not binary.is_file() or not os.access(binary, os.X_OK):
        raise ValueError(f"missing regular executable: {binary}")
    return digest(binary)

def ensure_not_running():
    libproc = ctypes.CDLL("/usr/lib/libproc.dylib", use_errno=True)
    libproc.proc_pidpath.argtypes = [ctypes.c_int, ctypes.c_void_p, ctypes.c_uint32]
    libproc.proc_pidpath.restype = ctypes.c_int
    result = subprocess.run(["/bin/ps", "-axo", "pid="], capture_output=True, text=True, check=True, timeout=5)
    targets = {(bundle / "Contents/MacOS/BazerApp").resolve() for bundle in (source, destination)}
    for value in result.stdout.split():
        pid = int(value)
        buffer = ctypes.create_string_buffer(4096)
        if libproc.proc_pidpath(pid, buffer, len(buffer)) > 0:
            if Path(os.fsdecode(buffer.value)).resolve() in targets:
                raise ValueError(f"Bazer is running (PID {pid}); quit it through the app before installing")

def clean_generated_metadata(bundle):
    # Only the newly copied bundle is touched. Preserve FileProvider/provenance.
    for root, directories, files in os.walk(bundle, followlinks=False):
        for path in [Path(root), *(Path(root) / name for name in directories + files)]:
            result = subprocess.run(["/usr/bin/xattr", "-s", str(path)], capture_output=True,
                                    text=True, check=True)
            for attribute in result.stdout.splitlines():
                if attribute in {"com.apple.FinderInfo", "com.apple.ResourceFork"}:
                    subprocess.run(["/usr/bin/xattr", "-s", "-d", attribute, str(path)], check=True)

stage_root = None
backup = None
installed_new_bundle = False
preserve_stage = False
try:
    if sys.platform != "darwin":
        raise ValueError("macOS is required")
    if not destination.is_absolute() or destination.name != "Bazer.app":
        raise ValueError("destination must be an absolute path ending in Bazer.app")
    if destination.is_symlink():
        raise ValueError("refusing a symlink destination")
    destination = destination.resolve()
    if destination == source.resolve() or source.resolve() in destination.parents:
        raise ValueError("destination must be outside the generated source bundle")
    source_hash = validate_bundle(source)
    existing_hash = None
    if args.replace != bool(args.expected_existing_sha256):
        raise ValueError("--replace and --expected-existing-sha256 must be supplied together")
    if args.expected_existing_sha256 and (len(args.expected_existing_sha256) != 64 or
            any(c not in "0123456789abcdefABCDEF" for c in args.expected_existing_sha256)):
        raise ValueError("expected existing SHA256 must contain 64 hexadecimal characters")
    if destination.exists():
        if not args.replace:
            raise ValueError("destination already exists; default installation never overwrites it")
        existing_hash = validate_bundle(destination)
        if existing_hash != args.expected_existing_sha256.lower():
            raise ValueError("existing binary does not match the explicitly expected SHA256")
    elif args.replace:
        raise ValueError("replacement requested but destination does not exist")
    ensure_not_running()
    print(f"Source: {source}\nDestination: {destination}\nBinary SHA256: {source_hash}", flush=True)
    if args.dry_run:
        print("Dry run: no files changed; staged signature verification happens during actual installation.")
        sys.exit(0)
    destination.parent.mkdir(parents=True, exist_ok=True)
    stage_root = Path(tempfile.mkdtemp(prefix=".bazer-install-", dir=destination.parent))
    staged = stage_root / "Bazer.app"
    subprocess.run(["/usr/bin/ditto", "--extattr", str(source), str(staged)], check=True)
    clean_generated_metadata(staged)
    if validate_bundle(staged) != source_hash:
        raise ValueError("staged executable SHA256 differs from source")
    subprocess.run(["/usr/bin/codesign", "--verify", "--strict", "--verbose=2", str(staged)], check=True)
    ensure_not_running()
    # Revalidate after copying, before replacing. Never silently absorb a changed destination.
    if existing_hash is not None:
        if validate_bundle(destination) != existing_hash:
            raise ValueError("destination changed during installation")
        backup = stage_root / "previous-Bazer.app"
        destination.rename(backup)
    elif destination.exists() or destination.is_symlink():
        raise ValueError("destination appeared during installation")
    staged.rename(destination)
    installed_new_bundle = True
    subprocess.run(["/usr/bin/codesign", "--verify", "--strict", "--verbose=2", str(destination)], check=True)
    if validate_bundle(destination) != source_hash:
        raise ValueError("installed executable SHA256 differs from source")
    if backup is not None:
        # The new installation is now verified. Cleanup failure must not trigger
        # rollback to a possibly partially deleted backup.
        try:
            shutil.rmtree(backup)
            backup = None
        except OSError as cleanup_error:
            preserve_stage = True
            print(f"Installed app is verified; old-backup cleanup failed: {cleanup_error}", file=sys.stderr)
    print(f"Installed {destination}\nOpen explicitly with: open '{destination}'")
except (OSError, ValueError, plistlib.InvalidFileException, subprocess.SubprocessError) as error:
    # Recovery is best effort. Never delete the only old copy if removing the
    # new bundle or renaming the backup fails (for example, an immutable file).
    recovery_errors = []
    if installed_new_bundle:
        try:
            shutil.rmtree(destination)
        except OSError as cleanup_error:
            recovery_errors.append(f"could not remove new bundle {destination}: {cleanup_error}")
    if backup is not None and backup.exists():
        if destination.exists() or destination.is_symlink():
            recovery_errors.append(f"destination still exists; old backup was not overwritten: {backup}")
        else:
            try:
                backup.rename(destination)
                backup = None
            except OSError as restore_error:
                recovery_errors.append(f"could not restore old backup {backup}: {restore_error}")
    preserve_stage = bool(recovery_errors) or (backup is not None and backup.exists())
    print(f"Installation refused/failed: {error}", file=sys.stderr)
    for recovery_error in recovery_errors:
        print(f"Recovery incomplete: {recovery_error}", file=sys.stderr)
    sys.exit(1)
finally:
    if stage_root is not None:
        # This independent guard also protects backup data if a recovery step
        # raises unexpectedly. Never blindly erase a stage containing an old app.
        if preserve_stage or (backup is not None and backup.exists()):
            print(f"Recovery/staging files retained at: {stage_root}", file=sys.stderr)
            if backup is not None and backup.exists():
                print(f"Previous app recovery path: {backup}", file=sys.stderr)
        else:
            try:
                shutil.rmtree(stage_root)
            except OSError as cleanup_error:
                print(f"Staging cleanup failed; files retained at {stage_root}: {cleanup_error}", file=sys.stderr)
PY

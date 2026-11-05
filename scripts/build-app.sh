#!/bin/bash
set -euo pipefail

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
app_path="${project_root}/build/Bazer.app"
custom_output=0
requested_sdk=""
requested_scratch=""

usage() {
    echo "Usage: build-app.sh [--output /absolute/path/Bazer.app] [--sdk /absolute/path/MacOSX.sdk] [--scratch-path /absolute/path]"
    echo "Default output replaces only build/Bazer.app; a custom output must not exist."
}
while [[ $# -gt 0 ]]; do
    case "$1" in
        --output)
            if [[ $# -lt 2 || ${custom_output} -eq 1 ]]; then usage >&2; exit 2; fi
            app_path="$2"
            custom_output=1
            shift 2
            ;;
        --sdk)
            if [[ $# -lt 2 || -n "${requested_sdk}" || "$2" != /* || ! -d "$2" ]]; then usage >&2; exit 2; fi
            requested_sdk="$2"
            shift 2
            ;;
        --scratch-path)
            if [[ $# -lt 2 || -n "${requested_scratch}" || "$2" != /* ]]; then usage >&2; exit 2; fi
            requested_scratch="$2"
            shift 2
            ;;
        --help|-h) usage; exit 0 ;;
        *) usage >&2; exit 2 ;;
    esac
done

validate_custom_output() {
    python3 - "$1" <<'PY'
from pathlib import Path
import sys

target = Path(sys.argv[1])
def refuse(message):
    print(f"Packaging refused: {message}", file=sys.stderr)
    sys.exit(2)
if not target.is_absolute() or target.name != "Bazer.app" or ".." in target.parts:
    refuse("custom output must be an absolute path ending in Bazer.app without '..'")
if target.exists() or target.is_symlink():
    refuse(f"custom output already exists; refusing to overwrite: {target}")
for parent in target.parents:
    if parent.is_symlink() or (parent.exists() and not parent.is_dir()):
        refuse(f"custom output parent is not a regular directory: {parent}")
PY
}
if [[ ${custom_output} -eq 1 ]]; then validate_custom_output "${app_path}"; fi

build_arguments=(--package-path "${project_root}" --configuration release)
if [[ -n "${requested_sdk}" ]]; then build_arguments+=(--sdk "${requested_sdk}"); fi
if [[ -n "${requested_scratch}" ]]; then build_arguments+=(--scratch-path "${requested_scratch}"); fi
xcrun swift build "${build_arguments[@]}" --product BazerApp
binary_directory="$(xcrun swift build "${build_arguments[@]}" --show-bin-path)"

# Desktop may be managed by FileProvider, which can inject FinderInfo while
# codesign is building its resource envelope. Sign completely outside it first.
stage_root="$(mktemp -d /private/tmp/bazer-package.XXXXXX)"
staged_app="${stage_root}/Bazer.app"
staged_verified=0
phase="assemble staging bundle"

finish_packaging() {
    result=$?
    trap - EXIT
    if [[ ${result} -eq 0 ]]; then
        if rm -rf "${stage_root}"; then
            echo "Built ${app_path}"
        else
            echo "Verified app was built, but staging cleanup failed: ${stage_root}" >&2
            result=1
        fi
    else
        echo "Packaging failed during ${phase}; staging retained at: ${stage_root}" >&2
        if [[ ${staged_verified} -eq 1 ]]; then
            echo "Verified staging bundle available at: ${staged_app}" >&2
        fi
    fi
    exit "${result}"
}
trap finish_packaging EXIT

clean_generated_metadata() {
    # Never clear all xattrs. List first so absent attributes are not treated as
    # failures, and never follow a symlink outside the generated bundle.
    python3 - "$1" <<'PY'
import os
from pathlib import Path
import subprocess
import sys

bundle = Path(sys.argv[1])
if bundle.is_symlink() or not bundle.is_dir():
    raise ValueError(f"not a regular generated app bundle: {bundle}")
paths = [bundle]
for root, directories, files in os.walk(bundle, followlinks=False):
    paths.extend(Path(root) / name for name in directories + files)
for path in paths:
    attributes = subprocess.run(["/usr/bin/xattr", "-s", str(path)],
                                capture_output=True, text=True, check=True).stdout.splitlines()
    for attribute in attributes:
        if attribute in {"com.apple.FinderInfo", "com.apple.ResourceFork"}:
            subprocess.run(["/usr/bin/xattr", "-s", "-d", attribute, str(path)], check=True)
PY
}

mkdir -p "${staged_app}/Contents/MacOS" "${staged_app}/Contents/Resources"
/usr/bin/ditto --extattr --rsrc --qtn --acl "${binary_directory}/BazerApp" "${staged_app}/Contents/MacOS/BazerApp"
/usr/bin/ditto --extattr --rsrc --qtn --acl "${project_root}/Resources/Info.plist" "${staged_app}/Contents/Info.plist"
clean_generated_metadata "${staged_app}"
/usr/bin/plutil -lint "${staged_app}/Contents/Info.plist"
test -x "${staged_app}/Contents/MacOS/BazerApp"
phase="sign staging bundle"
/usr/bin/codesign --force --sign - --identifier local.karl.Bazer "${staged_app}"
/usr/bin/codesign --verify --strict --verbose=2 "${staged_app}"
staged_verified=1

phase="copy verified bundle to build directory"
if [[ ${custom_output} -eq 1 ]]; then
    validate_custom_output "${app_path}"
    mkdir -p "$(dirname "${app_path}")"
    validate_custom_output "${app_path}"
    # Reserve a new real directory atomically; never merge into an existing app.
    mkdir "${app_path}"
else
    if [[ -L "${project_root}/build" || -L "${app_path}" ]]; then
        echo "Refusing a symlink in the generated app destination: ${app_path}" >&2
        exit 1
    fi
    # Replace only this generated bundle; never an installed or custom bundle.
    mkdir -p "${project_root}/build"
    rm -rf "${app_path}"
fi
/usr/bin/ditto --extattr --rsrc --qtn --acl "${staged_app}" "${app_path}"
phase="wait for copied bundle metadata"
# FileProvider metadata writes may arrive after ditto returns. Do not treat the
# first brief clean interval as a stable verification result.
/bin/sleep 1
phase="clean and verify copied bundle"
clean_generated_metadata "${app_path}"
/usr/bin/codesign --verify --strict --verbose=2 "${app_path}"
phase="verify copied bundle after metadata settles"
/bin/sleep 1
/usr/bin/codesign --verify --strict --verbose=2 "${app_path}"
test -d "${app_path}"
test ! -L "${app_path}"
test ! -L "${app_path}/Contents/MacOS/BazerApp"
test -x "${app_path}/Contents/MacOS/BazerApp"

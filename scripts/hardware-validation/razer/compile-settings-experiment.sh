#!/bin/bash
set -euo pipefail
experiment_directory="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
project_directory="$(cd "${experiment_directory}/../../.." && pwd)"
workspace_directory="${project_directory}"
offline=false
requested_output_directory=""
requested_source_root=""
while [[ "$#" -gt 0 ]]; do
    case "$1" in
        --offline) if ${offline}; then echo 'Repeated --offline' >&2; exit 2; fi; offline=true; shift ;;
        --output-dir)
            if [[ "$#" -lt 2 || -n "${requested_output_directory}" || "$2" != /* ]]; then echo '--output-dir requires one new absolute directory' >&2; exit 2; fi
            requested_output_directory="$2"; shift 2 ;;
        --source-root)
            if [[ "$#" -lt 2 || -n "${requested_source_root}" || "$2" != /* || ! -f "$2/Package.swift" ]]; then echo '--source-root requires one absolute Swift package directory' >&2; exit 2; fi
            requested_source_root="$2"; shift 2 ;;
        *) echo "Usage: $0 [--offline] [--source-root /absolute/frozen/package] [--output-dir /absolute/new/directory]" >&2; exit 2 ;;
    esac
done
if [[ -n "${requested_source_root}" ]]; then project_directory="$(cd "${requested_source_root}" && pwd -P)"; fi
if [[ -n "${requested_output_directory}" ]]; then
    if [[ -e "${requested_output_directory}" || -L "${requested_output_directory}" ]]; then echo 'Output already exists' >&2; exit 1; fi
    mkdir -m 700 "${requested_output_directory}"
    output_directory="$(cd "${requested_output_directory}" && pwd -P)"
else
    output_parent="${workspace_directory}/build/hardware-validation/razer"
    mkdir -p "${output_parent}"
    output_directory="$(mktemp -d "${output_parent}/compile-XXXXXXXX")"
fi
echo "Output directory: ${output_directory}"
# Compile only. Neither generated executable is launched by this script.
scratch_directory="${output_directory}/swiftpm"
build_flags=(--package-path "${project_directory}" --scratch-path "${scratch_directory}" -c release --target BazerDrivers)
# The hardware-disabled fake uses the existing internal process-lock injection
# seam. Its dependency modules expose testability, but retain identical sources.
# Live modules keep their normal visibility and real process lock unchanged.
if ${offline}; then build_flags+=(-Xswiftc -enable-testing); fi
xcrun swift build "${build_flags[@]}"
module_directory="${scratch_directory}/arm64-apple-macosx/release"
objects=()
if [[ -d "${scratch_directory}/release/BazerCore.swiftmodule" ]]; then
    # Swift 6.2+ defaults to swiftbuild, whose products are merged module objects.
    module_directory="${scratch_directory}/release"
    module_import_directory="${module_directory}"
    for module in BazerCore RazerProtocol LogitechHIDPP BazerHID BazerDrivers; do
        [[ -f "${module_directory}/${module}.o" ]] || { echo "Missing merged module: ${module}" >&2; exit 1; }
        objects+=("${module_directory}/${module}.o")
    done
else
    module_import_directory="${module_directory}/Modules"
    for module in BazerCore RazerProtocol LogitechHIDPP BazerHID BazerDrivers; do
        for object in "${module_directory}/${module}.build/"*.swift.o; do
            [[ -f "${object}" ]] || { echo "Missing compiled module: ${module}" >&2; exit 1; }
            objects+=("${object}")
        done
    done
fi
sources=("${experiment_directory}/RazerSettingsExperiment.swift")
flags=(-swift-version 6 -parse-as-library -target arm64-apple-macosx13.0 -I "${module_import_directory}")
output="${output_directory}/razer-settings-experiment"
if ${offline}; then
    flags+=(-D RAZER_OFFLINE_TESTS)
    sources+=("${experiment_directory}/RazerSettingsFakeHarness.swift")
    output="${output_directory}/razer-settings-offline"
fi
xcrun swiftc "${flags[@]}" "${sources[@]}" "${objects[@]}" -o "${output}"
python3 - "${project_directory}" "${experiment_directory}" "${output_directory}" "${output}" "${offline}" <<'PY'
import hashlib, json, os, pathlib, sys
source_root, runner_root, out_root, binary, offline = map(pathlib.Path, sys.argv[1:])
def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()
sources = [source_root / 'Package.swift', *sorted((source_root / 'Sources').rglob('*.swift'))]
runners = sorted(path for path in runner_root.iterdir() if path.is_file())
record = {'schemaVersion': 1, 'sourceRoot': str(source_root), 'offline': str(offline) == 'true',
          'dependencyEnableTesting': str(offline) == 'true', 'offlineProcessLockFactory': 'none' if str(offline) == 'true' else None,
          'productSourceSHA256': {str(path.relative_to(source_root)): sha(path) for path in sources},
          'runnerSourceSHA256': {path.name: sha(path) for path in runners},
          'binary': str(binary), 'binarySHA256': sha(binary), 'hardwareExecutedByCompile': False}
path = out_root / 'compile-provenance.json'
descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
with os.fdopen(descriptor, 'w') as handle:
    json.dump(record, handle, indent=2, sort_keys=True)
    handle.write('\n')
    handle.flush()
    os.fsync(handle.fileno())
PY
shasum -a 256 "${output}"

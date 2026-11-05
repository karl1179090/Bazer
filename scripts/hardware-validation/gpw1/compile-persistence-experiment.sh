#!/bin/bash
set -euo pipefail

experiment_directory="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
project_directory="$(cd "${experiment_directory}/../../.." && pwd)"
offline=false
requested_output_directory=""
while [[ "$#" -gt 0 ]]; do
    case "$1" in
        --offline)
            if ${offline}; then echo "Repeated --offline" >&2; exit 2; fi
            offline=true
            shift
            ;;
        --output-dir)
            if [[ "$#" -lt 2 || -n "${requested_output_directory}" || "$2" != /* ]]; then
                echo "--output-dir requires one new absolute directory" >&2
                exit 2
            fi
            requested_output_directory="$2"
            shift 2
            ;;
        *)
            echo "Usage: $0 [--offline] [--output-dir /absolute/new/directory]" >&2
            exit 2
            ;;
    esac
done

# Every invocation reserves a new directory. Neither this script nor swiftc can
# overwrite the binaries or evidence from a previous hardware experiment.
if [[ -n "${requested_output_directory}" ]]; then
    if [[ -e "${requested_output_directory}" || -L "${requested_output_directory}" ]]; then
        echo "Refusing existing output directory: ${requested_output_directory}" >&2
        exit 1
    fi
    mkdir -m 700 "${requested_output_directory}"
    output_directory="$(cd "${requested_output_directory}" && pwd -P)"
else
    output_parent="${project_directory}/build/hardware-validation/gpw1"
    mkdir -p "${output_parent}"
    output_directory="$(mktemp -d "${output_parent}/compile-XXXXXXXX")"
fi
echo "Output directory: ${output_directory}"

# Compile/link only. Never execute either generated binary. The isolated SwiftPM
# cache also leaves the already-used release modules/binaries untouched.
scratch_directory="${output_directory}/swiftpm"
xcrun swift build --package-path "${project_directory}" --scratch-path "${scratch_directory}" -c release --target BazerDrivers
module_directory="${scratch_directory}/arm64-apple-macosx/release"
objects=()
for module in BazerCore RazerProtocol LogitechHIDPP BazerHID BazerDrivers; do
    for object in "${module_directory}/${module}.build/"*.swift.o; do
        [[ -f "${object}" ]] || { echo "Missing compiled module objects: ${module}" >&2; exit 1; }
        objects+=("${object}")
    done
done
sources=("${experiment_directory}/GPW1PersistenceExperiment.swift")
flags=("-swift-version" "6" "-parse-as-library" "-target" "arm64-apple-macosx13.0" "-I" "${module_directory}/Modules")
output="${output_directory}/gpw1-persistence-experiment"
if ${offline}; then
    flags+=("-D" "GPW1_OFFLINE_TESTS")
    sources+=("${experiment_directory}/GPW1PersistenceFakeHarness.swift")
    output="${output_directory}/gpw1-persistence-offline"
fi
xcrun swiftc "${flags[@]}" "${sources[@]}" "${objects[@]}" -o "${output}"
shasum -a 256 "${output}"

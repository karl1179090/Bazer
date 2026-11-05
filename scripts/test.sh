#!/bin/bash
set -euo pipefail

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
developer_directory="$(xcode-select -p)"
developer_library="${developer_directory}/Library/Developer"
framework_directory="${developer_library}/Frameworks"

if [[ -d "${framework_directory}/Testing.framework" ]]; then
    # CLT includes official Swift Testing in a non-default location. Both the
    # generated SwiftPM runner and its dlopen helper need these search paths.
    exec xcrun swift test --package-path "${project_root}" \
        --scratch-path "${project_root}/.build/testing" \
        --disable-xctest \
        -Xswiftc -F -Xswiftc "${framework_directory}" \
        -Xlinker -F -Xlinker "${framework_directory}" \
        -Xlinker -rpath -Xlinker "${framework_directory}" \
        -Xlinker -rpath -Xlinker "${developer_library}/usr/lib" \
        "$@"
else
    # A full Swift/Xcode toolchain normally supplies its testing search paths.
    exec xcrun swift test --package-path "${project_root}" "$@"
fi

# Explicit GPW1 persistence experiment

This directory preserves the independently reviewed experiment sources when a source archive excludes `build/`. The two Swift files are byte-for-byte copies of the frozen sources used for the 2026-11-04 experiment. The original used sources, binaries and evidence remain in `build/gpw1-live-2026-11-04/`; this compilation script never replaces them.

Only a human or the explicitly designated root agent may run hardware phases, after reviewing the production modules and tool. This helper does not change the product CLI or its `--restore-original` requirement. It uses production `BatteryMonitor`, `DriverRegistry`, `DeviceController`, exact candidate authorization, profile codecs and private-file APIs.

From the project root, compile for the current arm64 macOS environment:

```sh
bash scripts/hardware-validation/gpw1/compile-persistence-experiment.sh
bash scripts/hardware-validation/gpw1/compile-persistence-experiment.sh --offline
```

Each invocation prints a newly reserved directory under `build/hardware-validation/gpw1/compile-<random>/`. Its executable and isolated SwiftPM build cache live there. The script only builds and links; it never runs any executable. It neither adds hardware work to `scripts/test.sh` nor changes product startup.

For an explicit destination, its parent must already exist and the directory itself must be new. Existing files, directories and final symlinks are refused before compilation:

```sh
bash scripts/hardware-validation/gpw1/compile-persistence-experiment.sh \
  --offline --output-dir /absolute/new/gpw1-offline-build
/absolute/new/gpw1-offline-build/gpw1-persistence-offline --offline-self-test
```

The self-test exits through its dedicated branch and creates only synthetic discovery/protocol backends. It writes disposable private fixture files under the macOS temporary directory, then removes its own directory. It never reads user preferences or constructs a native HID backend. Running this exact self-test is separate from compilation. No production hardware verb is needed for it.

Use the production executable path printed by a separate compilation without `--offline` for a hardware experiment. Every phase requires an explicit verb and a pinned input SHA256. Obtain each digest from the exact reviewed file with `shasum -a 256 <file>`. A source archive need not contain old machine metadata: first obtain and review current diagnostic identity evidence through a separately authorized root-controlled read-only capture. No device host ID, endpoint registry ID, receiver PID, WPID or slot is prefilled in these Swift sources.

```sh
# Human/root only. Substitute the new production executable and reviewed current metadata.
/absolute/new/gpw1-live-build/gpw1-persistence-experiment apply \
  --reference /absolute/reviewed-current-capabilities.json \
  --reference-sha256 '<reviewed-reference-sha256>'

# Human/root only, in a new process after the user-controlled physical power cycle.
/absolute/new/gpw1-live-build/gpw1-persistence-experiment observe \
  --manifest '<absolute-manifest-path-returned-by-apply>' \
  --manifest-sha256 '<manifest-sha256-returned-by-apply>'

# Human/root only, a third explicit process. No phase invokes restore automatically.
/absolute/new/gpw1-live-build/gpw1-persistence-experiment restore \
  --manifest '<absolute-manifest-path-returned-by-apply>' \
  --manifest-sha256 '<manifest-sha256-returned-by-apply>'
```

Keep stdout and stderr as experiment evidence. Before the first setting write, stderr records the new private prepared-intent path and its SHA256. Every backup, intent, manifest and result evidence file is a new user-owned regular 0600 file under `~/Library/Application Support/Bazer/HardwareBackups/gpw1-persistence-<UUID>/`; experiment directories use 0700. Existing files and symlinks are rejected. Ordinary stdout contains hashes, paths, selector, state and comparison results; it does not encode raw units, sessions or profile bytes.

`apply` requires the actual current profile 1, current stage 2 and existing non-current stage 0 at 400 DPI. It checks that 400 and 450 and every restoration value are in the discovered domain, that current/default stage IDs exist, and that the known layout, directory and CRCs are valid. It saves the full original exported regions and uses `prepareProfileRestore` plus the same 8100 candidate authorizer to preflight the complete restoration. It writes only the stage-0 change, requires a verified transaction, then compares every raw region with the expected image produced by the production `HIDPPProfileSector.patch`. Only then does it create `verifiedAwaitingUserPowerCycle`. Any failure leaves available private evidence and performs no retry or automatic recovery.

`observe` adds a session boundary that rejects every `command.isWrite`. It pins the manifest and original/after/reference file hashes before discovery, re-identifies the same unit and firmware/descriptor through current discovery, exports a new full image, and requires profile, directory, info and mode bytes to match the expected after image. The current DPI index may differ after a physical power cycle; that difference is reported and is not silently repaired. `allRegionsMatch` is false when that index differs. The tool always reports `physicalPowerCycleVerifiedByTool: false`.

Root may attach an external user-confirmation record to `observe` with paired `--power-cycle-evidence <absolute-file>` and `--power-cycle-evidence-sha256 <sha256>` options. This records the file reference and hash as an external attestation. The tool does not verify the physical action or turn this record into its own persistence claim.

`restore` requires the current full image to equal either the expected after image or the already-original image, allowing only a separately reported current-index difference. A changed unknown byte, macro, mode, directory, geometry, unit, firmware or descriptor refuses the operation. It uses a new rollback image, `prepareProfileRestore` and exact `.logitechHIDPP8100Profile` authorization. Full original profile/region comparison must pass before an independent runtime request can restore the original current stage 2. An already-original profile/current stage is skipped without a no-op settings probe. The final complete image and safe settings summary must equal the original.

An explicit `restore` can also accept a pinned `prepared-intent.json` when apply could not create its final manifest. The prepared intent is written and fsynced before the first setting write and locates the original private backup. Recovery still requires the current valid complete image to be exactly original or exactly the planned after image; partial writes, changed unknown bytes and uncertain layouts are refused. `observe` requires the final verified manifest. A failed phase never schedules recovery itself.

The offline harness covers the production client/driver/controller with a 255-byte fake memory image, exact padded write plan, fresh process/session identities, read-only observe, restoration after current-index change, zero-write domain/default/weak-unit/unknown-layout rejection, file-hash tampering before discovery, valid-CRC opaque readback drift, no automatic replay/recovery, private file checks and stop/drain. It does not establish real hardware persistence. The source still targets this exact 400→450→400 experiment rather than exposing a general settings editor.

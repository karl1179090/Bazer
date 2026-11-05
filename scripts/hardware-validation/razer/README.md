# Razer 00C5 standalone settings experiment

This runner is separate from the product. Only the root operator executes live
phases. The registry contains one Razer adapter, no Logitech adapter or telemetry
reader. Passive HID enumeration can see other interfaces; no request is sent to
them. No arguments and `--help` return before constructing HIDDiscovery.

Compile only, against the reviewed source snapshot:

```sh
bash scripts/hardware-validation/razer/compile-settings-experiment.sh --offline --source-root /absolute/frozen/Bazer --output-dir /absolute/new-build-directory
/absolute/new-build-directory/razer-settings-offline --offline-self-test
```

The offline executable refuses every hardware phase. Omit `--offline` to compile
the live executable; the compile script never launches a generated executable.
An independent review must precede root-operated live writes.
The XY-version offline build enables Swift testability on its separately compiled
dependencies and injects a nil process-lock factory into its fake HIDDiscovery.
It does not acquire the user's Bazer global flock. This does not alter live
visibility, live locking or the frozen dependency source files. The archived old
offline binary used the real global flock despite sending no real HID reports.

The parent of each output directory must already exist. The runner exclusively
creates a new 0700 directory and 0600 files. Inputs must be user-owned, canonical
regular 0600 files with no symlink components. Every live action has an explicit
hardware flag. Examples below are templates, not commands already executed:

```text
razer-settings-experiment prepare --allow-hardware-read --device <current-selector> --output-dir /private/new-prepare

razer-settings-experiment run --allow-setting-write-and-restore --device <current-selector> --before /private/new-prepare/before.json --before-sha256 <printed-receipt-sha256> --field dpi --original 800 --target 1600 --output-dir /private/new-dpi-test

razer-settings-experiment run --allow-setting-write-and-restore --device <current-selector> --before /private/new-prepare/before.json --before-sha256 <printed-receipt-sha256> --field rate --original 1000 --target 500 --output-dir /private/new-rate-test
```

`prepare` reads settings, exports all 80 stage bytes, captures validated full 90B
DPI/stage responses, and reads the backup-only unit hash. The original document
embeds all evidence and binds both auxiliary files by SHA256. A usable strong
unit hash, exact firmware, descriptor and 1532:00C5 identity are mandatory.
The captured stage layout stays unknown, even with an arbitrary count or IDs.

`run` uses the production DeviceController candidate authorization and typed
RazerMouseDriver transaction. It pre-authorizes restoration of the exact original
before the first write, applies one field, records the result, captures fresh
identity/settings/raw replies, then restores that field with a fresh authorization
and independently captures the final state. There are no raw-setting, stage,
extended-rate, retry or alternate-protocol paths. Original DPI must be symmetric;
DPI values are 100...26000 in steps of 50, and rates are 125/500/1000 Hz.

The independent XY path is explicit and uses only the production
`razer00C5IndependentXY` authorization. It requires both original axes and both
requested axes; it cannot use scalar flags or fall back to unified DPI. For
example, with an actual 800/800 original:

```text
razer-settings-experiment run --allow-setting-write-and-restore --device <current-selector> --before /private/new-prepare/before.json --before-sha256 <exact-sha256> --field xy --original-x 800 --original-y 800 --target-x 800 --target-y 1600 --output-dir /private/new-xy-test
razer-settings-experiment recover --allow-original-value-write --device <fresh-selector> --before /private/new-prepare/before.json --before-sha256 <exact-sha256> --field xy --original-x 800 --original-y 800 --output-dir /private/new-xy-recovery
```

An asymmetric original such as 800/1200 is restored as 800/1200. Both independent
readback axes must match exactly; a single matching axis is a failed XY result.
The complete stage image, rate and all unedited DPI payload bytes are compared.
The original `before.json` schema and auxiliary files are unchanged, so old
read-only prepare evidence can be used by this XY version with its exact SHA256.
The previous four sources are archived separately; old binaries and provenance
remain immutable and do not gain independent XY support.

If the test result is unverified, the runner stops without speculative restoration.
If a receipt save fails after a verified test, it still attempts the already
authorized restoration, then reports failure and refuses to promote the run.
Failed restoration stops immediately without retry. The private before evidence
survives process exit and supports a one-way recovery:

```text
razer-settings-experiment recover --allow-original-value-write --device <fresh-current-selector> --before /private/new-prepare/before.json --before-sha256 <exact-sha256> --field dpi --original 800 --output-dir /private/new-recovery
```

`recover` validates the complete original evidence and hashes before constructing
HID. It checks the current strong unit, firmware and descriptor, preserves all
unedited DPI bytes and unrelated settings, and writes the explicitly named original
field once. It never restores the experiment value afterwards. Stage differences
can be observed and reported, but cannot authorize stage writes. A firmware-linked
stage change during a test makes `fullStageUnchanged` false even if restoring DPI
also restores the stage image. That run cannot prove unchanged-stage behavior.

For a physical power-cycle experiment, append `--hold-for-power-cycle` to a `run`.
It writes one field, independently reads it back, saves evidence and exits with
`originalRestored:false` and an explicit pending-recovery state. The root operator
then performs the real OFF/unplug/ON/replug actions. A new process can inspect it:

```text
razer-settings-experiment verify --allow-hardware-read --device <fresh-selector> --before /private/new-prepare/before.json --before-sha256 <exact-sha256> --field dpi --original 800 --target 1600 --output-dir /private/new-post-cycle-read
```

`verify` never writes. It verifies the held value and compares identity, all stage
bytes, unrelated fields and unedited DPI payload. It does not attest that physical
power removal actually occurred; that requires the operator's separate evidence.
Finally invoke `recover`. Run each field as its own cycle, or prepare a new complete
baseline before editing a second field; unrelated drift is rejected.

For one combined physical cycle, first hold XY using baseline A, prepare a new
baseline B containing that asymmetric XY pair and the original rate, then hold
rate using B. After the actual physical cycle, `verify` B's rate also requires
both XY axes to equal B. Recover B's rate first, then recover A with `--field xy`.
This preserves strict single-field requests and restores in reverse order.

Standard output contains only a safe state, selector, private evidence path/hash,
write count and comparison booleans. Full raw payloads stay in private files.
Controller results provide validated ACK/readback outcomes; this runner does not
claim an external raw TX/RX trace, and never fabricates ACK frames. A storage-1
readback is not a physical persistence claim (`persistenceVerified` stays false).

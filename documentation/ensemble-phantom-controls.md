# Ensemble FireWire phantom controls

Development branch: `feature/ensemble-native-controls`. Upstream design discussion:
https://github.com/mrmidi/ASFireWire/issues/269.

The original Ensemble (`0x0003db` / `0x01eeee`, AV/C unit specifier
`0x00a02d`, version `0x010001`) gets four input strips in Device Controls.
Each strip has explicit **48V On** and **48V Off** actions. Both the Console
and Parameters presentations use the normal generic control model and write path.
The previous experimental Advanced Tools shortcut is removed on this branch.

## Why actions rather than a lit toggle

Phantom state and input-mode readback are not established. The ALSA behavioral
reference `protocols/bebob/src/apogee/ensemble.rs` documents `MicPower` (E5,
zero-based channel, boolean; lines 1272–1274), mandatory padding (1679–1688),
and write-only cached parameter updates (879–907). Its hardware meter decoding
(1011–1051) does not establish phantom readback. Do not synthesize a STATUS
query, apply defaults on connection, or label an accepted command as observed state.

Reference (behavior only; no code copied):
https://github.com/alsa-project/snd-firewire-ctl-services/blob/master/protocols/bebob/src/apogee/ensemble.rs

`EnsembleControls` publishes eight `ActionDomain` parameters with phantom-power
semantics and no remembered values. The standard `ControlService` validates the
snapshot revision and parameter type. The provider sends one command only after an
explicit action, requires the complete accepted echo observed during the hardware
test, and returns an action completion. It does not queue overlapping requests or
retry failed actions. Rebinding/detaching invalidates outstanding completions.
Opening, preparing, refreshing, and binding the provider perform no hardware I/O.
CoreAudio boolean controls are not published without observed boolean state.

The controls use the existing generic AV/C streaming implementation, selected by
an exact catalog identity. No transport, clock, mixer, gain, input-mode, or audio
streaming changes are introduced. The provider intentionally exposes only the
four mic inputs' phantom actions; it does not claim full Ensemble mixer support.

## Hardware evidence and limits

The owner verified one Mic 4 ON/OFF cycle using the **installed ASFW 0.6.0 build 33
app's raw AV/C interface**, with Logic stopped, monitoring muted and Mic 4
disconnected. Inputs 1–3 were already ON; Mic 4 began and ended OFF.

| Action | Request | Accepted response |
| --- | --- | --- |
| Mic 4 ON | `00 FF 00 00 03 DB E5 03 01 FF FF FF` | `09 FF 00 00 03 DB E5 03 01 FF FF FF` |
| Mic 4 OFF | `00 FF 00 00 03 DB E5 03 00 FF FF FF` | `09 FF 00 00 03 DB E5 03 00 FF FF FF` |

The owner confirmed the physical indicator after each action. The installed driver
reports `de0cc7e DIRTY`; exact source parity is unestablished. This test does not
validate the new provider, new buttons, other channels, input-mode handling,
reconnect behavior, or post-test recording. No new hardware commands were sent
while developing this implementation.

## Build and test without installation

Keep `ASFW_HARDWARE_FREE_TESTS=1` in the shared test plan. The test host skips the
production UI and refuses driver connections. Build with signing disabled using
`xcodebuild build-for-testing`, then run `test-without-building`. Do not use Run,
Activate, Install, or the driver's install scripts for this development check.
The new C++ `EnsembleControlsTests` uses a fake AV/C unit; it never opens a driver.
The Swift console-layout/render tests use a fake control source.

For a future hardware test, a properly signed build containing this driver-side
provider is required. The installed 0.6.0 driver cannot acquire it from an app-only
update. Keep the working installation until the user separately approves a
replacement/test environment and rollback plan. A spare Mac or maintainer-signed
release is preferable for initial end-to-end testing. Verify each input's physical
indicator, failure/disconnect handling, and Logic recording before claiming full
hardware support. Do not infer phantom state from a successful command reply.

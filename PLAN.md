# Sound Radar: exact source and per-app volume

Goal: see exactly where every sound comes from (app, window, browser tab, display, desktop) and set each app's volume, in a Liquid Glass macOS 26 interface.
Design: https://claude.ai/artifact/25hghm6qx7ucWKAGgP3ujL (Radar window, Source detail, Menu bar mixer, Permissions).
Seams: `Sources/SoundRadar/Contracts.swift` (`AudioMixing`, `SoundLocating`). The model (`RadarModel.swift`) already calls them.

## Slices (parallel, disjoint files)

| Lane | Owns | Delivers | Blocked by |
|---|---|---|---|
| L1 mixer | `Sources/SoundRadar/Audio/`, `Tests/`, `Package.swift`, `build.sh` | `AppAudioMixer: AudioMixing`: process taps, live levels, 0-150% volume, mute, device-change recovery, Info.plist usage strings, unit tests for the pure math | none |
| L2 locator | `Sources/SoundRadar/Locate/` | `SoundLocator: SoundLocating`: window titles (Accessibility), desktop status (all Spaces), browser tab title and URL (AppleScript), jump to window or tab | none |
| L3 interface | `Sources/SoundRadar/Views.swift`, `Sources/SoundRadar/UI/`, `SoundRadarApp.swift` | Liquid Glass radar window, mixer strips with meters, source detail, menu bar mixer, permissions sheet | none (builds against Null* seams) |
| L0 integrate | `RadarModel.swift`, `Contracts.swift`, this file | wire real types, build, run, screenshot, review | L1, L2, L3 |

## Done when
- A playing app shows its window and tab name and desktop; "Go to" brings that exact window or tab forward.
- Each playing app has a live meter and a 0-150% volume slider that audibly changes it; mute works; volumes survive a device switch.
- Builds clean with `./build.sh`; unit tests pass with `swift test`.

## Completion plan (2026-10-08)

State: L1-L3 merged and wired (`81d9b96`); `swift build` clean, 17 tests green, app runs. Not yet proven on live audio: needs the operator's permission grants.

| Step | Owner | Work | Proof |
|---|---|---|---|
| 1 Live test | operator grants, L0 drives | slider 50/0/150 %, meter, mute, solo, output switch, Arc tab + Go to, other desktop, quit restores sound | screenshots + listening |
| 2a Audio quality | lane LA | no click when leaving 100 % (stay in processing mode once touched), ramp from real sample rate, mic-skip test | `swift test`, mutation |
| 2b Locator tests | lane LB | tests for window pick, desktop status, AppleScript escaping, tab reply parsing | `swift test`, mutation |
| 2c Interface polish | lane LC | map fills the space, window/tab names in chips, output device name, master volume, off-desktop sources | build + screenshot |
| 3 Close | L0 | two-pass review, `./build.sh`, tests, this file marked done | final screenshots |

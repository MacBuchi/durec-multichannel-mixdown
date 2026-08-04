# Changelog

All notable changes to DurecMix. Version scheme: `MAJOR.MINOR.PATCH`, kept in
`pubspec.yaml`; every version bump merged to `main` automatically tags,
releases and ships the artifacts. The app bundles this file and shows it under
**About → What's new**.

## [0.18.3] – 2026-08-04

### Changed

- **The start ramp is 50 ms now.** The 10 ms ramp from 0.18.2 killed the
  click, but on the device the first moment of playback still felt abrupt.
  Tuned by ear to 50 ms: playback eases in, and it still reads as "playback
  starts", not as a fade-in.

## [0.18.2] – 2026-08-04

### Fixed

- **Scrubbing the timeline is smooth now.** Dragging the position slider used
  to jump playback on every tick of the gesture — dozens of restarts per
  drag, audible as a stutter of noises. The slider and the time readout now
  follow the finger while the mix keeps playing where it was, and the single
  jump happens when you let go.
- **Play and seek no longer click.** Starting playback drops the needle
  mid-waveform, and that first sample is a step you could hear even on a
  clean mix. A 10 ms ramp now eases playback in — far too short to hear as a
  fade-in, long enough to take the click out. Exports are untouched: the ramp
  exists only in the live preview.

## [0.18.1] – 2026-08-04

### Changed

- **Ready for recordings with a few hundred tracks.** Some interfaces record
  far more than the 34 channels this app was built against, and a multisample
  recording can reach several hundred. Two places did work that grew with the
  square of the track count — invisible at 34, the dominant cost at 200. Mixing
  now stays comfortable there, and moving a fader stays instant.

## [0.18.0] – 2026-08-04

### Added

- **A bug report now brings the evidence with it.** When something goes wrong,
  the app writes down what happened; reporting a bug attaches those last
  entries, so a problem can be traced instead of guessed at. Paths are
  shortened so your user name is not part of it, and it only happens on a bug
  report, never on a feature request — the dialog says so before you send.
- **Nothing goes unnoticed any more.** Unexpected errors anywhere in the app are
  recorded from now on, including the ones that used to disappear silently.

### Fixed

- **Reports filed from the browser had no platform.** The form offered macOS,
  Windows, Android and iOS — a report from the web version quietly arrived with
  that field empty. It has said "Web" since this release.

## [0.17.0] – 2026-08-04

### Added

- **A level meter on every track.** A thin vertical bar next to each fader,
  with the same scale and colours as the master meter, so "hot" means the same
  thing in both places.
- **Switchable between what arrives and what you send.** The small **pre** /
  **post** button next to the loudness target flips all of them: *post* shows
  what the track contributes to the mix (the default), *pre* shows what arrives
  on it regardless of where its fader sits — that is the one for finding a
  silent or an overloaded channel.
- **A muted track keeps showing its level, greyed out.** Muting is exactly when
  you want to see that there is signal there.
- The bars follow the track's EQ, and hold a peak briefly so a short one is
  visible at all.

## [0.16.0] – 2026-08-04

### Added

- **Export several takes at once in the browser.** Tick the takes in the file
  list, edit their names, press Export — the current mix is applied to each one
  and every finished mixdown is downloaded as soon as it is ready.
- Downloading each file as it finishes rather than everything at the end means
  a cancelled run keeps what it already produced.
- Because a browser is not allowed to write into a folder of your choosing,
  there is no `Mixdown/` subfolder there; the files land wherever your browser
  puts downloads. On iPhone and iPad Safari asks once per file.

With this, everything the installed app does is available in the browser except
MP3 export.

## [0.15.0] – 2026-08-04

### Added

- **Reference mastering now works in the browser.** Pick a commercial song as
  a reference, and your mix is matched to it exactly as the installed app does
  — the exported file is bit-for-bit the same one the app would have written.
- **Including the mastered preview:** switch it on and you hear the matched
  sound before exporting, on a tablet too.
- Once analyzed, a reference is remembered: after a reload the app reuses what
  it learned about that song instead of reading it again.

## [0.14.0] – 2026-08-04

### Added

- **In the browser, your work now survives a reload.** Mixes, the appearance
  setting, the waveform caches and the reference profiles are kept in the
  browser instead of only for as long as the tab is open. Come back tomorrow,
  choose the same recording again, and your mix is exactly where you left it.
- The recording itself cannot be kept — a browser is not allowed to hold on to
  a file you picked, so you do choose it again after a reload. The mix finds
  its way back on its own, by the file's name.
- **Settings now says which of the two you are getting.** In a private window
  a browser stores nothing at all; rather than quietly losing your mix, the
  dialog tells you so.

## [0.13.3] – 2026-08-03

### Fixed

- **The last few dropouts while dragging a fader in the browser.** 0.13.1
  sized the buffer from how fast the device mixes, and that was still not
  enough on the iPad. Two reasons. The audio was briefly spliced: while the
  app asked the engine to go back and re-mix, the loader could slip in one
  more block from where it had been reading — a second further into the
  recording — so you heard a jump forward and then back. And the buffer was
  sized from an average round, which a browser can exceed once at any time,
  for instance while it lays out the channel strips under your finger.
- The buffer therefore no longer only predicts, it also learns: every dropout
  raises it a little and a clean move gives that back, so a device settles on
  the buffer it really needs instead of the one it was expected to need.
- **Settings → Playback diagnostics** now also shows that buffer, so a device
  that still clicks can say by how much it is off.

## [0.13.2] – 2026-07-27

### Added

- **Hear what you will get: preview at export level.** The headphones button
  next to the loudness target plays the mix at the level the exported file
  will have. Until now the preview left out the gain the export applies — on
  a DUREC take that is around 17 dB, so the limiter worked flat out and the
  preview sounded nothing like the result. Switching it on measures the mix
  once; after that the meters show the delivered signal.
- Change the mix afterwards and the button turns amber: the measurement no
  longer fits. The sound stays as it is — a level that jumped on every fader
  move would be worse — and a tap measures again.

## [0.13.1] – 2026-07-27

### Fixed

- **No more clicks when you drag a fader in the browser.** To make a fader
  move audible right away, the app throws away the audio it had already
  mixed and mixes it again — but it kept a fixed amount of sound to play
  while doing so, and on a tablet mixing 34 channels that ran out before the
  replacement arrived. It now measures how fast the device actually mixes and
  keeps as much as that device needs; where even that is not enough, your
  change simply takes effect a moment later instead of tearing a hole into
  playback. Nothing changes on a fast machine.
- Settings now shows how often playback ran dry and how fast this device
  mixes — the numbers to send along when browser playback stutters.

## [0.13.0] – 2026-07-27

### Added

- **DurecMix now runs in a browser.** Open a recording from the DUREC stick,
  see all its tracks, mix, listen, and export a stereo file — no install, on
  a tablet too. The same audio engine as the app does the work, and the
  exported file is bit-for-bit what the installed app would have produced.
  Tested with a 1.35 GB, 34-track take on an iPad.
- **It works offline.** After the first visit the page starts without a
  network, and your recordings never leave the device — there is no upload,
  the file is read straight from your disk.
- **Export can be cancelled** while it renders.

### Known limits in the browser

- Nothing survives a reload yet: mixes, settings and caches are kept in
  memory only.
- Multi-file export, reference mastering and MP3 are app-only for now. Where
  a feature is missing, its button is gone or says so instead of failing
  silently.
- On slower tablets, dragging a fader during playback can click.

## [0.12.16] – 2026-07-27

### Changed

- **Every track of a new recording now starts in the mix.** Until now the app
  quietly left out channels whose names looked like monitor feeds — In Ear,
  Phones, Talkback, Line Out, Monitor — and never said so, which made faders
  look broken for no visible reason. Track names are yours to choose, they
  come from your interface configuration, so no name decides anything any
  more. Monitor and cue buses still don't belong in a mixdown: take them out
  with the **mix** chip, and the choice is remembered per take.

## [0.12.15] – 2026-07-25

### Added

- **The app now tells you what changed:** this changelog ships inside the app
  — "What's new" in the About dialog lists every version's changes.

## [0.12.14] – 2026-07-23

### Fixed

- **Android playback works again on the modern audio stack.** The app now
  hands the Android context to the audio engine at startup, which the AAudio
  backend of cpal 0.18 requires — missing it was the crash behind
  0.12.10–0.12.12. An on-device playback regression test guards this.

### Changed

- Audio backend back on cpal 0.18 (0.12.13 had reverted to 0.16).

## [0.12.13] – 2026-07-22

### Fixed

- **Play works again on Android:** reverted the audio backend to cpal 0.16 —
  since 0.12.10 every play tap crashed the app.

## [0.12.12] – 2026-07-21

### Changed

- Internal: the whole codebase is reformatted (tall style) and CI enforces it.
  No user-facing change.

## [0.12.11] – 2026-07-21

### Fixed

- **Mastering reference files decode again** after the 0.12.10 dependency
  update: the reference decoder migrated to Symphonia 0.6.

## [0.12.10] – 2026-07-21

### Changed

- Dependency updates (cpal 0.18, quick-xml) and Dependabot enabled. **This
  release broke Android playback** — fixed in 0.12.13/0.12.14.

## [0.12.9] – 2026-07-20

### Added

- **Open-source licenses in the About dialog,** Rust crates included.

## [0.12.8] – 2026-07-20

### Changed

- The start-screen logo animates continuously.

## [0.12.7] – 2026-07-20

### Fixed

- **One folder control on the start screen — and it asks** before replacing
  the current folder.

## [0.12.6] – 2026-07-20

### Added

- **Light, dark or system appearance,** switchable behind the new settings
  gear.

## [0.12.5] – 2026-07-20

### Fixed

- The feedback bar stays visible until it is dismissed.

## [0.12.4] – 2026-07-20

### Fixed

- **Android in-app update installs again:** the app crashed right after the
  update download because a FileProvider declaration was missing.

## [0.12.3] – 2026-07-20

### Fixed

- **Update check and feedback work on macOS:** the sandbox now allows
  outbound network.

### Added

- MIT license and acknowledgements (Matchering clean-room reimplementation,
  third-party notices).

## [0.12.2] – 2026-07-20

### Changed

- Internal code-health cleanup (issues #45–#51).

## [0.12.1] – 2026-07-19

### Added

- **About dialog:** installed version, update status, GitHub link and a
  feedback shortcut.

## [0.12.0] – 2026-07-19

### Added

- **In-app feedback and update notification:** file a feature request or bug
  report straight from the app; a banner appears when a newer release is out.

## [0.11.1] – 2026-07-19

### Added

- **User guide** with annotated screenshots, generated by a reproducible
  pipeline.

## [0.11.0] – 2026-07-19

### Added

- **Multi-reference mastering:** average several reference songs into one
  target.

## [0.10.0] – 2026-07-18

### Added

- **Mastered playback preview:** hear the reference-matched sound before
  exporting.

### Fixed

- The transport bar keeps a constant height.

## [0.9.0] – 2026-07-18

### Added

- **Reference mastering:** match the export to a reference track
  (WAV/FLAC/MP3/OGG) in loudness, tonality and stereo width — a clean-room
  Rust reimplementation of the Matchering approach.

### Fixed

- **FLAC exports pass strict decoders:** STREAMINFO declared a wrong minimum
  block size, so some decoders refused the files.

## [0.8.2] – 2026-07-18

### Fixed

- UX-walkthrough fixes: analysis cache, visible export target, probe resume,
  collision-safe output names.

## [0.8.1] – 2026-07-17

### Added

- Browser selection mode and editable output names.

## [0.8.0] – 2026-07-17

### Added

- **Multi-file export:** tick several takes in the browser and render them
  all with the current mix into a Mixdown/ folder — with the system share
  sheet on Android.

## [0.7.4] – 2026-07-16

### Added

- The animated logo doubles as a playback indicator.

## [0.7.3] – 2026-07-16

### Fixed

- The loading animation is actually visible.

## [0.7.2] – 2026-07-16

### Fixed

- **Stable Android release signing:** downloaded APKs update the existing
  installation instead of failing with a signature mismatch. Final app id
  de.macbuchi.durecmix — this release required a one-time reinstall.

## [0.7.1] – 2026-07-16

### Changed

- **No separate start screen:** the app opens straight into the browser, with
  an animated loading logo.

## [0.7.0] – 2026-07-15

### Added

- **In-app WAV browser:** folder listing with take metadata and instant take
  switching.

## [0.6.2] – 2026-07-12

### Added

- App logo and platform icons.

## [0.6.1] – 2026-07-12

### Fixed

- A/B snapshot overwrite is always possible.

## [0.6.0] – 2026-07-12

### Added

- **Batch export queue** (desktop): several targets/formats in one run.
- **iOS Files picker** with in-place security-scoped access.
- **Phone layout:** overflow-menu app bar and two-row transport.
- **Background export:** Android foreground service, iOS background task.
- Per-pair unlink for stereo-pair linking.

### Changed

- Releases are tagged and published automatically on version bump.

## [0.5.1] – 2026-07-12

### Added

- **A/B mix snapshots:** store and recall two mixes from the app bar.
- **Stereo-pair linking** (default on) and monitor-feed auto-exclusion on
  fresh sessions.

## [0.5.0] – 2026-07-12

### Added

- **Android SAF support:** open, analyze, play and export directly via file
  descriptors — no copying of multi-GB files.

## [0.4.0] – 2026-07-12

### Added

- **FLAC and MP3 export** (streaming).
- **Trim in/out with fades, BPM detection** and export filename templating.

## [0.3.0] – 2026-07-12

### Added

- **First release. Engine core:** streaming WAV/RF64/BW64 reader, iXML track
  names, constant-power pan, mix bus (solo/mute/polarity/in-mix), two-pass
  peak-normalised render.
- **Live playback** with meters (peak, LUFS, correlation), streaming
  waveforms and the full mixer UI.

[0.18.3]: https://github.com/MacBuchi/durec-multichannel-mixdown/releases/tag/v0.18.3
[0.18.2]: https://github.com/MacBuchi/durec-multichannel-mixdown/releases/tag/v0.18.2
[0.18.1]: https://github.com/MacBuchi/durec-multichannel-mixdown/releases/tag/v0.18.1
[0.18.0]: https://github.com/MacBuchi/durec-multichannel-mixdown/releases/tag/v0.18.0
[0.17.0]: https://github.com/MacBuchi/durec-multichannel-mixdown/releases/tag/v0.17.0
[0.16.0]: https://github.com/MacBuchi/durec-multichannel-mixdown/releases/tag/v0.16.0
[0.15.0]: https://github.com/MacBuchi/durec-multichannel-mixdown/releases/tag/v0.15.0
[0.14.0]: https://github.com/MacBuchi/durec-multichannel-mixdown/releases/tag/v0.14.0
[0.13.3]: https://github.com/MacBuchi/durec-multichannel-mixdown/releases/tag/v0.13.3
[0.13.2]: https://github.com/MacBuchi/durec-multichannel-mixdown/releases/tag/v0.13.2
[0.13.1]: https://github.com/MacBuchi/durec-multichannel-mixdown/releases/tag/v0.13.1
[0.13.0]: https://github.com/MacBuchi/durec-multichannel-mixdown/releases/tag/v0.13.0
[0.12.16]: https://github.com/MacBuchi/durec-multichannel-mixdown/releases/tag/v0.12.16
[0.12.15]: https://github.com/MacBuchi/durec-multichannel-mixdown/releases/tag/v0.12.15
[0.12.14]: https://github.com/MacBuchi/durec-multichannel-mixdown/releases/tag/v0.12.14
[0.12.13]: https://github.com/MacBuchi/durec-multichannel-mixdown/releases/tag/v0.12.13
[0.12.12]: https://github.com/MacBuchi/durec-multichannel-mixdown/releases/tag/v0.12.12
[0.12.11]: https://github.com/MacBuchi/durec-multichannel-mixdown/releases/tag/v0.12.11
[0.12.10]: https://github.com/MacBuchi/durec-multichannel-mixdown/releases/tag/v0.12.10
[0.12.9]: https://github.com/MacBuchi/durec-multichannel-mixdown/releases/tag/v0.12.9
[0.12.8]: https://github.com/MacBuchi/durec-multichannel-mixdown/releases/tag/v0.12.8
[0.12.7]: https://github.com/MacBuchi/durec-multichannel-mixdown/releases/tag/v0.12.7
[0.12.6]: https://github.com/MacBuchi/durec-multichannel-mixdown/releases/tag/v0.12.6
[0.12.5]: https://github.com/MacBuchi/durec-multichannel-mixdown/releases/tag/v0.12.5
[0.12.4]: https://github.com/MacBuchi/durec-multichannel-mixdown/releases/tag/v0.12.4
[0.12.3]: https://github.com/MacBuchi/durec-multichannel-mixdown/releases/tag/v0.12.3
[0.12.2]: https://github.com/MacBuchi/durec-multichannel-mixdown/releases/tag/v0.12.2
[0.12.1]: https://github.com/MacBuchi/durec-multichannel-mixdown/releases/tag/v0.12.1
[0.12.0]: https://github.com/MacBuchi/durec-multichannel-mixdown/releases/tag/v0.12.0
[0.11.1]: https://github.com/MacBuchi/durec-multichannel-mixdown/releases/tag/v0.11.1
[0.11.0]: https://github.com/MacBuchi/durec-multichannel-mixdown/releases/tag/v0.11.0
[0.10.0]: https://github.com/MacBuchi/durec-multichannel-mixdown/releases/tag/v0.10.0
[0.9.0]: https://github.com/MacBuchi/durec-multichannel-mixdown/releases/tag/v0.9.0
[0.8.2]: https://github.com/MacBuchi/durec-multichannel-mixdown/releases/tag/v0.8.2
[0.8.1]: https://github.com/MacBuchi/durec-multichannel-mixdown/releases/tag/v0.8.1
[0.8.0]: https://github.com/MacBuchi/durec-multichannel-mixdown/releases/tag/v0.8.0
[0.7.4]: https://github.com/MacBuchi/durec-multichannel-mixdown/releases/tag/v0.7.4
[0.7.3]: https://github.com/MacBuchi/durec-multichannel-mixdown/releases/tag/v0.7.3
[0.7.2]: https://github.com/MacBuchi/durec-multichannel-mixdown/releases/tag/v0.7.2
[0.7.1]: https://github.com/MacBuchi/durec-multichannel-mixdown/releases/tag/v0.7.1
[0.7.0]: https://github.com/MacBuchi/durec-multichannel-mixdown/releases/tag/v0.7.0
[0.6.2]: https://github.com/MacBuchi/durec-multichannel-mixdown/releases/tag/v0.6.2
[0.6.1]: https://github.com/MacBuchi/durec-multichannel-mixdown/releases/tag/v0.6.1
[0.6.0]: https://github.com/MacBuchi/durec-multichannel-mixdown/releases/tag/v0.6.0
[0.5.1]: https://github.com/MacBuchi/durec-multichannel-mixdown/releases/tag/v0.5.1
[0.5.0]: https://github.com/MacBuchi/durec-multichannel-mixdown/releases/tag/v0.5.0
[0.4.0]: https://github.com/MacBuchi/durec-multichannel-mixdown/releases/tag/v0.4.0
[0.3.0]: https://github.com/MacBuchi/durec-multichannel-mixdown/releases/tag/v0.3.0

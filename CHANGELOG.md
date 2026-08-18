# Changelog

All notable changes to Mixstack. Version scheme: `MAJOR.MINOR.PATCH`, kept in
`pubspec.yaml`; every version bump merged to `main` automatically tags and
builds a release, but it stays a prerelease — invisible to the update check —
until someone runs the Promote workflow by hand. The app bundles this file
and shows it under **About → What's new**.

## [0.20.5] – 2026-08-19

### Changed

- **Updates now arrive in batches instead of after every single change.**
  New versions still get built right away, but the in-app update check (and
  the GitHub release page) only shows a version once it's been reviewed and
  promoted — usually bundling a few changes together instead of prompting
  you every day. Nothing about how you install an update changes.

## [0.20.4] – 2026-08-18

### Changed

- **The Android package id changed again**, from `de.macbuchi.mixstack` to
  `de.mcbuchi.mixstack` — a typo from the original rename, corrected before
  any store listing locked it in.
- ⚠️ **Same consequence as the last package id change: on Android, this one
  takes your saved mixes with it.** The new version installs alongside the
  old one instead of replacing it; your takes and their WAV files are
  untouched, but the mixes stored inside the app do not come along. Export
  anything you want to keep first, then remove the old version. macOS,
  Windows, iOS and the browser are unaffected.

## [0.20.3] – 2026-08-18

### Fixed

- **The links inside the app point at the right place again.** The project
  moved to a new address to match the app's name. Links to the project itself
  keep working from anywhere, but the browser version and the privacy notice
  moved with it — if you had the browser version bookmarked, it now lives at
  https://macbuchi.github.io/mixstack/

## [0.20.2] – 2026-08-17

### Changed

- **Updated the building blocks the app is made of** — among them the decoder
  that reads a reference song. Nothing you can see.

## [0.20.1] – 2026-08-17

### Changed

- Housekeeping only — nothing you can see or notice.

## [0.20.0] – 2026-08-15

### Changed

- **The app is now called Mixstack.** It was DurecMix, and that name claimed
  more than it should have: DUREC is RME's name for their recorder, not ours
  to build a product name from — and it was never accurate either, because
  the engine reads any interleaved multichannel WAV (RIFF, RF64, BW64, at any
  channel count), whether it came off an RME interface, a Zoom or Sound
  Devices field recorder, or a multitrack export from a DAW. The recorder is
  still named where it belongs, in the description of what the app opens.
- ⚠️ **If you already have the app on Android, this one takes your saved
  mixes with it.** Android ties an app's storage to its package id, and that
  id had to change with the name — so the new version installs alongside the
  old one instead of replacing it. Your takes and their WAV files are
  untouched, but the mixes stored inside the app do not come along and have
  to be set up again. Export anything you want to keep first, then remove the
  old version. A fresh install is unaffected, and so are macOS, Windows, iOS
  and the browser: they keep everything.

### Added

- **Groundwork for a store release.** Nothing about using the app changes —
  the store edition simply receives its updates through the store.

## [0.19.0] – 2026-08-05

### Added

- **MP3 export works in the browser now.** It was the last thing the web
  version could not do. The catch is worth knowing: the encoder the apps use
  (LAME) is C and cannot be built for the browser at all, so the browser
  encodes with Shine instead. Same 320 kbps, but a simpler encoder without a
  psychoacoustic model — measured against white noise, the hardest case, it
  lands about a decibel off where LAME stays within half of one. Good enough
  to send someone a rough mix from the iPad; for a master, export from the
  app or choose FLAC. The app says as much where you pick the format and
  under Settings, rather than quietly handing you a different file.

### Fixed

- **An impossible export target now fails immediately.** Choosing MP3 for a
  recording the browser's encoder cannot handle (anything but 32, 44.1 or
  48 kHz) used to be discovered only after the whole recording had been
  measured. It is refused before the work starts, and says which formats do
  work.

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

- **Mixstack now runs in a browser.** Open a recording from the DUREC stick,
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

- **Playing a mix on Android works again — properly this time.** Versions
  0.12.10 to 0.12.12 crashed the moment you pressed play, because the audio
  part of the app was never told which Android it was running on. It is told
  now, and a test that runs on a real phone makes sure it stays that way. The
  quick workaround from 0.12.13 is gone; the app is back on the current audio
  system.

## [0.12.13] – 2026-07-22

### Fixed

- **Pressing play no longer crashes the app on Android.** Since 0.12.10 it
  did, every time. This is the quick fix — the real one follows in 0.12.14.

## [0.12.12] – 2026-07-21

### Changed

- Housekeeping only — nothing you can see or notice.

## [0.12.11] – 2026-07-21

### Fixed

- **Reference songs can be read again.** The update in 0.12.10 had broken
  it, so mastering to a reference refused to start.

## [0.12.10] – 2026-07-21

### Changed

- Updated the building blocks the app is made of. ⚠️ **This release broke
  playback on Android** — repaired in 0.12.13 and properly in 0.12.14.

## [0.12.9] – 2026-07-20

### Added

- **The licences of everything the app is built from** are now readable
  inside the app, under About.

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

- **Updating on Android no longer fails at the last moment.** The app closed
  itself right at the end of an update instead of finishing it.

## [0.12.3] – 2026-07-20

### Fixed

- **On macOS the app can reach the internet again**, so checking for a newer
  version and sending a wish or a bug report actually go through.

### Added

- The project's licence and its acknowledgements — including where the
  reference-mastering idea comes from.

## [0.12.2] – 2026-07-20

### Changed

- Housekeeping only — nothing you can see or notice.

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

- **A user guide** that walks through every screen, with numbered
  screenshots.

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

- **Reference mastering.** Point the app at a song you like — any WAV, FLAC,
  MP3 or OGG — and your export is matched to it: how loud it is, how bright or
  warm it sounds, and how wide the stereo image sits.

### Fixed

- **Exported FLAC files are accepted everywhere now.** They carried a wrong
  entry in their header, and stricter players refused to open them.

## [0.8.2] – 2026-07-18

### Fixed

- Four annoyances from a walk through the app: switching between takes no
  longer re-analyses what was already analysed, the loudness and format you
  are about to export to are visible instead of hidden in a menu, the file
  list carries on scanning after an export, and a second export no longer
  silently overwrites the first.

## [0.8.1] – 2026-07-17

### Added

- **Picking several takes is its own mode now**, so the file list reads as a
  list again — and you can rename each file before exporting it.

## [0.8.0] – 2026-07-17

### Added

- **Export several takes in one go.** Tick them in the file list and the
  current mix is applied to each one, all landing in a `Mixdown` folder. On
  Android you can hand the results straight to another app afterwards.

## [0.7.4] – 2026-07-16

### Added

- The animated logo doubles as a playback indicator.

## [0.7.3] – 2026-07-16

### Fixed

- The loading animation is actually visible.

## [0.7.2] – 2026-07-16

### Fixed

- **Updating on Android works from here on.** Until now every update refused
  to install over the existing copy, and the app had to be removed first.
  Getting to this version still needs that once — after it, updates simply
  replace what is there.

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

- The A and B mix snapshots can always be overwritten, not only sometimes.

## [0.6.0] – 2026-07-12

### Added

- **Several exports in one run** on the desktop — different loudness targets
  and formats queued up, one after the other.
- **Opening recordings on iOS** through the Files app, read where they lie
  rather than copied first.
- **A layout made for phones:** the controls that do not fit move into a menu,
  and the transport sits on two rows.
- **Exporting continues when you leave the app**, with the progress shown as
  a notification.
- Linked stereo pairs can be unlinked one pair at a time.

### Changed

- New versions are published automatically, so a fix reaches you as soon as
  it is finished.

## [0.5.1] – 2026-07-12

### Added

- **Two mixes side by side.** Store one as A and one as B and flip between
  them to compare.
- **Stereo pairs move together** — a fader, a mute or an EQ on one side
  applies to both, and the panorama mirrors.

## [0.5.0] – 2026-07-12

### Added

- **Recordings open straight off a USB stick on Android**, without being
  copied first. A take of several gigabytes would otherwise have to be
  duplicated onto the phone before anything could happen.

## [0.4.0] – 2026-07-12

### Added

- **Export as FLAC or MP3**, not only WAV.
- **Trim the start and the end**, with a short fade so the cut is not audible.
- **The tempo is detected** and can go into the file name, along with the take
  name, the loudness target and the date.

## [0.3.0] – 2026-07-12

### Added

- **The first version.** Open a multichannel WAV recording, see every track
  with the name the recorder gave it, and mix: fader, panorama, polarity,
  solo, mute, and a switch for whether a track belongs in the mix at all. The
  recording is read in pieces instead of being loaded whole, so a take of
  several gigabytes opens without filling the memory. The result is written
  as a stereo WAV, levelled so the loudest peak sits just under the maximum.
- **Listen while you mix**, with meters for level, loudness and how well the
  two sides of the stereo image agree — plus a waveform on every track.

[0.20.5]: https://github.com/MacBuchi/mixstack/releases/tag/v0.20.5
[0.20.4]: https://github.com/MacBuchi/mixstack/releases/tag/v0.20.4
[0.20.3]: https://github.com/MacBuchi/mixstack/releases/tag/v0.20.3
[0.20.2]: https://github.com/MacBuchi/mixstack/releases/tag/v0.20.2
[0.20.1]: https://github.com/MacBuchi/mixstack/releases/tag/v0.20.1
[0.20.0]: https://github.com/MacBuchi/mixstack/releases/tag/v0.20.0
[0.19.0]: https://github.com/MacBuchi/mixstack/releases/tag/v0.19.0
[0.18.3]: https://github.com/MacBuchi/mixstack/releases/tag/v0.18.3
[0.18.2]: https://github.com/MacBuchi/mixstack/releases/tag/v0.18.2
[0.18.1]: https://github.com/MacBuchi/mixstack/releases/tag/v0.18.1
[0.18.0]: https://github.com/MacBuchi/mixstack/releases/tag/v0.18.0
[0.17.0]: https://github.com/MacBuchi/mixstack/releases/tag/v0.17.0
[0.16.0]: https://github.com/MacBuchi/mixstack/releases/tag/v0.16.0
[0.15.0]: https://github.com/MacBuchi/mixstack/releases/tag/v0.15.0
[0.14.0]: https://github.com/MacBuchi/mixstack/releases/tag/v0.14.0
[0.13.3]: https://github.com/MacBuchi/mixstack/releases/tag/v0.13.3
[0.13.2]: https://github.com/MacBuchi/mixstack/releases/tag/v0.13.2
[0.13.1]: https://github.com/MacBuchi/mixstack/releases/tag/v0.13.1
[0.13.0]: https://github.com/MacBuchi/mixstack/releases/tag/v0.13.0
[0.12.16]: https://github.com/MacBuchi/mixstack/releases/tag/v0.12.16
[0.12.15]: https://github.com/MacBuchi/mixstack/releases/tag/v0.12.15
[0.12.14]: https://github.com/MacBuchi/mixstack/releases/tag/v0.12.14
[0.12.13]: https://github.com/MacBuchi/mixstack/releases/tag/v0.12.13
[0.12.12]: https://github.com/MacBuchi/mixstack/releases/tag/v0.12.12
[0.12.11]: https://github.com/MacBuchi/mixstack/releases/tag/v0.12.11
[0.12.10]: https://github.com/MacBuchi/mixstack/releases/tag/v0.12.10
[0.12.9]: https://github.com/MacBuchi/mixstack/releases/tag/v0.12.9
[0.12.8]: https://github.com/MacBuchi/mixstack/releases/tag/v0.12.8
[0.12.7]: https://github.com/MacBuchi/mixstack/releases/tag/v0.12.7
[0.12.6]: https://github.com/MacBuchi/mixstack/releases/tag/v0.12.6
[0.12.5]: https://github.com/MacBuchi/mixstack/releases/tag/v0.12.5
[0.12.4]: https://github.com/MacBuchi/mixstack/releases/tag/v0.12.4
[0.12.3]: https://github.com/MacBuchi/mixstack/releases/tag/v0.12.3
[0.12.2]: https://github.com/MacBuchi/mixstack/releases/tag/v0.12.2
[0.12.1]: https://github.com/MacBuchi/mixstack/releases/tag/v0.12.1
[0.12.0]: https://github.com/MacBuchi/mixstack/releases/tag/v0.12.0
[0.11.1]: https://github.com/MacBuchi/mixstack/releases/tag/v0.11.1
[0.11.0]: https://github.com/MacBuchi/mixstack/releases/tag/v0.11.0
[0.10.0]: https://github.com/MacBuchi/mixstack/releases/tag/v0.10.0
[0.9.0]: https://github.com/MacBuchi/mixstack/releases/tag/v0.9.0
[0.8.2]: https://github.com/MacBuchi/mixstack/releases/tag/v0.8.2
[0.8.1]: https://github.com/MacBuchi/mixstack/releases/tag/v0.8.1
[0.8.0]: https://github.com/MacBuchi/mixstack/releases/tag/v0.8.0
[0.7.4]: https://github.com/MacBuchi/mixstack/releases/tag/v0.7.4
[0.7.3]: https://github.com/MacBuchi/mixstack/releases/tag/v0.7.3
[0.7.2]: https://github.com/MacBuchi/mixstack/releases/tag/v0.7.2
[0.7.1]: https://github.com/MacBuchi/mixstack/releases/tag/v0.7.1
[0.7.0]: https://github.com/MacBuchi/mixstack/releases/tag/v0.7.0
[0.6.2]: https://github.com/MacBuchi/mixstack/releases/tag/v0.6.2
[0.6.1]: https://github.com/MacBuchi/mixstack/releases/tag/v0.6.1
[0.6.0]: https://github.com/MacBuchi/mixstack/releases/tag/v0.6.0
[0.5.1]: https://github.com/MacBuchi/mixstack/releases/tag/v0.5.1
[0.5.0]: https://github.com/MacBuchi/mixstack/releases/tag/v0.5.0
[0.4.0]: https://github.com/MacBuchi/mixstack/releases/tag/v0.4.0
[0.3.0]: https://github.com/MacBuchi/mixstack/releases/tag/v0.3.0

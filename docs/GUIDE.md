# DurecMix — User Guide

DurecMix turns a multichannel **RME DUREC** recording (WAV/RF64/BW64 from a
USB stick) into a finished stereo mix — on macOS, Windows, Android and iOS,
fully offline. This guide walks through every screen; the numbered badges in
the screenshots match the lists below them.

All screenshots are generated from the app itself and can be refreshed any
time with `tool/make_screenshots.sh` (see [Development](#regenerating-the-screenshots)).

---

## 1. Opening a recording — the WAV browser

On first launch, pick your recordings folder (the DUREC USB stick or a copy
of it). DurecMix lists the WAV files with their metadata and remembers the
folder.

![WAV browser](screenshots/browser_annotated.png)

1. **Selection mode** — tick several takes for a [multi-file export](#8-exporting).
2. **Sort** by name or recording date.
3. **Switch to another folder.**
4. Marks the **currently loaded take**.
5. **Tap a row** to open that take in the mixer. The subtitle shows
   channels · sample rate · bit depth · duration · iXML track count, probed
   lazily in the background (fine on slow USB sticks).

Tips: the app-bar **title** in the mixer reopens this browser, so switching
between takes of a session is two taps. iOS currently uses the system file
picker instead of the in-app browser.

## 2. The mixer

![Mixer](screenshots/mixer_annotated.png)

1. **Loaded take** — tap to switch to another recording of the folder.
2. **Reference mastering** — match the export to reference songs
   ([section 7](#7-reference-mastering)). Blue = active, amber = the
   mastered preview is stale.
3. **Loudness target** — applied on export only; the preview always plays
   the raw mix ([section 6](#6-loudness-targets--output-formats)).
4. **Output format** — WAV 16/24/32-float, FLAC 16/24, MP3 320.
5. **Export** the stereo mixdown ([section 8](#8-exporting)).
6. **Batch export** — render several loudness/format targets in one go
   (desktop).
7. **A/B mix snapshots** — tap an empty slot to store the current mix, tap a
   filled slot to recall it; long-press (or right-click) overwrites.
8. **Link stereo pairs** — tracks named `…·L`/`…·R` mirror gain, mute, solo
   and EQ, with inverted pans. The link chip on a paired strip unlinks just
   that pair; relinking copies the tapped side to its partner.
9. **Choose the recordings folder.**
10. **Track strip** — one per recorded channel ([section 3](#3-track-strips--eq)).
11. **Play / stop** the live preview ([section 4](#4-playback--metering)).
12. **Trim-in / trim-out** at the playhead; long-press clears
    ([section 5](#5-trimming)).

Fresh sessions automatically exclude obvious monitor feeds (In Ear, Phones,
IEM, Talkback, Line Out, Monitor) from the mix — DUREC also records those
buses, and a unity mix including them would clip far above full scale.
`…_Out` stems stay in: engineers often mix from them.

## 3. Track strips & EQ

Each strip carries (left to right): track number and name, the toggle chips,
pan, fader, and the waveform.

- **ø** — polarity invert (instead of any destructive auto-"phase fix").
- **M / S** — mute / solo.
- **mix** — whether the track is part of the mixdown at all (green = in).
- **EQ** — expands the per-track EQ panel:

![EQ panel](screenshots/eq_annotated.png)

1. **High-pass filter** with 12 or 24 dB/oct slope — rumble and stage bleed.
2. Each band has an **on/off switch** plus gain and frequency sliders:
   low shelf, mid peak, high shelf (RBJ biquads — identical in preview and
   export).
3. The **EQ chip** toggles the panel; it lights up while any band is active.

Every change is saved automatically (debounced) into a per-take session
file, so reopening a recording restores the exact mix.

## 4. Playback & metering

Play starts a live preview of the current mix — faders, pans, EQ and
solo/mute react instantly (~0.2 s). The transport bar keeps a constant
height; its meters show:

- **Peak L/R** bars,
- **LUFS-M / LUFS-I** — momentary and integrated loudness (EBU R128),
- **TP** — running true-peak maximum (dBTP),
- **corr** — stereo correlation.

The preview plays *pre-normalisation*: LUFS-I predicts what the export's
first pass will measure. With the [mastered preview](#7-reference-mastering)
enabled, the meters show the mastered signal instead.

After an export, the status line above the transport summarises the result —
hover for the full text (desktop) or **tap it** for a detail dialog with all
values and the output path.

## 5. Trimming

The trim buttons (mixer badge 12) set trim-in/trim-out at the current
playhead; long-press clears a point. Exports render only the trimmed range
and apply 80 ms fades at trim boundaries. Trim and fades are per-take and
deliberately **not** carried into batch or multi-file exports.

## 6. Loudness targets & output formats

The loudness dropdown selects the export normalisation:

| Choice | Meaning |
|---|---|
| none | No gain change (static clip protection if the limiter is off) |
| −1 dBFS | Peak-normalise the sample peak to −1 dBFS |
| −14 / −16 / −23 LUFS | Integrated-loudness targets (streaming / R128) |
| custom LUFS | Any value, −30…−6 |

A true-peak limiter (8× oversampled detection, −1 dBTP ceiling) guards every
export; 16-bit targets get TPDF dither. While reference mastering is active
the loudness dropdown is greyed out — the reference owns the level.

## 7. Reference mastering

Match your mix to how finished songs sound — loudness, tonal balance
(matching EQ) and stereo width. A clean-room implementation of the
Matchering idea, validated against Matchering 2.0 (−23.5 dB null-test depth).

![Mastering dialog](screenshots/mastering_annotated.png)

1. **Master to reference** — the main switch. While on, exports are matched
   to the reference set and the loudness target is bypassed (the true-peak
   limiter stays active as the safety net).
2. The **chosen references**. One song imposes its own character; several
   stylistically matching songs average into a genre target curve — one
   vote per song. Remove entries with ✕.
3. **Add reference** — any WAV/FLAC/MP3/OGG. Each file is analyzed once
   (spectrum fingerprint, cached), so re-using a reference is instant.
4. **Preview mastered playback** — analyzes the current mix once (progress
   bar) and inserts the mastering stage into the live preview. After mix
   changes the preview keeps playing the frozen plan and the wand icon turns
   **amber**; hit *Refresh* in this dialog to re-analyze. Nothing re-scans
   your multi-GB file behind your back.

The export report then reads `matched to <reference> (±x dB)`. Mastering
works in single, batch and multi-file exports alike.

## 8. Exporting

- **Export** (mixer badge 5) renders the current take: two streamed passes,
  so multi-GB recordings never load into RAM — phones included. A report
  (LUFS-I, dBTP, LRA, gain or mastering match) appears above the transport.
- **Batch export** (badge 6, desktop): queue several loudness/format
  combinations of the *current* take and render them into one folder,
  auto-named like `Take_-14LUFS_120BPM_2026-07-19.wav`.

![Batch export](screenshots/batch_annotated.png)

- **Multi-file export** (browser selection mode): tick several takes and
  export them all with the *current* mix applied by track name (index
  fallback). Outputs land in a `Mixdown/` subfolder; every row shows its own
  progress, and Android offers the system share sheet afterwards. Sessions
  of the other takes are never modified.

## 9. On the phone

<p>
  <img src="screenshots/phone_android_annotated.png" width="300" alt="Phone mixer"/>
  <img src="screenshots/phone_menu_android.png" width="300" alt="Phone overflow menu"/>
</p>

1. **Export** stays visible (the button shows render progress); a
   notification keeps reporting while the app is in the background.
2. Everything else — mastering, loudness, format, snapshots, pair linking —
   moves into the **overflow menu**.
3. The meters live on their own row and idle while stopped.

Android reads recordings straight off the USB stick through Storage Access
Framework file descriptors — the multi-GB file is never copied. Grant the
folder once; the app keeps the permission. Exports can be shared from the
result snackbar. iOS opens files in place via the system picker.

## 10. Feedback & updates

Two slim banners can appear above the mixer (each dismissible with ✕ for the
session):

- **💡 Request a feature or report a bug** — opens a short dialog (Feature or
  Bug, plus a text field). Submitting files a GitHub issue directly in the
  [project repo](https://github.com/MacBuchi/durec-multichannel-mixdown/issues),
  pre-tagged and pre-filled with your app version and platform. On builds
  without the issue token it opens the pre-filled issue form in your browser
  instead — same result, one extra click.
- **🔄 Update to vX.Y.Z available** — appears when a newer release exists.
  On Android it downloads and installs the APK in-app (with a progress bar);
  on desktop it opens the release page. The check is best-effort and silent
  on failure — it never interrupts your work.

## 11. Where things live

| Data | Location |
|---|---|
| Mix sessions (`<take>_<hash>.durecmix.json`) | app container, `Application Support/sessions/` |
| Waveform/BPM analysis cache | app container, `analysis/` |
| Reference profiles (mastering) | app container, `reference_profiles/` |
| Exports | wherever you save them; multi-file exports in `Mixdown/` next to the takes |

Sessions are keyed by file identity, so they survive renaming the folder or
re-plugging the stick. Nothing ever writes next to your recordings except
the explicit `Mixdown/` output folder.

---

## Regenerating the screenshots

```sh
tool/make_screenshots.sh                 # desktop set (annotated)
tool/make_screenshots.sh -d emulator-…   # phone set from an Android emulator
```

The integration test renders every screen from a synthetic 8-track fixture
through the real engine and dumps marker coordinates from the live widget
tree; `tool/annotate_screenshots.py` draws the numbered callouts. The marker
labels double as the legends above — if the UI changes, rerun the script and
update the lists.

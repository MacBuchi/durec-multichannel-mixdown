/// End-to-end smoke test of the real app against the real Rust engine —
/// the command-line replacement for clicking through the GUI by hand:
///
///   flutter test integration_test -d macos
///
/// It runs inside the app process (WidgetTester injects events internally,
/// so it never touches the real mouse/keyboard) and uses a tiny synthetic
/// DUREC-like WAV generated into the app's sandbox-writable temp directory.
/// The native file picker itself stays a manual-test surface; the test
/// enters through `MixerState.open`, which is the picker's target.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:durecmix/main.dart';
import 'package:durecmix/src/rust/api/mixer.dart' as rust;
import 'package:durecmix/state/app_settings.dart';
import 'package:durecmix/state/batch_export.dart';
import 'package:durecmix/state/mixer_state.dart';
import 'package:durecmix/state/wav_browser.dart';
import 'package:durecmix/src/rust/frb_generated.dart';
import 'package:durecmix/state/update_check.dart';
import 'package:durecmix/ui/animated_logo.dart';
import 'package:durecmix/ui/meters.dart';
import 'package:durecmix/ui/track_strip.dart';
import 'package:durecmix/ui/wav_browser_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';

/// `flutter test integration_test -d macos --dart-define=SCREENSHOTS=true`
/// additionally renders the documentation screenshots (docs/screenshots/)
/// from a richer fixture and prints SCREENSHOT_DIR=… with the output
/// location. Never set in CI.
const bool kScreenshots = bool.fromEnvironment('SCREENSHOTS');

final GlobalKey _shotKey = GlobalKey();

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;
  late String fixturePath;

  setUpAll(() async {
    await RustLib.init();
    UpdateCheck.enabled = false; // no network / GitHub call in tests
    // The start-screen logo animates continuously (#73); a repeating
    // animation keeps the frame queue non-empty, so pumpAndSettle() below
    // would spin until its timeout. The logo still renders, just still.
    AnimatedLogo.enabled = false;
    tempDir = await Directory.systemTemp.createTemp('durecmix_test');
    fixturePath = '${tempDir.path}/fixture_4ch.wav';
    File(fixturePath).writeAsBytesSync(_buildFixtureWav());
  });

  tearDownAll(() async {
    await tempDir.delete(recursive: true);
  });

  testWidgets('open → mix → EQ → export against the real engine', (
    tester,
  ) async {
    // The flow below drives the WIDE layout (app-bar selectors, A/B chips,
    // batch icon). On a phone/emulator the natural surface is narrow, so pin
    // a desktop-sized test surface; phone-layout sections set their own.
    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1.0;
    // Every surface pin must also pin BOTH inset kinds: on a real Android
    // device the view keeps its PHYSICAL-pixel status/gesture insets
    // (sized for DPR ~2.6+), which at the faked DPR of 1.0 balloon to
    // ~190 logical px — and focusing a text field summons the real soft
    // keyboard, whose viewInsets collapse dialogs to a few px mid-test.
    // macOS has neither; zeroing both makes the platforms lay out
    // identically.
    tester.view.padding = FakeViewPadding.zero;
    tester.view.viewInsets = FakeViewPadding.zero;
    // Injected through the MixerScope seam — the test owns the state and
    // never reaches into widget internals.
    final state = MixerState();
    addTearDown(state.dispose);
    await tester.pumpWidget(
      RepaintBoundary(
        key: _shotKey,
        child: DurecMixApp(state: state),
      ),
    );
    await tester.pumpAndSettle();
    // No separate start screen: the main window's empty track area carries
    // the (continuously animated) logo and the folder affordance.
    expect(find.text('Choose folder'), findsOneWidget);
    expect(find.byType(AnimatedLogo), findsOneWidget);
    // Exactly ONE folder affordance here — the centre button. Two controls
    // with the same icon but different behaviour is what #74 reported.
    expect(
      find.descendant(
        of: find.byType(FilledButton),
        matching: find.byIcon(Icons.folder_open),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: find.byType(AppBar),
        matching: find.byIcon(Icons.folder_open),
      ),
      findsNothing,
    );

    // Feedback banner: shown once per start (update banner stays hidden —
    // the check is disabled). Opening it validates empty input, then
    // dismissing hides it for the session.
    expect(find.textContaining('Request a feature'), findsOneWidget);
    await tester.tap(find.textContaining('Request a feature'));
    await tester.pumpAndSettle();
    expect(find.text('Make a wish!'), findsOneWidget);
    await tester.tap(find.text('Send')); // too short → stays open
    await tester.pump();
    expect(find.text('Make a wish!'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    // Dismiss the banner. Not a coordinate tap: on a real Android device the
    // status-bar inset shifts this top-of-screen zone and the derived tap
    // point misses the 18 px icon (macOS has no inset, so the same tap
    // passes there). Invoking the InkWell's onTap keeps the dismissal logic
    // covered on every platform without depending on inset geometry.
    tester
        .widget<InkWell>(
          find
              .ancestor(
                of: find.byIcon(Icons.close).first,
                matching: find.byType(InkWell),
              )
              .first, // nearest enclosing InkWell = the dismiss affordance
        )
        .onTap!();
    await tester.pump();
    expect(find.textContaining('Request a feature'), findsNothing);

    // Settings: the gear in the app bar opens appearance + the way to About.
    await tester.tap(find.byIcon(Icons.settings_outlined).first);
    await tester.pumpAndSettle();
    expect(find.text('Settings'), findsOneWidget);
    expect(find.text('Appearance'), findsOneWidget);

    // Theme choice round-trips through the notifier the app listens to.
    expect(AppSettings.themeMode.value, ThemeMode.system);
    await tester.tap(find.text('Light'));
    await tester.pumpAndSettle();
    expect(AppSettings.themeMode.value, ThemeMode.light);
    expect(
      Theme.of(tester.element(find.byType(Scaffold).first)).brightness,
      Brightness.light,
    );
    await tester.tap(find.text('Dark'));
    await tester.pumpAndSettle();
    expect(AppSettings.themeMode.value, ThemeMode.dark);
    expect(
      Theme.of(tester.element(find.byType(Scaffold).first)).brightness,
      Brightness.dark,
    );

    // About sits at the bottom of Settings and still shows version + links.
    await tester.tap(find.text('About DurecMix'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Version'), findsWidgets);
    expect(find.text('GitHub project'), findsOneWidget);

    // The licence page proves both halves of #68 at once: the Rust notices
    // are bundled as an asset AND registered with LicenseRegistry. Either
    // one missing and this entry never appears.
    await tester.tap(find.text('Open-source licenses'));
    // No pumpAndSettle here: the page shows a CircularProgressIndicator
    // while the registry is collected, and a spinner never settles. Poll
    // for the entry instead, with a bound so a real regression still fails.
    final rustEntry = find.text('DurecMix Rust engine');
    for (var i = 0; i < 100 && rustEntry.evaluate().isEmpty; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    // findsWidgets, not findsOneWidget: on a wide surface the licence page
    // is master-detail and renders the name in both panes.
    expect(rustEntry, findsWidgets);
    await tester.pageBack(); // leaves the licence page (About already popped)
    await tester.pump(const Duration(milliseconds: 500));

    // Open the fixture (the picker's target API; the native panel itself
    // cannot be driven headlessly).
    await state.open(fixturePath);
    await tester.pumpAndSettle();

    // iXML track names and the stereo-pair pan heuristic arrived intact.
    expect(state.error, isNull);
    expect(state.tracks, hasLength(4));
    expect(find.text('Vocals'), findsOneWidget);
    expect(find.text('Kick'), findsOneWidget);
    expect(state.tracks[2].pan, -1.0); // "Keys L"
    expect(state.tracks[3].pan, 1.0); // "Keys R"

    // …and with a recording open the app-bar folder icon is back (#74): it
    // is the "switch folder" control, not a second start-screen button.
    expect(
      find.descendant(
        of: find.byType(AppBar),
        matching: find.byIcon(Icons.folder_open),
      ),
      findsOneWidget,
    );

    // REAL playback through the platform audio backend — Android only.
    // v0.12.10 shipped with every play tap panicking (cpal's AAudio backend
    // needs an initialized ndk_context, issue #88) while every test stayed
    // green, because nothing ever played audio on Android. This section is
    // that missing coverage; it runs on-device/emulator, not in CI (the CI
    // matrix builds the APK but cannot run it).
    //
    // The assertions are chosen so a silent-but-alive stream still fails:
    // the decode thread blocks once the ~0.2 s ring buffer is full, so the
    // position can only pass 0.5 s if the AAudio callback actually drains
    // frames. Peaks prove the mix carries signal, not zeros.
    if (Platform.isAndroid) {
      await state.playback.togglePlay();
      await tester.pump();
      expect(
        state.error,
        isNull,
        reason: 'playerStart must not fail (ndk_context handshake, #88)',
      );
      expect(state.playback.playing, isTrue);
      // Real wall-clock playback; pump keeps the 30 Hz meter poll alive.
      // Sample the meters per iteration and assert on the maxima: the
      // fixture is only 2 s, so by the end of this loop playback has hit
      // EOF and the final poll legitimately reads silence — a read-once at
      // the end races the fixture length (it did, emulator run 1).
      var maxPeak = 0.0;
      var maxPos = 0.0;
      for (var i = 0; i < 15; i++) {
        await tester.pump(const Duration(milliseconds: 100));
        expect(state.error, isNull, reason: 'stream died at ~${i * 100} ms');
        // The #88 failure mode was playback dying instantly, so the core
        // assertion is continuity: while the 2 s fixture is not near its
        // end, the player must still be running. Position-gated rather
        // than iteration-gated so slow devices cannot race the EOF.
        if (state.playback.positionSeconds < 1.5) {
          expect(
            state.playback.playing,
            isTrue,
            reason:
                'playback stopped early at '
                '${state.playback.positionSeconds.toStringAsFixed(2)} s',
          );
        }
        maxPeak = math.max(maxPeak, state.playback.peakL);
        maxPos = math.max(maxPos, state.playback.positionSeconds);
      }
      expect(
        maxPos,
        greaterThan(1.0),
        reason:
            'at least one full second must have played — the decode thread '
            'alone only reaches ~0.2 s (ring capacity), so this proves the '
            'AAudio callback keeps draining frames',
      );
      expect(
        maxPeak,
        greaterThan(0.01),
        reason: 'meters must see signal, not a silent stream',
      );
      state.playback.stop();
      await tester.pump();
      expect(state.playback.playing, isFalse);
      // Playback must be restartable after a stop (stream teardown clean).
      // Seek home first — the loop above ran the 2 s fixture to EOF, and a
      // restart at EOF finishes immediately.
      state.playback.seek(0);
      await state.playback.togglePlay();
      await tester.pump();
      expect(state.error, isNull);
      expect(state.playback.playing, isTrue);
      state.playback.stop();
      await tester.pump();
    }

    // Mute toggle through a real tap on the first track's M chip.
    await tester.tap(find.text('M').first);
    await tester.pump();
    expect(state.tracks[0].muted, isTrue);
    await tester.tap(find.text('M').first);
    await tester.pump();
    expect(state.tracks[0].muted, isFalse);

    // A/B snapshots: tap stores an empty slot, tap recalls; regression:
    // long-press must OVERWRITE — the chip's Tooltip used to win the
    // long-press gesture (its mobile trigger), making overwrite impossible.
    await tester.tap(find.text('A')); // store (slot empty)
    await tester.pump();
    state.updateTrack(state.tracks[0], (t) => t.gainDb = -12.0);
    await tester.pump();
    await tester.tap(find.text('A')); // recall
    await tester.pump();
    expect(state.tracks[0].gainDb, 0.0);
    state.updateTrack(state.tracks[0], (t) => t.gainDb = -9.0);
    await tester.pump();
    await tester.longPress(find.text('A')); // overwrite with −9 dB
    await tester.pump();
    state.updateTrack(state.tracks[0], (t) => t.gainDb = 0.0);
    await tester.pump();
    await tester.tap(find.text('A')); // recall must yield the overwritten mix
    await tester.pump();
    expect(state.tracks[0].gainDb, -9.0);
    state.updateTrack(state.tracks[0], (t) => t.gainDb = 0.0);
    await tester.pump(const Duration(seconds: 3)); // let the snack bar retire

    // Stereo-pair linking: a gain edit on "Keys L" mirrors onto "Keys R"…
    state.updateTrack(state.tracks[2], (t) => t.gainDb = -6.0);
    await tester.pump();
    expect(state.tracks[3].gainDb, -6.0);

    // …until the pair is unlinked via the link chip on its strip.
    final pairChips = find.descendant(
      of: find.byType(TrackStrip),
      matching: find.byIcon(Icons.link),
    );
    expect(pairChips, findsNWidgets(2)); // Keys L + Keys R
    await tester.tap(pairChips.first);
    await tester.pump();
    expect(find.byIcon(Icons.link_off), findsNWidgets(2));
    state.updateTrack(state.tracks[2], (t) => t.gainDb = -3.0);
    await tester.pump();
    expect(state.tracks[3].gainDb, -6.0); // partner no longer follows

    // Relinking copies the tapped side back onto the partner.
    await tester.tap(
      find
          .descendant(
            of: find.byType(TrackStrip),
            matching: find.byIcon(Icons.link_off),
          )
          .first,
    );
    await tester.pump();
    expect(state.tracks[3].gainDb, -3.0);

    // EQ panel: expand via the EQ chip, enable the HPF via its switch.
    await tester.tap(find.text('EQ').first);
    await tester.pumpAndSettle();
    expect(find.text('HPF'), findsOneWidget);
    await tester.tap(find.byType(Switch).first);
    await tester.pump();
    expect(state.tracks[0].eq.hpfEnabled, isTrue);

    // Session autosave (debounced 1 s) must land in the app container.
    await tester.pump(const Duration(seconds: 2));
    await state.saveSession();
    expect(state.error, isNull);

    // Export at a custom −17.5 LUFS through the real two-pass engine
    // (non-preset value, so the session round-trip below must restore it
    // as `lufsCustom` rather than canonicalising to a preset).
    state.customLufs = -17.5;
    state.setLoudness(LoudnessChoice.lufsCustom);
    // Exports land in a subfolder so the browser section below only sees
    // the two fixtures (the browser lists direct children).
    Directory('${tempDir.path}/out').createSync();
    final outPath = '${tempDir.path}/out/mix.wav';
    await state.exporter.export(outPath);
    await tester.pumpAndSettle();

    expect(state.error, isNull);
    final report = state.exporter.lastReport;
    expect(report, isNotNull);
    expect(File(outPath).existsSync(), isTrue);
    // The engine's own tests verify measurement accuracy; here we check the
    // report is coherent: target hit and ceiling respected.
    expect((report!.integratedLufs - -17.5).abs(), lessThan(0.5));
    expect(report.truePeakDbtp, lessThanOrEqualTo(-1.0 + 0.05));
    expect(find.textContaining('Exported:'), findsOneWidget);

    // Batch export: two jobs (−14 LUFS MP3 + the current −17.5 LUFS WAV)
    // rendered sequentially into one folder, auto-named per target/format.
    final batchDir = Directory('${tempDir.path}/batch')..createSync();
    state.exporter.addBatchJob();
    state.exporter.batchQueue[0]
      ..loudness = LoudnessChoice.lufs14
      ..format = rust.ApiFormat.mp3;
    state.exporter
        .addBatchJob(); // copies the current selection: custom LUFS, WAV 24
    await state.exporter.exportBatch(batchDir.path);
    await tester.pumpAndSettle();
    expect(state.error, isNull);
    expect(state.exporter.batchRunning, isFalse);
    final batchFiles = batchDir.listSync().map((f) => f.path).toList();
    expect(batchFiles, hasLength(2));
    expect(
      batchFiles.any((p) => p.endsWith('.mp3') && p.contains('_14LUFS')),
      isTrue,
    );
    expect(
      batchFiles.any((p) => p.endsWith('.wav') && p.contains('_17.5LUFS')),
      isTrue,
    );

    // Reference mastering: use the fixture itself as reference (WAV decode
    // through the real Symphonia path). The export must run the matching
    // stage and say so in the report; the loudness target is bypassed.
    await state.mastering.addReference(fixturePath, 'fixture_4ch.wav');
    await tester.pumpAndSettle();
    expect(state.error, isNull);
    expect(state.mastering.enabled, isTrue);
    expect(state.mastering.profile, isNotNull);

    // Multi-reference: a second (different) song merges into an averaged
    // target curve; removing it falls back to the single profile.
    // In out/: the browser section below must keep seeing exactly the
    // two fixtures as direct children of the temp folder.
    final refBPath = '${tempDir.path}/out/refB.wav';
    File(refBPath).writeAsBytesSync(
      _buildFixtureWav(
        tracks: const [('Pad', 220.0, 0.3, 0.0), ('Hat', 6000.0, 0.1, 0.0)],
        seconds: 2,
      ),
    );
    await state.mastering.addReference(refBPath, 'refB.wav');
    await tester.pumpAndSettle();
    expect(state.mastering.references, hasLength(2));
    expect(state.mastering.referenceName, '2 references');
    expect(state.mastering.profile, isNotNull);
    await state.mastering.removeReference(state.mastering.references.last);
    await tester.pumpAndSettle();
    expect(state.mastering.references, hasLength(1));
    expect(state.mastering.profile, isNotNull);
    final masteredPath = '${tempDir.path}/out/mastered.wav';
    await state.exporter.export(masteredPath);
    await tester.pumpAndSettle();
    expect(state.error, isNull);
    expect(state.exporter.lastReport!.masteringApplied, isTrue);
    expect(File(masteredPath).existsSync(), isTrue);
    expect(find.textContaining('matched to fixture_4ch.wav'), findsOneWidget);

    // Mastering preview: enabling analyzes the current mix (real engine
    // pass); mix edits mark the analysis stale; refresh clears it. (No
    // audio device is exercised — CI runners have none.)
    await state.mastering.enablePreview();
    await tester.pumpAndSettle();
    expect(state.mastering.preview, isTrue);
    expect(state.mastering.mixStats, isNotNull);
    expect(state.mastering.mixStatsStale, isFalse);
    state.updateTrack(state.tracks[0], (t) => t.gainDb = -3.0);
    await tester.pump();
    expect(
      state.mastering.mixStatsStale,
      isTrue,
      reason: 'mix edit must mark preview stale',
    );
    await state.mastering.refreshPreview();
    await tester.pumpAndSettle();
    expect(state.mastering.mixStatsStale, isFalse);
    state.updateTrack(state.tracks[0], (t) => t.gainDb = 0.0);
    state.mastering.disablePreview();
    await tester.pump();

    // Reopen: the EQ setting, loudness choice and mastering reference
    // round-trip via the session.
    await state.open(fixturePath);
    await tester.pumpAndSettle();
    expect(state.tracks[0].eq.hpfEnabled, isTrue);
    expect(state.loudness, LoudnessChoice.lufsCustom);
    expect(state.customLufs, -17.5);
    expect(state.mastering.enabled, isTrue);
    expect(state.mastering.referenceName, 'fixture_4ch.wav');
    // The rest of the test exercises loudness-driven exports.
    state.mastering.setEnabled(false);
    await tester.pump(const Duration(seconds: 2)); // let the autosave land

    // Analysis cache: the first open persisted waveforms+BPM; the reopen
    // above served them from disk without an analyzing phase.
    final support = await getApplicationSupportDirectory();
    expect(Directory('${support.path}/analysis').listSync(), isNotEmpty);
    expect(state.analyzing, isFalse);
    expect(state.waveforms, isNotNull);

    // Phone layout: a narrow window collapses the app-bar selectors into
    // the overflow menu (Export stays a direct button).
    tester.view.physicalSize = const Size(480, 800);
    tester.view.devicePixelRatio = 1.0;
    tester.view.padding = FakeViewPadding.zero; // see the pin at the top
    tester.view.viewInsets = FakeViewPadding.zero;
    tester.view.viewInsets = FakeViewPadding.zero;
    addTearDown(tester.view.reset);
    await tester.pumpAndSettle();
    expect(find.byType(PopupMenuButton<String>), findsOneWidget);
    expect(find.byType(DropdownButton<LoudnessChoice>), findsNothing);
    expect(find.text('Export'), findsOneWidget);

    // In-app WAV browser: seeded with the temp folder, opened by tapping
    // the file name in the app bar; entries carry lazily probed metadata;
    // tapping a row switches the recording without restarting.
    final twoChPath = '${tempDir.path}/fixture_2ch.wav';
    File(twoChPath).writeAsBytesSync(
      _buildFixtureWav(
        tracks: const [('Left', 220.0, 0.2, 0.0), ('Right', 221.0, 0.2, 0.0)],
      ),
    );
    // Seed BOTH persisted settings — they survive across test runs (that's
    // the feature), so the test must not depend on a previous run's state.
    final settings = await AppSettings.load();
    settings
      ..lastFolder = tempDir.path
      ..sortByDate = false;
    await settings.save();

    await tester.tap(find.text('fixture_4ch.wav')); // app-bar title
    await tester.pumpAndSettle();
    expect(find.byType(WavBrowserPage), findsOneWidget);
    final browser = tester
        .widget<WavBrowserPage>(find.byType(WavBrowserPage))
        .browser;
    // Wait for the listing + sequential probes to finish (real async I/O).
    for (
      var i = 0;
      i < 100 &&
          (browser.loading ||
              browser.entries.isEmpty ||
              browser.entries.any(
                (e) => e.probe == null && e.probeError == null,
              ));
      i++
    ) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(browser.error, isNull);
    expect(browser.entries, hasLength(2));
    final byName = {for (final e in browser.entries) e.name: e};
    expect(byName['fixture_4ch.wav']!.probe!.channels, 4);
    expect(byName['fixture_4ch.wav']!.probe!.ixmlTrackCount, 4);
    expect(byName['fixture_2ch.wav']!.probe!.channels, 2);
    expect(byName['fixture_2ch.wav']!.probe!.ixmlTrackCount, 2);

    // Sort toggle: name order puts 2ch first, newest-first puts it first
    // too (written later) — so assert the order flips back on re-toggle.
    expect(browser.sortByDate, isFalse);
    expect(browser.entries.first.name, 'fixture_2ch.wav');
    await tester.tap(find.byIcon(Icons.sort_by_alpha));
    await tester.pump();
    expect(browser.sortByDate, isTrue);
    expect(browser.entries.first.name, 'fixture_2ch.wav'); // newest first

    // Switch to the 2-channel take by tapping its row.
    await tester.tap(find.text('fixture_2ch.wav'));
    await tester.pumpAndSettle();
    expect(find.byType(WavBrowserPage), findsNothing);
    expect(state.error, isNull);
    expect(state.tracks, hasLength(2));
    expect(find.text('fixture_2ch.wav'), findsOneWidget); // new title

    // Reopen: the loaded take carries the marker; close via row tap.
    await tester.tap(find.text('fixture_2ch.wav'));
    await tester.pumpAndSettle();
    expect(find.byIcon(Icons.graphic_eq), findsOneWidget); // current marker
    await tester.tap(find.text('fixture_4ch.wav'));
    await tester.pumpAndSettle();
    expect(state.tracks, hasLength(4));

    // Multi-file export lives behind an explicit selection mode: the plain
    // list has NO checkboxes (rows open the mixer — the v0.8.0 confusion),
    // the checklist icon reveals them with multichannel takes pre-ticked.
    await tester.tap(find.text('fixture_4ch.wav')); // app-bar title
    await tester.pumpAndSettle();
    final browser2 = tester
        .widget<WavBrowserPage>(find.byType(WavBrowserPage))
        .browser;
    expect(find.byType(Checkbox), findsNothing);
    expect(find.byIcon(Icons.chevron_right), findsNWidgets(2));

    await tester.tap(find.byIcon(Icons.checklist));
    await tester.pumpAndSettle();
    expect(find.byType(Checkbox), findsNWidgets(2));
    final sel = {for (final e in browser2.entries) e.name: e.selected};
    expect(sel['fixture_4ch.wav'], isTrue);
    expect(sel['fixture_2ch.wav'], isFalse);
    expect(find.text('1 selected'), findsOneWidget);

    // The export target is visible and changeable right in selection mode:
    // switching the format flips the name-field extension live.
    expect(find.text('Export target:'), findsOneWidget);
    expect(find.text('-17.5 LUFS'), findsOneWidget);
    await tester.tap(find.text('WAV 24')); // format chip
    await tester.pumpAndSettle();
    await tester.tap(find.text('MP3 320')); // dialog option
    await tester.pumpAndSettle();
    expect(find.text('.mp3'), findsOneWidget); // suffix of the one name field
    await tester.tap(find.text('MP3 320')); // chip again
    await tester.pumpAndSettle();
    await tester.tap(find.text('WAV 24')); // back to WAV for the batch below
    await tester.pumpAndSettle();
    expect(find.text('.wav'), findsOneWidget);

    // In selection mode a row TAP toggles the tick (list convention)…
    await tester.tap(
      find.descendant(
        of: find.byType(WavBrowserPage),
        matching: find.text('fixture_2ch.wav'),
      ),
    );
    await tester.pump();
    expect(browser2.selectedEntries, hasLength(2));
    expect(find.text('2 selected'), findsOneWidget);

    // …and ticked rows expose an editable output name (stem + fixed ext).
    await tester.enterText(
      find.widgetWithText(TextField, 'fixture_4ch'),
      'MeinMix',
    );
    await tester.pump();

    // Name collisions must not overwrite: pre-plant the target name.
    Directory('${tempDir.path}/Mixdown').createSync();
    File('${tempDir.path}/Mixdown/MeinMix.wav').writeAsBytesSync(const [0]);

    await tester.tap(find.textContaining('Export (2)'));
    for (
      var i = 0;
      i < 300 && !tester.any(find.textContaining('exported to Mixdown'));
      i++
    ) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(find.textContaining('2 mixdowns exported'), findsOneWidget);

    final mixdownDir = Directory('${tempDir.path}/Mixdown');
    final mixdowns = mixdownDir
        .listSync()
        .map((f) => f.path.split('/').last)
        .toSet();
    // The planted dummy survives untouched; the render deduplicated to (1).
    expect(mixdowns, {'MeinMix.wav', 'MeinMix (1).wav', 'fixture_2ch.wav'});
    expect(File('${mixdownDir.path}/MeinMix.wav').lengthSync(), 1);
    for (final name in ['MeinMix (1).wav', 'fixture_2ch.wav']) {
      final p = await rust.probeRecording(path: '${mixdownDir.path}/$name');
      expect(p.channels, 2); // every output is a stereo render
    }

    // Leave selection mode, then a row tap opens the take again.
    await tester.tap(
      find.descendant(
        of: find.byType(WavBrowserPage),
        matching: find.byIcon(Icons.close),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byType(Checkbox), findsNothing);
    await tester.tap(
      find.descendant(
        of: find.byType(WavBrowserPage),
        matching: find.text('fixture_4ch.wav'),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byType(WavBrowserPage), findsNothing);

    if (kScreenshots) {
      await _captureDocScreenshots(tester, state, tempDir);
    }
  });
}

// ── documentation screenshots (only with --dart-define=SCREENSHOTS=true) ────

/// Renders documentation screenshots from a musical-looking 8-track
/// fixture: mixer, EQ panel, mastering dialog, batch dialog, WAV browser,
/// phone layouts. Captured through the root RepaintBoundary — real
/// renderer, no OS interaction.
///
/// Next to every PNG a `<name>.json` lands with numbered marker rects
/// (label + position of each interactive control, in PNG pixels) — the
/// input for `tool/annotate_screenshots.py`, which draws the numbered
/// callouts used by docs/GUIDE.md. Coordinates come from the live widget
/// tree (`tester.getRect`), so they survive layout changes.
Future<void> _captureDocScreenshots(
  WidgetTester tester,
  MixerState state,
  Directory tempDir,
) async {
  // Docs are a dark-theme set. Pinned explicitly rather than inherited from
  // whatever the flow left behind: under ThemeMode.system the test binding
  // reports LIGHT, which would silently flip every screenshot in docs/.
  AppSettings.themeMode.value = ThemeMode.dark;
  await tester.pumpAndSettle();

  final shotsDir = Directory.systemTemp.createTempSync('durecmix_shots');

  Future<void> waitForAnalysis() async {
    while (state.analyzing) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    await tester.pumpAndSettle();
  }

  Future<void> shot(
    String name, [
    List<(String, Finder)> markers = const [],
  ]) async {
    await tester.pumpAndSettle();
    final boundary = tester.renderObject<RenderRepaintBoundary>(
      find.byKey(_shotKey),
    );
    late final Uint8List bytes;
    await tester.runAsync(() async {
      final image = await boundary.toImage(pixelRatio: 2);
      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      bytes = data!.buffer.asUint8List();
    });
    File('${shotsDir.path}/$name.png').writeAsBytesSync(bytes);
    if (markers.isNotEmpty) {
      final items = <Map<String, Object>>[];
      var n = 0;
      for (final (label, finder) in markers) {
        if (finder.evaluate().isEmpty) continue; // absent on this platform
        final rect = tester.getRect(finder.first);
        items.add({
          'n': ++n,
          'label': label,
          'x': rect.left * 2,
          'y': rect.top * 2,
          'w': rect.width * 2,
          'h': rect.height * 2,
        });
      }
      File(
        '${shotsDir.path}/$name.json',
      ).writeAsStringSync(const JsonEncoder.withIndent('  ').convert(items));
    }
  }

  const docTracks = [
    ('Kick', 55.0, 0.9, 2.0),
    ('Snare', 220.0, 0.55, 1.0),
    ('Bass', 82.0, 0.7, 0.5),
    ('Gtr L', 330.0, 0.4, 0.25),
    ('Gtr R', 333.0, 0.4, 0.25),
    ('Keys L', 523.0, 0.35, 0.125),
    ('Keys R', 527.0, 0.35, 0.125),
    ('Vocals', 440.0, 0.5, 0.4),
  ];
  final docsWav = '${tempDir.path}/UFX33_01_Demo.wav';
  File(
    docsWav,
  ).writeAsBytesSync(_buildFixtureWav(tracks: docTracks, seconds: 8));

  await state.open(docsWav);
  await waitForAnalysis();
  // The wide-layout tour only renders on desktop — phones contribute the
  // real phone shots below (batch/browser widgets differ per platform).
  if (!Platform.isAndroid) {
    // Wide desktop mixer.
    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1.0;
    tester.view.padding = FakeViewPadding.zero; // see the pin at the top
    tester.view.viewInsets = FakeViewPadding.zero;
    tester.view.viewInsets = FakeViewPadding.zero;
    await tester.pumpAndSettle();
    await shot('mixer', [
      (
        'Loaded take — tap to switch to another recording of the folder',
        find.textContaining('UFX33_01_Demo'),
      ),
      (
        'Reference mastering — match the export to reference songs',
        find.byIcon(Icons.auto_fix_high),
      ),
      (
        'Loudness target (applied on export)',
        find.byType(DropdownButton<LoudnessChoice>),
      ),
      ('Output format', find.byType(DropdownButton<rust.ApiFormat>)),
      ('Export the stereo mixdown', find.text('Export')),
      (
        'Batch export: several loudness/format targets in one go',
        find.byIcon(Icons.playlist_add_check),
      ),
      (
        'A/B mix snapshots — tap to store/recall, long-press to overwrite',
        find.text('A'),
      ),
      ('Link stereo pairs (·L/·R)', find.byIcon(Icons.link).first),
      ('Choose the recordings folder', find.byIcon(Icons.folder_open)),
      (
        'Track strip: fader, pan, ø/M/S/mix toggles, EQ, waveform',
        find.byType(TrackStrip).first,
      ),
      ('Play / stop the live preview', find.byIcon(Icons.play_arrow)),
      (
        'Set trim-in / trim-out at the playhead (long-press clears)',
        find.byIcon(Icons.first_page),
      ),
      (
        'Settings — appearance, About, links, feedback',
        find.byIcon(Icons.settings_outlined),
      ),
    ]);

    // EQ panel expanded on the vocal track.
    state.toggleEqPanel(state.tracks[7]);
    state.updateTrack(state.tracks[7], (t) => t.eq.hpfEnabled = true);
    await tester.pumpAndSettle();
    await shot('eq', [
      ('High-pass filter with 12/24 dB per octave slope', find.text('HPF')),
      ('Band on/off', find.byType(Switch).first),
      (
        'Expanded EQ panel of one track (chip toggles it)',
        find.text('EQ').first,
      ),
    ]);
    state.toggleEqPanel(state.tracks[7]);
    await tester.pumpAndSettle();

    // Mastering dialog with a reference chosen and the preview armed.
    await state.mastering.addReference(
      '${tempDir.path}/fixture_4ch.wav',
      'Reference Song.wav',
    );
    await state.mastering.enablePreview();
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.auto_fix_high));
    await tester.pumpAndSettle();
    await shot('mastering', [
      (
        'Master the export to the reference set',
        find.text('Master to reference'),
      ),
      (
        'Chosen reference — several average into one genre curve',
        find.text('Reference Song.wav'),
      ),
      (
        'Add another reference (WAV/FLAC/MP3)',
        find.textContaining('reference…'),
      ),
      (
        'Hear the mastered result in the live preview',
        find.text('Preview mastered playback'),
      ),
    ]);
    await tester.tap(find.text('Done'));
    await tester.pumpAndSettle();
    state.mastering.disablePreview();
    state.mastering.setEnabled(false);
    await tester.pumpAndSettle();

    // Batch-export dialog with two differing jobs queued.
    state.exporter.addBatchJob();
    state.exporter.addBatchJob();
    state.exporter.batchQueue[1]
      ..loudness = LoudnessChoice.lufs14
      ..format = rust.ApiFormat.mp3;
    await tester.tap(find.byIcon(Icons.playlist_add_check));
    await tester.pumpAndSettle();
    await shot('batch', [
      (
        'One job = one loudness target + format',
        find.byType(DropdownButton<LoudnessChoice>).first,
      ),
      ('Render all jobs into one folder', find.text('Export all…')),
    ]);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();

    // WAV browser over the temp folder (three fixtures listed).
    final browser = WavBrowser(await AppSettings.load());
    await browser.openFolder(tempDir.path);
    tester
        .state<NavigatorState>(find.byType(Navigator))
        .push(
          MaterialPageRoute(
            builder: (_) => WavBrowserPage(
              browser: browser,
              currentSource: docsWav,
              exportConfig: () => MultiExportConfig(
                tracks: const [],
                master: state.master,
                loudness: state.loudness,
                customLufs: state.customLufs,
                format: state.format,
              ),
            ),
          ),
        );
    // Let the lazy probe queue annotate the rows.
    for (
      var i = 0;
      i < 50 && browser.entries.any((e) => e.probe == null);
      i++
    ) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    await tester.pumpAndSettle();
    await shot('browser', [
      (
        'Selection mode: tick takes for multi-file export',
        find.byIcon(Icons.checklist),
      ),
      ('Sort by name / date', find.byIcon(Icons.sort_by_alpha)),
      ('Switch to another folder', find.byIcon(Icons.drive_folder_upload)),
      ('Currently loaded take', find.byIcon(Icons.graphic_eq)),
      (
        'Tap a row to open it in the mixer',
        find.byIcon(Icons.chevron_right).first,
      ),
    ]);
    tester.state<NavigatorState>(find.byType(Navigator)).pop();
    await tester.pumpAndSettle();
    browser.dispose();
  }

  // Phone layout + its overflow menu.
  tester.view.physicalSize = const Size(420, 860);
  tester.view.devicePixelRatio = 1.0;
  tester.view.padding = FakeViewPadding.zero; // see the pin at the top
  tester.view.viewInsets = FakeViewPadding.zero;
  await tester.pumpAndSettle();
  await shot('phone', [
    ('Export (progress shows here while rendering)', find.text('Export')),
    (
      'Settings — appearance, About, links, feedback',
      find.byIcon(Icons.settings_outlined),
    ),
    (
      'Everything else lives in the overflow menu',
      find.byType(PopupMenuButton<String>),
    ),
    ('Meters idle here and run while playing', find.byType(StereoPeakMeter)),
  ]);
  await tester.tap(find.byType(PopupMenuButton<String>));
  await tester.pumpAndSettle();
  await shot('phone_menu');
  tester.state<NavigatorState>(find.byType(Navigator)).pop();
  await tester.pumpAndSettle();
  tester.view.reset();
  await tester.pumpAndSettle();

  // ignore: avoid_print
  print('SCREENSHOT_DIR=${shotsDir.path}');
  if (Platform.isAndroid) {
    // Keep the app alive so the host can `run-as`-pull the shots — the
    // harness uninstalls the app afterwards and code_cache dies with it.
    for (var i = 0; i < 300; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
  }
}

/// 16-bit 44.1 kHz WAV with a DUREC-style iXML track list — the same shape
/// as `engine/examples/gen_fixture.rs`, small enough to build inline (the
/// app sandbox cannot read files the test didn't create itself). Each track
/// is `(name, freq, amp, pulseHz)`; a non-zero pulse rate applies a decaying
/// envelope so waveforms look like played notes (used for doc screenshots).
Uint8List _buildFixtureWav({
  List<(String, double, double, double)> tracks = const [
    ('Vocals', 440.0, 0.25, 0.0),
    ('Kick', 55.0, 0.5, 0.0),
    ('Keys L', 330.0, 0.125, 0.0),
    ('Keys R', 331.0, 0.125, 0.0),
  ],
  int seconds = 2,
}) {
  const sampleRate = 44100;
  final channels = tracks.length;

  final frames = sampleRate * seconds;
  final data = BytesBuilder();
  for (var n = 0; n < frames; n++) {
    final t = n / sampleRate;
    for (final (_, freq, amp, pulseHz) in tracks) {
      final envelope = pulseHz == 0.0
          ? 1.0
          : math.exp(-5.0 * ((t * pulseHz) - (t * pulseHz).floorToDouble()));
      final v = (amp * envelope * math.sin(2 * math.pi * freq * t) * 32767)
          .round();
      data.add([v & 0xFF, (v >> 8) & 0xFF]);
    }
  }

  final ixmlTracks = StringBuffer();
  for (var i = 0; i < tracks.length; i++) {
    ixmlTracks.write(
      '<TRACK><CHANNEL_INDEX>${i + 1}</CHANNEL_INDEX>'
      '<INTERLEAVE_INDEX>${i + 1}</INTERLEAVE_INDEX>'
      '<NAME>${tracks[i].$1}</NAME></TRACK>',
    );
  }
  final ixml =
      '<?xml version="1.0" encoding="UTF-8"?><BWFXML>'
      '<IXML_VERSION>1.5</IXML_VERSION><TRACK_LIST>'
      '<TRACK_COUNT>$channels</TRACK_COUNT>$ixmlTracks</TRACK_LIST></BWFXML>';

  Uint8List chunk(String id, List<int> payload) {
    final b = BytesBuilder();
    b.add(ascii.encode(id));
    b.add(_u32(payload.length));
    b.add(payload);
    if (payload.length.isOdd) b.addByte(0);
    return b.toBytes();
  }

  final blockAlign = channels * 2;
  final fmt = BytesBuilder()
    ..add(_u16(1)) // PCM
    ..add(_u16(channels))
    ..add(_u32(sampleRate))
    ..add(_u32(sampleRate * blockAlign))
    ..add(_u16(blockAlign))
    ..add(_u16(16));

  final body = BytesBuilder()
    ..add(ascii.encode('WAVE'))
    ..add(chunk('fmt ', fmt.toBytes()))
    ..add(chunk('data', data.toBytes()))
    ..add(chunk('iXML', utf8.encode(ixml)));

  final bodyBytes = body.toBytes();
  final file = BytesBuilder()
    ..add(ascii.encode('RIFF'))
    ..add(_u32(bodyBytes.length))
    ..add(bodyBytes);
  return file.toBytes();
}

Uint8List _u16(int v) =>
    Uint8List(2)..buffer.asByteData().setUint16(0, v, Endian.little);
Uint8List _u32(int v) =>
    Uint8List(4)..buffer.asByteData().setUint32(0, v, Endian.little);

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:path_provider/path_provider.dart';

import '../src/rust/api/mixer.dart' as rust;
import 'session_paths.dart';

/// Cache of analyzed reference profiles: analyzing a reference decodes the
/// whole file (slow for a long FLAC on a phone), but the result is a tiny
/// spectrum fingerprint (~16 KB JSON). Cached per reference file so choosing
/// the same track again — or exporting later without re-granting SAF access
/// to the reference — is instant.
///
/// Keyed by the source identity hash and the engine's profile version, so
/// algorithm changes invalidate stored profiles naturally.
class ReferenceProfileCache {
  static Future<File> _fileFor(String source) async {
    final support = await getApplicationSupportDirectory();
    final dir = Directory('${support.path}/reference_profiles');
    await dir.create(recursive: true);
    final version = await rust.referenceProfileVersion();
    return File('${dir.path}/${sourceHashFor(source)}_v$version.json');
  }

  static Future<rust.ApiReferenceProfile?> load(String source) async {
    try {
      final file = await _fileFor(source);
      if (!file.existsSync()) return null;
      final m = jsonDecode(await file.readAsString()) as Map<String, dynamic>;
      Float32List spectrum(String key) =>
          Float32List.fromList((m[key] as List).cast<num>().map((v) => v.toDouble()).toList());
      return rust.ApiReferenceProfile(
        version: m['version'] as int,
        sampleRate: m['sampleRate'] as int,
        fftSize: m['fftSize'] as int,
        pieceSeconds: (m['pieceSeconds'] as num).toDouble(),
        durationSeconds: (m['durationSeconds'] as num).toDouble(),
        midRms: (m['midRms'] as num).toDouble(),
        sideRms: (m['sideRms'] as num).toDouble(),
        midSpectrum: spectrum('midSpectrum'),
        sideSpectrum: spectrum('sideSpectrum'),
      );
    } catch (_) {
      return null; // any corruption → treat as miss
    }
  }

  static Future<void> save(String source, rust.ApiReferenceProfile p) async {
    try {
      final file = await _fileFor(source);
      await file.writeAsString(jsonEncode({
        'version': p.version,
        'sampleRate': p.sampleRate,
        'fftSize': p.fftSize,
        'pieceSeconds': p.pieceSeconds,
        'durationSeconds': p.durationSeconds,
        'midRms': p.midRms,
        'sideRms': p.sideRms,
        'midSpectrum': p.midSpectrum,
        'sideSpectrum': p.sideSpectrum,
      }));
    } catch (_) {
      // Cache writes are best effort — never surface failures.
    }
  }
}

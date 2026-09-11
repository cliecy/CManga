import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:cmanga/foundation/appdata.dart';

void main() {
  final settings = appdata.settings;
  const integerValues = <String, int>{
    'preloadImageCount': 8,
    'downloadThreads': 6,
    'autoPageTurningInterval': 10,
    'readerScreenPicNumberForLandscape': 3,
    'readerScreenPicNumberForPortrait': 2,
  };
  const aiValues = <String, double>{
    'anime4KV4Intensity': 1.30,
    'anime4KEnhancementStrength': 0.35,
    'colorizationIntensity': 0.35,
  };
  late Map<String, dynamic> previousValues;

  setUp(() {
    previousValues = {
      for (final key in integerValues.keys) key: settings[key],
      for (final key in aiValues.keys) key: settings[key],
      'comicSpecificSettings': settings['comicSpecificSettings'],
    };
    settings['comicSpecificSettings'] = <String, dynamic>{};
  });

  tearDown(() {
    for (final entry in previousValues.entries) {
      settings[entry.key] = entry.value;
    }
  });

  test('legacy JSON doubles satisfy the global integer settings contract', () {
    final legacySettings =
        jsonDecode(
              jsonEncode({
                for (final entry in integerValues.entries)
                  entry.key: entry.value.toDouble(),
              }),
            )
            as Map<String, dynamic>;

    // Loading appdata and applying sync data both use this Settings API.
    for (final entry in legacySettings.entries) {
      settings[entry.key] = entry.value;
    }

    for (final entry in integerValues.entries) {
      final int value = settings[entry.key];
      expect(value, entry.value, reason: entry.key);
    }
  });

  test('legacy comic overrides are integers and keep reader precedence', () {
    for (final key in integerValues.keys) {
      settings[key] = 1.0;
    }
    settings['comicSpecificSettings'] = jsonDecode(
      jsonEncode({
        'comic@source': {
          'enabled': true,
          for (final entry in integerValues.entries)
            entry.key: entry.value.toDouble(),
        },
      }),
    );

    for (final entry in integerValues.entries) {
      final int value = settings.getReaderSetting('comic', 'source', entry.key);
      expect(value, entry.value, reason: entry.key);
      final int otherComicValue = settings.getReaderSetting(
        'other',
        'source',
        entry.key,
      );
      expect(otherComicValue, 1, reason: entry.key);
    }

    settings.setEnabledComicSpecificSettings('comic', 'source', false);
    final int disabledValue = settings.getReaderSetting(
      'comic',
      'source',
      'preloadImageCount',
    );
    expect(disabledValue, 1);

    settings.setEnabledComicSpecificSettings('comic', 'source', true);
    settings.setReaderSetting('comic', 'source', 'preloadImageCount', 12.0);
    final int updatedValue = settings.getReaderSetting(
      'comic',
      'source',
      'preloadImageCount',
    );
    expect(updatedValue, 12);
    final int globalValue = settings['preloadImageCount'];
    expect(globalValue, 1);

    settings.resetComicReaderSettings('comic@source');
    settings.setEnabledComicSpecificSettings('comic', 'source', true);
    final int missingOverride = settings.getReaderSetting(
      'comic',
      'source',
      'preloadImageCount',
    );
    expect(missingOverride, 1);
  });

  test('AI decimal settings survive global and comic reads and writes', () {
    for (final entry in aiValues.entries) {
      settings[entry.key] = entry.value;
    }
    settings['comicSpecificSettings'] = jsonDecode(
      jsonEncode({
        'comic@source': {'enabled': true, ...aiValues},
      }),
    );

    for (final entry in aiValues.entries) {
      final double globalValue = settings[entry.key];
      final double comicValue = settings.getReaderSetting(
        'comic',
        'source',
        entry.key,
      );
      expect(globalValue, entry.value, reason: entry.key);
      expect(comicValue, entry.value, reason: entry.key);
    }

    settings.setReaderSetting(
      'comic',
      'source',
      'anime4KEnhancementStrength',
      0.65,
    );
    final double updatedValue = settings.getReaderSetting(
      'comic',
      'source',
      'anime4KEnhancementStrength',
    );
    expect(updatedValue, 0.65);
    expect(settings['anime4KEnhancementStrength'], 0.35);
  });
}

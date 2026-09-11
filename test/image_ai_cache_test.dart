import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:cmanga/utils/image_ai_cache.dart';

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  final cache = ImageAiCache.instance;
  late Directory root;
  late String directory;
  final png = Uint8List.fromList(img.encodePng(img.Image(width: 2, height: 3)));
  final key = sha256.convert(utf8.encode('page')).toString();
  late int entryBytes;

  String page(int number) =>
      sha256.convert(utf8.encode('page-$number')).toString();

  File imageFile(String group, String digest, {String? scope}) {
    final container = scope == null
        ? directory
        : '$directory/scopes/${sha256.convert(utf8.encode(scope))}';
    return File('$container/${group}_$digest.png');
  }

  Future<void> age(String group, String digest, int order, {String? scope}) =>
      imageFile(
        group,
        digest,
        scope: scope,
      ).setLastModified(DateTime.utc(2000, 1, 1, 0, 0, order));

  setUpAll(() async {
    root = await Directory.systemTemp.createTemp('cmanga-cache-regression-');
    binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (call) async => '${root.path}/${call.method}',
    );
    directory = await cache.directory();
    await cache.write('esrgan', key, png);
    entryBytes = await cache.size('esrgan');
  });
  setUp(() async {
    await cache.setLimits(
      defaultMaxBytes: 2 * 1024 * 1024 * 1024,
      comicMaxBytes: {},
    );
    await cache.clear('esrgan');
    await cache.clear('deoldify');
  });
  tearDownAll(() async {
    binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      null,
    );
    await root.delete(recursive: true);
  });

  test(
    'interrupted replacement cannot pair new pixels with old metadata',
    () async {
      await cache.write('esrgan', key, png, metadata: {'scale': 2});
      final changed = img.Image(width: 4, height: 6);
      changed.setPixelRgb(0, 0, 255, 0, 0);
      await File(
        '$directory/esrgan_$key.png',
      ).writeAsBytes(img.encodePng(changed));
      expect(await cache.read('esrgan', key), isNull);
      await cache.write('esrgan', key, png, metadata: {'scale': 2});
      final restored = await cache.read('esrgan', key);
      expect(restored!.bytes, png);
      expect(restored.metadata['scale'], 2);
    },
  );

  test('incomplete PNG cannot replace a previously completed result', () async {
    await cache.write('deoldify', key, png, metadata: {'backend': 'metal'});
    await expectLater(
      cache.write(
        'deoldify',
        key,
        Uint8List.sublistView(png, 0, png.length - 12),
      ),
      throwsFormatException,
    );
    final result = await cache.read('deoldify', key);
    expect(result!.bytes, png);
    expect(result.metadata['backend'], 'metal');
  });

  test('comic quotas have independent cross-engine LRU pools', () async {
    await cache.setLimits(
      defaultMaxBytes: entryBytes,
      comicMaxBytes: {'a@local': entryBytes * 2, 'b@source': entryBytes},
    );
    await cache.write('esrgan', page(1), png, scope: 'a@local');
    await cache.write('deoldify', page(2), png, scope: 'a@local');
    await cache.write('esrgan', page(3), png, scope: 'b@source');
    await cache.write('esrgan', page(4), png);
    await age('esrgan', page(1), 1, scope: 'a@local');
    await age('deoldify', page(2), 2, scope: 'a@local');
    expect((await cache.read('esrgan', page(1), scope: 'a@local'))?.bytes, png);
    await cache.write('esrgan', page(5), png, scope: 'a@local');

    expect(await cache.read('deoldify', page(2), scope: 'a@local'), isNull);
    expect((await cache.read('esrgan', page(1), scope: 'a@local'))?.bytes, png);
    expect((await cache.read('esrgan', page(5), scope: 'a@local'))?.bytes, png);
    expect(
      (await cache.read('esrgan', page(3), scope: 'b@source'))?.bytes,
      png,
    );
    expect((await cache.read('esrgan', page(4)))?.bytes, png);
  });

  test('unconfigured scopes and flat entries share one LRU budget', () async {
    await cache.setLimits(defaultMaxBytes: entryBytes * 2, comicMaxBytes: {});
    await cache.write('esrgan', page(1), png);
    await age('esrgan', page(1), 1);
    await cache.write('deoldify', page(2), png, scope: 'a@local');
    await age('deoldify', page(2), 2, scope: 'a@local');
    await cache.write('esrgan', page(3), png, scope: 'b@source');

    expect(await cache.read('esrgan', page(1)), isNull);
    expect(
      (await cache.read('deoldify', page(2), scope: 'a@local'))?.bytes,
      png,
    );
    expect(
      (await cache.read('esrgan', page(3), scope: 'b@source'))?.bytes,
      png,
    );

    await age('esrgan', page(3), 1, scope: 'b@source');
    await cache.write('esrgan', page(4), png);
    expect(await cache.read('esrgan', page(3), scope: 'b@source'), isNull);
    expect(
      (await cache.read('deoldify', page(2), scope: 'a@local'))?.bytes,
      png,
    );
    expect((await cache.read('esrgan', page(4)))?.bytes, png);

    await age('deoldify', page(2), 1, scope: 'a@local');
    await cache.setLimits(defaultMaxBytes: entryBytes, comicMaxBytes: {});
    expect(await cache.read('deoldify', page(2), scope: 'a@local'), isNull);
    expect((await cache.read('esrgan', page(4)))?.bytes, png);
  });

  test(
    'changing and removing quotas immediately rebalances existing entries',
    () async {
      await cache.setLimits(
        defaultMaxBytes: entryBytes,
        comicMaxBytes: {'a@local': entryBytes * 2, 'b@source': entryBytes},
      );
      await cache.write('esrgan', page(1), png, scope: 'a@local');
      await age('esrgan', page(1), 1, scope: 'a@local');
      await cache.write('deoldify', page(2), png, scope: 'a@local');
      await cache.write('esrgan', page(3), png, scope: 'b@source');
      await cache.write('esrgan', page(4), png);
      await age('esrgan', page(4), 2);

      await cache.setLimits(
        defaultMaxBytes: entryBytes,
        comicMaxBytes: {'a@local': entryBytes, 'b@source': entryBytes},
      );
      expect(await cache.read('esrgan', page(1), scope: 'a@local'), isNull);
      expect(
        (await cache.read('deoldify', page(2), scope: 'a@local'))?.bytes,
        png,
      );
      expect((await cache.read('esrgan', page(4)))?.bytes, png);
      await age('esrgan', page(4), 2);

      await cache.setLimits(
        defaultMaxBytes: entryBytes,
        comicMaxBytes: {'b@source': entryBytes},
      );
      expect(await cache.read('esrgan', page(4)), isNull);
      expect(
        (await cache.read('deoldify', page(2), scope: 'a@local'))?.bytes,
        png,
      );
      expect(
        (await cache.read('esrgan', page(3), scope: 'b@source'))?.bytes,
        png,
      );

      // The on-disk scope survives removal, so restoring its quota protects the
      // existing result without rewriting it or persisting a stale byte limit.
      await cache.setLimits(
        defaultMaxBytes: entryBytes,
        comicMaxBytes: {'a@local': entryBytes, 'b@source': entryBytes},
      );
      await age('deoldify', page(2), 1, scope: 'a@local');
      await cache.write('esrgan', page(5), png);
      expect(
        (await cache.read('deoldify', page(2), scope: 'a@local'))?.bytes,
        png,
      );
      expect((await cache.read('esrgan', page(5)))?.bytes, png);
    },
  );

  test(
    'legacy flat results are adopted and protected by the requesting quota',
    () async {
      await imageFile('esrgan', key).writeAsBytes(png);
      await File(
        '$directory/esrgan_$key.json',
      ).writeAsString(jsonEncode({'scale': 2}));
      const scope = '../../comic@local';
      await cache.setLimits(
        defaultMaxBytes: entryBytes * 2,
        comicMaxBytes: {scope: entryBytes * 2},
      );
      final adopted = await cache.read('esrgan', key, scope: scope);
      expect(adopted?.bytes, png);
      expect(adopted?.metadata['scale'], 2);
      expect(await cache.read('esrgan', key), isNull);

      await cache.setLimits(
        defaultMaxBytes: 0,
        comicMaxBytes: {scope: entryBytes * 2},
      );
      final reference = ImageAiCacheRef('esrgan', key, scope: scope);
      expect(await reference.read(), png);
      final changed = img.Image(width: 4, height: 6);
      changed.setPixelRgb(0, 0, 255, 0, 0);
      await imageFile(
        'esrgan',
        key,
        scope: scope,
      ).writeAsBytes(img.encodePng(changed));
      expect(await reference.read(), isNull);
    },
  );

  test('failed adoption still returns validated legacy output', () async {
    await cache.write('esrgan', key, png, metadata: {'scale': 2});
    const scope = 'blocked@local';
    final container = imageFile('esrgan', key, scope: scope).parent;
    await container.parent.create(recursive: true);
    final blocker = File(container.path);
    await blocker.writeAsString('not a directory');
    try {
      final result = await cache.read('esrgan', key, scope: scope);
      expect(result?.bytes, png);
      expect(result?.metadata['scale'], 2);
      expect(result?.metadata['cacheWarning'], isNotNull);
      expect((await cache.read('esrgan', key))?.bytes, png);
    } finally {
      await blocker.delete();
    }
  });

  test(
    'queued reads observe complete writes and subsequent clearing',
    () async {
      final reference = ImageAiCacheRef('esrgan', key, scope: 'a@local');
      final writing = cache.write('esrgan', key, png, scope: 'a@local');
      final completed = reference.read();
      final clearing = cache.clear('esrgan');
      final cleared = reference.read();
      await writing;
      expect(await completed, png);
      await clearing;
      expect(await cleared, isNull);
    },
  );

  test(
    'group size and clear include every scope without clearing other engines',
    () async {
      await cache.write('esrgan', page(1), png);
      await cache.write('esrgan', page(1), png, scope: 'a@local');
      await cache.write('esrgan', page(1), png, scope: 'b@source');
      await cache.write('deoldify', page(1), png, scope: 'a@local');
      expect(await cache.size('esrgan'), entryBytes * 3);

      await cache.clear('esrgan');
      expect(await cache.size('esrgan'), 0);
      expect(await ImageAiCacheRef('esrgan', page(1)).read(), isNull);
      expect(
        await ImageAiCacheRef('esrgan', page(1), scope: 'a@local').read(),
        isNull,
      );
      expect(
        await ImageAiCacheRef('esrgan', page(1), scope: 'b@source').read(),
        isNull,
      );
      expect(
        (await cache.read('deoldify', page(1), scope: 'a@local'))?.bytes,
        png,
      );
    },
  );
}

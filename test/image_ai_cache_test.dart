import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:venera/utils/image_ai_cache.dart';

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  final cache = ImageAiCache.instance;
  late Directory root;
  late String directory;
  final png = Uint8List.fromList(img.encodePng(img.Image(width: 2, height: 3)));
  final key = sha256.convert(utf8.encode('page')).toString();

  setUpAll(() async {
    root = await Directory.systemTemp.createTemp('venera-cache-regression-');
    binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (call) async => '${root.path}/${call.method}',
    );
    directory = await cache.directory();
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
}

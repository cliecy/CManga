import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:cmanga/foundation/image_provider/base_image_provider.dart';

class ControlledImage extends BaseImageProvider<ControlledImage> {
  ControlledImage(this.key);

  @override
  final String key;
  final release = Completer<Uint8List>();
  var completedLoads = 0;

  @override
  Future<ControlledImage> obtainKey(ImageConfiguration configuration) =>
      SynchronousFuture(this);

  @override
  Future<Uint8List> load(
    StreamController<ImageChunkEvent> chunks,
    void Function() checkStop,
  ) async {
    final bytes = await release.future;
    checkStop();
    completedLoads++;
    return bytes;
  }
}

Future<ui.Codec> decodeImage(
  ui.ImmutableBuffer buffer, {
  ui.TargetImageSizeCallback? getTargetSize,
}) => ui.instantiateImageCodecWithSize(buffer, getTargetSize: getTargetSize);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final png = Uint8List.fromList(img.encodePng(img.Image(width: 2, height: 3)));

  test(
    'Abandoning an image stops processing without reporting a load failure',
    () async {
      final previousHandler = FlutterError.onError;
      final errors = <FlutterErrorDetails>[];
      FlutterError.onError = errors.add;
      addTearDown(() => FlutterError.onError = previousHandler);
      final provider = ControlledImage('cancelled');
      final stream = provider.loadImage(provider, decodeImage);
      final listener = ImageStreamListener((image, _) => image.dispose());
      stream.addListener(listener);
      stream.removeListener(listener);
      provider.release.complete(png);
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);
      expect(provider.completedLoads, 0);
      expect(errors, isEmpty);
    },
  );

  test(
    'Normal chunk stream completion still delivers the decoded image',
    () async {
      final provider = ControlledImage('completed');
      final stream = provider.loadImage(provider, decodeImage);
      final result = Completer<ImageInfo>();
      final listener = ImageStreamListener(
        (image, _) => result.complete(image),
        onError: result.completeError,
      );
      stream.addListener(listener);
      provider.release.complete(png);
      final image = await result.future.timeout(const Duration(seconds: 5));
      expect((image.image.width, image.image.height), (2, 3));
      image.dispose();
      stream.removeListener(listener);
    },
  );

  test('A real failure still reaches an active image consumer', () async {
    final provider = ControlledImage('failed');
    final stream = provider.loadImage(provider, decodeImage);
    final result = Completer<Object>();
    final listener = ImageStreamListener(
      (image, _) => image.dispose(),
      onError: (error, _) => result.complete(error),
    );
    stream.addListener(listener);
    final failure = StateError('Invalid Status Code: 403');
    provider.release.completeError(failure);
    expect(await result.future, same(failure));
    stream.removeListener(listener);
  });
}

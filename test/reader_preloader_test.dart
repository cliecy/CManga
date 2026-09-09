import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/services.dart';
import 'package:crypto/crypto.dart';
import 'package:image/image.dart' as img;
import 'package:venera/utils/image_ai_cache.dart';
import 'package:venera/foundation/image_provider/reader_image.dart';
import 'package:venera/foundation/image_provider/reader_image_details.dart';
import 'package:venera/foundation/image_provider/reader_preloader.dart';
import 'package:venera/utils/image_ai_service.dart';

class _Attempt {
  final result = Completer<Uint8List>();

  void succeed(int value) => result.complete(Uint8List.fromList([value]));

  void fail(Object error) => result.completeError(error);
}

class _ControlledPage extends ReaderImageProvider {
  _ControlledPage(int page, this.startedPages, {required this.cacheResults})
    : super('page-$page', 'local', 'comic', 'chapter', page);

  final List<int> startedPages;
  final bool cacheResults;
  final _attempts = <Completer<_Attempt>>[];
  var _starts = 0;
  Uint8List? _cached;
  ImageAiCacheRef? renderedRef;

  Completer<_Attempt> _slot(int index) {
    while (_attempts.length <= index) {
      _attempts.add(Completer<_Attempt>());
    }
    return _attempts[index];
  }

  Future<_Attempt> attempt([int index = 0]) => _slot(index).future;

  ReaderImageDetails get details => ReaderImageDetailsStore.instance.lookup(
    imageKey,
    sourceKey,
    cid,
    eid,
    page,
  )!;

  @override
  Future<Uint8List> loadForQueue(
    StreamController<ImageChunkEvent> chunkEvents,
    void Function() checkStop, {
    required ReaderImageDetails record,
    bool forceReprocess = false,
  }) async {
    final attempt = _Attempt();
    startedPages.add(page);
    _slot(_starts++).complete(attempt);
    // Native work can return after cancellation. The queue must independently
    // reject its stale result, even when the provider never calls checkStop.
    final generated = await attempt.result.future;
    record.cacheRef = renderedRef;
    if (!cacheResults) return generated;
    final bytes = forceReprocess ? generated : _cached ?? generated;
    _cached = bytes;
    return bytes;
  }
}

class _Chapter {
  _Chapter(int count, {int initialPage = 1, bool cacheResults = false}) {
    pages = List.generate(
      count,
      (index) =>
          _ControlledPage(index + 1, started, cacheResults: cacheResults),
    );
    queue.configure(pages, initialPage: initialPage);
    addTearDown(queue.dispose);
  }

  final queue = ReaderPreloader();
  final started = <int>[];
  late final List<_ControlledPage> pages;

  _ControlledPage page(int number) => pages[number - 1];

  Future<Uint8List> read(int number) async {
    final events = StreamController<ImageChunkEvent>.broadcast();
    try {
      return await queue.load(page(number), events);
    } finally {
      await events.close();
    }
  }
}

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  late Directory cacheRoot;
  final diskCache = ImageAiCache.instance;
  final cachedPng = Uint8List.fromList(
    img.encodePng(img.Image(width: 2, height: 3)),
  );
  final cachedKey = sha256.convert(utf8.encode('reader-return')).toString();
  late ImageAiCacheRef renderedRef;
  setUpAll(() async {
    cacheRoot = await Directory.systemTemp.createTemp('reader-return-');
    binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (call) async => '${cacheRoot.path}/${call.method}',
    );
    await diskCache.directory();
    renderedRef = ImageAiCacheRef(
      'reader_return',
      cachedKey,
      scope: 'comic@local',
    );
  });
  tearDownAll(() async {
    binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      null,
    );
    await cacheRoot.delete(recursive: true);
  });

  test(
    'completed disk result returns while a later page is still processing',
    () async {
      final chapter = _Chapter(2);
      chapter.page(1).renderedRef = renderedRef;
      await diskCache.write(
        'reader_return',
        cachedKey,
        cachedPng,
        scope: 'comic@local',
      );
      final firstRead = chapter.read(1);
      (await chapter.page(1).attempt()).result.complete(cachedPng);
      expect(await firstRead, cachedPng);
      final laterRead = chapter.read(2);
      final later = await chapter.page(2).attempt();
      try {
        expect(
          await chapter.read(1).timeout(const Duration(seconds: 5)),
          cachedPng,
        );
        expect(chapter.page(1).details.state, 'Complete');
        expect(chapter.started, [1, 2]);
      } finally {
        later.succeed(2);
        await laterRead;
      }
      // Explicit reprocessing must bypass the otherwise reusable completed result.
      final forced = chapter.queue.reprocess(chapter.page(1));
      (await chapter.page(1).attempt(1)).succeed(9);
      await forced;
      expect(chapter.started, [1, 2, 1]);
    },
  );

  test('evicted completed result rejoins the processing queue', () async {
    final chapter = _Chapter(1);
    chapter.page(1).renderedRef = renderedRef;
    await diskCache.write(
      'reader_return',
      cachedKey,
      cachedPng,
      scope: 'comic@local',
    );
    final firstRead = chapter.read(1);
    (await chapter.page(1).attempt()).result.complete(cachedPng);
    await firstRead;
    await diskCache.clear('reader_return');
    final reload = chapter.read(1);
    (await chapter.page(1).attempt(1)).succeed(7);
    expect(await reload, [7]);
    expect(chapter.started, [1, 1]);
  });
  test('more than 16 admitted pages survive jumps in chapter order', () async {
    final chapter = _Chapter(24, initialPage: 5);
    final visible = chapter.read(5);
    final first = await chapter.page(5).attempt();

    chapter.queue.update([chapter.page(24)]);
    chapter.queue.update([chapter.page(12)]);
    first.succeed(5);
    expect(await visible, [5]);

    for (var number = 6; number <= 24; number++) {
      final attempt = await chapter.page(number).attempt();
      expect(chapter.page(number - 1).details.state, 'Complete');
      attempt.succeed(number);
    }
    await pumpEventQueue();

    expect(chapter.started, List.generate(20, (index) => index + 5));
    expect(chapter.page(24).details.state, 'Complete');
  });

  test(
    'failure survives new demand until an explicit in-place retry',
    () async {
      final chapter = _Chapter(3);
      final failedRead = expectLater(
        chapter.read(1),
        throwsA(isA<ImageAiFailure>()),
      );
      final first = await chapter.page(1).attempt();
      var laterCompleted = false;
      final later = chapter.read(3).then((bytes) {
        laterCompleted = true;
        return bytes;
      });
      first.fail(
        ImageAiFailure(
          'test',
          'processing failed',
          previewBytes: Uint8List.fromList([99]),
        ),
      );
      await failedRead;
      await pumpEventQueue();

      chapter.queue.update([chapter.page(3)]);
      await expectLater(
        chapter.read(1),
        throwsA(
          isA<ImageAiFailure>().having(
            (error) => error.previewBytes,
            'retained preview',
            isNull,
          ),
        ),
      );
      await pumpEventQueue();
      expect(chapter.started, [1]);
      expect(laterCompleted, isFalse);
      expect(chapter.queue.blockedPage, chapter.page(1));
      expect(chapter.page(1).details.state, 'Failed');
      expect(chapter.page(2).details.state, 'Waiting for previous page');
      expect(chapter.page(3).details.state, 'Waiting for previous page');

      final retried = chapter.queue.reprocess(chapter.page(1));
      expect(chapter.page(1).details.state, 'Retrying');
      (await chapter.page(1).attempt(1)).succeed(11);
      await retried;
      (await chapter.page(2).attempt()).succeed(2);
      (await chapter.page(3).attempt()).succeed(3);
      expect(await later, [3]);
      expect(chapter.started, [1, 1, 2, 3]);
      expect(chapter.queue.blockedPage, isNull);
      expect(chapter.page(1).details.state, 'Complete');
    },
  );

  test(
    'disposal rejects readers and discards late native completion',
    () async {
      final chapter = _Chapter(2);
      final cancelled = expectLater(
        chapter.read(1),
        throwsA(isA<ReaderProcessingCancelled>()),
      );
      final active = await chapter.page(1).attempt();
      final record = chapter.page(1).details;
      chapter.queue.update([chapter.page(2)]);

      chapter.queue.dispose();
      await cancelled;
      chapter.queue.update(chapter.pages);
      await expectLater(
        chapter.read(2),
        throwsA(isA<ReaderProcessingCancelled>()),
      );
      active.succeed(1);
      await pumpEventQueue();

      expect(chapter.started, [1]);
      expect(record.state, 'Cancelled');
      expect(ReaderPreloader.forPage(chapter.page(1)), isNull);
    },
  );

  test(
    'settings invalidation cannot deliver the previous generation',
    () async {
      final chapter = _Chapter(2);
      chapter.queue.update(chapter.pages);
      final cancelled = expectLater(
        chapter.read(1),
        throwsA(isA<ReaderProcessingCancelled>()),
      );
      final old = await chapter.page(1).attempt();
      final oldRecord = chapter.page(1).details;

      ReaderPreloader.invalidateAll();
      await cancelled;
      var replacementCompleted = false;
      final replacement = chapter.read(1).then((bytes) {
        replacementCompleted = true;
        return bytes;
      });
      old.succeed(10);
      final updated = await chapter.page(1).attempt(1);
      expect(replacementCompleted, isFalse);
      expect(oldRecord.state, 'Cancelled');
      updated.succeed(20);
      expect(await replacement, [20]);
      (await chapter.page(2).attempt()).succeed(2);
      await pumpEventQueue();

      expect(chapter.started, [1, 1, 2]);
      expect(chapter.page(1).details.state, 'Complete');
      expect(chapter.page(2).details.state, 'Complete');
    },
  );

  test(
    'forced reprocess replaces in-flight bytes rather than reusing cache',
    () async {
      final chapter = _Chapter(1, cacheResults: true);
      var visibleCompleted = false;
      final visible = chapter.read(1).then((bytes) {
        visibleCompleted = true;
        return bytes;
      });
      final obsolete = await chapter.page(1).attempt();

      final reprocessed = chapter.queue.reprocess(chapter.page(1));
      obsolete.succeed(7);
      final fresh = await chapter.page(1).attempt(1);
      expect(visibleCompleted, isFalse);
      fresh.succeed(9);
      await reprocessed;

      expect(await visible, [9]);
      expect(chapter.started, [1, 1]);
      expect(chapter.page(1).details.state, 'Complete');
    },
  );

  test('forced completed page still waits behind an earlier failure', () async {
    final chapter = _Chapter(3, initialPage: 3, cacheResults: true);
    final original = chapter.read(3);
    (await chapter.page(3).attempt()).succeed(3);
    expect(await original, [3]);

    final failed = expectLater(chapter.read(1), throwsStateError);
    (await chapter.page(1).attempt()).fail(StateError('earlier page failed'));
    await failed;
    final reprocessed = chapter.queue.reprocess(chapter.page(3));
    final replacement = chapter.read(3);
    await pumpEventQueue();
    expect(chapter.started, [3, 1]);
    expect(chapter.queue.blockedPage, chapter.page(1));
    expect(chapter.page(3).details.state, 'Waiting for previous page');

    final retried = chapter.queue.reprocess(chapter.page(1));
    (await chapter.page(1).attempt(1)).succeed(11);
    await retried;
    (await chapter.page(2).attempt()).succeed(2);
    (await chapter.page(3).attempt(1)).succeed(33);
    await reprocessed;

    expect(await replacement, [33]);
    expect(chapter.started, [3, 1, 1, 2, 3]);
  });

  test('backward demand preserves each failure until its own retry', () async {
    final chapter = _Chapter(3, initialPage: 2);
    final secondFailure = expectLater(chapter.read(2), throwsStateError);
    (await chapter.page(2).attempt()).fail(StateError('second page failed'));
    await secondFailure;
    final firstFailure = expectLater(chapter.read(1), throwsStateError);
    chapter.queue.update([chapter.page(3)]);
    (await chapter.page(1).attempt()).fail(StateError('first page failed'));
    await firstFailure;

    expect(chapter.queue.blockedPage, chapter.page(1));
    expect(chapter.page(1).details.state, 'Failed');
    expect(chapter.page(2).details.state, 'Failed');
    expect(chapter.page(3).details.state, 'Waiting for previous page');
    expect(chapter.page(3).details.values['Waiting for page'], '1');

    final retryFirst = chapter.queue.reprocess(chapter.page(1));
    (await chapter.page(1).attempt(1)).succeed(11);
    await retryFirst;
    await pumpEventQueue();
    expect(chapter.started, [2, 1, 1]);
    expect(chapter.queue.blockedPage, chapter.page(2));
    expect(chapter.page(2).details.state, 'Failed');
    expect(chapter.page(3).details.values['Waiting for page'], '2');

    final retrySecond = chapter.queue.reprocess(chapter.page(2));
    (await chapter.page(2).attempt(1)).succeed(22);
    await retrySecond;
    (await chapter.page(3).attempt()).succeed(3);
    await pumpEventQueue();
    expect(chapter.started, [2, 1, 1, 2, 3]);
    expect(chapter.page(3).details.state, 'Complete');
  });
}

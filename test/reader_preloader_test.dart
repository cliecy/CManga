import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/image_provider/reader_image.dart';
import 'package:venera/foundation/image_provider/reader_preloader.dart';

class _ControlledPage extends ReaderImageProvider {
  _ControlledPage(String id) : super(id, 'local', 'comic', 'chapter', 1);

  final started = Completer<void>();
  final release = Completer<void>();
  var starts = 0;
  var completed = false;

  @override
  Future<Uint8List> load(
    StreamController<ImageChunkEvent> chunkEvents,
    void Function() checkStop, {
    Uint8List? sourceBytes,
  }) async {
    starts++;
    if (!started.isCompleted) started.complete();
    await release.future;
    checkStop();
    completed = true;
    return Uint8List(1);
  }
}

void main() {
  test(
    'preloading is bounded and drops pages outside the new window',
    () async {
      final queue = ReaderPreloader();
      addTearDown(queue.dispose);
      final first = _ControlledPage('first');
      final obsolete = _ControlledPage('obsolete');
      final next = _ControlledPage('next');
      queue.update([first, obsolete]);
      await first.started.future;
      expect(obsolete.starts, 0);

      queue.update([next]);
      first.release.complete();
      await next.started.future;
      expect(first.completed, isFalse);
      expect(obsolete.starts, 0);
      next.release.complete();
      await Future<void>.delayed(Duration.zero);
      expect(next.completed, isTrue);
    },
  );

  test(
    'settings invalidation cancels old work and permits the same page again',
    () async {
      final queue = ReaderPreloader();
      addTearDown(queue.dispose);
      final old = _ControlledPage('same-page');
      final updated = _ControlledPage('same-page');
      queue.update([old]);
      await old.started.future;
      queue.update([updated]);
      ReaderPreloader.invalidateAll();
      old.release.complete();
      await updated.started.future;
      expect(old.completed, isFalse);
      updated.release.complete();
      await Future<void>.delayed(Duration.zero);
      queue.update([updated]);
      await Future<void>.delayed(Duration.zero);
      expect(updated.starts, 1);

      final afterClose = _ControlledPage('after-close');
      queue.dispose();
      queue.update([afterClose]);
      await Future<void>.delayed(Duration.zero);
      expect(afterClose.starts, 0);
    },
  );
}

import 'dart:async';
import 'dart:collection';
import 'dart:typed_data';

import 'package:flutter/painting.dart';

import 'reader_image.dart';
import 'package:venera/utils/image_ai_service.dart';
import 'reader_image_details.dart';

/// One ordered, chapter-owned pipeline for visible and preloaded pages.
///
/// Pending pages retain metadata only. Scrolling cannot abandon an admitted
/// page, and a failed page blocks later pages until it is explicitly retried.
class ReaderPreloader {
  ReaderPreloader() {
    _instances.add(this);
  }

  static final _instances = <ReaderPreloader>{};
  final _pages = <int, ReaderImageProvider>{};
  final _pending = SplayTreeSet<int>();
  final _readers = <int, _PageReaders>{};
  final _failures = <int, ({Object error, StackTrace stack})>{};
  final _records = <int, ReaderImageDetails>{};
  final _force = <int>{};
  final _versions = <int, int>{};
  int? _first;
  int? _last;
  int? _windowStart;
  int? _windowEnd;
  var _generation = 0;
  var _running = false;
  var _disposed = false;

  static ReaderPreloader? forPage(ReaderImageProvider page) {
    ReaderPreloader? match;
    for (final instance in _instances) {
      if (!instance._disposed && instance._pages[page.page]?.key == page.key) {
        match = instance;
      }
    }
    return match;
  }

  ReaderImageProvider? get blockedPage =>
      _pending.isNotEmpty && _failures.containsKey(_pending.first)
      ? _pages[_pending.first]
      : null;

  static void invalidateAll() {
    for (final instance in _instances) {
      instance._invalidate();
    }
  }

  /// Register the whole chapter before image widgets can request distant pages.
  /// A saved reading position is the start of this session, not page one.
  void configure(
    Iterable<ReaderImageProvider> pages, {
    required int initialPage,
  }) {
    if (_disposed) return;
    final chapter = {for (final page in pages) page.page: page};
    if (chapter.length == _pages.length &&
        chapter.entries.every((entry) => _pages[entry.key] == entry.value)) {
      return;
    }
    _reset();
    _pages
      ..clear()
      ..addAll(chapter);
    if (_pages.isEmpty) return;
    final start = _pages.containsKey(initialPage)
        ? initialPage
        : _pages.keys.first;
    _windowStart = _windowEnd = start;
    _extendTo(start);
    _schedule();
  }

  /// Extend demand, never drop unfinished pages when the viewport moves.
  void update(Iterable<ReaderImageProvider> pages) {
    if (_disposed) return;
    final wanted =
        pages
            .where((page) => _pages[page.page]?.key == page.key)
            .map((page) => page.page)
            .toList()
          ..sort();
    if (wanted.isEmpty) return;
    _windowStart = wanted.first;
    _windowEnd = wanted.last;
    _extendTo(wanted.first);
    _extendTo(wanted.last);
    _showBlockedPages();
    _schedule();
  }

  Future<Uint8List> load(
    ReaderImageProvider page,
    StreamController<ImageChunkEvent> events,
  ) async {
    if (_disposed || _pages[page.page]?.key != page.key) {
      throw const ReaderProcessingCancelled();
    }
    final failure = _failures[page.page];
    if (failure != null) {
      Error.throwWithStackTrace(failure.error, failure.stack);
    }
    final readers = _readers.putIfAbsent(page.page, _PageReaders.new);
    readers.events.add(events);
    _extendTo(page.page);
    // A previously preloaded page is read from the rendered disk cache rather
    // than retaining every completed PNG in this chapter's futures.
    _enqueue(page.page);
    _showBlockedPages();
    _schedule();
    try {
      return await readers.result.future;
    } finally {
      readers.events.remove(events);
    }
  }

  Future<void> reprocess(ReaderImageProvider page) async {
    if (_disposed || _pages[page.page]?.key != page.key) {
      throw const ReaderProcessingCancelled();
    }
    if (_force.add(page.page)) {
      _versions.update(page.page, (value) => value + 1, ifAbsent: () => 1);
    }
    _failures.remove(page.page);
    _extendTo(page.page);
    _enqueue(page.page, retry: true);
    final events = StreamController<ImageChunkEvent>.broadcast();
    try {
      await load(page, events);
    } finally {
      await events.close();
    }
  }

  void _extendTo(int page) {
    final first = _first;
    final last = _last;
    if (first == null || last == null) {
      _first = _last = page;
      _enqueue(page);
    } else if (page < first) {
      for (var index = page; index < first; index++) {
        _enqueue(index);
      }
      _first = page;
    } else if (page > last) {
      for (var index = last + 1; index <= page; index++) {
        _enqueue(index);
      }
      _last = page;
    }
  }

  void _enqueue(int page, {bool retry = false}) {
    final provider = _pages[page];
    if (provider == null) return;
    if (!_pending.add(page) && !retry) return;
    final details = ReaderImageDetailsStore.instance;
    final record = details.begin(
      provider.imageKey,
      provider.sourceKey,
      provider.cid,
      provider.eid,
      page,
      values: {'Source': provider.imageKey, 'Page': '$page'},
    );
    _records[page] = record;
    details.update(record, state: retry ? 'Retrying' : 'Queued');
  }

  void _showBlockedPages() {
    if (_pending.isEmpty) return;
    final first = _pending.first;
    if (!_failures.containsKey(first)) return;
    for (final page in _pending) {
      if (page == first || _failures.containsKey(page)) continue;
      final record = _records[page];
      if (record != null) {
        ReaderImageDetailsStore.instance.update(
          record,
          state: 'Waiting for previous page',
          values: {'Waiting for page': '$first'},
        );
      }
    }
  }

  void _schedule() {
    if (_running || _disposed || _pending.isEmpty) return;
    if (_failures.containsKey(_pending.first)) return;
    _running = true;
    Future<void>(_drain);
  }

  Future<void> _drain() async {
    try {
      while (!_disposed && _pending.isNotEmpty) {
        final page = _pending.first;
        if (_failures.containsKey(page)) {
          _showBlockedPages();
          break;
        }
        final provider = _pages[page]!;
        final generation = _generation;
        final version = _versions[page] ?? 0;
        final force = _force.remove(page);
        final events = StreamController<ImageChunkEvent>.broadcast();
        final subscription = events.stream.listen((event) {
          for (final consumer
              in _readers[page]?.events ??
                  const <StreamController<ImageChunkEvent>>[]) {
            if (!consumer.isClosed && consumer.hasListener) consumer.add(event);
          }
        });
        void checkActive() {
          if (_disposed ||
              generation != _generation ||
              version != (_versions[page] ?? 0)) {
            throw const ReaderProcessingCancelled();
          }
        }

        try {
          ReaderImageDetailsStore.instance.update(
            _records[page]!,
            state: 'Processing',
          );
          final bytes = await provider.loadForQueue(
            events,
            checkActive,
            forceReprocess: force,
            record: _records[page]!,
          );
          checkActive();
          ReaderImageDetailsStore.instance.update(
            _records[page]!,
            state: 'Complete',
          );
          _pending.remove(page);
          _records.remove(page);
          _readers.remove(page)?.result.complete(bytes);
        } catch (error, stack) {
          if (_disposed ||
              generation != _generation ||
              version != (_versions[page] ?? 0)) {
            continue;
          }
          // Failed pages retain diagnostics, not every original encoded image.
          final retainedError = error is ImageAiFailure
              ? ImageAiFailure(error.code, error.message, detail: error.detail)
              : error;
          _failures[page] = (error: retainedError, stack: stack);
          ReaderImageDetailsStore.instance.update(
            _records[page]!,
            state: 'Failed',
            values: {'Error': error.toString()},
          );
          _readers.remove(page)?.result.completeError(error, stack);
          _showBlockedPages();
          break;
        } finally {
          await events.close();
          await subscription.cancel();
        }
      }
    } finally {
      _running = false;
      _schedule();
    }
  }

  void _reset() {
    _generation++;
    for (final record in _records.values) {
      ReaderImageDetailsStore.instance.update(record, state: 'Cancelled');
    }
    for (final readers in _readers.values) {
      readers.result.completeError(const ReaderProcessingCancelled());
    }
    _readers.clear();
    _pending.clear();
    _failures.clear();
    _records.clear();
    _force.clear();
    _versions.clear();
    _first = _last = null;
  }

  void _invalidate() {
    if (_disposed) return;
    final start = _windowStart;
    final end = _windowEnd;
    _reset();
    if (start != null) _extendTo(start);
    if (end != null) _extendTo(end);
    _schedule();
  }

  void dispose() {
    _disposed = true;
    _reset();
    _pages.clear();
    _instances.remove(this);
  }
}

class _PageReaders {
  final result = Completer<Uint8List>();
  final events = <StreamController<ImageChunkEvent>>{};
}

class ReaderProcessingCancelled implements Exception {
  const ReaderProcessingCancelled();

  @override
  String toString() => 'Reader or processing settings changed';
}

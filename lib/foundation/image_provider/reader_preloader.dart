import 'dart:async';

import 'package:flutter/painting.dart';

import 'reader_image.dart';

/// Warms the same encoded processing caches used by visible reader pages.
/// Only one background page owns image bytes at a time; decoded Flutter images
/// remain the responsibility of the visible-page image cache.
class ReaderPreloader {
  ReaderPreloader() {
    _instances.add(this);
  }

  static final _instances = <ReaderPreloader>{};
  final _wanted = <String, ReaderImageProvider>{};
  final _attempted = <String>{};
  var _generation = 0;
  var _running = false;
  var _disposed = false;

  static void invalidateAll() {
    for (final instance in _instances) {
      instance._generation++;
      instance._attempted.clear();
      instance._schedule();
    }
  }

  /// Replace, rather than append to, the current near-to-far preload window.
  void update(Iterable<ReaderImageProvider> pages) {
    if (_disposed) return;
    _wanted
      ..clear()
      ..addEntries(pages.map((page) => MapEntry(page.key, page)));
    _attempted.removeWhere((key) => !_wanted.containsKey(key));
    _schedule();
  }

  void _schedule() {
    if (_running || _disposed) return;
    _running = true;
    // Let the visible page resolve first, and never notify image-detail widgets
    // synchronously while the reader is building its preload window.
    Future<void>(_drain);
  }

  Future<void> _drain() async {
    try {
      while (!_disposed) {
        final page = _wanted.values
            .where((page) => !_attempted.contains(page.key))
            .firstOrNull;
        if (page == null) break;
        final key = page.key;
        final generation = _generation;
        _attempted.add(key);
        final events = StreamController<ImageChunkEvent>.broadcast();
        void checkActive() {
          if (_disposed ||
              generation != _generation ||
              !_wanted.containsKey(key)) {
            throw const _PreloadCancelled();
          }
        }

        try {
          // ReaderImageProvider performs source processing -> SR -> color and
          // persists successful rendered stages. Do not predecode the entire
          // preload window into Flutter's memory cache.
          await page.load(events, checkActive);
          checkActive();
        } on _PreloadCancelled {
          _attempted.remove(key);
        } catch (_) {
          // The provider records the page's failure. Leave it retryable by the
          // visible reader, without a background retry loop on every rebuild.
        } finally {
          await events.close();
        }
      }
    } finally {
      _running = false;
    }
  }

  void dispose() {
    _disposed = true;
    _generation++;
    _wanted.clear();
    _attempted.clear();
    _instances.remove(this);
  }
}

class _PreloadCancelled implements Exception {
  const _PreloadCancelled();

  @override
  String toString() => 'Page left the preload window';
}

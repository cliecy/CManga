import 'dart:async';
import 'dart:collection';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:venera/utils/image_ai_cache.dart';

/// Metadata only: never retains decoded images or encoded page bytes.
class ReaderImageDetails {
  ReaderImageDetails._(this._key, Map<String, String> initial)
    : _values = Map.of(initial);

  final String _key;
  final Map<String, String> _values;
  late final Map<String, String> values = UnmodifiableMapView(_values);
  String state = 'Loading';
  bool isStale = false;
  ImageAiCacheRef? cacheRef;
}

class ReaderImageDetailsStore extends ChangeNotifier {
  ReaderImageDetailsStore._();
  static final instance = ReaderImageDetailsStore._();
  final _records = <String, ReaderImageDetails>{};
  bool _notificationPending = false;

  String _key(
    String imageKey,
    String? sourceKey,
    String cid,
    String eid,
    int page,
  ) => jsonEncode([imageKey, sourceKey ?? 'local', cid, eid, page]);

  ReaderImageDetails? lookup(
    String imageKey,
    String? sourceKey,
    String cid,
    String eid,
    int page,
  ) => _records[_key(imageKey, sourceKey, cid, eid, page)];

  ReaderImageDetails begin(
    String imageKey,
    String? sourceKey,
    String cid,
    String eid,
    int page, {
    required Map<String, String> values,
  }) {
    final key = _key(imageKey, sourceKey, cid, eid, page);
    final record = ReaderImageDetails._(key, values);
    _records[key] = record;
    _notifyLater();
    return record;
  }

  void update(
    ReaderImageDetails record, {
    String? state,
    Map<String, String> values = const {},
  }) {
    // A slower old request must not replace a newer page/parameter result.
    if (!identical(_records[record._key], record) || record.isStale) return;
    if (state != null) record.state = state;
    record._values.addAll(values);
    _notifyLater();
  }

  void invalidate() {
    for (final record in _records.values) {
      record.isStale = true;
    }
    _notifyLater();
  }

  void _notifyLater() {
    if (_notificationPending) return;
    _notificationPending = true;
    scheduleMicrotask(() {
      _notificationPending = false;
      notifyListeners();
    });
  }
}

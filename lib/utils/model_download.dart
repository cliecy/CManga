import 'package:flutter/foundation.dart';

/// One manager-owned download, retained after its observers leave the screen.
@immutable
class ModelDownloadState {
  final String modelId;
  final String modelName;
  final String message;
  final int receivedBytes;
  final int totalBytes;
  final bool isDownloading;
  final String? error;

  const ModelDownloadState({
    required this.modelId,
    required this.modelName,
    required this.message,
    required this.receivedBytes,
    required this.totalBytes,
    required this.isDownloading,
    this.error,
  });

  double? get progress =>
      totalBytes <= 0 ? null : (receivedBytes / totalBytes).clamp(0.0, 1.0);
}

/// Keeps legacy callbacks observing the same task without owning its lifetime.
/// Observer failures (for example a disposed widget) must not abort installation.
Future<void> forwardModelDownloadCallbacks(
  Future<void> task,
  ValueNotifier<ModelDownloadState?> state, {
  void Function(double progress)? onProgress,
  void Function(String status)? onStatus,
  bool replay = false,
}) {
  if (onProgress == null && onStatus == null) return task;
  String? lastMessage;
  double? lastProgress;

  void notifySafely(VoidCallback callback) {
    try {
      callback();
    } catch (error, stack) {
      FlutterError.reportError(
        FlutterErrorDetails(
          exception: error,
          stack: stack,
          library: 'model download',
          context: ErrorDescription('notifying a download observer'),
        ),
      );
    }
  }

  void notify() {
    final value = state.value;
    if (value == null) return;
    if (onStatus != null && value.message != lastMessage) {
      lastMessage = value.message;
      notifySafely(() => onStatus(value.message));
    }
    final progress = value.progress;
    if (onProgress != null && progress != null && progress != lastProgress) {
      lastProgress = progress;
      notifySafely(() => onProgress(progress));
    }
  }

  state.addListener(notify);
  if (replay) notify();
  task.then<void>(
    (_) => state.removeListener(notify),
    onError: (Object error, StackTrace stack) => state.removeListener(notify),
  );
  return task;
}

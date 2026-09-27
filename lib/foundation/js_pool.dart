import 'dart:async';
import 'dart:isolate';
import 'package:flutter/services.dart';
import 'package:flutter_qjs/flutter_qjs.dart';
import 'package:cmanga/foundation/js_engine.dart';
import 'package:cmanga/foundation/log.dart';

class JSPool {
  static final int _maxInstances = 4;

  /// A source script can loop forever inside a worker isolate. Tasks are
  /// bounded so one bad source cannot DoS the pool for the whole app.
  static const Duration _taskTimeout = Duration(minutes: 5);

  final List<IsolateJsEngine> _instances = [];
  Uint8List? _jsInit;
  bool _isInitializing = false;

  static final JSPool _singleton = JSPool._internal();
  factory JSPool() {
    return _singleton;
  }
  JSPool._internal();

  Future<void> init() async {
    if (_isInitializing) return;
    _isInitializing = true;
    var jsInitBuffer = await rootBundle.load("assets/init.js");
    _jsInit = jsInitBuffer.buffer.asUint8List();
    for (int i = 0; i < _maxInstances; i++) {
      _instances.add(IsolateJsEngine(_jsInit!));
    }
    _isInitializing = false;
  }

  Future<dynamic> execute(String jsFunction, List<dynamic> args) async {
    await init();
    var selectedInstance = _instances[0];
    for (var instance in _instances) {
      if (instance.pendingTasks < selectedInstance.pendingTasks) {
        selectedInstance = instance;
      }
    }
    try {
      return await selectedInstance
          .execute(jsFunction, args)
          .timeout(_taskTimeout);
    } on TimeoutException {
      // The isolate is stuck and can never recover: drop it, kill it and
      // spawn a replacement so the pool keeps working.
      _instances.remove(selectedInstance);
      selectedInstance.close();
      _instances.add(IsolateJsEngine(_jsInit!));
      rethrow;
    }
  }
}

class _IsolateJsEngineInitParam {
  final SendPort sendPort;

  final Uint8List jsInit;

  _IsolateJsEngineInitParam(this.sendPort, this.jsInit);
}

class IsolateJsEngine {
  Isolate? _isolate;

  SendPort? _sendPort;
  ReceivePort? _receivePort;

  int _counter = 0;
  final Map<int, Completer<dynamic>> _tasks = {};

  bool _isClosed = false;

  int get pendingTasks => _tasks.length;

  IsolateJsEngine(Uint8List jsInit) {
    _receivePort = ReceivePort();
    _receivePort!.listen(_onMessage);
    Isolate.spawn(_run, _IsolateJsEngineInitParam(_receivePort!.sendPort, jsInit));
  }

  void _onMessage(dynamic message) {
    if (message is SendPort) {
      _sendPort = message;
    } else if (message is TaskResult) {
      final completer = _tasks.remove(message.id);
      if (completer != null) {
        if (message.error != null) {
          completer.completeError(message.error!);
        } else {
          completer.complete(message.result);
        }
      }
    } else if (message is Exception) {
      Log.error("IsolateJsEngine", message.toString());
      for (var completer in _tasks.values) {
        completer.completeError(message);
      }
      _tasks.clear();
      close();
    }
  }

  static void _run(_IsolateJsEngineInitParam params) async {
    var sendPort = params.sendPort;
    final port = ReceivePort();
    sendPort.send(port.sendPort);
    final engine = JsEngine();
    try {
      JsEngine.cacheJsInit(params.jsInit);
      await engine.init();
    }
    catch(e, s) {
      sendPort.send(Exception("Failed to initialize JS engine: $e\n$s"));
      return;
    }
    await for (final message in port) {
      if (message is Task) {
        try {
          final jsFunc = engine.runCode(message.jsFunction);
          if (jsFunc is! JSInvokable) {
            throw Exception("The provided code does not evaluate to a function.");
          }
          final result = jsFunc.invoke(message.args);
          jsFunc.free();
          sendPort.send(TaskResult(message.id, result, null));
        } catch (e) {
          sendPort.send(TaskResult(message.id, null, e.toString()));
        }
      }
    }
  }

  Future<dynamic> execute(String jsFunction, List<dynamic> args) async {
    if (_isClosed) {
      throw Exception("IsolateJsEngine is closed.");
    }
    while (_sendPort == null) {
      await Future.delayed(const Duration(milliseconds: 10));
    }
    final completer = Completer<dynamic>();
    final taskId = _counter++;
    _tasks[taskId] = completer;
    final task = Task(taskId, jsFunction, args);
    _sendPort?.send(task);
    return completer.future;
  }

  /// Kills this isolate. Pending tasks are failed immediately: a stuck
  /// isolate can never complete them, and waiting here would deadlock the
  /// shutdown path.
  void close() {
    if (!_isClosed) {
      _isClosed = true;
      for (var completer in _tasks.values) {
        if (!completer.isCompleted) {
          completer.completeError(
              Exception("JS worker isolate was closed."));
        }
      }
      _tasks.clear();
      _receivePort?.close();
      _isolate?.kill(priority: Isolate.immediate);
      _isolate = null;
    }
  }
}

class Task {
  final int id;
  final String jsFunction;
  final List<dynamic> args;

  const Task(this.id, this.jsFunction, this.args);
}

class TaskResult {
  final int id;
  final Object? result;
  final String? error;

  const TaskResult(this.id, this.result, this.error);
}

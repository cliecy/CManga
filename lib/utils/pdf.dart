import 'dart:async';
import 'dart:convert';
import 'dart:isolate';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/local.dart';
import 'package:venera/utils/image.dart';
import 'package:venera/utils/io.dart';
import 'package:venera/utils/local_comic_export.dart';
import 'package:zip_flutter/zip_flutter.dart';

typedef DecodeImage = Future<Image> Function(Uint8List data);

Future<Isolate> _runIsolate(
  String title,
  String author,
  List<String> imagePaths,
  String savePath,
  SendPort sendPort,
) {
  return Isolate.spawn<SendPort>(
    (sendPort) async {
      final receivePort = ReceivePort();
      sendPort.send(receivePort.sendPort);
      Completer<Image>? pendingImage;
      receivePort.listen((message) {
        final pending = pendingImage;
        if (pending == null) return;
        pendingImage = null;
        if (message is Image) {
          pending.complete(message);
        } else if (message is List<String>) {
          pending.completeError(
            StateError(message[0]),
            StackTrace.fromString(message[1]),
          );
        }
      });
      try {
        final generator = PdfGenerator(
          title: title,
          author: author,
          imagePaths: imagePaths,
          outputPath: savePath,
          decodeImage: (data) {
            final pending = Completer<Image>();
            pendingImage = pending;
            sendPort.send(data);
            return pending.future;
          },
        );
        await generator.generate();
        sendPort.send(null);
      } catch (error, stack) {
        sendPort.send([error.toString(), stack.toString()]);
      } finally {
        receivePort.close();
      }
    },
    sendPort,
    onError: sendPort,
    errorsAreFatal: true,
  );
}

Future<File> createPdfFromComicIsolate(
  LocalComic comic,
  String savePath, {
  void Function()? checkCanceled,
}) async {
  final prepared = await LocalComicExport.prepare(
    comic,
    checkCanceled: checkCanceled,
  );
  final receivePort = ReceivePort();
  SendPort? sendPort;
  Isolate? isolate;
  final completer = Completer<void>();
  receivePort.listen((message) async {
    if (message is SendPort) {
      sendPort = message;
    } else if (message is Uint8List) {
      try {
        checkCanceled?.call();
        final image = await Image.decodeImage(message);
        checkCanceled?.call();
        sendPort!.send(image);
      } catch (error, stack) {
        // Let the worker close its output before reporting failure/cleanup.
        sendPort!.send([error.toString(), stack.toString()]);
      }
    } else if (!completer.isCompleted) {
      if (message == null) {
        completer.complete();
      } else if (message is List) {
        completer.completeError(
          StateError(message[0].toString()),
          StackTrace.fromString(message[1].toString()),
        );
      }
    }
  });
  try {
    final output = File(FilePath.join(prepared.directory.path, 'result.pdf'));
    isolate = await _runIsolate(
      comic.title,
      comic.subtitle,
      [
        prepared.cover.path,
        for (final chapter in prepared.chapters)
          for (final image in chapter.images) image.path,
      ],
      output.path,
      receivePort.sendPort,
    );
    await completer.future;
    checkCanceled?.call();
    return await output.rename(savePath);
  } finally {
    isolate?.kill();
    receivePort.close();
    await prepared.dispose();
  }
}

class PdfGenerator {
  final String title;
  final String author;
  final List<String> imagePaths;
  final String outputPath;
  final DecodeImage decodeImage;

  // PDF文件的对象ID计数器
  int _objectId = 1;

  // 存储每个对象在PDF中的字节位置
  final Map<int, int> _objectOffsets = {};

  static const double a4Width = 595.0; // points
  static const double a4Height = 842.0; // points

  PdfGenerator({
    required this.title,
    required this.author,
    required this.imagePaths,
    required this.outputPath,
    required this.decodeImage,
  });

  Future<void> generate() async {
    var file = File(outputPath);
    final output = file.openWrite();

    int length = 0;

    void write(String str) {
      var data = utf8.encode(str);
      output.add(data);
      length += data.length;
    }

    void writeData(Uint8List data) {
      output.add(data);
      length += data.length;
    }

    int getCurrentLength() {
      return length;
    }

    try {
      // 1. 写入PDF头部
      write('%PDF-1.7\n%\xFF\xFF\xFF\xFF\n\n');

      // 2. 写入Catalog对象
      _objectOffsets[_objectId] = getCurrentLength();
      write('$_objectId 0 obj\n');
      write('<<\n');
      write('/Type /Catalog\n');
      write('/Pages ${_objectId + 1} 0 R\n');
      write('>>\nendobj\n\n');

      final catalogId = _objectId++;

      // 3. 写入Pages对象
      _objectOffsets[_objectId] = getCurrentLength();
      write('$_objectId 0 obj\n');
      write('<<\n');
      write('/Type /Pages\n');
      write('/Kids [');
      final pageIds = <int>[];
      for (var i = 0; i < imagePaths.length; i++) {
        pageIds.add(_objectId + 1 + i * 3);
        write('${_objectId + 1 + i * 3} 0 R ');
      }
      write(']\n');
      write('/Count ${imagePaths.length}\n');
      write('>>\nendobj\n\n');

      final pagesId = _objectId++;

      // 4. 为每个图片创建Page和Image对象
      for (var i = 0; i < imagePaths.length; i++) {
        final imagePath = imagePaths[i];
        final image = await _getImage(imagePath);

        // 写入Page对象
        _objectOffsets[_objectId] = getCurrentLength();
        write('$_objectId 0 obj\n');
        write('<<\n');
        write('/Type /Page\n');
        write('/Parent $pagesId 0 R\n');
        write('/Resources <<\n');
        write('/XObject << /Im${i + 1} ${_objectId + 1} 0 R >>\n');
        write('>>\n');
        write('/MediaBox [0 0 $a4Width $a4Height]\n');
        write('/Contents ${_objectId + 2} 0 R\n');
        write('>>\nendobj\n\n');

        _objectId++;

        // 写入Image对象
        _objectOffsets[_objectId] = getCurrentLength();
        write('$_objectId 0 obj\n');
        write('<<\n');
        write('/Type /XObject\n');
        write('/Subtype /Image\n');
        write('/Width ${image.width}\n');
        write('/Height ${image.height}\n');
        write('/ColorSpace /DeviceRGB\n');
        write('/BitsPerComponent 8\n');
        write('/Filter /FlateDecode\n');
        write('/Length ${image.data.length}\n');
        write('>>\nstream\n');
        writeData(image.data);
        write('\nendstream\nendobj\n\n');

        _objectId++;

        // 写入Contents对象（绘制图片的指令）
        _objectOffsets[_objectId] = getCurrentLength();
        write('$_objectId 0 obj\n');
        write('<<\n');
        var stream = '';
        stream += 'q\n';
        // Calculate scaling factors
        var scaleX = a4Width / image.width;
        var scaleY = a4Height / image.height;
        var scale = scaleX < scaleY ? scaleX : scaleY;
        // Calculate centering offsets
        var offsetX = (a4Width - (image.width * scale)) / 2;
        var offsetY = (a4Height - (image.height * scale)) / 2;
        // Apply transformation matrix
        stream += '1 0 0 1 $offsetX $offsetY cm\n'; // Translate
        stream += '${scale * image.width} 0 0 ${scale * image.height} 0 0 cm\n';
        stream += '/Im${i + 1} Do\n';
        stream += 'Q\n';
        var streamData = utf8.encode(stream);
        write('/Length ${streamData.length}\n');
        write('>>\nstream\n');
        writeData(streamData);
        write('endstream\nendobj\n\n');

        _objectId++;
      }

      // 5. 写入Info对象（元数据）
      final infoId = _objectId;
      _objectOffsets[_objectId] = getCurrentLength();
      write('$_objectId 0 obj\n');
      write('<<\n');
      write('/Title <');
      writeData(_toPdfString(title));
      write('>\n');
      write('/Author <');
      writeData(_toPdfString(author));
      write('>\n');
      write('/Producer (venera v${App.version})\n');
      write('/CreationDate (D:${_formatDateTime(DateTime.now())})\n');
      write('>>\nendobj\n\n');

      _objectId++;

      // 6. 写入交叉引用表
      final xrefOffset = getCurrentLength();
      write('xref\n');
      write('0 $_objectId\n');
      write('0000000000 65535 f\r\n');

      for (var i = 1; i < _objectId; i++) {
        final offset = _objectOffsets[i]!;
        write('${offset.toString().padLeft(10, '0')} 00000 n\r\n'); // 使用\r\n
      }

      // 7. 写入文件尾部
      write('trailer\n');
      write('<<\n');
      write('/Size $_objectId\n');
      write('/Root $catalogId 0 R\n');
      write('/Info $infoId 0 R\n');
      write('>>\n');
      write('startxref\n');
      write('$xrefOffset\n');
      write('%%EOF\n');
    } finally {
      await output.close();
    }
  }

  int _codeUnitForDigit(int digit) =>
      digit < 10 ? digit + 0x30 : digit + 0x61 - 10;

  Uint8List _toPdfString(String str) {
    Uint8List data;
    try {
      data = latin1.encode(str);
    } catch (e) {
      data = Uint8List.fromList(<int>[0xfe, 0xff] + _encodeUtf16be(str));
    }
    var result = <int>[];
    for (final byte in data) {
      result.add(_codeUnitForDigit((byte & 0xF0) >> 4));
      result.add(_codeUnitForDigit(byte & 0x0F));
    }
    return Uint8List.fromList(result);
  }

  List<int> _encodeUtf16be(String str) {
    const unicodeReplacementCharacterCodePoint = 0xfffd;
    const unicodeByteZeroMask = 0xff;
    const unicodeByteOneMask = 0xff00;
    const unicodeValidRangeMax = 0x10ffff;
    const unicodePlaneOneMax = 0xffff;
    const unicodeUtf16ReservedLo = 0xd800;
    const unicodeUtf16ReservedHi = 0xdfff;
    const unicodeUtf16Offset = 0x10000;
    const unicodeUtf16SurrogateUnit0Base = 0xd800;
    const unicodeUtf16SurrogateUnit1Base = 0xdc00;
    const unicodeUtf16HiMask = 0xffc00;
    const unicodeUtf16LoMask = 0x3ff;

    final encoding = <int>[];

    void add(int unit) {
      encoding.add((unit & unicodeByteOneMask) >> 8);
      encoding.add(unit & unicodeByteZeroMask);
    }

    for (final unit in str.codeUnits) {
      if ((unit >= 0 && unit < unicodeUtf16ReservedLo) ||
          (unit > unicodeUtf16ReservedHi && unit <= unicodePlaneOneMax)) {
        add(unit);
      } else if (unit > unicodePlaneOneMax && unit <= unicodeValidRangeMax) {
        final base = unit - unicodeUtf16Offset;
        add(
          unicodeUtf16SurrogateUnit0Base + ((base & unicodeUtf16HiMask) >> 10),
        );
        add(unicodeUtf16SurrogateUnit1Base + (base & unicodeUtf16LoMask));
      } else {
        add(unicodeReplacementCharacterCodePoint);
      }
    }
    return encoding;
  }

  // 格式化日期时间
  String _formatDateTime(DateTime dt) {
    return dt
        .toUtc()
        .toString()
        .replaceAll('-', '')
        .replaceAll(':', '')
        .replaceAll(' ', '')
        .replaceAll('.', '')
        .substring(0, 14);
  }

  Future<({int width, int height, Uint8List data})> _getImage(
    String imagePath,
  ) async {
    var data = await File(imagePath).readAsBytes();
    var image = await decodeImage(data);
    var width = image.width;
    var height = image.height;
    data = Uint8List(width * height * 3);
    for (var i = 0; i < width * height; i++) {
      var pixel = image.getPixelAtIndex(i);
      data[i * 3] = pixel.r;
      data[i * 3 + 1] = pixel.g;
      data[i * 3 + 2] = pixel.b;
    }
    data = tdeflCompressData(data, true, true, 9);
    return (width: width, height: height, data: data);
  }
}

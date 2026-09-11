import 'dart:convert';
import 'package:flutter_7zip/flutter_7zip.dart';
import 'package:cmanga/foundation/app.dart';
import 'package:cmanga/foundation/comic_source/comic_source.dart';
import 'package:cmanga/foundation/comic_type.dart';
import 'package:cmanga/foundation/local.dart';
import 'package:cmanga/utils/ext.dart';
import 'package:cmanga/utils/file_type.dart';
import 'package:cmanga/utils/io.dart';
import 'package:cmanga/utils/processed_image_store.dart';
import 'package:cmanga/utils/local_comic_export.dart';
import 'package:zip_flutter/zip_flutter.dart';

class ComicMetaData {
  final String title;

  final String author;

  final List<String> tags;

  final List<ComicChapter>? chapters;

  Map<String, dynamic> toJson() => {
    'title': title,
    'author': author,
    'tags': tags,
    'chapters': chapters?.map((e) => e.toJson()).toList(),
  };

  ComicMetaData.fromJson(Map<String, dynamic> json)
    : title = json['title'],
      author = json['author'],
      tags = List<String>.from(json['tags']),
      chapters = json['chapters'] == null
          ? null
          : List<ComicChapter>.from(
              json['chapters'].map((e) => ComicChapter.fromJson(e)),
            );

  ComicMetaData({
    required this.title,
    required this.author,
    required this.tags,
    this.chapters,
  });
}

class ComicChapter {
  final String title;

  final int start;

  final int end;

  Map<String, dynamic> toJson() => {'title': title, 'start': start, 'end': end};

  ComicChapter.fromJson(Map<String, dynamic> json)
    : title = json['title'],
      start = json['start'],
      end = json['end'];

  ComicChapter({required this.title, required this.start, required this.end});
}

/// Comic Book Archive. Currently supports CBZ, ZIP and 7Z formats.
abstract class CBZ {
  static Future<FileType> checkType(File file) async {
    var header = <int>[];
    await for (var bytes in file.openRead()) {
      header.addAll(bytes);
      if (header.length >= 32) break;
    }
    return detectFileType(header);
  }

  static Future<void> extractArchive(File file, Directory out) async {
    var fileType = await checkType(file);
    if (fileType.mime == 'application/zip') {
      await ZipFile.openAndExtractAsync(file.path, out.path, 4);
    } else if (fileType.mime == "application/x-7z-compressed") {
      await SZArchive.extractIsolates(file.path, out.path, 4);
    } else {
      throw Exception('Unsupported archive type');
    }
  }

  static Future<LocalComic> import(File file) async {
    var cache = Directory(FilePath.join(App.cachePath, 'cbz_import'));
    if (cache.existsSync()) cache.deleteSync(recursive: true);
    cache.createSync();
    await extractArchive(file, cache);
    var f = cache
        .listSync()
        .where((entry) => !ProcessedImageStore.containsPath(entry.path))
        .toList();
    if (f.length == 1 && f.first is Directory) {
      cache = f.first as Directory;
    }
    var metaDataFile = File(FilePath.join(cache.path, 'metadata.json'));
    ComicMetaData? metaData;
    if (metaDataFile.existsSync()) {
      try {
        metaData = ComicMetaData.fromJson(
          jsonDecode(metaDataFile.readAsStringSync()),
        );
      } catch (_) {}
    }
    metaData ??= ComicMetaData(
      title: file.name.substring(0, file.name.lastIndexOf('.')),
      author: "",
      tags: [],
    );
    var old = LocalManager().findByName(metaData.title);
    if (old != null) {
      throw Exception('Comic with name ${metaData.title} already exists');
    }
    var files = cache.listSync().whereType<File>().toList();
    files.removeWhere((e) {
      var ext = e.path.split('.').last;
      return !['jpg', 'jpeg', 'png', 'webp', 'gif', 'jpe'].contains(ext);
    });
    if (files.isEmpty) {
      cache.deleteSync(recursive: true);
      throw Exception('No images found in the archive');
    }
    files.sort((a, b) {
      var aName = a.basenameWithoutExt;
      var bName = b.basenameWithoutExt;
      var aIndex = int.tryParse(aName);
      var bIndex = int.tryParse(bName);
      if (aIndex != null && bIndex != null) {
        return aIndex.compareTo(bIndex);
      } else {
        return a.path.compareTo(b.path);
      }
    });
    var coverFile = files.firstWhereOrNull(
      (element) =>
          element.path.endsWith('cover.${element.path.split('.').last}'),
    );
    if (coverFile != null) {
      files.remove(coverFile);
    } else {
      coverFile = files.first;
    }
    Map<String, String>? cpMap;
    var dest = Directory(
      FilePath.join(LocalManager().path, sanitizeFileName(metaData.title)),
    );
    dest.createSync();
    coverFile.copyMem(FilePath.join(dest.path, 'cover.${coverFile.extension}'));
    if (metaData.chapters == null) {
      for (var i = 0; i < files.length; i++) {
        var src = files[i];
        var dst = File(
          FilePath.join(dest.path, '${i + 1}.${src.path.split('.').last}'),
        );
        await src.copyMem(dst.path);
      }
    } else {
      dest.createSync();
      var chapters = <String, List<File>>{};
      for (var chapter in metaData.chapters!) {
        chapters[chapter.title] = files.sublist(chapter.start - 1, chapter.end);
      }
      int i = 0;
      cpMap = <String, String>{};
      for (var chapter in chapters.entries) {
        cpMap[i.toString()] = chapter.key;
        var chapterDir = Directory(FilePath.join(dest.path, i.toString()));
        chapterDir.createSync();
        for (var i = 0; i < chapter.value.length; i++) {
          var src = chapter.value[i];
          var dst = File(
            FilePath.join(
              chapterDir.path,
              '${i + 1}.${src.path.split('.').last}',
            ),
          );
          await src.copyMem(dst.path);
        }
      }
    }
    var comic = LocalComic(
      id: LocalManager().findValidId(ComicType.local),
      title: metaData.title,
      subtitle: metaData.author,
      tags: metaData.tags,
      comicType: ComicType.local,
      directory: dest.name,
      chapters: ComicChapters.fromJsonOrNull(cpMap),
      downloadedChapters: cpMap?.keys.toList() ?? [],
      cover: 'cover.${coverFile.extension}',
      createdAt: DateTime.now(),
    );
    await cache.delete(recursive: true);
    return comic;
  }

  static Future<File> export(
    LocalComic comic,
    String outFilePath, {
    void Function()? checkCanceled,
  }) async {
    final prepared = await LocalComicExport.prepare(
      comic,
      checkCanceled: checkCanceled,
    );
    try {
      final cache = await Directory(
        FilePath.join(prepared.directory.path, 'archive'),
      ).create();
      final total = prepared.chapters.fold<int>(
        0,
        (count, chapter) => count + chapter.images.length,
      );
      final width = total.toString().length;
      final chapters = comic.hasChapters ? <ComicChapter>[] : null;
      var index = 1;
      for (final chapter in prepared.chapters) {
        final start = index;
        for (final image in chapter.images) {
          checkCanceled?.call();
          await image.copy(
            FilePath.join(
              cache.path,
              '${index.toString().padLeft(width, '0')}.${image.extension}',
            ),
          );
          index++;
        }
        chapters?.add(
          ComicChapter(title: chapter.title, start: start, end: index - 1),
        );
      }
      await prepared.cover.copy(
        FilePath.join(cache.path, 'cover.${prepared.cover.extension}'),
      );
      final metaData = ComicMetaData(
        title: comic.title,
        author: comic.subtitle,
        tags: comic.tags,
        chapters: chapters,
      );
      await File(
        FilePath.join(cache.path, 'metadata.json'),
      ).writeAsString(jsonEncode(metaData));
      await File(
        FilePath.join(cache.path, 'ComicInfo.xml'),
      ).writeAsString(_buildComicInfoXml(metaData));
      checkCanceled?.call();
      final output = File(FilePath.join(prepared.directory.path, 'result.cbz'));
      await _compress(cache.path, output.path);
      checkCanceled?.call();
      return await output.rename(outFilePath);
    } finally {
      await prepared.dispose();
    }
  }

  static String _buildComicInfoXml(ComicMetaData data) {
    final buffer = StringBuffer();
    buffer.writeln('<?xml version="1.0" encoding="utf-8"?>');
    buffer.writeln(
      '<ComicInfo xmlns:xsd="http://www.w3.org/2001/XMLSchema" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">',
    );

    buffer.writeln('  <Title>${_escapeXml(data.title)}</Title>');
    buffer.writeln('  <Series>${_escapeXml(data.title)}</Series>');

    if (data.author.isNotEmpty) {
      buffer.writeln('  <Writer>${_escapeXml(data.author)}</Writer>');
    }

    if (data.tags.isNotEmpty) {
      var tags = data.tags;
      if (tags.length > 5) {
        tags = tags.sublist(0, 5);
      }
      buffer.writeln('  <Genre>${_escapeXml(tags.join(', '))}</Genre>');
    }

    if (data.chapters != null && data.chapters!.isNotEmpty) {
      final chaptersInfo = data.chapters!
          .map(
            (chapter) =>
                '${_escapeXml(chapter.title)}: ${chapter.start}-${chapter.end}',
          )
          .join('; ');
      buffer.writeln('  <Notes>Chapters: $chaptersInfo</Notes>');
    }

    buffer.writeln('  <Manga>Unknown</Manga>');
    buffer.writeln('  <BlackAndWhite>Unknown</BlackAndWhite>');

    final now = DateTime.now();
    buffer.writeln('  <Year>${now.year}</Year>');

    buffer.writeln('</ComicInfo>');
    return buffer.toString();
  }

  static String _escapeXml(String text) {
    return text
        .replaceAll('&', '&amp;')
        .replaceAll('<', '&lt;')
        .replaceAll('>', '&gt;')
        .replaceAll('"', '&quot;')
        .replaceAll("'", '&apos;');
  }

  static _compress(String src, String dst) async {
    await ZipFile.compressFolderAsync(src, dst, 4);
  }
}

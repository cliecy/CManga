import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/image_provider/reader_image.dart';
import 'package:venera/foundation/local.dart';
import 'package:venera/utils/file_type.dart';
import 'package:venera/utils/io.dart';

/// Prepares explicit book exports on the main isolate, where AI platform
/// channels and the reader's per-comic settings are available.
class LocalComicExport {
  final Directory directory;
  final File cover;
  final List<({String title, List<File> images})> chapters;

  LocalComicExport._(this.directory, this.cover, this.chapters);

  static Future<LocalComicExport> prepare(
    LocalComic comic, {
    void Function()? checkCanceled,
  }) async {
    checkCanceled?.call();
    final cache = await Directory(App.cachePath).create(recursive: true);
    final directory = await cache.createTemp('comic_export_');
    try {
      final imageDirectory = await Directory(
        FilePath.join(directory.path, 'images'),
      ).create();
      var index = 0;
      Future<File> prepareImage(String imageKey, String eid, int page) async {
        checkCanceled?.call();
        final bytes = await ReaderImageProvider(
          imageKey,
          comic.comicType.sourceKey,
          comic.id,
          eid,
          page,
        ).exportImage();
        checkCanceled?.call();
        final type = detectFileType(bytes);
        if (!type.mime.startsWith('image/')) {
          throw StateError('Processed export page is not an image: $imageKey');
        }
        final file = File(
          FilePath.join(imageDirectory.path, '${index++}${type.ext}'),
        );
        await file.writeAsBytes(bytes);
        return file;
      }

      final chapters = <({String title, List<File> images})>[];
      final chapterIds = comic.hasChapters ? comic.downloadedChapters : ['0'];
      final cover = await prepareImage(
        'file://${comic.coverFile.path}',
        chapterIds.isEmpty ? '0' : chapterIds.first,
        1,
      );
      for (final chapterId in chapterIds) {
        checkCanceled?.call();
        final sources = await LocalManager().getImages(
          comic.id,
          comic.comicType,
          comic.hasChapters ? chapterId : 1,
        );
        final images = <File>[];
        for (var page = 0; page < sources.length; page++) {
          images.add(await prepareImage(sources[page], chapterId, page + 1));
        }
        chapters.add((
          title: comic.hasChapters ? comic.chapters![chapterId]! : comic.title,
          images: images,
        ));
      }
      checkCanceled?.call();
      return LocalComicExport._(directory, cover, chapters);
    } catch (_) {
      await directory.delete(recursive: true);
      rethrow;
    }
  }

  Future<void> dispose() => directory.delete(recursive: true);
}

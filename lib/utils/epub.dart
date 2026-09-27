import 'dart:isolate';

import 'package:uuid/uuid.dart';
import 'package:xml/xml.dart';
import 'package:path/path.dart' as p;
import 'package:cmanga/foundation/app.dart';
import 'package:cmanga/foundation/comic_type.dart';
import 'package:cmanga/foundation/local.dart';
import 'package:cmanga/utils/file_type.dart';
import 'package:cmanga/utils/io.dart';
import 'package:cmanga/utils/local_comic_export.dart';
import 'package:zip_flutter/zip_flutter.dart';
import 'safe_extract.dart';

class EpubData {
  final String title;

  final String author;

  final File cover;

  final Map<String, List<File>> chapters;

  const EpubData({
    required this.title,
    required this.author,
    required this.cover,
    required this.chapters,
  });
}

Future<File> createEpubComic(
  EpubData data,
  String cacheDir,
  String outFilePath,
) async {
  final workingDir = Directory(FilePath.join(cacheDir, 'epub'));
  if (workingDir.existsSync()) {
    workingDir.deleteSync(recursive: true);
  }
  workingDir.createSync(recursive: true);

  // mimetype
  workingDir.joinFile('mimetype').writeAsStringSync('application/epub+zip');

  // META-INF
  Directory(FilePath.join(workingDir.path, 'META-INF')).createSync();
  File(
    FilePath.join(workingDir.path, 'META-INF', 'container.xml'),
  ).writeAsStringSync('''
<?xml version="1.0"?>
<container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
  <rootfiles>
    <rootfile full-path="content.opf" media-type="application/oebps-package+xml"/>
  </rootfiles>
</container>
  ''');

  Directory(FilePath.join(workingDir.path, 'OEBPS')).createSync();

  // copy images, create html files
  final imageDir = Directory(FilePath.join(workingDir.path, 'OEBPS', 'images'));
  imageDir.createSync();
  final coverExt = data.cover.extension;
  final coverMime = FileType.fromExtension(coverExt).mime;
  imageDir
      .joinFile('cover.$coverExt')
      .writeAsBytesSync(data.cover.readAsBytesSync());
  int imgIndex = 0;
  int chapterIndex = 0;
  var manifestStrBuilder = StringBuffer();
  manifestStrBuilder.writeln(
    '        <item id="cover_image" href="OEBPS/images/cover.$coverExt" media-type="$coverMime"/>',
  );
  manifestStrBuilder.writeln(
    '        <item id="toc" href="toc.ncx" media-type="application/x-dtbncx+xml"/>',
  );
  for (final chapter in data.chapters.keys) {
    var images = <String>[];
    for (final image in data.chapters[chapter]!) {
      final ext = image.extension;
      imageDir
          .joinFile('img$imgIndex.$ext')
          .writeAsBytesSync(image.readAsBytesSync());
      images.add('images/img$imgIndex.$ext');
      var mime = FileType.fromExtension(ext).mime;
      manifestStrBuilder.writeln(
        '        <item id="img$imgIndex" href="OEBPS/images/img$imgIndex$ext" media-type="$mime"/>',
      );
      imgIndex++;
    }
    var html = File(
      FilePath.join(workingDir.path, 'OEBPS', '$chapterIndex.html'),
    );
    html.writeAsStringSync('''
<!DOCTYPE html PUBLIC "-//W3C//DTD XHTML 1.1//EN" 
    "http://www.w3.org/TR/xhtml11/DTD/xhtml11.dtd">
<html xmlns="http://www.w3.org/1999/xhtml">
<head>
    <title>$chapter</title>
    <style type="text/css">
        img { 
            max-width: 100%;
            height: auto;
        }
        body {
            margin: 0;
            padding: 0;
        }
    </style>
</head>
<body>
    <h1>$chapter</h1>
    <div>
${images.map((e) => '        <img src="$e" alt="$e"/>').join('\n')}
    </div>
</body>
</html>
    ''');
    manifestStrBuilder.writeln(
      '        <item id="chapter$chapterIndex" href="OEBPS/$chapterIndex.html" media-type="application/xhtml+xml"/>',
    );
    chapterIndex++;
  }

  // content.opf
  final contentOpf = File(FilePath.join(workingDir.path, 'content.opf'));
  final uuid = const Uuid().v4();
  var spineStrBuilder = StringBuffer();
  for (var i = 0; i < chapterIndex; i++) {
    var idRef = 'idref="chapter$i"';
    spineStrBuilder.writeln('        <itemref $idRef/>');
  }
  contentOpf.writeAsStringSync('''
<?xml version="1.0" encoding="UTF-8"?>
<package version="3.0" 
    xmlns="http://www.idpf.org/2007/opf"
    xmlns:dc="http://purl.org/dc/elements/1.1/">
    <metadata>
        <dc:title>${data.title}</dc:title>
        <dc:creator>${data.author}</dc:creator>
        <dc:identifier id="book_id">urn:uuid:$uuid</dc:identifier>
        <meta name="cover" content="cover_image"/>
    </metadata>
    <manifest>
${manifestStrBuilder.toString()}       
    </manifest>
    <spine toc="toc">
${spineStrBuilder.toString()}
    </spine>
</package>
  ''');

  // toc.ncx
  final tocNcx = File(FilePath.join(workingDir.path, 'toc.ncx'));
  var navMapStrBuilder = StringBuffer();
  var playOrder = 2;
  final chapterNames = data.chapters.keys.toList();
  for (var i = 0; i < chapterIndex; i++) {
    navMapStrBuilder.writeln(
      '        <navPoint id="chapter$i" playOrder="$playOrder">',
    );
    navMapStrBuilder.writeln(
      '            <navLabel><text>${chapterNames[i]}</text></navLabel>',
    );
    navMapStrBuilder.writeln('            <content src="OEBPS/$i.html"/>');
    navMapStrBuilder.writeln('        </navPoint>');
    playOrder++;
  }

  tocNcx.writeAsStringSync('''
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE ncx PUBLIC "-//NISO//DTD ncx 2005-1//EN" "http://www.daisy.org/z3986/2005/ncx-2005-1.dtd">
<ncx xmlns="http://www.daisy.org/z3986/2005/ncx" version="2005-1">
    <head>
        <meta name="dtb:uid" content="urn:uuid:$uuid"/>
        <meta name="dtb:depth" content="1"/>
        <meta name="dtb:totalPageCount" content="0"/>
        <meta name="dtb:maxPageNumber" content="0"/>
    </head>
    <docTitle>
        <text>${data.title}</text>
    </docTitle>
    <navMap>
${navMapStrBuilder.toString()}
    </navMap>
</ncx>
  ''');

  ZipFile.compressFolder(workingDir.path, outFilePath);

  workingDir.deleteSync(recursive: true);

  return File(outFilePath);
}

Future<File> createEpubWithLocalComic(
  LocalComic comic,
  String outFilePath, {
  void Function()? checkCanceled,
}) async {
  final prepared = await LocalComicExport.prepare(
    comic,
    checkCanceled: checkCanceled,
  );
  try {
    final data = EpubData(
      title: comic.title,
      author: comic.subtitle,
      cover: prepared.cover,
      chapters: {
        for (final chapter in prepared.chapters) chapter.title: chapter.images,
      },
    );
    final cacheDir = prepared.directory.path;
    final outputPath = FilePath.join(cacheDir, 'result.epub');
    checkCanceled?.call();
    await Isolate.run(
      () => overrideIO(() async {
        await createEpubComic(data, cacheDir, outputPath);
      }),
    );
    checkCanceled?.call();
    return await File(outputPath).rename(outFilePath);
  } finally {
    await prepared.dispose();
  }
}

/// Import side of the EPUB support: reads image-based EPUBs (scanned
/// manga distributed as .epub) and registers them as local comics.
class Epub {
  static Future<LocalComic> import(File file) async {
    var cache = Directory(FilePath.join(App.cachePath, 'epub_import'));
    if (cache.existsSync()) cache.deleteSync(recursive: true);
    cache.createSync();
    try {
      await SafeExtract.extractZipIsolate(file.path, cache.path);

      // 1. META-INF/container.xml → OPF location.
      var containerFile = File(FilePath.join(cache.path, 'META-INF', 'container.xml'));
      if (!containerFile.existsSync()) {
        throw Exception('Not a valid EPUB: META-INF/container.xml is missing');
      }
      var containerDoc = XmlDocument.parse(containerFile.readAsStringSync());
      if (_byLocal(containerDoc, 'rootfile').isEmpty) {
        throw Exception('Invalid EPUB: container.xml has no rootfile');
      }
      var opfPath = _byLocal(containerDoc, 'rootfile').first.getAttribute('full-path');
      if (opfPath == null || opfPath.isEmpty) {
        throw Exception('Invalid EPUB: container.xml has no rootfile full-path');
      }
      var opfFile = File(p.normalize(FilePath.join(cache.path, opfPath)));
      if (!opfFile.existsSync()) {
        throw Exception('Invalid EPUB: OPF file not found at $opfPath');
      }

      // 2. Parse the OPF package: metadata, image manifest items, spine order.
      var doc = XmlDocument.parse(opfFile.readAsStringSync());
      var opfDir = opfFile.parent;
      var imagesById = <String, File>{};
      String? coverItemId;
      for (var item in _byLocal(doc, 'item')) {
        var id = item.getAttribute('id');
        var href = item.getAttribute('href');
        var mediaType = item.getAttribute('media-type') ?? '';
        if (id == null || href == null || !mediaType.startsWith('image/')) continue;
        imagesById[id] = File(p.normalize(FilePath.join(opfDir.path, href)));
        if ((item.getAttribute('properties') ?? '').split(' ').contains('cover-image')) {
          coverItemId = id;
        }
      }

      // 3. Reading order comes from the spine; fall back to manifest order.
      var pages = <File>[];
      for (var ref in _byLocal(doc, 'itemref')) {
        var page = imagesById[ref.getAttribute('idref')];
        if (page != null && page.existsSync()) {
          pages.add(page);
        }
      }
      if (pages.isEmpty) {
        for (var page in imagesById.values) {
          if (page.existsSync()) pages.add(page);
        }
      }
      if (pages.isEmpty) {
        throw Exception('No images found in the EPUB');
      }

      // 4. Metadata with filename fallbacks.
      var titleEls = _byLocal(doc, 'title');
      var creatorEls = _byLocal(doc, 'creator');
      var title = (titleEls.isNotEmpty && titleEls.first.innerText.trim().isNotEmpty)
          ? titleEls.first.innerText.trim()
          : file.name.substring(0, file.name.lastIndexOf('.'));
      var author =
          creatorEls.isNotEmpty ? creatorEls.first.innerText.trim() : '';

      var old = LocalManager().findByName(title);
      if (old != null) {
        throw Exception('Comic with name $title already exists');
      }

      // 5. Copy into the local library in spine order, like CBZ.import does.
      File coverFile;
      var coverItem = imagesById[coverItemId ?? ''];
      if (coverItemId != null && coverItem != null && coverItem.existsSync()) {
        coverFile = coverItem;
        pages.removeWhere((p) => p.path == coverFile.path);
      } else {
        coverFile = pages.first;
      }

      var dest = Directory(
          FilePath.join(LocalManager().path, sanitizeFileName(title)));
      dest.createSync();
      await coverFile.copyMem(FilePath.join(dest.path, 'cover.${coverFile.extension}'));
      for (var i = 0; i < pages.length; i++) {
        var src = pages[i];
        await src.copyMem(FilePath.join(dest.path, '${i + 1}.${src.extension}'));
      }

      return LocalComic(
        id: LocalManager().findValidId(ComicType.local),
        title: title,
        subtitle: author,
        tags: [],
        comicType: ComicType.local,
        directory: dest.name,
        chapters: null,
        downloadedChapters: [],
        cover: 'cover.${coverFile.extension}',
        createdAt: DateTime.now(),
      );
    } finally {
      if (cache.existsSync()) {
        cache.deleteSync(recursive: true);
      }
    }
  }

  /// Elements by local name — OPF/container prefixes vary between files
  /// (dc:, opf:, ...), so qualified-name matching is unreliable.
  static List<XmlElement> _byLocal(XmlDocument doc, String local) => doc.rootElement
      .descendants
      .whereType<XmlElement>()
      .where((e) => e.localName == local)
      .toList();
}

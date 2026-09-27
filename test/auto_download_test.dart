import 'dart:ffi';
import 'dart:io';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:cmanga/foundation/app.dart';
import 'package:cmanga/foundation/appdata.dart';
import 'package:cmanga/foundation/comic_source/comic_source.dart';
import 'package:cmanga/foundation/comic_type.dart';
import 'package:cmanga/foundation/favorites.dart';
import 'package:cmanga/foundation/follow_updates.dart';
import 'package:cmanga/foundation/js_engine.dart';
import 'package:cmanga/foundation/local.dart';
import 'package:cmanga/foundation/res.dart';
import 'package:cmanga/network/download.dart';
import 'package:cmanga/utils/epub.dart';
import 'package:zip_flutter/zip_flutter.dart';

bool _nativeZipAvailable() {
  try {
    DynamicLibrary.open('libzip_flutter.so');
    return true;
  } catch (_) {
    return false;
  }
}

/// Integration test for the auto-download-new-chapters feature: a stub
/// comic source (pure Dart closures, no JS engine) plus real SQLite
/// favorites/local databases in a temp directory.
const sourceKey = 'stub_source';

void main() {
  final type = ComicType.fromKey(sourceKey);

  late String dataDir;

  setUpAll(() async {
    var tmp = Directory.systemTemp.createTempSync('auto_dl_test');
    dataDir = tmp.path;
    // path_provider is not registered under flutter test; mock the channel
    // so Appdata.doInit (getApplicationSupportDirectory) cannot hang.
    TestWidgetsFlutterBinding.ensureInitialized();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
            const MethodChannel('plugins.flutter.io/path_provider'),
            (call) async => tmp.path);
    App.dataPath = dataDir;
    App.cachePath = p.join(dataDir, 'cache');
    Directory(App.cachePath).createSync(recursive: true);
    // LocalManager resolves its storage path from this file.
    File(p.join(dataDir, 'local_path'))
        .writeAsStringSync(p.join(dataDir, 'comics'));
    // Mirror the production init order (init.dart + App.initComponents):
    // appdata, the JS engine and the source manager must be initialized
    // before managers that await their ensureInit() completers.
    await appdata.init();
    await JsEngine().init();
    await ComicSourceManager().init();
    Directory(p.join(dataDir, 'comics')).createSync(recursive: true);
    await LocalFavoritesManager().init();
    await LocalManager().init();

    var favs = LocalFavoritesManager();
    favs.createFolder('followed');
    favs.prepareTableForFollowUpdates('followed');

    ComicSourceManager().add(_stubSource());
  });

  tearDownAll(() {
    if (Directory(dataDir).existsSync()) {
      Directory(dataDir).deleteSync(recursive: true);
    }
  });

  void addFavorite(String id, String name) {
    LocalFavoritesManager().addComic(
        'followed',
        FavoriteItem(id: id, name: name, coverPath: '', author: 'a', type: type, tags: []),
        null,
        '2026-01-01');
  }

  Future<void> addLocalComic(String id, String name) async {
    await LocalManager().add(LocalComic(
      id: id,
      title: name,
      subtitle: '',
      tags: [],
      directory: '${id}_stub',
      chapters: null,
      cover: '',
      comicType: type,
      downloadedChapters: ['ch1'],
      createdAt: DateTime.now(),
    ));
  }

  test('enqueues only the new chapters of a local comic when enabled', () async {
    addFavorite('c1', 'Test Comic');
    await addLocalComic('c1', 'Test Comic');

    appdata.settings['autoDownloadNewChapters'] = true;
    var c = LocalFavoritesManager()
        .getComicsWithUpdatesInfo('followed')
        .firstWhere((e) => e.id == 'c1');

    var result = await updateComic(c, 'followed');
    expect(result.updated, isTrue);

    var tasks = LocalManager()
        .downloadingTasks
        .whereType<ImagesDownloadTask>()
        .toList();
    expect(tasks.length, 1);
    expect(tasks.first.comicId, 'c1');
    // ch1 is already downloaded; only the new chapters are enqueued.
    expect(tasks.first.chapters, ['ch2', 'ch3']);
    // Stop the task before it can touch the network (the stub source has
    // no image APIs); resume() checks _isRunning after its first await.
    tasks.first.cancel();
  });

  test('never downloads comics that are not in the local library', () async {
    addFavorite('c2', 'Remote Only');

    appdata.settings['autoDownloadNewChapters'] = true;
    var c = LocalFavoritesManager()
        .getComicsWithUpdatesInfo('followed')
        .firstWhere((e) => e.id == 'c2');
    var before = LocalManager().downloadingTasks.length;
    var result = await updateComic(c, 'followed');
    expect(result.updated, isTrue);
    // Give a (wrongly) enqueued task time to appear.
    await Future.delayed(const Duration(milliseconds: 100));
    expect(LocalManager().downloadingTasks.length, before);
  });

  test('does nothing when the setting is disabled', () async {
    addFavorite('c3', 'Disabled');
    await addLocalComic('c3', 'Disabled');

    appdata.settings['autoDownloadNewChapters'] = false;
    var c = LocalFavoritesManager()
        .getComicsWithUpdatesInfo('followed')
        .firstWhere((e) => e.id == 'c3');
    var before = LocalManager().downloadingTasks.length;

    await updateComic(c, 'followed');
    await Future.delayed(const Duration(milliseconds: 100));
    expect(LocalManager().downloadingTasks.length, before);
  });

  test('respects the chapter limit (only newest N in source order)', () async {
    addFavorite('c4', 'Limited');
    await addLocalComic('c4', 'Limited');

    appdata.settings['autoDownloadNewChapters'] = true;
    appdata.settings['autoDownloadChapterLimit'] = 1;
    var c = LocalFavoritesManager()
        .getComicsWithUpdatesInfo('followed')
        .firstWhere((e) => e.id == 'c4');

    await updateComic(c, 'followed');

    var tasks = LocalManager()
        .downloadingTasks
        .whereType<ImagesDownloadTask>()
        .toList();
    expect(tasks.length, 1);
    // ch1 already downloaded; of the new chapters (ch2, ch3) only the first
    // in source order is enqueued when the limit is 1.
    expect(tasks.first.chapters, ['ch2']);
    tasks.first.cancel();
  });

  group('computeDownloadChapters (headless download idempotency)', () {
    var details = ComicDetails.fromJson({
      'title': 'T',
      'cover': '',
      'tags': {},
      'chapters': {'c1': 'One', 'c2': 'Two', 'c3': 'Three'},
      'sourceKey': sourceKey,
      'comicId': 'x',
    });

    LocalComic localWith(List<String> downloaded) => LocalComic(
          id: 'x',
          title: 'T',
          subtitle: '',
          tags: [],
          directory: 'd',
          chapters: null,
          cover: '',
          comicType: type,
          downloadedChapters: downloaded,
          createdAt: DateTime.now(),
        );

    test('no local copy → all chapters', () {
      expect(computeDownloadChapters(details), ['c1', 'c2', 'c3']);
    });

    test('local copy → only missing chapters', () {
      expect(
          computeDownloadChapters(details, local: localWith(['c1'])),
          ['c2', 'c3']);
    });

    test('fully downloaded → empty (cron exits as up-to-date)', () {
      expect(computeDownloadChapters(details,
              local: localWith(['c1', 'c2', 'c3'])),
          isEmpty);
    });

    test('force overrides the filter', () {
      expect(
          computeDownloadChapters(details,
              local: localWith(['c1']), force: true),
          ['c1', 'c2', 'c3']);
    });

    test('requested list is filtered against downloaded', () {
      expect(computeDownloadChapters(details,
              local: localWith(['c2']), requested: ['c2', 'c3']),
          ['c3']);
    });
  });

  group('local library sort and tag filter', () {
    test('tag filter narrows results; author sort orders by subtitle',
        () async {
      await LocalManager().add(LocalComic(
        id: 'f1',
        title: 'Beta Comic',
        subtitle: 'Zeta Author',
        tags: ['genre:action'],
        directory: 'f1',
        chapters: null,
        cover: '',
        comicType: type,
        downloadedChapters: [],
        createdAt: DateTime(2026, 1, 3),
      ));
      await LocalManager().add(LocalComic(
        id: 'f2',
        title: 'Alpha Comic',
        subtitle: 'Adam Author',
        tags: ['genre:romance'],
        directory: 'f2',
        chapters: null,
        cover: '',
        comicType: type,
        downloadedChapters: [],
        createdAt: DateTime(2026, 1, 1),
      ));
      await LocalManager().add(LocalComic(
        id: 'f3',
        title: 'Gamma Comic',
        subtitle: 'Adam Author',
        tags: ['genre:action', 'genre:drama'],
        directory: 'f3',
        chapters: null,
        cover: '',
        comicType: type,
        downloadedChapters: [],
        createdAt: DateTime(2026, 1, 2),
      ));

      // Tag filter has AND semantics.
      var action = LocalManager().getComics(LocalSortType.name, ['genre:action']);
      expect(action.map((c) => c.id).toSet(), {'f1', 'f3'});
      var both = LocalManager()
          .getComics(LocalSortType.name, ['genre:action', 'genre:drama']);
      expect(both.map((c) => c.id), ['f3']);
      // Author sort: subtitle first, title as tiebreaker. Comics without an
      // author (empty subtitle) sort before named ones; compare the f-series
      // relative order only (c1/c3/c4 from earlier tests have no author).
      var byAuthor = LocalManager().getComics(LocalSortType.author);
      expect(byAuthor.map((c) => c.id).where((id) => id.startsWith('f')).toList(), ['f2', 'f3', 'f1']);

      // Search respects the tag filter too.
      var searched = LocalManager().search('Comic', ['genre:romance']);
      expect(searched.map((c) => c.id), ['f2']);

      // tagCounts aggregates with frequency order.
      var counts = LocalManager().tagCounts();
      expect(counts.first.$1, 'genre:action');
      expect(counts.first.$2, 2);
    });
  });

  var nativeSkip = !_nativeZipAvailable()
      ? 'libzip_flutter.so not loadable in this environment'
      : false;
  group('Epub import', () {
    test('imports spine-ordered images with cover and metadata', () async {
      var src = Directory(p.join(dataDir, 'epub_src'))..createSync(recursive: true);
      File(p.join(src.path, 'cover.jpg')).writeAsBytesSync([1]);
      // Spine order deliberately differs from filename order. Images live in
      // OEBPS/ next to the OPF, like a real EPUB.
      var oebps = Directory(p.join(src.path, 'OEBPS'))..createSync();
      File(p.join(oebps.path, 'p_gamma.png')).writeAsBytesSync([2]);
      File(p.join(oebps.path, 'p_alpha.png')).writeAsBytesSync([3]);
      File(p.join(oebps.path, 'p_beta.webp')).writeAsBytesSync([4]);
      var metaInf = Directory(p.join(src.path, 'META-INF'))..createSync();
      File(p.join(metaInf.path, 'container.xml')).writeAsStringSync('''
<?xml version="1.0"?>
<container version="1.0">
  <rootfiles>
    <rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/>
  </rootfiles>
</container>''');

      File(p.join(oebps.path, 'content.opf')).writeAsStringSync('''
<?xml version="1.0"?>
<package xmlns:dc="http://purl.org/dc/elements/1.1/" version="3.0">
  <metadata>
    <dc:title>Epub Test Comic</dc:title>
    <dc:creator>Author X</dc:creator>
  </metadata>
  <manifest>
    <item id="cover" href="../cover.jpg" media-type="image/jpeg" properties="cover-image"/>
    <item id="g" href="p_gamma.png" media-type="image/png"/>
    <item id="a" href="p_alpha.png" media-type="image/png"/>
    <item id="b" href="p_beta.webp" media-type="image/webp"/>
  </manifest>
  <spine>
    <itemref idref="g"/>
    <itemref idref="a"/>
    <itemref idref="b"/>
  </spine>
</package>''');

      var epubPath = p.join(dataDir, 'test.epub');
      var zip = ZipFile.open(epubPath);
      zip.addFile('cover.jpg', p.join(src.path, 'cover.jpg'));
      zip.addFile('OEBPS/p_gamma.png', p.join(oebps.path, 'p_gamma.png'));
      zip.addFile('OEBPS/p_alpha.png', p.join(oebps.path, 'p_alpha.png'));
      zip.addFile('OEBPS/p_beta.webp', p.join(oebps.path, 'p_beta.webp'));
      zip.addFile('META-INF/container.xml', p.join(metaInf.path, 'container.xml'));
      zip.addFile('OEBPS/content.opf', p.join(oebps.path, 'content.opf'));
      zip.close();

      var comic = await Epub.import(File(epubPath));
      expect(comic.title, 'Epub Test Comic');
      expect(comic.subtitle, 'Author X');
      expect(comic.cover, 'cover.jpg');

      // Pages are copied in SPINE order (gamma, alpha, beta), not filename
      // order; the cover item is excluded from the page list.
      var dest = Directory(p.join(LocalManager().path, comic.directory));
      expect(File(p.join(dest.path, '1.png')).readAsBytesSync(), [2]);
      expect(File(p.join(dest.path, '2.png')).readAsBytesSync(), [3]);
      expect(File(p.join(dest.path, '3.webp')).readAsBytesSync(), [4]);
      expect(File(p.join(dest.path, 'cover.jpg')).existsSync(), isTrue);
    }, skip: nativeSkip);

    test('rejects an archive without container.xml', () async {
      var txt = File(p.join(dataDir, 'plain.txt'))..writeAsStringSync('hi');
      var plainPath = p.join(dataDir, 'plain.epub');
      var zip = ZipFile.open(plainPath);
      zip.addFile('a.txt', txt.path);
      zip.close();
      expect(() => Epub.import(File(plainPath)), throwsA(predicate((e) => e.toString().contains('container.xml'))));
    }, skip: nativeSkip);
  });
}

ComicSource _stubSource() {
  var details = ComicDetails.fromJson({
    'title': 'Test Comic',
    'cover': '',
    'tags': {},
    'chapters': {'ch1': 'Chapter 1', 'ch2': 'Chapter 2', 'ch3': 'Chapter 3'},
    'sourceKey': sourceKey,
    'comicId': 'c1',
    'updateTime': '2026-09-27',
  });
  return ComicSource(
    'Stub Source', // name
    sourceKey, // key
    null, // account
    null, // categoryData
    null, // categoryComicsData
    null, // favoriteData
    [], // explorePages
    null, // searchPageData
    null, // settings
    (id) async => Res(details), // loadComicInfo
    null, // loadComicThumbnail
    null, // loadComicPages
    null, // getImageLoadingConfig
    null, // getThumbnailLoadingConfig
    '', // filePath
    '', // url
    '1.0.0', // version
    null, // commentsLoader
    null, // sendCommentFunc
    null, // chapterCommentsLoader
    null, // sendChapterCommentFunc
    null, // likeOrUnlikeComic
    null, // voteCommentFunc
    null, // likeCommentFunc
    null, // idMatcher
    null, // translations
    null, // handleClickTagEvent
    null, // onTagSuggestionSelected
    null, // linkHandler
    false, // enableTagsSuggestions
    false, // enableTagsTranslate
    null, // starRatingFunc
    null, // archiveDownloader
  );
}

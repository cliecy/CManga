import 'package:flutter_test/flutter_test.dart';
import 'package:cmanga/foundation/comic_source/comic_source.dart';
import 'package:cmanga/network/download.dart';

/// Regression test: archive downloads used to be serialized on save but
/// dropped by the fromJson dispatcher on restore (only ImagesDownloadTask
/// was handled), so a killed app lost every in-flight CBZ download.
void main() {
  const sourceKey = 'archive_stub_source';

  setUpAll(() {
    ComicSourceManager().add(ComicSource(
      'Archive Stub', // name
      sourceKey, // key
      null, // account
      null, // categoryData
      null, // categoryComicsData
      null, // favoriteData
      [], // explorePages
      null, // searchPageData
      null, // settings
      (id) async => throw UnimplementedError(), // loadComicInfo
      null, // loadComicThumbnail
      null, // loadComicPages
      null, // getImageLoadingConfig
      null, // getThumbnailLoadingConfig
      '', // filePath
      '', // url
      '1.0.0', // version
      null, null, null, null, null, null, null, null, null, null, null, null,
      false, // enableTagsSuggestions
      false, // enableTagsTranslate
      null, // starRatingFunc
      null, // archiveDownloader
    ));
  });

  test('archive task survives the dispatcher round-trip', () {
    var comic = ComicDetails.fromJson({
      'title': 'Archived Comic',
      'cover': '',
      'tags': {},
      'chapters': null,
      'sourceKey': sourceKey,
      'comicId': 'a1',
    });
    var task = ArchiveDownloadTask('https://example.com/a.cbz', comic);
    var json = task.toJson();
    expect(json['type'], 'ArchiveDownloadTask');

    var restored = DownloadTask.fromJson(json);
    expect(restored, isA<ArchiveDownloadTask>());
    expect((restored as ArchiveDownloadTask).archiveUrl,
        'https://example.com/a.cbz');
    expect(restored.title, 'Archived Comic');
  });

  test('dispatcher returns null for unknown task types', () {
    expect(DownloadTask.fromJson({'type': 'MysteryTask'}), isNull);
  });

  test('archive restore tolerates a removed source instead of crashing', () {
    var comic = ComicDetails.fromJson({
      'title': 'Orphaned',
      'cover': '',
      'tags': {},
      'chapters': null,
      'sourceKey': 'no_such_source',
      'comicId': 'a2',
    });
    expect(
        ArchiveDownloadTask.fromJson({
          'type': 'ArchiveDownloadTask',
          'archiveUrl': 'https://example.com/b.cbz',
          'comic': comic.toJson(),
          'path': null,
        }),
        isNull);
  });
}

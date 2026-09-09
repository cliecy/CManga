import 'dart:async' show Future, StreamController;
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/foundation/comic_type.dart';
import 'package:venera/foundation/local.dart';
import 'package:venera/network/images.dart';
import 'package:venera/utils/io.dart';
import '../history.dart';
import 'base_image_provider.dart';
import 'image_favorites_provider.dart' as image_provider;
import 'reader_image.dart';

class ImageFavoritesProvider
    extends BaseImageProvider<image_provider.ImageFavoritesProvider> {
  /// Image provider for imageFavorites
  const ImageFavoritesProvider(this.imageFavorite);

  final ImageFavorite imageFavorite;

  int get page => imageFavorite.page;

  String get sourceKey => imageFavorite.sourceKey;

  String get cid => imageFavorite.id;

  String get eid => imageFavorite.eid;

  @override
  Future<Uint8List> load(
    StreamController<ImageChunkEvent>? chunkEvents,
    void Function()? checkStop,
  ) async {
    final source = await _loadSource(chunkEvents, checkStop);
    final events = chunkEvents ?? StreamController<ImageChunkEvent>.broadcast();
    try {
      return await ReaderImageProvider(
        source.imageKey,
        sourceKey,
        cid,
        eid,
        page,
      ).load(events, checkStop ?? () {}, sourceBytes: source.bytes);
    } finally {
      if (chunkEvents == null) await events.close();
    }
  }

  Future<Uint8List> exportImage() async {
    final source = await _loadSource(null, null);
    return ReaderImageProvider(
      source.imageKey,
      sourceKey,
      cid,
      eid,
      page,
    ).exportImage(sourceBytes: source.bytes);
  }

  Future<({String imageKey, Uint8List bytes})> _loadSource(
    StreamController<ImageChunkEvent>? chunkEvents,
    void Function()? checkStop,
  ) async {
    var imageKey = imageFavorite.imageKey;
    final localKey = await _localImageKey();
    checkStop?.call();
    if (localKey != null) {
      return (
        imageKey: localKey,
        bytes: await File(localKey.substring(7)).readAsBytes(),
      );
    }
    var cacheImage = await readFromCache();
    checkStop?.call();
    if (cacheImage != null) {
      return (imageKey: imageKey, bytes: cacheImage);
    }
    var gotImageKey = false;
    if (imageKey == "") {
      imageKey = await getImageKey();
      checkStop?.call();
      gotImageKey = true;
    }
    Uint8List image;
    try {
      image = await getImageFromNetwork(imageKey, chunkEvents, checkStop);
    } catch (e) {
      if (gotImageKey) {
        rethrow;
      } else {
        imageKey = await getImageKey();
        image = await getImageFromNetwork(imageKey, chunkEvents, checkStop);
      }
    }
    await writeToCache(image);
    return (imageKey: imageKey, bytes: image);
  }

  Future<void> writeToCache(Uint8List image) async {
    var fileName = md5.convert(key.codeUnits).toString();
    var file = File(FilePath.join(App.cachePath, 'image_favorites', fileName));
    if (!file.existsSync()) {
      file.createSync(recursive: true);
    }
    await file.writeAsBytes(image);
  }

  Future<Uint8List?> readFromCache() async {
    var fileName = md5.convert(key.codeUnits).toString();
    var file = File(FilePath.join(App.cachePath, 'image_favorites', fileName));
    if (!file.existsSync()) {
      return null;
    }
    return await file.readAsBytes();
  }

  /// Delete a image favorite cache
  static Future<void> deleteFromCache(ImageFavorite imageFavorite) async {
    var fileName = md5
        .convert(ImageFavoritesProvider(imageFavorite).key.codeUnits)
        .toString();
    var file = File(FilePath.join(App.cachePath, 'image_favorites', fileName));
    if (file.existsSync()) {
      await file.delete();
    }
  }

  Future<String?> _localImageKey() async {
    if (imageFavorite.imageKey.startsWith('file://') &&
        await File(imageFavorite.imageKey.substring(7)).exists()) {
      return imageFavorite.imageKey;
    }
    final type = ComicType.fromKey(sourceKey);
    final comic = LocalManager().find(cid, type);
    if (comic == null ||
        (comic.hasChapters && !comic.downloadedChapters.contains(eid))) {
      return null;
    }
    final images = await LocalManager().getImages(
      cid,
      type,
      comic.hasChapters ? eid : 1,
    );
    return images.elementAtOrNull(page - 1);
  }

  Future<Uint8List> getImageFromNetwork(
    String imageKey,
    StreamController<ImageChunkEvent>? chunkEvents,
    void Function()? checkStop,
  ) async {
    await for (var progress in ImageDownloader.loadComicImage(
      imageKey,
      sourceKey,
      cid,
      eid,
    )) {
      checkStop?.call();
      if (chunkEvents != null) {
        chunkEvents.add(
          ImageChunkEvent(
            cumulativeBytesLoaded: progress.currentBytes,
            expectedTotalBytes: progress.totalBytes,
          ),
        );
      }
      if (progress.imageBytes != null) {
        return progress.imageBytes!;
      }
    }
    throw "Error: Empty response body.";
  }

  Future<String> getImageKey() async {
    String sourceKey = imageFavorite.sourceKey;
    String cid = imageFavorite.id;
    String eid = imageFavorite.eid;
    var page = imageFavorite.page;
    var comicSource = ComicSource.find(sourceKey);
    if (comicSource == null) {
      throw "Error: Comic source not found.";
    }
    var res = await comicSource.loadComicPages!(cid, eid);
    return res.data[page - 1];
  }

  @override
  Future<ImageFavoritesProvider> obtainKey(ImageConfiguration configuration) {
    return SynchronousFuture(this);
  }

  @override
  String get key =>
      "ImageFavorites ${imageFavorite.imageKey}@${imageFavorite.sourceKey}@${imageFavorite.id}@${imageFavorite.eid}";
}

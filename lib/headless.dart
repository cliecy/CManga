import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/widgets.dart';
import 'package:cmanga/utils/data_sync.dart';
import 'package:cmanga/foundation/comic_source/comic_source.dart';
import 'package:cmanga/foundation/log.dart';
import 'package:cmanga/pages/comic_source_page.dart';
import 'package:cmanga/init.dart';
import 'package:cmanga/foundation/follow_updates.dart';
import 'package:cmanga/foundation/favorites.dart';
import 'package:cmanga/foundation/appdata.dart';
import 'package:cmanga/foundation/local.dart';
import 'package:cmanga/network/download.dart';
import 'package:cmanga/foundation/comic_type.dart';
import 'package:cmanga/utils/ext.dart';
import 'package:cmanga/utils/image_ai_service.dart';

void cliPrint(Map<String, dynamic> data) {
  print('[CLI PRINT] ${jsonEncode(data)}');
}

Future<void> runHeadlessMode(List<String> args) async {
  WidgetsFlutterBinding.ensureInitialized();
  if (args.contains('--ignore-disheadless-log')) {
    Log.isMuted = true;
  }
  if(Platform.isLinux || Platform.isMacOS){
    Directory.current = Platform.environment['HOME']!;
  }
  // The first arg is '--headless', so we look at the next ones.
  var commandIndex = args.indexOf('--headless') + 1;
  if (commandIndex >= args.length) {
    cliPrint({'status': 'error', 'message': 'No command provided for headless mode.'});
    exit(1);
  }

  // Need to initialize the app for some features to work
  await init();

  var command = args[commandIndex];
  var subCommand = (commandIndex + 1 < args.length) ? args[commandIndex + 1] : null;

  switch (command) {
    case 'webdav':
      if (subCommand == 'up') {
        cliPrint({'status': 'running', 'message': 'Uploading WebDAV data...'});
        await DataSync().uploadData();
        cliPrint({'status': 'success', 'message': 'Upload complete.'});
      } else if (subCommand == 'down') {
        cliPrint({'status': 'running', 'message': 'Downloading WebDAV data...'});
        await DataSync().downloadData();
        cliPrint({'status': 'success', 'message': 'Download complete.'});
      } else {
        cliPrint({'status': 'error', 'message': 'Invalid webdav command. Use "up" or "down".'});
        exit(1);
      }
      break;
    case 'ai':
      // Process an image through the native AI pipeline and report the
      // backend actually used. Args: --model --image --type --output
      // [--backend auto|cpu|webgpu] [--scale N] [--strength N] [--intensity N]
      final Map<String, String> opts = <String, String>{};
      for (var i = commandIndex + 1; i + 1 < args.length; i++) {
        final a = args[i];
        if (a.startsWith('--')) opts[a.substring(2)] = args[i + 1];
      }
      final modelPath = opts['model'];
      final imagePath = opts['image'];
      final type = opts['type'] ?? 'esrgan';
      final outputPath = opts['output'] ?? 'ai_output.png';
      if (modelPath == null || imagePath == null) {
        cliPrint({'status': 'error', 'message': 'ai command requires --model and --image'});
        exit(1);
      }
      cliPrint({'status': 'running', 'message': 'Processing with AI (type=$type, backend=${opts['backend'] ?? 'auto'})...'});
      final imageBytes = await File(imagePath).readAsBytes();
      final stopwatch = Stopwatch()..start();
      final result = await ImageAiService.instance.process({
        'type': type,
        'imageBytes': imageBytes,
        'modelPath': modelPath,
        'backend': opts['backend'] ?? 'auto',
        'outputScale': double.tryParse(opts['scale'] ?? '0') ?? 0,
        'strength': double.tryParse(opts['strength'] ?? '1') ?? 1,
        'intensity': double.tryParse(opts['intensity'] ?? '1') ?? 1,
      }, forceReprocess: true);
      stopwatch.stop();
      final outBytes = result['imageBytes'] as Uint8List;
      await File(outputPath).writeAsBytes(outBytes);
      cliPrint({
        'status': 'success',
        'type': type,
        'backend': result['backend'],
        'scale': result['scale'],
        'cacheHit': result['cacheHit'],
        'fallbackReason': result['fallbackReason'],
        'outputBytes': outBytes.length,
        'elapsedMs': stopwatch.elapsedMilliseconds,
        'output': outputPath,
      });
      break;
    case 'updatescript':
      if (subCommand == 'all') {
        cliPrint({'status': 'running', 'message': 'Checking for comic source script updates...'});
        await ComicSourcePage.checkComicSourceUpdate();
        var updates = ComicSourceManager().availableUpdates;
        if (updates.isEmpty) {
          cliPrint({'status': 'success', 'message': 'No updates found.'});
        } else {
          var total = updates.length;
          var current = 0;
          var errors = 0;
          var updated = 0;
          cliPrint({
            'status': 'running',
            'message': 'Updating all comic source scripts...',
            'data': {
              'total': total,
              'current': 0,
              'updated': 0,
              'errors': 0,
            }
          });
          for (var key in updates.keys) {
            var source = ComicSource.find(key);
            if (source != null) {
              current++;
              var data = {
                'current': current,
                'total': total,
                'source': {
                  'key': source.key,
                  'name': source.name,
                  'version': source.version,
                  'url': source.url,
                }
              };
              try {
                await ComicSourcePage.update(source, false);
                updated++;
                cliPrint({
                  'status': 'running',
                  'message': 'Progress',
                  'data': data,
                });
              } catch (e) {
                errors++;
                cliPrint({
                  'status': 'running',
                  'message': 'ProgressError',
                  'data': {
                    ...data,
                    'error': e.toString(),
                  },
                });
              }
            }
          }
          cliPrint({
            'status': 'success',
            'message': 'All scripts updated.',
            'data': {
              'total': total,
              'updated': updated,
              'errors': errors,
            }
          });
        }
      } else {
        cliPrint({'status': 'error', 'message': 'Invalid updatescript command. Use "all".'});
        exit(1);
      }
      break;
    case 'updatesubscribe':
      cliPrint({'status': 'running', 'message': 'Updating subscribed comics...'});
      var folder = appdata.settings["followUpdatesFolder"];
      if (folder == null) {
        cliPrint({'status': 'error', 'message': 'Follow updates folder is not configured.'});
        exit(1);
      }

      var updateIndex = args.indexOf('--update-comic-by-id-type');
      if (updateIndex != -1) {
        var id = args[updateIndex + 1];
        var type = args[updateIndex + 2];
        var comics = LocalFavoritesManager().getComicsWithUpdatesInfo(folder);
        var comic = comics.firstWhere((c) => c.id == id && c.type.sourceKey == type);
        
        var result = await updateComic(comic, folder);
        
        Map<String, dynamic> data = {
          'current': 1,
          'total': 1,
          'comic': {
            'id': comic.id,
            'name': comic.name,
            'coverUrl': comic.coverPath,
            'author': comic.author,
            'type': comic.type.sourceKey,
            'updateTime': comic.updateTime,
            'tags': comic.tags,
          }
        };

        var message = 'Progress';
        if (result.errorMessage != null) {
          message = 'ProgressError';
          data['error'] = result.errorMessage;
        }

        cliPrint({
          'status': 'running',
          'message': message,
          'data': data,
        });

        cliPrint({
          'status': 'running',
          'message': 'Update check complete.',
          'data': {
            'total': 1,
            'updated': result.updated ? 1 : 0,
            'errors': result.errorMessage != null ? 1 : 0,
          }
        });

        await Future.delayed(const Duration(milliseconds: 500));
        var json = await getUpdatedComicsAsJson(folder);
        cliPrint({
          'status': result.errorMessage != null ? 'error' : 'success',
          'message': 'Updated comics list.',
          'data': jsonDecode(json),
        });
      } else {
        int total = 0;
        int updated = 0;
        int errors = 0;
        await for (var progress in updateFolder(folder, true)) {
          total = progress.total;
          updated = progress.updated;
          errors = progress.errors;
          Map<String, dynamic> data = {
            'current': progress.current,
            'total': progress.total,
          };
          if (progress.comic != null) {
            data['comic'] = {
              'id': progress.comic!.id,
              'name': progress.comic!.name,
              'coverUrl': progress.comic!.coverPath,
              'author': progress.comic!.author,
              'type': progress.comic!.type.sourceKey,
              'updateTime': progress.comic!.updateTime,
              'tags': progress.comic!.tags,
            };
          }
          var message = 'Progress';
          if (progress.errorMessage != null) {
            message = 'ProgressError';
            data['error'] = progress.errorMessage;
          }
          cliPrint({
            'status': 'running',
            'message': message,
            'data': data,
          });
        }
        cliPrint({
          'status': 'running',
          'message': 'Update check complete.',
          'data': {
            'total': total,
            'updated': updated,
            'errors': errors,
          }
        });
        await Future.delayed(const Duration(milliseconds: 500));
        var json = await getUpdatedComicsAsJson(folder);
        cliPrint({
          'status': errors > 0 ? 'error' : 'success',
          'message': 'Updated comics list.',
          'data': jsonDecode(json),
        });
      }
      break;
    case 'download':
      // Args: --comic-id <id> --source-key <key> [--chapters c1,c2,...] [--force]
      final Map<String, String> opts = <String, String>{};
      for (var i = commandIndex + 1; i + 1 < args.length; i++) {
        if (args[i].startsWith('--')) opts[args[i].substring(2)] = args[i + 1];
      }
      final comicId = opts['comic-id'];
      final sourceKey = opts['source-key'];
      if (comicId == null || sourceKey == null) {
        cliPrint({
          'status': 'error',
          'message': 'download requires --comic-id and --source-key'
        });
        exit(1);
      }
      var source = ComicSource.find(sourceKey);
      if (source == null) {
        cliPrint({'status': 'error', 'message': 'Comic source not found: $sourceKey'});
        exit(1);
      }
      // Idempotency: repeated runs must not re-download existing chapters.
      var force = args.contains('--force');
      var type = ComicType.fromKey(sourceKey);
      var local = LocalManager().find(comicId, type);
      List<String>? target; // null → the task downloads everything
      var chOpt = opts['chapters'];
      if (chOpt != null && chOpt.isNotEmpty) {
        var requested = chOpt.split(',').map((e) => e.trim()).where((e) => e.isNotEmpty).toList();
        var downloaded = force || local == null ? <String>{} : local.downloadedChapters.toSet();
        target = requested.where((id) => !downloaded.contains(id)).toList();
      } else if (!force && local != null) {
        // No explicit list: only fetch missing chapters. Needs the chapter
        // inventory from the source (one metadata call per run).
        if (source.loadComicInfo == null) {
          cliPrint({'status': 'error', 'message': 'Source provides no chapter list; use --chapters or --force'});
          exit(1);
        }
        ComicDetails? details;
        try {
          details = (await source.loadComicInfo!(comicId)).dataOrNull;
        } catch (e) {
          cliPrint({'status': 'error', 'message': 'Failed to fetch chapter list: $e'});
          exit(1);
        }
        if (details == null) {
          cliPrint({'status': 'error', 'message': 'Source returned no comic details for $comicId'});
          exit(1);
        }
        target = computeDownloadChapters(details, local: local);
      }
      if (target != null && target.isEmpty) {
        cliPrint({'status': 'success', 'message': 'Already up to date: nothing to download.'});
        break;
      }
      var manager = LocalManager();
      // Reuse an in-flight/queued task for the same comic instead of stacking duplicates.
      var existing = manager.downloadingTasks.firstWhereOrNull((t) => t.id == comicId && t.comicType == type);
      DownloadTask task;
      if (existing != null) {
        cliPrint({'status': 'running', 'message': 'Download already in progress, waiting...'});
        task = existing;
      } else {
        task = ImagesDownloadTask(source: source, comicId: comicId, chapters: target);
        manager.addTask(task);
        // Run this download immediately even if restored tasks are queued.
        manager.moveToFirst(task);
      }
      task.resume();
      var start = DateTime.now();
      var lastReport = start;
      while (manager.downloadingTasks.contains(task)) {
        if (task.isError) break;
        // Hard cap so a stalled download cannot block cron forever.
        if (DateTime.now().difference(start) > const Duration(hours: 2)) break;
        if (DateTime.now().difference(lastReport) >= const Duration(seconds: 15)) {
          cliPrint({'status': 'running', 'message': task.message, 'data': {'progress': task.progress}});
          lastReport = DateTime.now();
        }
        await Future.delayed(const Duration(seconds: 2));
      }
      var ok = !task.isError && !manager.downloadingTasks.contains(task);
      cliPrint({
        'status': ok ? 'success' : 'error',
        'message': ok ? 'Download complete.' : 'Download failed or timed out: ${task.message}',
        'data': {'comicId': comicId, 'progress': task.progress},
      });
      if (!ok) exit(1);
      break;
    default:
      cliPrint({'status': 'error', 'message': 'Unknown command: $command'});
      exit(1);
  }

  // Exit after command execution
  exit(0);
}

part of 'settings_page.dart';

/// Changes to global AI settings and installed models also invalidate open readers.
final ValueNotifier<int> imageAiSettingsRevision = ValueNotifier(0);

void _refreshAiImages() {
  PaintingBinding.instance.imageCache.clear();
  PaintingBinding.instance.imageCache.clearLiveImages();
  ComicImage.clear();
  imageAiSettingsRevision.value++;
}

Future<bool> _allowImageAi(BuildContext context) async {
  final supported = await ImageAiService.instance.init();
  if (!supported && context.mounted) {
    context.showMessage(
      message: ImageAiService.instance.status.value.message.tl,
    );
  }
  return supported;
}

class _ImageAiCacheLimit extends StatelessWidget {
  const _ImageAiCacheLimit({this.comicId, this.comicSource});

  final String? comicId;
  final String? comicSource;

  bool get _isComic => comicId != null && comicSource != null;

  int? get _override {
    if (!_isComic) return null;
    final entry =
        appdata.settings['comicSpecificSettings']['$comicId@$comicSource'];
    final value = entry?['imageAiCacheSizeMiB'];
    return entry?['enabled'] == true && value is int && value > 0
        ? value
        : null;
  }

  String _sizeLabel(int mib) => '@mib MiB (@gib GiB)'.tlParams({
    'mib': mib.toString(),
    'gib': (mib / 1024).toStringAsFixed(3),
  });

  Future<void> _save(int? mib) async {
    if (_isComic) {
      appdata.settings.setReaderSetting(
        comicId!,
        comicSource!,
        'imageAiCacheSizeMiB',
        mib,
      );
    } else {
      appdata.settings['imageAiCacheSizeMiB'] = mib!;
    }
    await appdata.saveData();
    await ImageAiService.instance.updateCacheLimits();
  }

  Future<void> _enterValue(BuildContext context) async {
    final value = _isComic
        ? _override
        : appdata.settings['imageAiCacheSizeMiB'];
    await showInputDialog(
      context: context,
      title:
          (_isComic
                  ? 'Independent AI cache quota (MiB)'
                  : 'Shared AI cache limit (MiB)')
              .tl,
      initialValue: value?.toString(),
      hintText: '1 – 1048576 MiB (1 TiB)',
      onConfirm: (text) async {
        final entered = int.tryParse(text.trim(), radix: 10);
        if (entered == null || entered < 1 || entered > 1048576) {
          return 'Enter a whole number from 1 to 1048576 MiB'.tl;
        }
        await _save(entered);
        return null;
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: appdata.settings,
      builder: (context, _) {
        final quota = _override;
        final sharedSize = _sizeLabel(appdata.settings['imageAiCacheSizeMiB']);
        final size = _isComic && quota == null
            ? 'Using shared pool: @size'.tlParams({'size': sharedSize})
            : _sizeLabel(quota ?? appdata.settings['imageAiCacheSizeMiB']);
        final description =
            (_isComic
                    ? 'An independent quota covers all AI stages for this comic and is separate from the shared pool. It can increase total disk usage; least recently used (LRU) results are removed first.'
                    : 'Shared by comics without an independent quota. Super-resolution and colorization share this limit; least recently used (LRU) results are removed first.')
                .tl;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ListTile(
              title: Text(
                (_isComic
                        ? 'AI cache quota for this comic'
                        : 'Shared AI cache pool')
                    .tl,
              ),
              subtitle: Text('$size\n$description'),
              trailing: _isComic ? null : const Icon(Icons.edit),
              onTap: () => _enterValue(context),
            ),
            if (_isComic)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Wrap(
                  spacing: 8,
                  children: [
                    TextButton(
                      onPressed: () => _enterValue(context),
                      child: Text(
                        (quota == null
                                ? 'Set independent quota'
                                : 'Edit independent quota')
                            .tl,
                      ),
                    ),
                    TextButton(
                      onPressed: quota == null ? null : () => _save(null),
                      child: Text('Use shared pool'.tl),
                    ),
                  ],
                ),
              ),
          ],
        );
      },
    );
  }
}

/// Persistent download activity, independent of any settings page's lifetime.
class ModelDownloadStatusView extends StatelessWidget {
  const ModelDownloadStatusView({super.key});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([
        Anime4KV4ModelManager.downloadState,
        ColorizationModelManager.downloadState,
      ]),
      builder: (context, _) {
        final states =
            [
              Anime4KV4ModelManager.downloadState.value,
              ColorizationModelManager.downloadState.value,
            ].whereType<ModelDownloadState>().where(
              (state) => state.isDownloading || state.error != null,
            );
        if (states.isEmpty) return const SizedBox.shrink();
        return Card(
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (final state in states)
                  _ModelDownloadProgress(state: state),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _ModelDownloadProgress extends StatelessWidget {
  const _ModelDownloadProgress({required this.state});

  final ModelDownloadState? state;

  @override
  Widget build(BuildContext context) {
    final state = this.state;
    if (state == null || (!state.isDownloading && state.error == null)) {
      return const SizedBox.shrink();
    }
    final progress = state.progress;
    final bytes = state.totalBytes > 0
        ? '${state.receivedBytes} / ${state.totalBytes}'
        : '${state.receivedBytes}';
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            state.modelName.tl,
            style: const TextStyle(fontWeight: FontWeight.bold),
          ),
          Text(
            state.error == null
                ? state.message.tl
                : 'Download failed: @e'.tlParams({'e': state.error!}),
            style: TextStyle(
              color: state.error == null
                  ? context.colorScheme.onSurfaceVariant
                  : context.colorScheme.error,
            ),
          ),
          Text(
            '@bytes bytes'.tlParams({'bytes': bytes}) +
                (progress == null
                    ? ''
                    : ' · ${(progress * 100).toStringAsFixed(1)}%'),
          ),
          if (state.isDownloading) ...[
            const SizedBox(height: 4),
            LinearProgressIndicator(value: progress),
            Text('Downloads continue after closing settings.'.tl),
          ],
        ],
      ),
    );
  }
}

class _ImageAiControls extends StatefulWidget {
  const _ImageAiControls({
    required this.superResolution,
    this.comicId,
    super.key,
    this.comicSource,
    this.onChanged,
  });

  final bool superResolution;
  final String? comicId;
  final String? comicSource;
  final void Function(String)? onChanged;

  @override
  State<_ImageAiControls> createState() => _ImageAiControlsState();
}

class _ImageAiControlsState extends State<_ImageAiControls> {
  @override
  void initState() {
    super.initState();
    _probe();
  }

  Future<void> _probe() async {
    await ImageAiService.instance.init();
    if (widget.superResolution) {
      await Anime4KV4Service.instance.checkModelAvailable();
    } else {
      await ColorizationService.instance.checkModelAvailable();
    }
    if (mounted) setState(() {});
  }

  dynamic _value(String key) => widget.comicId == null
      ? appdata.settings[key]
      : appdata.settings.getReaderSetting(
          widget.comicId!,
          widget.comicSource!,
          key,
        );

  void _changed(String key) {
    _refreshAiImages();
    widget.onChanged?.call(key);
    setState(() {});
  }

  void _set(String key, dynamic value) {
    if (widget.comicId == null) {
      appdata.settings[key] = value;
    } else {
      appdata.settings.setReaderSetting(
        widget.comicId!,
        widget.comicSource!,
        key,
        value,
      );
    }
    appdata.saveData();
    _changed(key);
  }

  Widget _slider(
    String key,
    String title,
    double min,
    double max, {
    double interval = .01,
    bool percent = false,
    String suffix = '',
  }) {
    return _SliderSetting(
      key: ValueKey('$key@${widget.comicId}@${widget.comicSource}'),
      title: title.tl,
      settingsIndex: key,
      min: min,
      max: max,
      interval: interval,
      preciseInput: true,
      displayScale: percent ? 100 : 1,
      suffix: percent ? '%' : suffix,
      comicId: widget.comicId,
      comicSource: widget.comicSource,
      onChanged: () => _changed(key),
    );
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([appdata.settings, imageAiSettingsRevision]),
      builder: (context, _) => ValueListenableBuilder<ImageAiStatus>(
        valueListenable: ImageAiService.instance.status,
        builder: (context, status, _) {
          final isV4 = _value('anime4KVersion') == 'v4';
          final nativeScale =
              Anime4KV4Service.instance.modelInfo?['scale'] as num?;
          final outputScale =
              (_value('anime4KV4OutputScale') as num?)?.toDouble() ?? 0;
          return Column(
            children: [
              if (!widget.superResolution || isV4) ...[
                ListTile(
                  leading: status.isProcessing
                      ? const SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : Icon(
                          status.isError
                              ? Icons.warning_amber
                              : Icons.info_outline,
                        ),
                  title: Text('Last AI operation'.tl),
                  subtitle: Text(status.message.tl),
                ),
                if (App.isMacOS || App.isIOS)
                  ListTile(
                    title: Text('AI execution backend'.tl),
                    subtitle: Text(
                      'ONNX Runtime WebGPU (Metal) only. CPU neural inference is not supported.'
                          .tl,
                    ),
                  )
                else
                  SelectSetting(
                    title: 'AI execution backend'.tl,
                    help:
                        (App.isWindows
                                ? 'Auto tries DirectML, then the same AI model on CPU.'
                                : App.isAndroid
                                ? 'Auto tries NNAPI for super-resolution, then the same model on CPU. Colorization uses CPU.'
                                : 'Native AI is supported only on Windows, Android, macOS and iOS')
                            .tl,
                    settingKey: 'imageAiBackend',
                    optionTranslation: {'auto': 'Auto'.tl, 'cpu': 'CPU'},
                    comicId: widget.comicId,
                    comicSource: widget.comicSource,
                    onChanged: () => _changed('imageAiBackend'),
                  ),
              ],
              if (widget.superResolution) ...[
                if (isV4) ...[
                  SwitchListTile(
                    title: Text('Follow model scale'.tl),
                    subtitle: Text(
                      nativeScale == null
                          ? 'Select a compatible model to set the output scale.'
                                .tl
                          : 'Native scale: @scale×'.tlParams({
                              'scale': nativeScale.toString(),
                            }),
                    ),
                    value: outputScale == 0,
                    onChanged: nativeScale == null
                        ? null
                        : (follow) => _set(
                            'anime4KV4OutputScale',
                            follow ? 0.0 : nativeScale.toDouble(),
                          ),
                  ),
                  if (outputScale != 0 &&
                      nativeScale != null &&
                      nativeScale > 1)
                    _slider(
                      'anime4KV4OutputScale',
                      'Final output scale',
                      1,
                      nativeScale.toDouble(),
                      interval: .05,
                      suffix: '×',
                    ),
                  if (nativeScale != null && outputScale > nativeScale)
                    ListTile(
                      subtitle: Text(
                        'Output scale exceeds this model. Choose a smaller scale or follow the model.'
                            .tl,
                      ),
                    ),
                ] else
                  _slider(
                    'anime4KScaleFactor',
                    'Scale Factor',
                    1,
                    4,
                    interval: .05,
                    suffix: '×',
                  ),
                _slider(
                  'anime4KEnhancementStrength',
                  'Super-resolution strength',
                  0,
                  1,
                  percent: true,
                ),
                ListTile(
                  subtitle: Text(
                    '0%: ordinary resize. 100%: full enhancement. Strength does not change output size.'
                        .tl,
                  ),
                ),
                if (isV4)
                  _slider(
                    'anime4KV4Intensity',
                    'AI output contrast',
                    .3,
                    1.2,
                    percent: true,
                  ),
              ] else ...[
                _slider(
                  'colorizationIntensity',
                  'Colorization strength',
                  0,
                  1.2,
                  percent: true,
                ),
                ListTile(
                  subtitle: Text(
                    '0%: neutral colors. 100%: predicted colors. Above 100%: more vivid colors. Brightness and dimensions are unchanged.'
                        .tl,
                  ),
                ),
              ],
            ],
          );
        },
      ),
    );
  }
}

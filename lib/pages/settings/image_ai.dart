part of 'settings_page.dart';

void _refreshAiImages() {
  PaintingBinding.instance.imageCache.clear();
  PaintingBinding.instance.imageCache.clearLiveImages();
  ComicImage.clear();
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
      listenable: appdata.settings,
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
                SelectSetting(
                  title: 'AI execution backend'.tl,
                  help:
                      'Auto tries platform acceleration, then the same AI model on CPU.'
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

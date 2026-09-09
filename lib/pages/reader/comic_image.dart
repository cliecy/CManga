part of 'reader.dart';

class ComicImage extends StatefulWidget {
  /// Modified from flutter Image
  ComicImage({
    required ImageProvider image,
    super.key,
    double scale = 1.0,
    this.semanticLabel,
    this.excludeFromSemantics = false,
    this.width,
    this.height,
    this.color,
    this.opacity,
    this.colorBlendMode,
    this.fit,
    this.alignment = Alignment.center,
    this.repeat = ImageRepeat.noRepeat,
    this.centerSlice,
    this.matchTextDirection = false,
    this.gaplessPlayback = false,
    this.filterQuality = FilterQuality.medium,
    this.isAntiAlias = false,
    Map<String, String>? headers,
    int? cacheWidth,
    int? cacheHeight,
    this.onInit,
    this.onDispose,
  }) : image = ResizeImage.resizeIfNeeded(cacheWidth, cacheHeight, image),
       assert(cacheWidth == null || cacheWidth > 0),
       assert(cacheHeight == null || cacheHeight > 0);

  final ImageProvider image;

  final String? semanticLabel;

  final bool excludeFromSemantics;

  final double? width;

  final double? height;

  final bool gaplessPlayback;

  final bool matchTextDirection;

  final Rect? centerSlice;

  final ImageRepeat repeat;

  final AlignmentGeometry alignment;

  final BoxFit? fit;

  final BlendMode? colorBlendMode;

  final FilterQuality filterQuality;

  final Animation<double>? opacity;

  final Color? color;

  final bool isAntiAlias;

  final void Function(State<ComicImage> state)? onInit;

  final void Function(State<ComicImage> state)? onDispose;

  static void clear() {
    ReaderImageDetailsStore.instance.invalidate();
    ReaderPreloader.invalidateAll();
    _ComicImageState.clear();
  }

  @override
  State<ComicImage> createState() => _ComicImageState();
}

class _ComicImageState extends State<ComicImage> with WidgetsBindingObserver {
  ImageStream? _imageStream;
  ImageInfo? _imageInfo;
  ImageChunkEvent? _loadingProgress;
  bool _isListeningToStream = false;
  late bool _invertColors;
  int? _frameNumber;
  bool _wasSynchronouslyLoaded = false;
  late DisposableBuildContext<State<ComicImage>> _scrollAwareContext;
  Object? _lastException;
  ImageStreamCompleterHandle? _completerHandle;

  static final Map<int, Size> _cache = {};

  /// 追踪所有活跃的实例，用于在 clear() 时重置所有实例的处理状态
  static final Set<_ComicImageState> _instances = {};

  static void clear() {
    _cache.clear();
    // Processing belongs to ReaderImageProvider. Resolve a fresh stream after
    // settings changes; do not run a second colorization pass in the widget.
    for (final instance in _instances) {
      if (instance.mounted) {
        instance._resolveImage();
      }
    }
  }

  ReaderImageProvider? get _readerProvider {
    ImageProvider provider = widget.image;
    while (provider is ResizeImage) {
      provider = provider.imageProvider;
    }
    return provider is ReaderImageProvider ? provider : null;
  }

  bool _matchesPage(ReaderImageProvider provider) {
    final current = _readerProvider;
    return current != null &&
        current.imageKey == provider.imageKey &&
        current.sourceKey == provider.sourceKey &&
        current.cid == provider.cid &&
        current.eid == provider.eid &&
        current.page == provider.page;
  }

  static Future<void> reprocess(ReaderImageProvider provider) async {
    await provider.reprocess();
    await provider.evict();
    final images = _instances
        .where((image) => image.mounted && image._matchesPage(provider))
        .toList();
    for (final image in images) {
      if (!image.mounted || !image._matchesPage(provider)) continue;
      // ResizeImage has its own Flutter cache entry; evict only this page.
      await image.widget.image.evict();
    }
    for (final image in images) {
      if (!image.mounted || !image._matchesPage(provider)) continue;
      image.setState(() {
        image._loadingProgress = null;
        image._lastException = null;
      });
      image._resolveImage();
    }
  }

  @override
  void initState() {
    super.initState();
    _instances.add(this);
    WidgetsBinding.instance.addObserver(this);
    _scrollAwareContext = DisposableBuildContext<State<ComicImage>>(this);
    widget.onInit?.call(this);
  }

  @override
  void dispose() {
    assert(_imageStream != null);
    _instances.remove(this);
    WidgetsBinding.instance.removeObserver(this);
    _stopListeningToStream();
    _completerHandle?.dispose();
    _scrollAwareContext.dispose();
    _replaceImage(info: null);
    widget.onDispose?.call(this);
    super.dispose();
  }

  @override
  void didChangeDependencies() {
    _updateInvertColors();
    _resolveImage();

    if (TickerMode.valuesOf(context).enabled) {
      _listenToStream();
    } else {
      _stopListeningToStream(keepStreamAlive: true);
    }

    super.didChangeDependencies();
  }

  @override
  void didUpdateWidget(ComicImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.image != oldWidget.image) {
      _resolveImage();
    }
  }

  @override
  void didChangeAccessibilityFeatures() {
    super.didChangeAccessibilityFeatures();
    setState(() {
      _updateInvertColors();
    });
  }

  @override
  void reassemble() {
    _resolveImage(); // in case the image cache was flushed
    super.reassemble();
  }

  bool containsPoint(Offset point) {
    if (!mounted) {
      return false;
    }
    var renderBox = context.findRenderObject() as RenderBox;
    var localPoint = renderBox.globalToLocal(point);
    return renderBox.paintBounds.contains(localPoint);
  }

  void _updateInvertColors() {
    _invertColors =
        MediaQuery.maybeInvertColorsOf(context) ??
        SemanticsBinding.instance.accessibilityFeatures.invertColors;
  }

  void _resolveImage() {
    final ScrollAwareImageProvider provider = ScrollAwareImageProvider<Object>(
      context: _scrollAwareContext,
      imageProvider: widget.image,
    );
    final ImageStream newStream = provider.resolve(
      createLocalImageConfiguration(
        context,
        size: widget.width != null && widget.height != null
            ? Size(widget.width!, widget.height!)
            : null,
      ),
    );
    _updateSourceStream(newStream);
  }

  ImageStreamListener? _imageStreamListener;

  ImageStreamListener _getListener({bool recreateListener = false}) {
    if (_imageStreamListener == null || recreateListener) {
      _lastException = null;
      _imageStreamListener = ImageStreamListener(
        _handleImageFrame,
        onChunk: _handleImageChunk,
        onError: (Object error, StackTrace? stackTrace) {
          setState(() {
            _lastException = error;
          });
        },
      );
    }
    return _imageStreamListener!;
  }

  void _handleImageFrame(ImageInfo imageInfo, bool synchronousCall) {
    setState(() {
      _replaceImage(info: imageInfo);
      _loadingProgress = null;
      _lastException = null;
      _frameNumber = _frameNumber == null ? 0 : _frameNumber! + 1;
      _wasSynchronouslyLoaded = _wasSynchronouslyLoaded | synchronousCall;
    });
  }

  void _handleImageChunk(ImageChunkEvent event) {
    setState(() {
      _loadingProgress = event;
      _lastException = null;
    });
  }

  void _replaceImage({required ImageInfo? info}) {
    final ImageInfo? oldImageInfo = _imageInfo;
    SchedulerBinding.instance.addPostFrameCallback(
      (_) => oldImageInfo?.dispose(),
    );
    _imageInfo = info;
  }

  // Updates _imageStream to newStream, and moves the stream listener
  // registration from the old stream to the new stream (if a listener was
  // registered).
  void _updateSourceStream(ImageStream newStream) {
    if (_imageStream?.key == newStream.key) {
      return;
    }

    if (_isListeningToStream) {
      _imageStream!.removeListener(_getListener());
    }

    if (!widget.gaplessPlayback) {
      setState(() {
        _replaceImage(info: null);
      });
    }

    setState(() {
      _loadingProgress = null;
      _frameNumber = null;
      _wasSynchronouslyLoaded = false;
    });

    _imageStream = newStream;
    if (_isListeningToStream) {
      _imageStream!.addListener(_getListener());
    }
  }

  void _listenToStream() {
    if (_isListeningToStream) {
      return;
    }

    _imageStream!.addListener(_getListener());
    _completerHandle?.dispose();
    _completerHandle = null;

    _isListeningToStream = true;
  }

  /// Stops listening to the image stream, if this state object has attached a
  /// listener.
  ///
  /// If the listener from this state is the last listener on the stream, the
  /// stream will be disposed. To keep the stream alive, set `keepStreamAlive`
  /// to true, which create [ImageStreamCompleterHandle] to keep the completer
  /// alive and is compatible with the [TickerMode] being off.
  void _stopListeningToStream({bool keepStreamAlive = false}) {
    if (!_isListeningToStream) {
      return;
    }

    if (keepStreamAlive &&
        _completerHandle == null &&
        _imageStream?.completer != null) {
      _completerHandle = _imageStream!.completer!.keepAlive();
    }

    _imageStream!.removeListener(_getListener());
    _isListeningToStream = false;
  }

  @override
  Widget build(BuildContext context) {
    if (_lastException != null) {
      // display error and retry button on screen
      return SizedBox(
        height: widget.height == null ? 300 : null,
        width: widget.width == null ? 300 : null,
        child: Center(
          child: SizedBox(
            height: 300,
            child: Column(
              children: [
                Expanded(
                  child: Center(
                    child: Text(_lastException.toString().tl, maxLines: 3),
                  ),
                ),
                const SizedBox(height: 4),
                Listener(
                  onPointerDown: (_) {
                    GlobalState.find<_ReaderGestureDetectorState>()
                        .ignoreNextTap();
                  },
                  child: _readerProvider != null
                      ? _ReaderImageReprocessButton(provider: _readerProvider!)
                      : TextButton(
                          onPressed: () {
                            setState(() {
                              _loadingProgress = null;
                              _lastException = null;
                            });
                            _resolveImage();
                          },
                          child: Text('Retry'.tl),
                        ),
                ),
                const SizedBox(height: 16),
              ],
            ),
          ),
        ),
      );
    }

    return LayoutBuilder(
      builder: (context, constrains) {
        var width = widget.width;
        var height = widget.height;

        if (_imageInfo != null) {
          // Record the height and the width of the image
          _cache[widget.image.hashCode] = Size(
            _imageInfo!.image.width.toDouble(),
            _imageInfo!.image.height.toDouble(),
          );
        }

        Size? cacheSize = _cache[widget.image.hashCode];
        if (cacheSize != null) {
          if (width == double.infinity) {
            width = constrains.maxWidth;
            height = width * cacheSize.height / cacheSize.width;
          } else if (height == double.infinity) {
            height = constrains.maxHeight;
            width = height * cacheSize.width / cacheSize.height;
          }
        } else {
          if (width == double.infinity) {
            width = constrains.maxWidth;
            height = 300;
          } else if (height == double.infinity) {
            height = constrains.maxHeight;
            width = 300;
          }
        }

        if (_imageInfo != null) {
          // build image
          Widget result = RawImage(
            // Do not clone the image, because RawImage is a stateless wrapper.
            // The image will be disposed by this state object when it is not needed
            // anymore, such as when it is unmounted or when the image stream pushes
            // a new image.
            image: _imageInfo?.image,
            debugImageLabel: _imageInfo?.debugLabel,
            width: width,
            height: height,
            scale: _imageInfo?.scale ?? 1.0,
            color: widget.color,
            opacity: widget.opacity,
            colorBlendMode: widget.colorBlendMode,
            fit: widget.fit,
            alignment: widget.alignment,
            repeat: widget.repeat,
            centerSlice: widget.centerSlice,
            matchTextDirection: widget.matchTextDirection,
            invertColors: _invertColors,
            isAntiAlias: widget.isAntiAlias,
            filterQuality: widget.filterQuality,
          );

          if (!widget.excludeFromSemantics) {
            result = Semantics(
              container: widget.semanticLabel != null,
              image: true,
              label: widget.semanticLabel ?? '',
              child: result,
            );
          }
          result = SizedBox(
            width: width,
            height: height,
            child: Center(child: result),
          );
          final provider = _readerProvider;
          if (provider == null) return result;
          return AnimatedBuilder(
            animation: ReaderImageDetailsStore.instance,
            child: result,
            builder: (context, image) {
              final record = ReaderImageDetailsStore.instance.lookup(
                provider.imageKey,
                provider.sourceKey,
                provider.cid,
                provider.eid,
                provider.page,
              );
              if (record?.state != 'Failed' && record?.state != 'Cancelled') {
                return image!;
              }
              return Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  image!,
                  Text(record?.values['Error']?.tl ?? 'Failed'.tl, maxLines: 3),
                  _ReaderImageReprocessButton(provider: provider),
                ],
              );
            },
          );
        } else {
          // build progress
          return SizedBox(
            width: width,
            height: height,
            child: Center(
              child: AnimatedBuilder(
                animation: ReaderImageDetailsStore.instance,
                builder: (context, _) {
                  final provider = _readerProvider;
                  final blocked = provider == null
                      ? null
                      : ReaderPreloader.forPage(provider)?.blockedPage;
                  return Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      SizedBox(
                        width: 24,
                        height: 24,
                        child: CircularProgressIndicator(
                          strokeWidth: 3,
                          backgroundColor: context.colorScheme.surfaceContainer,
                          value: (_loadingProgress?.expectedTotalBytes ?? 0) > 0
                              ? _loadingProgress!.cumulativeBytesLoaded /
                                    _loadingProgress!.expectedTotalBytes!
                              : null,
                        ),
                      ),
                      if (blocked != null) ...[
                        Text(
                          'Waiting for page @page'.tlParams({
                            'page': '${blocked.page}',
                          }),
                        ),
                        _ReaderImageReprocessButton(provider: blocked),
                      ],
                    ],
                  );
                },
              ),
            ),
          );
        }
      },
    );
  }

  @override
  void debugFillProperties(DiagnosticPropertiesBuilder description) {
    super.debugFillProperties(description);
    description.add(DiagnosticsProperty<ImageStream>('stream', _imageStream));
    description.add(DiagnosticsProperty<ImageInfo>('pixels', _imageInfo));
    description.add(
      DiagnosticsProperty<ImageChunkEvent>('loadingProgress', _loadingProgress),
    );
    description.add(DiagnosticsProperty<int>('frameNumber', _frameNumber));
    description.add(
      DiagnosticsProperty<bool>(
        'wasSynchronouslyLoaded',
        _wasSynchronouslyLoaded,
      ),
    );
  }
}

class _ReaderImageReprocessButton extends StatefulWidget {
  const _ReaderImageReprocessButton({
    required this.provider,
    this.enabled = true,
  });

  final ReaderImageProvider provider;
  final bool enabled;

  @override
  State<_ReaderImageReprocessButton> createState() =>
      _ReaderImageReprocessButtonState();
}

class _ReaderImageReprocessButtonState
    extends State<_ReaderImageReprocessButton> {
  bool _processing = false;
  Object? _error;

  Future<void> _reprocess() async {
    if (_processing || !widget.enabled) return;
    setState(() {
      _processing = true;
      _error = null;
    });
    try {
      await _ComicImageState.reprocess(widget.provider);
    } catch (error) {
      if (mounted) {
        setState(() => _error = error);
      }
    } finally {
      if (mounted) {
        setState(() => _processing = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: ReaderImageDetailsStore.instance,
      builder: (context, _) {
        final provider = widget.provider;
        final state = ReaderImageDetailsStore.instance
            .lookup(
              provider.imageKey,
              provider.sourceKey,
              provider.cid,
              provider.eid,
              provider.page,
            )
            ?.state;
        final isQueuedOrProcessing = const {
          'Queued',
          'Waiting for previous page',
          'Retrying',
          'Processing',
          'Loading',
        }.contains(state);
        final busy = _processing || isQueuedOrProcessing;
        return Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextButton.icon(
              onPressed: widget.enabled && !busy ? _reprocess : null,
              icon: busy
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.refresh),
              label: Text(
                busy
                    ? (isQueuedOrProcessing ? state! : 'Queued').tl
                    : 'Reprocess page'.tl,
              ),
            ),
            if (_error != null)
              Semantics(
                liveRegion: true,
                child: Text(
                  '${"Reprocessing failed".tl}: ${_error.toString().tl}',
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ),
          ],
        );
      },
    );
  }
}

part of 'settings_page.dart';

/// Anime4K 设置页
///
/// 同时管理两个引擎版本：
///  - v1：纯 Dart CPU 算法（Gauss/Unblur/GradientRefine），缩放 1–4x，无模型文件；
///  - v4：ACNet / Real-ESRGAN ONNX 模型，Windows、Android、macOS 与 iOS 原生推理。
///    模型倍率、最终输出倍率、增强强度和输出对比度分别控制。
///
/// 两版本并存，由 `anime4KVersion` 设置选择；v4 选中时显示模型管理卡片，并隐藏 v1 专用滑块。
class Anime4KSettings extends StatefulWidget {
  const Anime4KSettings({super.key, this.modelsOnly = false});

  /// Render model management slivers inside the reader's settings viewport.
  final bool modelsOnly;

  @override
  State<Anime4KSettings> createState() => _Anime4KSettingsState();
}

class _Anime4KSettingsState extends State<Anime4KSettings> {
  bool _isModelDownloaded = false;
  bool get _isDownloading =>
      Anime4KV4ModelManager.downloadState.value?.isDownloading ?? false;
  String? _customModelName;
  List<String> _modelUrls = [];
  bool _usingCustom = false;
  static final ValueNotifier<bool> _modelManagementBusy = ValueNotifier(false);
  bool _loadingModelStatus = true;
  bool get _busy =>
      _isDownloading || _modelManagementBusy.value || _loadingModelStatus;

  Future<void> _manageModel(Future<void> Function() action) async {
    if (_busy) return;
    _modelManagementBusy.value = true;
    try {
      await action();
    } catch (e) {
      if (mounted) context.showMessage(message: e.toString());
    } finally {
      _modelManagementBusy.value = false;
    }
  }

  @override
  void initState() {
    super.initState();
    Anime4KV4ModelManager.downloadState.addListener(_downloadChanged);
    _modelManagementBusy.addListener(_managementChanged);
    _refreshModelStatus();
  }

  @override
  void dispose() {
    Anime4KV4ModelManager.downloadState.removeListener(_downloadChanged);
    _modelManagementBusy.removeListener(_managementChanged);
    super.dispose();
  }

  void _downloadChanged() {
    if (!_isDownloading) _refreshModelStatus();
    if (mounted) setState(() {});
  }

  void _managementChanged() {
    if (!_modelManagementBusy.value) _refreshModelStatus();
    if (mounted) setState(() {});
  }

  Future<void> _refreshModelStatus() async {
    final usingCustom = await Anime4KV4ModelManager.isCustomModelActive();
    final customName = await Anime4KV4ModelManager.getCustomModelName();
    final urls = await Anime4KV4ModelManager.getModelUrls();
    final downloaded = await Anime4KV4ModelManager.isModelDownloaded;
    if (mounted) {
      setState(() {
        _customModelName = customName;
        _modelUrls = urls;
        _isModelDownloaded = downloaded;
        _usingCustom = usingCustom;
        _loadingModelStatus = false;
      });
    }
  }

  String get _version => appdata.settings['anime4KVersion'] as String? ?? 'v1';

  void _setVersion(String v) {
    if (_version == v) return;
    appdata.settings['anime4KVersion'] = v;
    appdata.saveData();
    _refreshAiImages();
    setState(() {});
  }

  /// 切换 v4 超分模型（4x/2x）。不同倍数输出尺寸不同，清缓存避免串图。
  Future<void> _selectModel(String id) async {
    if (Anime4KV4ModelManager.selectedDef.id == id) return;
    await Anime4KV4Service.instance.setModel(id);
    _refreshAiImages();
    await _refreshModelStatus();
    if (mounted) setState(() {});
  }

  Future<void> _downloadModel() async {
    if (_isDownloading) return;
    // The manager owns transfer state; this future outlives the settings widget.

    try {
      await Anime4KV4ModelManager.downloadModel();
      if (mounted) {
        context.showMessage(message: "Model downloaded".tl);
      }
    } catch (e) {
      if (mounted) {
        context.showMessage(message: "Download failed: $e".tl);
      }
    } finally {
      // 模型文件已变更，失效原生会话缓存并刷新服务路径缓存
      await Anime4KV4Service.instance.resetNativeSession();
      await Anime4KV4Service.instance.checkModelAvailable();
      await _refreshModelStatus();
      _refreshAiImages();
    }
  }

  Future<void> _deleteModel() async {
    await Anime4KV4ModelManager.clearModel();
    await Anime4KV4Service.instance.clearCache();
    // 让服务感知模型已删除（重置 _modelPath，校验文件不存在）
    await Anime4KV4Service.instance.resetNativeSession();
    await Anime4KV4Service.instance.checkModelAvailable();
    await _refreshModelStatus();
    _refreshAiImages();
    if (mounted) {
      context.showMessage(message: "Model deleted".tl);
    }
  }

  /// 选择本地 .onnx 模型文件（优先级高于内置下载模型）
  Future<void> _pickLocalModel() async {
    try {
      final model = Anime4KV4ModelManager.selectedDef;
      final xFile = await selectFile(ext: ['onnx']);
      if (xFile == null) return;
      final dir = await getApplicationSupportDirectory();
      final targetPath = path.join(dir.path, model.fileName);
      await ImageAiService.instance.installModelFile(
        xFile.path,
        targetPath,
        'esrgan',
        preserveBackup: true,
      );

      // 记账为自选模型 + 失效原生会话缓存 + 让服务立即感知新路径
      await Anime4KV4ModelManager.markCustomModelActive(
        xFile.name,
        model: model,
      );
      await Anime4KV4Service.instance.resetNativeSession();
      await Anime4KV4Service.instance.checkModelAvailable();
      await _refreshModelStatus();
      _refreshAiImages();
      if (mounted) context.showMessage(message: "Custom model selected".tl);
    } catch (e) {
      if (mounted) context.showMessage(message: "Failed to pick file: $e".tl);
    }
  }

  /// 清除自选模型，回退到内置（下载）模型
  Future<void> _clearCustomModel() async {
    await Anime4KV4ModelManager.clearCustomModelSelection();
    await Anime4KV4Service.instance.resetNativeSession();
    await Anime4KV4Service.instance.checkModelAvailable();
    await _refreshModelStatus();
    _refreshAiImages();
    if (mounted) context.showMessage(message: "Reverted to built-in model".tl);
  }

  /// 添加一个自定义镜像 URL
  Future<void> _addMirrorUrl() async {
    await showInputDialog(
      context: context,
      title: "Add Mirror URL".tl,
      hintText: "https://.../${Anime4KV4ModelManager.modelFileName}",
      confirmText: "Add".tl,
      onConfirm: (url) async {
        await Anime4KV4ModelManager.addModelUrl(url);
        await _refreshModelStatus();
        return null as Object?;
      },
    );
  }

  /// 删除指定下标的镜像 URL
  Future<void> _removeMirrorUrl(int index) async {
    await Anime4KV4ModelManager.removeModelUrlAt(index);
    await _refreshModelStatus();
  }

  @override
  Widget build(BuildContext context) {
    final isV4 = _version == 'v4';
    final slivers = <Widget>[
      if (!widget.modelsOnly) ...[
        SliverAppbar(title: Text("Anime4K".tl)),
        _SwitchSetting(
          title: "Enable Anime4K Upscaling".tl,
          settingKey: "enableAnime4K",
          onChanged: _refreshAiImages,
          beforeChange: (newValue) async {
            // 关闭或 v1 直接放行
            if (!newValue) return true;
            if (_version != 'v4') return true;
            if (!await _allowImageAi(context)) return false;
            // v4 开启前必须确保模型已下载
            final downloaded = await Anime4KV4ModelManager.isModelDownloaded;
            if (downloaded) {
              return Anime4KV4Service.instance.checkModelAvailable();
            }
            if (!mounted) return false;
            final confirm = await showDialog<bool>(
              context: context,
              builder: (dialogContext) {
                return ContentDialog(
                  title: "Model Required".tl,
                  content: Text(
                    "Anime4K v4 model (${Anime4KV4ModelManager.selectedDef.displayName}) is not downloaded. Download (~${Anime4KV4ModelManager.selectedDef.sizeHintMB}MB) to enable?"
                        .tl,
                  ).paddingHorizontal(16).fixWidth(double.infinity),
                  actions: [
                    Button.filled(
                      onPressed: () => dialogContext.pop(true),
                      child: Text("Download".tl),
                    ),
                    Button.outlined(
                      onPressed: () => dialogContext.pop(false),
                      child: Text("Cancel".tl),
                    ),
                  ],
                );
              },
            );
            if (confirm == true) {
              await _manageModel(_downloadModel);
              if (mounted &&
                  await Anime4KV4Service.instance.checkModelAvailable()) {
                appdata.settings['enableAnime4K'] = true;
                appdata.saveData();
                PaintingBinding.instance.imageCache.clear();
                ComicImage.clear();
                setState(() {});
              }
            }
            // 由上面的手动置位控制开关，拦截这次手势
            return false;
          },
        ).toSliver(),
        // 引擎版本选择
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
            child: Text(
              "Engine Version".tl,
              style: TextStyle(
                color: context.colorScheme.primary,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
        ),
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: Wrap(
              spacing: 8,
              children: [
                ChoiceChip(
                  label: Text("v1 (CPU)".tl),
                  selected: !isV4,
                  onSelected: (_) => _setVersion('v1'),
                ),
                ChoiceChip(
                  label: Text("v4 (AI)".tl),
                  selected: isV4,
                  onSelected: (_) async {
                    if (await _allowImageAi(context) && mounted) {
                      _setVersion('v4');
                    }
                  },
                ),
              ],
            ),
          ),
        ),
      ],
      // v4 模型（倍数）选择：4x 动画 / 2x 通用
      if (isV4 || widget.modelsOnly)
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: Wrap(
              spacing: 8,
              children: Anime4KV4ModelManager.getModels().map((m) {
                final selected = Anime4KV4ModelManager.selectedDef.id == m.id;
                return ChoiceChip(
                  label: Text(m.displayName.tl),
                  selected: selected,
                  onSelected: _busy
                      ? null
                      : (_) => _manageModel(() => _selectModel(m.id)),
                );
              }).toList(),
            ),
          ),
        ),
      if (!widget.modelsOnly) ...[
        // v1 专用参数（Scale/Push/Grad）：仅 v1 显示
        SliverAnimatedVisibility(
          visible: !isV4,
          child: Column(
            children: [
              _SliderSetting(
                title: "Push Strength".tl,
                settingsIndex: "anime4KPushStrength",
                min: 0.0,
                max: 1.0,
                interval: 0.05,
                preciseInput: true,
                onChanged: _refreshAiImages,
              ),
              _SliderSetting(
                title: "Gradient Refine Strength".tl,
                settingsIndex: "anime4KPushGradStrength",
                min: 0.0,
                max: 1.0,
                interval: 0.05,
                preciseInput: true,
                onChanged: _refreshAiImages,
              ),
            ],
          ),
        ),
        _ImageAiControls(
          key: ValueKey(
            '${Anime4KV4ModelManager.selectedDef.id}@$_customModelName',
          ),
          superResolution: true,
        ).toSliver(),
        ListTile(
          title: Text("Clear Anime4K Cache".tl),
          trailing: const Icon(Icons.delete_sweep),
          onTap: () async {
            await Anime4KService.instance.clearCache();
            if (isV4) await Anime4KV4Service.instance.clearCache();
            _refreshAiImages();
            if (mounted) {
              context.showMessage(message: "Anime4K cache cleared".tl);
            }
          },
        ).toSliver(),
      ],
      // ---- v4 模型管理（仅 v4 显示） ----
      if (isV4 || widget.modelsOnly) ...[
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
            child: Text(
              "Model Management".tl,
              style: TextStyle(
                color: context.colorScheme.primary,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
        ),
        SliverToBoxAdapter(
          child: Card(
            margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    Anime4KV4ModelManager.selectedDef.displayName.tl,
                    style: const TextStyle(fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    _isModelDownloaded
                        ? "Model downloaded".tl
                        : "Model not downloaded (~${Anime4KV4ModelManager.selectedDef.sizeHintMB}MB)"
                              .tl,
                    style: TextStyle(
                      color: context.colorScheme.onSurfaceVariant,
                      fontSize: 12,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(Anime4KV4ModelManager.selectedDef.protocolNote.tl),
                  const SizedBox(height: 8),
                  Text(Anime4KV4ModelManager.selectedDef.licenseNote.tl),
                  const SizedBox(height: 8),
                  SelectableText(Anime4KV4ModelManager.selectedDef.sourceUrl),
                  if (Anime4KV4ModelManager.legacySelectionMigrated)
                    Text(
                      'The retired general_x2 selection was migrated to RealESRGAN-x2plus. Download the new weights; old files and custom import records were not reused.'
                          .tl,
                    ),
                  _ModelDownloadProgress(
                    state: Anime4KV4ModelManager.downloadState.value,
                  ),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      if (!_isModelDownloaded)
                        Expanded(
                          child: ElevatedButton.icon(
                            onPressed: _busy
                                ? null
                                : () => _manageModel(_downloadModel),
                            icon: _isDownloading
                                ? const SizedBox(
                                    width: 16,
                                    height: 16,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                    ),
                                  )
                                : const Icon(Icons.download),
                            label: Text(
                              _isDownloading
                                  ? "Downloading...".tl
                                  : "Download Model".tl,
                            ),
                          ),
                        ),
                      if (_isModelDownloaded) ...[
                        Expanded(
                          child: OutlinedButton.icon(
                            onPressed: _busy
                                ? null
                                : () => _manageModel(_deleteModel),
                            icon: const Icon(Icons.delete_outline),
                            label: Text("Delete Model".tl),
                          ),
                        ),
                      ],
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
        // 自选本地模型文件
        SliverToBoxAdapter(
          child: Card(
            margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    "Custom Model File".tl,
                    style: const TextStyle(fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    _usingCustom
                        ? "Using: ${_customModelName ?? 'custom model'}".tl
                        : "Select a local .onnx model to override the built-in one"
                              .tl,
                    style: TextStyle(
                      color: context.colorScheme.onSurfaceVariant,
                      fontSize: 12,
                    ),
                  ),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      Expanded(
                        child: ElevatedButton.icon(
                          onPressed: _busy
                              ? null
                              : () => _manageModel(_pickLocalModel),
                          icon: const Icon(Icons.folder_open),
                          label: Text("Select Model File".tl),
                        ),
                      ),
                      if (_customModelName != null) ...[
                        const SizedBox(width: 8),
                        Expanded(
                          child: OutlinedButton.icon(
                            onPressed: _busy
                                ? null
                                : () => _manageModel(_clearCustomModel),
                            icon: const Icon(Icons.restore),
                            label: Text("Use Built-in".tl),
                          ),
                        ),
                      ],
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
        // 镜像 URL 管理
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
            child: Text(
              "Download Mirrors".tl,
              style: TextStyle(
                color: context.colorScheme.primary,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
        ),
        ..._modelUrls.asMap().entries.map(
          (e) => _MirrorUrlTile(
            index: e.key,
            url: e.value,
            onDelete: _busy
                ? null
                : (index) => _manageModel(() => _removeMirrorUrl(index)),
          ),
        ),
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: _busy ? null : () => _manageModel(_addMirrorUrl),
                    icon: const Icon(Icons.add),
                    label: Text("Add Mirror URL".tl),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: _busy
                        ? null
                        : () => _manageModel(() async {
                            await Anime4KV4ModelManager.resetModelUrls();
                            await _refreshModelStatus();
                          }),
                    icon: const Icon(Icons.restart_alt),
                    label: Text("Reset".tl),
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    ];
    return widget.modelsOnly
        ? SliverMainAxisGroup(slivers: slivers)
        : SmoothCustomScrollView(slivers: slivers);
  }
}

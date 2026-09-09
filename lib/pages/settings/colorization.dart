part of 'settings_page.dart';

/// 图像上色设置页
///
/// 参考 Anime4K 设置页的模式。提供开关、强度调节和模型管理。
class ColorizationSettings extends StatefulWidget {
  const ColorizationSettings({super.key, this.modelsOnly = false});

  /// Render model management slivers inside the reader's settings viewport.
  final bool modelsOnly;

  @override
  State<ColorizationSettings> createState() => _ColorizationSettingsState();
}

class _ColorizationSettingsState extends State<ColorizationSettings> {
  bool _isModelDownloaded = false;
  bool get _isDownloading =>
      ColorizationModelManager.downloadState.value?.isDownloading ?? false;
  String? _customModelName;
  List<String> _modelUrls = [];
  bool _usingCustom = false;
  String _selectedVariant = 'deoldify';
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
    ColorizationModelManager.downloadState.addListener(_downloadChanged);
    _modelManagementBusy.addListener(_managementChanged);
    _refreshModelStatus();
  }

  @override
  void dispose() {
    ColorizationModelManager.downloadState.removeListener(_downloadChanged);
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
    final usingCustom = await ColorizationModelManager.isCustomModelActive();
    final customName = await ColorizationModelManager.getCustomModelName();
    final urls = await ColorizationModelManager.getModelUrls();
    final downloaded = await ColorizationModelManager.isModelDownloaded;
    final variant = await ColorizationModelManager.getSelectedVariant();
    if (mounted) {
      setState(() {
        _customModelName = customName;
        _modelUrls = urls;
        _isModelDownloaded = downloaded;
        _usingCustom = usingCustom;
        _selectedVariant = variant;
        _loadingModelStatus = false;
      });
    }
  }

  ColorizationModelVariant get _selectedDefinition =>
      ColorizationModelManager.modelVariants.firstWhere(
        (model) => model.id == _selectedVariant,
        orElse: () => ColorizationModelManager.modelVariants.first,
      );

  Future<void> _selectModel(String id) async {
    await ColorizationModelManager.setSelectedVariant(id);
    await ColorizationService.instance.resetNativeSession();
    await ColorizationService.instance.checkModelAvailable();
    await _refreshModelStatus();
    _refreshAiImages();
  }

  Future<void> _downloadModel() async {
    if (_isDownloading) return;
    final model = _selectedDefinition;
    if (!model.canDownload) return;
    if (model.requiresNonCommercialConsent) {
      final accepted = await showDialog<bool>(
        context: context,
        builder: (dialogContext) => ContentDialog(
          title: 'Non-commercial model license'.tl,
          content: Text(
            model.licenseNote.tl,
          ).paddingHorizontal(16).fixWidth(double.infinity),
          actions: [
            Button.filled(
              onPressed: () => dialogContext.pop(true),
              child: Text('Accept non-commercial use only'.tl),
            ),
            Button.outlined(
              onPressed: () => dialogContext.pop(false),
              child: Text('Cancel'.tl),
            ),
          ],
        ),
      );
      if (accepted != true || !mounted) return;
    }

    try {
      await ColorizationModelManager.downloadModel(
        variant: model.id,
        nonCommercialAccepted: model.requiresNonCommercialConsent,
      );
      if (mounted) {
        context.showMessage(message: "Model downloaded".tl);
      }
    } catch (e) {
      if (mounted) {
        context.showMessage(
          message: "Download failed: @e".tlParams({'e': e.toString()}),
        );
      }
    } finally {
      // 模型文件已变更，失效原生会话缓存并刷新服务路径缓存
      await ColorizationService.instance.resetNativeSession();
      await ColorizationService.instance.checkModelAvailable();
      await _refreshModelStatus();
      _refreshAiImages();
    }
  }

  Future<void> _deleteModel() async {
    await ColorizationModelManager.clearModel();
    await ColorizationService.instance.clearCache();
    // 让服务感知模型已删除（重置 _modelPath，校验文件不存在）
    await ColorizationService.instance.resetNativeSession();
    await ColorizationService.instance.checkModelAvailable();
    await _refreshModelStatus();
    _refreshAiImages();
    if (mounted) {
      context.showMessage(message: "Model deleted".tl);
    }
  }

  /// 选择本地 .onnx 模型文件（优先级高于内置下载模型）
  Future<void> _pickLocalModel() async {
    try {
      final model = await ColorizationModelManager.getSelectedDefinition();
      final xFile = await selectFile(ext: ['onnx']);
      if (xFile == null) return;
      final dir = await getApplicationSupportDirectory();
      final targetPath = path.join(dir.path, model.fileName);
      await ImageAiService.instance.installModelFile(
        xFile.path,
        targetPath,
        model.type,
        preserveBackup: true,
      );

      // 记账为自选模型 + 失效原生会话缓存 + 让服务立即感知新路径
      await ColorizationModelManager.markCustomModelActive(
        xFile.name,
        model: model,
      );
      await ColorizationService.instance.resetNativeSession();
      await ColorizationService.instance.checkModelAvailable();
      await _refreshModelStatus();
      _refreshAiImages();
      if (mounted) context.showMessage(message: "Custom model selected".tl);
    } catch (e) {
      if (mounted) {
        context.showMessage(
          message: "Failed to pick file: @e".tlParams({'e': e.toString()}),
        );
      }
    }
  }

  /// 清除自选模型，回退到内置（下载）模型
  Future<void> _clearCustomModel() async {
    await ColorizationModelManager.clearCustomModelSelection();
    await ColorizationService.instance.resetNativeSession();
    await ColorizationService.instance.checkModelAvailable();
    await _refreshModelStatus();
    _refreshAiImages();
    if (mounted) context.showMessage(message: "Reverted to built-in model".tl);
  }

  /// 添加一个自定义镜像 URL
  Future<void> _addMirrorUrl() async {
    await showInputDialog(
      context: context,
      title: "Add Mirror URL".tl,
      hintText: 'https://.../${_selectedDefinition.fileName}',
      confirmText: "Add".tl,
      onConfirm: (url) async {
        await ColorizationModelManager.addModelUrl(url);
        await _refreshModelStatus();
        return null as Object?;
      },
    );
  }

  /// 删除指定下标的镜像 URL
  Future<void> _removeMirrorUrl(int index) async {
    await ColorizationModelManager.removeModelUrlAt(index);
    await _refreshModelStatus();
  }

  @override
  Widget build(BuildContext context) {
    final slivers = <Widget>[
      if (!widget.modelsOnly) ...[
        SliverAppbar(title: Text("Colorization".tl)),
        _SwitchSetting(
          title: "Enable Image Colorization".tl,
          subtitle: _isModelDownloaded
              ? "Model file downloaded".tl
              : "Download model below to enable".tl,
          settingKey: "enableColorization",
          onChanged: _refreshAiImages,
          beforeChange: (enabled) async {
            if (!enabled) return true;
            if (!await _allowImageAi(context)) return false;
            final ready = await ColorizationService.instance
                .checkModelAvailable();
            if (!ready && mounted) {
              context.showMessage(
                message: ImageAiService.instance.status.value.message.tl,
              );
            }
            return ready;
          },
        ).toSliver(),
        _ImageAiControls(
          key: ValueKey('$_selectedVariant@$_customModelName'),
          superResolution: false,
        ).toSliver(),
      ],
      // 模型管理区域
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
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        _selectedDefinition.label.tl,
                        style: const TextStyle(fontWeight: FontWeight.bold),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                // Selection controls both the native pipeline and installation.
                Wrap(
                  spacing: 8,
                  children: ColorizationModelManager.modelVariants.map((v) {
                    final selected = _selectedVariant == v.id;
                    return ChoiceChip(
                      label: Text(v.label.tl),
                      selected: selected,
                      onSelected: _busy
                          ? null
                          : (_) => _manageModel(() => _selectModel(v.id)),
                    );
                  }).toList(),
                ),
                const SizedBox(height: 8),
                Text(
                  _isModelDownloaded
                      ? "Model downloaded".tl
                      : 'Model not downloaded'.tl,
                  style: TextStyle(
                    color: context.colorScheme.onSurfaceVariant,
                    fontSize: 12,
                  ),
                ),
                const SizedBox(height: 8),
                Text(_selectedDefinition.protocolNote.tl),
                const SizedBox(height: 8),
                Text(_selectedDefinition.licenseNote.tl),
                const SizedBox(height: 8),
                SelectableText(_selectedDefinition.sourceUrl),
                if (_selectedDefinition.sizeBytes != null)
                  Text('${_selectedDefinition.sizeBytes} bytes'),
                _ModelDownloadProgress(
                  state: ColorizationModelManager.downloadState.value,
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    if (!_isModelDownloaded && _selectedDefinition.canDownload)
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
                Row(
                  children: [
                    Text(
                      "Custom Model File".tl,
                      style: const TextStyle(fontWeight: FontWeight.bold),
                    ),
                    const SizedBox(width: 8),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 6,
                        vertical: 2,
                      ),
                      decoration: BoxDecoration(
                        color: Colors.orange.withValues(alpha: 0.15),
                        borderRadius: BorderRadius.circular(4),
                        border: Border.all(
                          color: Colors.orange.withValues(alpha: 0.4),
                        ),
                      ),
                      child: Text(
                        "实验性".tl,
                        style: TextStyle(
                          fontSize: 10,
                          color: Colors.orange.shade700,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                  ],
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
                          label: Text('Restore preset / remove import'.tl),
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
      if (_selectedDefinition.canDownload) ...[
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
                            await ColorizationModelManager.resetModelUrls();
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
      if (!widget.modelsOnly)
        ListTile(
          title: Text("Clear Colorization Cache".tl),
          trailing: const Icon(Icons.delete_sweep),
          onTap: () async {
            await ColorizationService.instance.clearCache();
            if (mounted) {
              context.showMessage(message: "Colorization cache cleared".tl);
            }
          },
        ).toSliver(),
    ];
    return widget.modelsOnly
        ? SliverMainAxisGroup(slivers: slivers)
        : SmoothCustomScrollView(slivers: slivers);
  }
}

/// 镜像 URL 列表项
class _MirrorUrlTile extends StatelessWidget {
  final int index;
  final String url;
  final void Function(int)? onDelete;

  const _MirrorUrlTile({
    required this.index,
    required this.url,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    return SliverToBoxAdapter(
      child: ListTile(
        dense: true,
        leading: Text('${index + 1}'),
        title: Text(
          url,
          style: const TextStyle(fontSize: 12),
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
        ),
        trailing: IconButton(
          icon: const Icon(Icons.delete_outline, size: 20),
          onPressed: onDelete == null ? null : () => onDelete!(index),
        ),
      ),
    );
  }
}

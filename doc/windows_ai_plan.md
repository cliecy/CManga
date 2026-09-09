# Windows / Android AI 图像处理：实现与验收记录

## 范围与当前状态

Windows 已接入本地 ACNet / Real-ESRGAN 超分和多种上色管线，Android 复用同一 Dart 服务与模型契约。两项独立强度、模型管理、阅读器处理结果保存/导出和逐页诊断已接入；本文区分实现契约、已测范围与尚未完成的环境验收，不把代码存在或构建成功当成全平台运行证明。

- AI 平台范围为 Windows、Android；不宣称 iOS、macOS、Linux 已支持原生 AI。
- 保留原有 DeOldify 及实验性 int8 兼容管线；新增 `anime_deoldify`、`ddcolor`、`manga_light`、`manga_v2`。
- 超分保留内置 2× ACNet、轻量动画 4× Real-ESRGAN，新增可独立下载/导入的 `realesrgan_x2plus`、`realesrgan_x4plus`。v1 仍是用户主动选择的传统算法，不是 AI 失败的静默回退。
- 不扩展为手动涂色、提示词配色、跨页人物颜色一致性或模型训练。Pix2Pix 缺少已核实的官方训练权重，未实现为可用选项。

## 实现位置与契约

| 位置 | 当前职责 |
| --- | --- |
| `lib/utils/image_ai_service.dart` | 能力检测、模型验证/安装、原生通道、实际后端及错误状态 |
| `lib/utils/anime4k/anime4k_v4_model_manager.dart` | 独立超分模型目录、来源/许可、下载与本地导入 |
| `lib/utils/colorization/colorization_processor.dart` | 六种上色选择及明确管线、来源/许可、独立安装与模型管理 |
| `lib/utils/colorization/colorization_service.dart` | 按当前模型类型加载/执行；文件存在不等于原生验证就绪 |
| `windows/runner/image_ai/`、`android/.../colorize/` | ONNX Runtime / OpenCV 的模型预处理、推理、后处理与缓存 |
| `lib/foundation/image_provider/reader_image.dart` | 全局/漫画专属参数、处理顺序、逐页记录、成功阶段落盘及严格导出 |
| `lib/utils/processed_image_store.dart` | 内容寻址的分类 PNG 保存，不覆盖源页和先前结果 |
| `lib/foundation/image_provider/reader_image_details.dart`、`lib/pages/reader/image_details.dart` | 逐页实际状态与尺寸、旧设置失效标记、当前页高亮和跳转 |
| `lib/utils/local_comic_export.dart`、`cbz.dart`、`epub.dart`、`pdf.dart` | 主 isolate 完成当前设置下的页面处理，再生成显式整书导出 |
| `lib/foundation/image_provider/reader_preloader.dart` | 有界预加载窗口、后台完整处理、切页/切参取消及阶段缓存预热 |
| `lib/utils/model_download.dart`、模型管理器、阅读设置侧栏 | 独立于页面生命周期的共享下载任务、字节进度及校验/安装/失败状态 |

### 原生与后端

Windows 使用 C++ + ONNX Runtime + OpenCV，经现有 `com.github.kiastr.venera_ssr/colorize` MethodChannel 接入，不引入 Python 子进程，也不要求用户配置 CUDA。通道的 `getCapabilities`、`getModelInfo`、`colorize`、`resetSession` 分别负责平台能力、模型检查、图像处理及会话释放。

- Windows **Auto** 尝试 DirectML；设备/模型加载或执行不兼容时重试同一模型 CPU，并传递回退原因。用户也可固定 CPU。
- Android 上色使用 CPU 策略，不据此承诺 NNAPI/GPU 上色可用。
- DirectML 同会话串行、关闭 memory pattern；解码、推理和编码在后台执行。会话及基础推理结果有界复用，不无界常驻所有大模型。
- 结果区分实际后端、缓存命中、回退与失败。后端可用不等于整个图所有算子均由 GPU 执行；缓存命中也不冒称本次执行了 GPU 推理。
- 模型按选中的明确契约验证张量类型、布局和尺寸，不靠文件名/大小判兼容。Windows 使用文件复制，Android 保留平台文件访问能力；先验证临时文件再替换，失败不破坏原有可用模型。

### 模型、来源与限制

各选项的模型文件、自选记录、备份和镜像配置独立。用户应先选正确模型，再导入匹配的 ONNX；更名无法把一个模型变成另一个。带固定摘要的下载还检查 SHA-256。完整用户说明见 [README 模型列表](../README.md#上色模型与来源)。

| 模型 | 约定 / 体积 | 来源与限制 |
| --- | --- | --- |
| `deoldify` / `deoldify-int8` | 保留现有 float32 NCHW RGB 0–255 → RGB 包装及亮度处理；标准约 243 MiB，int8 为实验性轻量变体 | [instant-high ONNX](https://github.com/instant-high/deoldify-onnx)、[Kiastr int8](https://github.com/Kiastr/AiColorize/releases/tag/models)；再分发前核对发布者和上游许可。int8 指内部量化，不是任意 int8 输入契约。 |
| `anime_deoldify` | 约 423 MB；固定 256² float32 RGB 0–255，原始归一化在图内 | 从 [Dakini AnimeColorDeOldify](https://github.com/Dakini/AnimeColorDeOldify) 的 Grayscale2Color 权重转换，[模型与转换来源发布](https://github.com/cliecy/Venera-SSR/releases/tag/image-ai-models-20260909)。Dakini 声明其训练权重为 MIT。应用保留原图 Lab L、透明度和尺寸，不逐像素复刻上游 YUV 滤镜。 |
| `ddcolor` | 约 980 MB；256² 中性 Lab 派生 RGB 0–1 → 两通道 Lab ab，保留原 L、透明度和尺寸 | [FaceFusion Artistic ONNX](https://huggingface.co/facefusion/models-3.0.0)，[piddnad/DDColor](https://github.com/piddnad/DDColor) 上游 Apache-2.0；FaceFusion 聚合仓库未为该导出单独声明许可。支持该模型协议，不承诺任意 DDColor 导出兼容。 |
| `manga_light`（Manga Light Colorizer V6） | 约 191 MB；512² 灰度 [-1,1] → RGB [-1,1]，保留原 L、透明度和尺寸 | [sharky172 固定版本](https://huggingface.co/sharky172/manga-light-colorizer/tree/2fb022c4ce55632b7671a1df306f63984928e36a) 的 `v6_generator.onnx`，SHA-256 `48284fcf0b7a606270702630f559af88eecf95bc6cdec1ff8bce8663d12b4bb6`。原选项已使用此 V6 权重，仅明确版本名，不增加重复模型。CC BY-NC-SA 4.0，须确认非商业限制并遵守署名、同许可要求。**仅生成器**：`sam_level0 [1,256,32,32]`、`sam_level1 [1,256,16,16]`、`wd14_embedding [1,1024]` 全部置零，不运行 SAM/WD14，不提供其语义引导，不等同完整上游管线。 |
| `manga_v2` | 约 61 MB；float32 `[1,5,H,W]`，第一通道为 RGB 的首通道 0–1，其余提示/掩码置零；长边适配 512，补齐至 32 的倍数；输出 RGB 0–1 后保留原 L、透明度和尺寸 | **仅本地导入**。[Faridzar 导出](https://huggingface.co/Faridzar/manga-colorization-v2-onnx) 标 MIT，但 [qweasdd 上游](https://github.com/qweasdd/manga-colorization-v2) 权重许可未核实，商业使用与再分发未澄清；不提供默认下载或自定义镜像绕过。 |

超分来源为 [Anime4KCPP / ACNet](https://github.com/TianZerL/Anime4KCPP)、[Real-ESRGAN](https://github.com/xinntao/Real-ESRGAN) 及 [SceneWorks 固定版本 ONNX](https://huggingface.co/SceneWorks/real-esrgan-onnx/tree/09f741bac80a246b407da3ee902bf5f3291b602f)。x2plus/x4plus 各约 67 MB，RGB 0–1 的 23-block RRDB 通用模型；遵守 BSD-3-Clause 的版权、许可和免责声明要求。它们比 ACNet 慢且更占内存，并非漫画专用，GAN 可能重绘细节；x4plus 不是 x4plus-anime-6B。旧的无可用发布 `general_x2` 选择迁移为 x2plus，但不会把旧文件冒认为新的权重。

文件大小不等于峰值 RAM/显存：还需模型会话、激活、图像和后处理缓冲。DDColor 是尤其重的选择。4× 原生输出为 16 倍像素，减小最终输出倍率不等于按同比例减少模型推理内存。Windows 单阶段输入及模型原生输出上限为 24×1024×1024 像素，另有工作内存限制；Android 也按处理阶段限制内存/像素。超限报告错误，不暗降倍率或伪装成功。

### 倍率、强度与缓存

- v4 最终倍率默认跟随模型，亦可在 1× 至原生倍率之间设置；滑块步进 0.05×，数字输入精度 0.01×。目标尺寸相对进入超分阶段的图片按 `round(width × scale)` / `round(height × scale)` 计算；v1 保留 1–4× 范围。
- 超分强度 0–100%、步进 1%，是同尺寸基础缩放与 AI 结果的线性 RGB 残差混合，不改变倍率；0% 仅基础缩放，100% 完整增强。高级“输出对比度”只作用于增强分支，不能影响强度 0% 的基础结果。
- 颜色浓度 0–120%、步进 1%；0% 中性色度、100% 模型预测色度、120% 额外增艳，不改变图像尺寸或给模型指定配色。0% 不保证逐字节还原原图，关闭功能才完全跳过该阶段。
- 纯倍率/强度/对比度修改复用仍在缓存的基础推理；强度为零且无基础缓存时跳过无贡献的推理。超分改变下游像素时，上色必须重新推理，不能复用错误输入的结果。
- 开关、模型和参数变化沿现有图片缓存刷新路径失效；逐页元数据也标为旧设置，旧异步结果不覆盖新页记录。

### 完整预加载与阅读侧栏模型管理

- 画廊/连续阅读都使用当前漫画的预加载数量；窗口替换而非不断累积队列，单个后台任务完成源图加载及所有启用阶段。预热编码阶段缓存，不把整个窗口的解码位图常驻内存；原生推理仍受已有串行队列和内存限制。
- 翻页复用已完成的阶段结果；模型、参数或窗口变化使旧工作在阶段边界停止。正在执行的原生算子不强行中断。图片消费者离开时取消等待，正常解码仍交付、晚到的解码资源释放、真实加载失败仍传给有效消费者，不把正常取消当成图片错误。
- 修复整数设置被通用滑块写成 double 的根因，并规范化旧 JSON 中的全局及漫画专属整数值；AI 倍率/强度等小数设置不被截断。
- 阅读侧栏直接复用原有模型管理组件；选择是全局的，参数仍遵循漫画覆盖优先级。安装完成后即使发起页面已销毁，也刷新模型服务、当前图片和预加载窗口。
- 每类模型管理器共享一个在途下载 Future，重开页面或重复点击不启动第二次传输。实际字节、未知总量、SHA 校验、原生安装、完成和失败分别可观察；100% 字节不等于已经安装完成。状态独立于设置页面，但不保证跨进程继续传输。

## 阅读、保存与显式导出

1. 阅读与导出共享“自定义图像处理（若启用）→ 超分 → 上色”顺序，采用现有全局/漫画专属设置优先级。阅读遇到 AI 失败可保留原图或前一成功阶段供阅读，同时标明未完成和原因。
2. 阅读器保存、分享、复制默认调用严格的当前处理结果导出，不直接取原图缓存。任一启用 AI 阶段失败则报错，不把可阅读的部分结果冒充完整处理结果。图片收藏中的保存也使用该处理路径。
3. 本地/已下载的 `file://` 源页在成功阶段自动保存 PNG 至源文件同级的 `.venera-processed/<分类>/<源文件名>/<输出内容 SHA-256>.png`。分类为 `super_resolution`、`colorization`、`super_resolution_colorization`；两阶段均成功时保存超分中间图与组合图，只有上色成功时保存到上色分类。
4. 同内容复用，不同内容并存；原图与旧结果不被覆盖。写入失败记录 `Local save error` 并报告，仍保留可阅读结果，不声称写入成功。在线页不自动写入漫画目录，普通漫画下载仍保存源页，不预处理整本书。
5. 处理目录从源页/章节扫描、导入中排除，并拒绝以处理目录文件再次作为处理源，避免历史派生图片混入漫画。
6. 显式 **CBZ / EPUB / PDF** 整书导出先在主 isolate 按当前设置处理封面及已下载章节，写入临时目录后打包；未翻阅页面也会处理，不依赖已有隐藏输出，不打包其历史版本。失败/取消清理临时输出；任一已启用 AI 阶段失败终止导出，不静默混入原图。源漫画保持不变。

## 逐页实际信息

阅读器“图像信息”按当前章节逐页列出，展开/高亮当前可见页并支持跳转。元数据不保留整页像素，记录：

- 原始图片实际解码尺寸及编码字节数；超分前后实际尺寸；最终实际尺寸及编码大小。
- 请求引擎、倍率、后端、超分强度、输出对比度和颜色浓度，与实际执行信息分开。
- 每阶段的等待/处理中/成功/失败、实际后端、缓存/执行说明、耗时、错误及成功保存路径。
- 未加载页不编造尺寸；处理中的页面、已取消、失败/不完整、旧设置待刷新有独立状态。不是用请求倍率推算成功尺寸，也不是把全局最近一次 AI 操作套给所有页。

## 验证记录与未完成的环境验收

本次已取得的模型级运行证据：

| 范围 | 已测结果与边界 |
| --- | --- |
| Windows 新增四条上色管线 | `anime_deoldify`、`ddcolor`、`manga_light`、`manga_v2` 的样图输出与独立 Python 参考最大像素差不超过 1/255；这是应用契约的数值对比，不是完整上游应用画风/滤镜复刻证明。 |
| Android 六个新增模型 | 四个上色模型与 x2plus/x4plus 两个超分模型的 CPU 强度 0 / 1 / 0.35 及缓存路径通过；不据此宣称 GPU 上色或所有设备内存均可用。 |
| 图片信息面板状态恢复 | 修复展开状态与可选文本滚动状态的存储键冲突；真实 Windows 窗口验证第二页首次展开、反复折叠/展开、滚动与跳页后重新打开，不再出现 bool 转 double 的异常。 |
| Windows 正式服务/导出链路 | 六个新增模型逐一经安装校验、目录选择和 ReaderImageProvider 导出成功；上色保留 127×129，两个超分模型最终 1.30× 输出 165×168。自定义脚本去除原始字节头后可正常解码，源尺寸显示未知而最终尺寸实测正确。 |
| 完整预加载与侧栏模型管理 | Windows 合成 127×129 页面，停在第一页时前五页已完成 ACNet → V6；1.30× 输出 165×168。侧栏切换并下载动画 Real-ESRGAN 后，发起页面已关闭仍刷新预加载。第五页两阶段命中结果缓存；1.75× 改为 222×226，超分复用基础推理、上色按新输入重算。画廊及连续模式快速切参、滚动后无框架异常。 |
| 模型下载生命周期 | 本机 HTTP 实际传输 Real-ESRGAN 和 191,335,312 字节 V6 权重；每类重复调用返回同一 Future、只产生一次请求。实际窗口验证退出/重开侧栏进度持续，未知总量不伪造百分比。V6 SHA 校验及原生安装期间保持 active；HTTP 503、不兼容 ONNX 和 SHA 不匹配保留失败状态与原有有效模型摘要。 |
| 现有回归与静态检查 | 整数设置、预加载窗口/失效、图片取消/正常解码/真实错误、Anime4K 与通道共 21 项回归通过。 |

以下保留为验收要求，而非全部已通过的清单：

- 新增超分真实图片 CPU 输出、原生/最终倍率和 1.30×、1.75× 尺寸；奇数边界、小图、长页、透明度、分块与内存限制。
- 实际硬件上的 DirectML 参与执行与 CPU 数值/视觉对比；不支持模型/设备的同模型 CPU 回退及原因，不以托管 CI 编译替代 GPU 实测。
- 两项强度端点/中间值、缓存复用与上游变化失效；切模型、同路径替换、删除和失败导入不残留旧结果。
- 本地原图不变、各处理分类、在线/离线页保存分享复制、CBZ/EPUB/PDF 的真实当前输出、失败不导出部分结果，以及逐页状态/尺寸与文件一致。
- Android 平台文件访问、内存受限设备、快速翻页/切模型/关闭窗口；Windows 中文和空格路径、离线加载。

**尚不能宣称完成**：未安装开发依赖的干净 Windows 虚拟机上 ZIP/安装版启动与推理、Windows ARM64 实机运行、未支持平台运行验证。也没有“所有模型/所有显卡全 GPU”保证。模型级 smoke、参考对比或已有开发机运行不能替代这些环境证明。

发布继续要求 CMake/打包规则携带 ONNX Runtime、DirectML、OpenCV 及实际依赖，不依赖开发机 PATH；架构和产物路径必须对应，不能把 x64 产物标为 ARM64。文档更新本身不新增构建、测试或发布证明。

## 参考

- [ONNX Runtime DirectML 官方文档](https://onnxruntime.ai/docs/execution-providers/DirectML-ExecutionProvider.html)：设备要求、同会话串行、memory pattern 限制及维护状态。
- 模型权重/导出来源与许可链接见上方模型表；模型目录代码是当前下载地址、固定版本和摘要的依据。

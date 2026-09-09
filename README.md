# Venera-SSR

A revision comic reader
support different resource source  
use anime4k to SR.
Black and white cartoon 
via ocr Translate Picture Embedded Text（MML Local inference high quality translation）
All running locally

一个支持不同漫画源，anime4k超分辨率，本地黑白漫画上色，本地ocr翻译的改版漫画阅读器

## Features

**黑白漫画上色**
**Black and white cartoon coloring**
（Windows / Android / macOS / iOS 共用升级版模型管理、阅读处理与导出功能；Linux 不接入原生 AI）

**支持webdav同步**

**漫画内嵌文字替换并翻译功能
Cartoon embedded text translation function**

- Read local comics
- Use javascript to create comic sources
- Read comics from network sources
- Manage favorite comics
- Download comics
- View comments, tags, and other information of comics if the source supports
- Login to comment, rate, and other operations if the source supports

### Windows / Android / macOS / iOS 本地 AI 图像处理

- 在“设置 → Anime4K”选择 **v4 (AI)**。内置 ACNet 为 2× 亮度超分；可选轻量动画 Real-ESRGAN 4×，以及通用 **RealESRGAN-x2plus / x4plus**（各约 67 MB，SceneWorks ONNX 导出）。后两者是较慢、内存占用更高的 23-block RRDB 模型，并非漫画专用，GAN 可能重绘细节；x4plus 不是 x4plus-anime-6B。v1 是独立的传统算法，不作为 AI 失败时的静默回退。
- **最终输出倍率**默认跟随模型，也可在 1× 至模型原生倍率之间设置：滑块步进 0.05×，数字输入精度 0.01×，例如 1.30×、1.75×。结果尺寸按进入超分阶段的原图尺寸四舍五入。
- **超分强度**为 0–100%，步进 1%。0% 仅做基础缩放，100% 使用完整增强结果；它不改变倍率，也不是高级设置中的“输出对比度”。v1 同样支持独立强度。
- 在“设置 → 上色”先选择模型，再下载或导入该模型契约兼容的 ONNX；各模型独立安装、替换、恢复和删除，不是任意 ONNX 自动识别器。**颜色浓度**独立控制 0–120%，步进 1%；100% 为模型预测色度，120% 额外增艳。0% 生成中性色度，不保证逐字节还原原图；关闭功能才完全跳过上色。
- Windows 的 **Auto** 优先尝试 DirectML，模型或设备不兼容时明确报告同一模型的 CPU 回退；也可指定 CPU。Android 超分 Auto 尝试 NNAPI 后回退 CPU，上色使用 CPU。macOS / iOS 的 Auto 和 CPU 均使用真实 ONNX Runtime CPU 推理，不宣称 CoreML、Metal 或 GPU 加速。后端可用不等于每个模型、每个算子均在 GPU 运行。
- 两项功能同时开启时顺序为“超分 → 上色”。全局和漫画专属设置遵循现有优先级；调参后刷新当前图片。基础推理结果有界缓存，缓存仍在时，纯倍率/强度/对比度调整不重复执行对应模型；上游像素变化会正确重算下游上色。
- **完整 AI 预加载**按当前阅读模式和预加载数量维护滚动窗口：后台页也会走完“超分 → 上色”，不再只下载原图。单个后台任务逐页处理，翻页复用已完成的阶段缓存；换模型或参数后重新处理受影响页面。缓存有容量限制，尚未完成或已被淘汰的页面仍需等待，不承诺所有页面即时显示或多模型同时占满 GPU。
- 阅读侧栏可直接展开**超分模型（AI v4）/ 上色模型**，选择、下载或导入模型，无需离开漫画。模型选择为全局设置，即使启用了漫画独立参数也对所有漫画生效；选择超分模型不会自动打开超分或把 v1 改成 v4。
- **模型下载进度跨页面持续显示**：关闭设置后阅读器仍显示模型、实际字节数和百分比，重新打开设置继续观察同一任务；总大小未知时显示不定进度。下载、SHA 校验和原生安装分别报告，失败保留原因且不破坏原有可用模型。此保证针对应用运行期间切换页面，不代表退出程序后继续下载或自动断点恢复。
- 四端提供同一模型集合、独立超分强度/颜色浓度、倍率控制、预加载、下载进度和逐页诊断；Linux 保持原生 AI 不支持。失败时保留可阅读图片并提示原因，不显示虚假的 AI 成功。Windows / macOS 单阶段输入及模型原生输出上限为 24×1024×1024 像素；iOS 为 4×1024×1024 像素，另有更小的队列、缓存和模型内存检查，超限明确报错而非擅自降低倍率。iOS 进入后台或收到内存警告时取消待处理任务并释放会话，回到前台后按需重建。
- Windows 发布包携带 AI 运行库；Android 使用随包原生依赖；Apple 通过 CocoaPods 链接固定 ONNX Runtime 1.22.0 与校验 SHA-256 的 OpenCV 4.11.0 XCFramework，复用 `native/image_ai/` 中的 Windows 推理核心。不需要 Python、CUDA 或用户手工安装推理库。上色模型不随包分发，首次下载/导入后可离线使用。
- **Apple 最低版本调整为 macOS 13.3 / iOS 15.1**，与官方 ONNX Runtime Apple 包要求一致。iOS 导入使用系统文件选择器的沙盒副本，再校验并安装 ONNX；iPad 分享提供弹出位置，避免处理图片分享时报错。

#### 上色模型与来源

| 选择 | 文件体积 / 输入输出约定 | 来源与限制 |
| --- | --- | --- |
| DeOldify Artistic / int8 | 标准版约 243 MiB；int8 为实验性轻量变体，仍需兼容 RGB 包装 | 保留现有 DeOldify 管线；[标准 ONNX](https://github.com/instant-high/deoldify-onnx)、[int8 发布](https://github.com/Kiastr/AiColorize/releases/tag/models)。再分发前核对发布者及上游许可。 |
| AnimeColorDeOldify (`anime_deoldify`) | 约 423 MB；固定 256×256、float32 RGB 0–255 | 来自 [Dakini Grayscale2Color](https://github.com/Dakini/AnimeColorDeOldify) 的原始权重转换，[项目 ONNX 发布及转换来源说明](https://github.com/cliecy/Venera-SSR/releases/tag/image-ai-models-20260909)。Dakini 声明其训练权重为 MIT；应用保留原图 Lab 亮度、透明度与尺寸，不是上游 YUV 滤镜的逐像素复刻。 |
| DDColor Artistic (`ddcolor`) | 约 980 MB；256×256 中性 Lab 转 RGB 输入，输出两通道 Lab ab | [FaceFusion ONNX](https://huggingface.co/facefusion/models-3.0.0)；[DDColor 上游](https://github.com/piddnad/DDColor) 为 Apache-2.0，FaceFusion 聚合仓库未单独声明该导出许可。支持这一明确契约，不代表任意 DDColor 导出均兼容。 |
| Manga Light Colorizer V6 (`manga_light`) | 约 191 MB；512×512 灰度，`v6_generator.onnx`，generator-only | [sharky172 固定版本](https://huggingface.co/sharky172/manga-light-colorizer/tree/2fb022c4ce55632b7671a1df306f63984928e36a)，CC BY-NC-SA 4.0：署名、仅非商业、衍生作品同许可；下载前须确认，导入也须遵守许可。原有 Manga Light 选项已经使用此 V6 权重，本次明确版本名称，不重复下载同一模型。SAM 特征和 WD14 嵌入填零，**不运行分割或标签语义引导**，不等同完整上游管线。 |
| Manga Colorization v2 (`manga_v2`) | 约 61 MB；五通道输入，提示/掩码置零，长边适配 512 并补齐至 32 的倍数 | **仅本地导入，无内置下载**。[Faridzar ONNX](https://huggingface.co/Faridzar/manga-colorization-v2-onnx) 标注 MIT，但 [qweasdd 上游权重](https://github.com/qweasdd/manga-colorization-v2) 许可未核实，商业使用及再分发未获澄清。 |

文件体积不是运行内存需求：模型会话、激活、原生倍率输出和图像缓存还会占用 RAM/显存，DDColor 尤其重；4× 超分原生输出有 16 倍像素，即使最终选较小倍率，也不能据此假定推理内存同步降低。超限会明确失败，建议低内存设备先用 ACNet 或较轻模型。Pix2Pix 缺少已核实的官方训练权重，未实现为可用模型选项。

超分来源：[Anime4KCPP / ACNet](https://github.com/TianZerL/Anime4KCPP)、[Real-ESRGAN](https://github.com/xinntao/Real-ESRGAN)、[SceneWorks 固定版本 ONNX](https://huggingface.co/SceneWorks/real-esrgan-onnx/tree/09f741bac80a246b407da3ee902bf5f3291b602f)。Real-ESRGAN 为 BSD-3-Clause，分发时保留版权、许可与免责声明。设置页展示各模型的来源、许可及输入输出要求；改文件名不能转换模型协议。

#### 保存、导出与逐页信息

- 阅读器的**保存、分享、复制图片默认使用当前有效设置下的处理结果**，不是下载缓存中的原图；按“自定义处理（若开启）→ 超分 → 上色”执行。任何已启用 AI 阶段失败时，阅读可保留可用图片，但显式导出会报错，不把原图或部分结果冒充完整处理结果。
- 对本地/已下载的 `file://` 源页，成功的处理阶段自动在源页同级的隐藏分类目录 `.venera-processed/` 中保存 PNG：`super_resolution`（超分）、`colorization`（仅成功上色）、`super_resolution_colorization`（超分后上色）。下层按原文件名和结果内容哈希组织，同一结果复用、不同结果并存；**不覆盖原图或旧结果**。两阶段均成功时保留超分中间图与最终组合图。写入失败在逐页信息中记录，不妨碍阅读，也不声称保存成功；在线页不会自动写到漫画目录。
- 隐藏处理目录不会作为源页/章节重新扫描，避免重复处理或污染导入。普通漫画下载仍保留原始页面，不会自动把整本书替换为 AI 结果。
- 用户明确选择 **CBZ / EPUB / PDF 整书导出**时，按当前全局/漫画专属设置处理已下载章节及封面，再从临时输出生成文件；不要求先逐页翻阅，不打包 `.venera-processed` 的历史版本。任一启用阶段失败则终止导出，不静默混入原图。
- 阅读器“图像信息”列出当前章节每页并支持跳转，突出当前可见页。记录实际解码的原始尺寸、超分前后尺寸、最终尺寸/编码大小，以及每阶段状态、实际后端、缓存/执行信息、耗时、错误和本地结果路径。尚未加载、处理中、失败/不完整、取消及旧设置待刷新会分别标示；不会把请求倍率推算值或别页的最近操作当成本页实测结果。

验证边界：共享 Dart 回归测试 21 项通过。macOS ARM64 使用与应用相同的 ONNX Runtime 1.22.0 / OpenCV 4.11.0 Apple 框架，对全部 10 个模型选项完成真实 CPU 推理、参数重渲染及缓存检查；透明度、强度端点和线性光混合也有独立检查。

完整应用已在 macOS 本机、Android 35 ARM64 平板模拟器和 iOS 27 iPhone 17 Pro 模拟器通过 CPU 路径验收：真实 V6 下载与 SHA-256 校验、离开设置页后继续下载、有效模型导入及无效替换保护、五页完整 AI 预加载、倍率/强度重渲染、逐页信息界面、CBZ / EPUB / PDF 严格导出、原图保护和缺模型时拒绝导出。验收图像由 127×129 按 1.30× 输出为 165×168，1.75× 输出为 222×226。

三端原生文件交互也已验收：保存面板产物与处理后的 PNG 逐字节一致；系统分享面板可正常显示并取消（未向外发送）；文件选择器可导入大写 `.ONNX` 扩展名的模型，并通过原生模型验证及 SHA-256 检查。iOS 另验证了目录选择与安全作用域释放，以及关闭选择器后的再次导入。

这些检查不是画质评测、性能承诺或所有图片/设备的保证；Android / iOS 真机、旧系统版本、Android NNAPI 和 Windows DirectML 没有据此获得运行验证。Windows 目标机测试按本次验收范围跳过，Linux 不在此次功能升级范围。CI 包含 iOS 模拟器和无签名设备构建、macOS 构建及原生 smoke。

## 界面展示 (Screenshots)

### 漫画文字翻译 (Comic Text Translation)

| 翻译前 (Before) | 翻译后 (After) |
|:---:|:---:|
| ![Translation Before](screenshots/translation_before.jpg) | ![Translation After](screenshots/translation_after.jpg) |

### 黑白漫画 AI 上色 (Black & White Cartoon Coloring)

> 使用 int8 轻量模型，阅读时实时本地上色
> Uses int8 lightweight model, Live local coloring while reading

| 上色前 (Before) | 上色后 (After) |
|:---:|:---:|
| ![Colorization Before](screenshots/colorization_before.jpg) | ![Colorization After](screenshots/colorization_after.jpg) |

### 其他界面 (Other Screenshots)

| 漫画源 (Comic Source) | 设置菜单 (Settings) |
|:---:|:---:|
| ![Comic Source](screenshots/comic_source.jpg) | ![Settings](screenshots/settings.jpg) |
| **Anime4K 设置** | **阅读界面 (Reader)** |
| ![Anime4K Settings](screenshots/anime4k_settings.jpg) | ![Reader View](screenshots/reader_view.jpg) |

## Build from source
1. Clone the repository
2. Install flutter, see [flutter.dev](https://flutter.dev/docs/get-started/install)
3. Install rust, see [rustup.rs](https://rustup.rs/)
4. Build for your platform: e.g. `flutter build apk`

Windows 构建还需要 Visual Studio 2022 的 C++ 桌面开发工作负载、Windows SDK 和 PATH 中的 NuGet。Flutter 3.41 按宿主架构构建：ARM64 完整应用需要 ARM64 Windows、原生 ARM64 Flutter SDK 及对应 MSVC 工具；不能用 x64 宿主构建后直接贴 ARM64 标签。AI 依赖由 CMake 从固定来源下载并校验 SHA-256：ONNX Runtime CPU/DirectML 1.22.0、DirectML 1.15.4、OpenCV 4.11.0（静态裁剪模块）。可用 `VENERA_AI_DOWNLOAD_CACHE` 指定下载缓存目录。

```powershell
flutter pub get
flutter build windows --release
python windows/build.py --verify-only
```

`python windows/build.py --zip-only` 构建并生成 ZIP；安装版使用 `python windows/build.py`，另需 Inno Setup 6.3+ 的 `ISCC` 位于 PATH。`windows/build_arm64.py` 对应 ARM64 构建与包校验，不复用 x64 输出。发布包会校验 DLL/EXE 架构并附带第三方许可证。

不依赖 Flutter 界面的真实模型 smoke：

```powershell
cmake -S windows -B build/ai-smoke -A x64 -DVENERA_AI_STANDALONE=ON
cmake --build build/ai-smoke --config Release --target venera_image_ai_smoke
build/ai-smoke/Release/venera_image_ai_smoke.exe --model assets/models/anime4k_acnet.onnx --image screenshots/colorization_before.jpg --output build/ai-smoke/result.png --type esrgan --backend cpu --scale 1.3 --renders 3 --check-strength true
```

smoke 输出实际后端、输出尺寸、推理次数、缓存命中和峰值内存；`--check-strength true` 额外验证 50% 是 0% 与 100% 的线性光中间结果且透明度不变，`--backend auto` 可在有兼容 GPU 的 Windows 机器验证 DirectML。交叉编译成功不代表目标设备运行验证。

Apple 应用构建需要 Flutter 3.41.2 或更新版本、完整 Xcode、对应 SDK 和 CocoaPods；仅安装 Command Line Tools 不足以构建 Flutter 应用。iOS 使用 UIScene 生命周期注册插件和创建原生通道，并锁定已支持 UIScene 的文件选择插件，避免旧 `AppDelegate.window` 路径导致模型导入失败。`ios/Podfile` 与 `macos/Podfile` 自动接入同一原生 AI 模块，不需要手动复制源码或修改生成的插件注册文件：

```sh
flutter pub get
flutter build macos --release
flutter build ios --simulator --debug
flutter build ios --release --no-codesign
```

无签名 iOS 构建产物仍须通过自己的合法签名/分发方式安装。macOS 独立推理 smoke 可在 Command Line Tools 环境运行：

```sh
brew install cmake opencv onnxruntime
cmake -S native/image_ai -B build/ai-smoke -DCMAKE_BUILD_TYPE=Release
cmake --build build/ai-smoke --parallel 2
build/ai-smoke/venera_image_ai_smoke --model assets/models/anime4k_acnet.onnx --image screenshots/colorization_before.jpg --output build/ai-smoke/result.png --type esrgan --backend auto --scale 1.3 --renders 3 --check-strength true
```

该独立 CMake 目标默认使用主机安装的库，不替代应用的固定 CocoaPods 依赖。复现固定版本时，可通过 `ORT_INCLUDE_DIR` / `ORT_LIBRARY` 指向官方 Apple 包头文件/框架，通过 `OpenCV_DIR` 选择相应 OpenCV 安装；应用框架的直接编译/链接验证与主机库 smoke 应分别记录。

## Create a new comic source
See [Comic Source](doc/comic_source.md)

## Thanks

### particularly thanks

Modify and add functions based on
[Venera](https://github.com/venera-app/venera)

### Tags Translation
[![Readme Card](https://github-readme-stats.vercel.app/api/pin/?username=EhTagTranslation&repo=Database)](https://github.com/EhTagTranslation/Database)

## Headless Mode
See [Headless Doc](doc/headless_doc.md)

The Chinese translation of the manga tags is from this project.


#免责声明

不得利用本项目进行任何非法活动。 不得干扰任何公司或个人的正常运营或生活和著作权。 不得传播恶意软件或病毒。 此外，为降低法律风险

🚫禁止在官方平台（如b站）及官方账号区域（如b站微博评论区）销售或**不当**宣传本项目

🚫禁止在微信公众号平台销售或**不当**宣传本项目

🚫禁止利用本项目牟利，本项目无任何盈利行为，第三方盈利与本项目无关

欢迎正常宣传

代码均来自开源项目或AI


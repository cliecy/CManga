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
（正在 feature/colorization 分支测试本地 AI 实时黑白漫画上色功能的**更多可选模型**）

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

### Windows / Android 本地 AI 图像处理

- 在“设置 → Anime4K”选择 **v4 (AI)**。内置 ACNet 为 2× 亮度超分；可下载/导入兼容的 Real-ESRGAN RGB 模型。v1 是独立的传统算法，不再作为 AI 失败时的静默回退。
- **最终输出倍率**默认跟随模型，也可在 1× 至模型原生倍率之间设置：滑块步进 0.05×，数字输入精度 0.01×，例如 1.30×、1.75×。结果尺寸按进入超分阶段的原图尺寸四舍五入。
- **超分强度**为 0–100%，步进 1%。0% 仅做基础缩放，100% 使用完整增强结果；它不改变倍率，也不是高级设置中的“输出对比度”。v1 同样支持独立强度。
- 在“设置 → 上色”下载或导入兼容 DeOldify Artistic/轻量 int8 ONNX 模型。**颜色浓度**独立控制 0–120%，步进 1%；100% 为模型预测色度，120% 额外增艳。0% 生成中性色度，不保证逐字节还原原图；关闭功能才完全跳过上色。不支持任意 ONNX/DDColor 模型。
- Windows 的 **Auto** 优先尝试 DirectML，模型或设备不兼容时明确报告 CPU 回退；也可指定 CPU。Android 上色沿用 CPU 策略。界面显示最近一次 AI 操作的实际后端、缓存命中和失败原因。
- 两项功能同时开启时顺序为“超分 → 上色”。全局和漫画专属设置遵循现有优先级；调参后刷新当前图片。基础推理结果有界缓存，缓存仍在时，纯倍率/强度/对比度调整不重复执行对应模型；上游像素变化会正确重算下游上色。
- AI 只在 Windows、Android 接入。失败时保留可阅读图片并提示原因，不显示虚假的 AI 成功。原生处理设有内存与像素上限；Windows 单阶段输入及模型原生输出上限为 24×1024×1024 像素，超限会报错而非擅自降低倍率。
- Windows 发布包包含所需 AI 运行库，不需要 Python、CUDA 或手工安装 ONNX Runtime。上色模型不随包分发，首次下载/导入后可离线使用。

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


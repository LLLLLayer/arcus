# Arcus —— 构建与运行

## 0. 环境

- macOS + **Xcode 16 或更新**（本工程用 `objectVersion 77` 的文件系统同步组；开发用 Xcode 26.3 验证）。
- 真机（iPhone，**iOS 17+**）才能体验完整效果：陀螺仪视差、`VNGenerateForegroundInstanceMaskRequest` 主体分割只在真机的 ANE/GPU 上可用。
- 模拟器可编译运行并做功能演示，但分割会走降级路径、无陀螺仪。

## 1. 下载 Core ML 深度模型（一次性）

模型 ~50MB，**未纳入 git**（见 `.gitignore`）。首次构建前运行：

```bash
./scripts/download_models.sh
```

它会把 `DepthAnythingV2SmallF16.mlpackage` 放到 `Arcus/Resources/`。脚本优先用 `huggingface-cli`，否则回退 `git clone`（需 git-lfs）。

> 没有模型也能跑：App 会用伪深度兜底出 3D 效果，但质量明显下降。要"Apple 级"效果务必先下模型。

## 2. 用 Xcode 打开

```bash
open Arcus.xcodeproj
```

1. 选中 **Arcus** target → Signing & Capabilities → 选你的开发团队（真机调试需要）。
2. 选一台 **iOS 17+ 真机** 或 **iOS 17+ 模拟器**。
3. ⌘R 运行。

## 3. 命令行编译验证

```bash
# 模拟器编译（CI / 快速校验）
xcodebuild -project Arcus.xcodeproj -scheme Arcus \
  -destination 'generic/platform=iOS Simulator' \
  -configuration Debug build

# 真机归档（需签名）
xcodebuild -project Arcus.xcodeproj -scheme Arcus \
  -destination 'generic/platform=iOS' -configuration Release build
```

## 4. 使用流程

1. 启动 → 点 **选择照片**（PhotosPicker）或用内置示例图。
2. App 跑端侧管线（深度 → 分割 → 去遮挡补全 → 烘焙），进度可见，通常 1–3 秒。
3. 进入 3D 预览：
   - **倾斜手机**或**手指拖动**看视差；
   - 调 **深度强度 / 视差幅度**；
   - 开 **调试图层**查看深度图 / mask / 补全背景；
4. 导出：
   - **视差视频**（mp4，存相册）；
   - **空间照片**（HEIC，可 AirDrop 到 Vision Pro）。

## 5. 目录速查

| 路径 | 内容 |
|---|---|
| `docs/` | 调研报告(01) / 架构(02) / 本文(03) |
| `scripts/download_models.sh` | 拉取 Core ML 深度模型 |
| `Arcus/Pipeline/` | 端侧处理管线（深度/分割/补全/烘焙） |
| `Arcus/Compute/` + `*.metal` | Metal compute（深度后处理、push-pull 补全） |
| `Arcus/Rendering/` | Metal 两层视差渲染器 + 运动控制 |
| `Arcus/Export/` | 视频 / 空间照片导出 |
| `Arcus/UI/` | SwiftUI 界面 |

## 5.1 性能说明（重要）

端侧管线的逐像素处理（深度后处理、push-pull 补全、重采样）是 CPU 数值循环：

- **Release 构建**：768×1024 整条管线约 **0.3s**；真机带 Core ML 深度（ANE ~30ms）+ 系统分割（~0.2s）总计约 **0.5–0.8s**。
- **Debug 构建（`-Onone`）**：同样的循环会慢 **30–50×**（且模拟器上 Vision 分割会走失败兜底，再加几秒）。**所以 Debug + 模拟器下首屏可能要十几秒，这是正常的**——务必以 **Release / 真机** 衡量真实速度。

测速可看控制台日志行：`[Pipeline] 完成 WxH 用时 …s`。

## 6. 常见问题

- **编译报找不到模型**：模型是运行时资源，不影响编译；缺失时运行期走伪深度兜底。要真效果先跑下载脚本。
- **模拟器主体分割无效**：`VNGenerateForegroundInstanceMaskRequest` 不支持模拟器/CPU，App 自动降级到深度阈值近似；请用真机看完整效果。
- **视差太小/太大**：在编辑页调"视差幅度"；或改 `ParallaxRenderer` 的 `depthScale` 默认值。
- **真机签名失败**：在 target 的 Signing 里选团队、改唯一 Bundle ID。

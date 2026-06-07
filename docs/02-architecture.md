# Arcus Demo —— 架构与实现决策

本文记录 **Arcus** 这个 iOS Demo 的具体技术取舍、模块划分与数据流。结论依据见 [`01-research.md`](01-research.md)。

## 1. 目标效果

把任意一张 2D 照片，在 **iPhone 端侧** 转成可交互的 3D 照片：

- 倾斜手机 / 手指拖动时产生**运动视差**（前景比背景移动更多）；
- **移动主体后，能看到主体背后被补全（inpaint）的背景**——这是与"廉价单层深度位移"最大的区别，也是 Apple 效果的灵魂；
- 全程**离线、无网络、无服务端**；
- 可导出**视差视频（mp4）**与**空间照片（立体 HEIC，可在 Vision Pro 查看）**。

## 2. 关键决策（与通用调研的差异）

调研给的"生产推荐"是 OpenCV 补全 + SceneKit 渲染。本 Demo 在两点上做了**更利于自包含、可控、易编译**的选择：

| 维度 | 通用推荐 | 本 Demo 选择 | 理由 |
|---|---|---|---|
| 去遮挡补全 | OpenCV Telea/NS | **纯 Metal push-pull（金字塔 pull-push）** | 不引入 OpenCV 这种重二进制依赖；push-pull 对"主体区域/窄带"这种一侧紧邻有效像素的洞，填充平滑无伪影，GPU 实时 |
| 渲染 | SceneKit geometry modifier | **自写 Metal 两层深度位移网格** | 完全控制相机视差、遮挡顺序、软边 alpha；避免 SceneKit 在自定义位移上的各种坑；最贴近"移动主体见背后" |
| 表示 | 2–3 层 LDI atlas mesh | **2 层（前景主体 + 补全背景）位移网格**，背景层在主体区域做了 color+depth 补全 | 2 层即可达成"见背后"效果；结构清晰，后续可平滑扩展到 N 层 |

> 升级路径都已预留：补全可换 LaMa Core ML（`Inpainter` 协议）；渲染可加第 3 层中景或接 MetalSplatter 做 3DGS 模式。

## 3. 模块划分

```
Arcus/
├── App/            应用入口、Info、权限
├── Pipeline/       端侧处理（一次性，结果缓存进 Photo3DScene）
│   ├── Photo3DPipeline.swift      编排：depth → segment → inpaint → bake
│   ├── DepthEstimator.swift       Core ML DA V2 / AVDepthData / 伪深度兜底
│   ├── SubjectSegmenter.swift     前景实例 mask / 人物分割兜底
│   ├── DisocclusionInpainter.swift 窄带膨胀 + push-pull 补全 color&depth
│   ├── ImageProcessing.swift      CIContext / 像素缓冲 / 归一化等工具
│   └── Photo3DScene.swift         烘焙产物：前景RGBA+深度、背景RGB+深度等纹理
├── Compute/        Metal compute（深度后处理 + 补全核）
│   ├── MetalContext.swift         共享 device/queue/library
│   ├── DepthProcessor.swift       归一化 + edge-aware(联合双边) 平滑
│   ├── PushPullInpainter.swift    金字塔 pull-push 填洞（color/depth 通用）
│   └── Compute.metal              上述 compute kernels
├── Rendering/      实时渲染
│   ├── ParallaxRenderer.swift     Metal 渲染器：两层位移网格 + 相机视差
│   ├── ParallaxMetalView.swift    SwiftUI ↔ MTKView 桥接 + 手势
│   ├── MotionController.swift     CMMotionManager 姿态(钳位+低通)
│   ├── PlaneMesh.swift            细分网格顶点/索引生成
│   └── Render.metal               顶点位移 + 采样片元着色器
├── Export/
│   ├── VideoExporter.swift        AVAssetWriter 渲染视差轨道为 mp4
│   └── SpatialPhotoExporter.swift ImageIO 立体 HEIC + 空间元数据
├── UI/             SwiftUI 界面
│   ├── ContentView.swift          主界面 / 状态机
│   ├── ProcessingView.swift       处理进度
│   ├── EditorView.swift           3D 预览 + 参数 + 导出
│   └── ControlsView.swift         深度强度 / 视差幅度 / 调试图层
└── Resources/      Assets、示例图、Core ML 模型(运行时，gitignored)
```

## 4. 端侧数据流（导入一张图后）

```
UIImage / CGImage  (orient-normalized, 长边 clamp 到 ~1536)
        │
        ├─[DepthEstimator] ──► dispMap  (Float, 0=远 1=近, 源分辨率)
        │     • 有 AVDepthData → 直接用并归一化（快速路径）
        │     • 否则 Core ML DA V2 Small（VNCoreMLRequest）→ 逆深度归一化
        │     • 模型缺失 → 伪深度（中心/亮度/垂直梯度）兜底，保证永不崩
        │
        ├─[DepthProcessor] ─► 联合双边平滑(以 RGB 为引导) + 归一化到 0..1
        │
        ├─[SubjectSegmenter] ─► mask (Float 0..1, 软边)
        │     • VNGenerateForegroundInstanceMaskRequest (iOS17+)
        │     • 兜底 VNGeneratePersonSegmentationRequest(.accurate)
        │     • 都失败 → 用深度阈值近似前景（保证有可视分层）
        │
        ├─[DisocclusionInpainter]
        │     ringMask = dilate(mask, r=maxDisparityPx) − mask     (MPSImageDilate)
        │     fillRegion = mask ∪ ringMask  (默认补整块主体区，更稳)
        │     bgColor = pushPull(rgb,   hole=fillRegion)           (Metal)
        │     bgDepth = pushPull(disp,  hole=fillRegion)           (Metal, 用更远的环境深度)
        │
        └─[Photo3DScene]  烘焙以下 GPU 纹理，供渲染器零拷贝使用：
              • fgColor  : RGBA (rgb + alpha=mask)        前景层
              • fgDepth  : R    (disp)                    前景位移
              • bgColor  : RGB  (inpainted)               背景层
              • bgDepth  : R    (inpainted disp)          背景位移
              • 元数据   : 图像宽高比、深度直方图近/远、建议视差幅度
```

## 5. 渲染（每帧）

两层各是一张 **细分平面网格（默认 192×192 顶点）**，在顶点着色器里沿 −Z 按该层 depth 位移（视差量 = `depthScale`），片元采样各自纹理：

- **背景层**先画（无 alpha 测试，填满）；
- **前景层**后画，`alpha < 0.5` 丢弃 + 软边混合，深度测试保证遮挡顺序。

相机做**小幅平移 + 注视原点**（off-axis），位移量来自：

- `MotionController`：`CMDeviceMotion.attitude` 相对初始参考的 roll/pitch delta，**钳位到 ±maxAngle，一阶低通滤波**去抖、忽略 yaw 漂移；
- 拖拽手势：手指位移映射到相机 x/y 偏移；
- 自动模式：无交互时做缓慢 Lissajous 轨迹（用于录制/演示）。

视差由"相机平移 + 各层按深度位移"自然产生：近处前景位移大、远处背景位移小，移动时前景边缘"滑开"，露出背景层在该处**已补全**的像素 → 实现"看到人背后"。

## 6. 导出

- **视差视频**：离屏渲染器跑一圈 Lissajous/水平往返相机轨迹，逐帧 `MTLTexture → CVPixelBuffer → AVAssetWriterInputPixelBufferAdaptor`，H.264/HEVC mp4。
- **空间照片**：渲染左右眼两个微偏相机（baseline≈左右各 ±32mm 等效），用 `CGImageDestinationCreateWithURL(..., "public.heic", 2, ...)` 写两张，附 `kCGImagePropertyGroups` 立体配对 + 相机 baseline/视场角元数据，得到可在 Apple Vision Pro 打开的空间照片。

## 7. 兜底与健壮性（"可用"的关键）

| 场景 | 行为 |
|---|---|
| Core ML 深度模型未下载 | 走伪深度（亮度+垂直梯度+中心偏置），仍出 3D（质量降级，UI 提示运行下载脚本） |
| 模拟器（不支持前景实例 mask / 部分 Core ML） | 自动降级：分割走深度阈值近似；功能可演示 |
| 非人物且无主体 | `VNGenerateForegroundInstanceMaskRequest` 返回空 → 用深度阈值取近景作"前景层" |
| LiDAR/人像照片自带深度 | 优先用 `AVDepthData`，免跑模型 |
| 低内存设备 | 长边 clamp + 自适应网格密度 + Metal heap 复用 |

## 8. 最低系统与依赖

- **iOS 17.0+**（`VNGenerateForegroundInstanceMaskRequest`）。代码对 iOS 16 以人物分割降级（已用 `if #available` 隔离）。
- **零第三方 SPM/Pod 依赖**：仅系统框架（SwiftUI / Vision / CoreML / Metal / MetalKit / MetalPerformanceShaders / CoreMotion / AVFoundation / ImageIO / Photos）。
- 唯一外部资产：`DepthAnythingV2SmallF16.mlpackage`（运行时资源，由 `scripts/download_models.sh` 拉取，已 gitignore）。

详细构建步骤见 [`03-build-and-run.md`](03-build-and-run.md)。

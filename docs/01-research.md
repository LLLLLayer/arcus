# 单张 2D 照片转 Apple 级别 iPhone 端侧 3D 照片：技术调研报告

> 面向中文 iOS 工程师。目标：在 iPhone 上把一张普通 2D 照片，转成"移动主体后还能看到主体背后被补全的背景"的 Apple 级别端侧 3D 照片。本文直接回答两大核心问题、拆解完整技术管线、给出技术对比矩阵与开源构件清单，并落地一套可执行的 Demo 架构。
>
> 本报告由多 agent 网络调研工作流（7 个维度并行检索 + 综合）产出，所有结论均附 §7 参考资料。

---

## 0. 执行摘要（TL;DR）

1. **表示法选型：用分层/2.5D（LDI / 深度位移 mesh），不要用 Gaussian Splatting（3DGS）作为核心。** 单张照片做"照片视差"这件事，3DGS 是杀鸡用牛刀——它无论如何都得幻觉出画面外的所有内容，相对一个好的 LDI 在中小幅视差下几乎没有可见收益，却带来数量级更高的算力和工程成本。3DGS 只在"大幅环绕 / 视角相关高光反射 / walk-around"时才真正胜出。**结论：LDI/2.5D 打 80% 的场景，Flash3D 式端侧 3DGS 作为可选高级模式，渲染统一交给 MetalSplatter。**

2. **Apple "移动主体仍见补全背景"的机制 = 深度分层 + 视差遮挡断边 + 去遮挡（disocclusion）窄带补全（inpainting）。** 关键洞察：视差永远**不会**暴露整张背景，只会沿主体轮廓暴露**一条与像素视差等宽的窄带**。所以只需对"膨胀后的边缘环带"做补全，而非整张洞。这把昂贵的生成式大洞补全，降级为廉价、实时、低内存的窄带填充——这正是 CVPR 2020 论文在深度边缘只膨胀约 5px 合成区的原因，也是 iOS 26 Spatial Scenes 体感"一两秒出片"的底层逻辑。

3. **最佳端侧技术栈：** Depth Anything V2 Small（Apple 官方 Core ML，约 50MB / ~30ms ANE）做深度 → `VNGenerateForegroundInstanceMaskRequest` 做主体分割 → `MPSImageDilate` 取窄带 + OpenCV Telea/NS（或 Metal push-pull）做去遮挡补全 → 2–3 层 LDI 烘焙成位移网格 → SceneKit/Metal 用 `CMMotionManager` 陀螺仪驱动视差。可直接复用 `3dify-ios`（MIT）的 Metal POM 着色器与 `iOS-Depth-Sampler`（MIT）的深度读取代码。

> 本 Demo 的实际取舍见 [`02-architecture.md`](02-architecture.md)：补全选用**纯 Metal push-pull**（避免引入 OpenCV 依赖），渲染选用**自写 Metal 两层位移网格**（最贴近"移动主体见背后"的目标效果，且完全可控）。

---

## 1. 直接回答两个核心问题

### 1.1 问题 A：Gaussian Splatting vs 分层/切片（LDI/MPI/mesh）——单张照片端侧 3D 该选谁？

**结论：默认选分层/2.5D（LDI / 深度位移 mesh），3DGS 仅作为可选的"深度视差 / 环绕"高级模式。绝不把 3DGS 作为单照片 App 的核心。**

理由分三层：

**(1) 经典"3D 照片视差"效果已被分层方案完整解决。** 单目深度 + 1–3 层补全 mesh，在 Metal 片元着色器里渲染，可在任意现代 iPhone 上以 120fps、极低内存运行；它用 Apple 原生深度 API，瞬时出片（无需逐场景优化）。Apple 自家的 iOS 景深/人像视差、Google Photos "Cinematic photos"、Facebook 3D Photos——全部是深度位移 mesh，而非辐射场。

**(2) 单图 3DGS 的优势在单照片场景里大幅缩水。** 从单张图出发，3DGS 同样必须幻觉出视锥外的一切。对于小/中等相机运动，它相对一个好的 LDI 几乎没有可见收益，却付出远高的算力与工程代价。两者的差距只剩"近场去遮挡区域"那一小块。

**(3) 3DGS 真正胜出的边界条件：** 大幅视差、视角相关的镜面/反射外观、照片级 walk-around 自由视点。LDI 在大视差下会崩（纹理拉伸、硬层接缝），而 3DGS 优雅降级且看起来照片级真实。

**单图 3DGS 的两个家族（混淆这两者是产品决策最大的坑）：**

| 家族 | 代表方法 | 适用对象 | 对本任务 |
|---|---|---|---|
| **(A) 物体级前馈 3DGS** | Splatter Image (CVPR'24)、TriplaneGaussian、LGM (ECCV'24) | 干净背景上的**物体**（ShapeNet/CO3D/Objaverse 训练）→ 3D 资产 | ❌ 不适配真实照片场景；LGM 需多视图扩散前端 + ~10GB 显存，服务端工作负载 |
| **(B) 场景级前馈 3DGS** | **Flash3D (3DV'25, Oxford VGG)** | 单张**真实照片** → 可渲染 3D 场景 | ✅ 唯一对口：用单目深度基座(UniDepth)放第一层高斯，再预测偏移层幻觉遮挡内容；零样本泛化 |
| 多视图前馈 3DGS | pixelSplat / latentSplat / MVSplat | 需 ≥2 张有位姿的视图 | ❌ 单张任意照片不适用 |

**渲染侧已经不是瓶颈：** MetalSplatter（MIT, Swift/Metal, iOS/macOS/visionOS）、Niantic Scaniverse（iPhone 11+ 端侧 3DGS 采集+优化，60–90s）、msplat（M4 Max 上 ~70s 训练完一个 Mip-NeRF-360 场景、~350 FPS 渲染）三者都证明了 Apple 芯片上跑得动。**真正的难点是把单图推理网络（Splatter Image / Flash3D）移植到 Core ML，且 Flash3D 的 UniDepth 基座偏重。**

> **决策**：LDI 打 80% 场景；若要做差异化的"深度视差/环绕"，走 Flash3D 式管线（端侧 Core ML 单目深度 → Splatter-Image 式逐像素高斯解码器，产出几十万~100万高斯 → MetalSplatter 渲染）。避开 LGM/TriplaneGaussian（除非产品转向 3D 资产生成）。

### 1.2 问题 B：Apple 如何做到"移动主体后仍能看到主体背后被补全的背景"？

这正是"3D 照片"的灵魂。机制可拆为 **深度 + 去遮挡补全（disocclusion inpainting）** 五步：

```
RGB 照片
  │
  ├─(1) 单目深度估计  → 每像素深度/视差图
  │
  ├─(2) 检测深度不连续(轮廓/silhouette 边)  → 切断前景边与背景边的连接
  │
  ├─(3) 沿这些边形成 context 区(已知背景) + synthesis 区(待补的洞)
  │
  ├─(4) 去遮挡补全：把被前景遮住的"背后"颜色+深度幻觉出来，
  │      作为新的层放在前景之后
  │
  └─(5) 烘焙成带纹理三角网格/分层，按相机运动渲染运动视差
```

**核心洞察（也是 Apple 能"一两秒出片、端侧、不依赖 Apple Intelligence"的原因）：**

> 视差**永远不会**暴露整张背景，只会沿主体轮廓暴露**一条窄带**，宽度等于该处的像素视差。所以你**只需补一条"膨胀后的边缘环带"**，而不是整张洞。

具体做法（窄带补全 trick，本任务真正的关键）：
1. 拿到主体 mask；
2. 用 `MPSImageDilate`（一次 GPU 调用）按"最大预期像素视差"膨胀 mask；
3. 膨胀后的 mask 减去原 mask → 得到一条紧贴背景的**薄环（thin ring）**；
4. **只**对这条薄环补全。因为它很薄且一侧紧邻有效背景像素，经典 Telea/NS 或一个小 LaMa crop 就绰绰有余，避免了大洞伪影；
5. 把主体叠加到补全后的背景上，加一个小视差偏移，分层合成。

CVPR 2020 (Shih et al.) 正是据此在深度边缘只膨胀**约 5px** 合成区。这把"昂贵的整洞生成式补全"降级为"廉价的窄带填充"，使整个效果实时、低内存。

**Apple 的原生答案（2025–2026）：iOS 26 / visionOS 26 "Spatial Scenes"** 把任意 2D 照片一键转成 3D 视差场景，"几秒钟"，支持 **iPhone 12 及更新机型**，**不需要 Apple Intelligence**。它用的就是"生成式深度 + 多视角合成（主体/背景分离 + 去遮挡填充）"——概念上等同于上面的深度+LDI+补全管线，只是变成了通过 Photos 框架的第一方 API，并能 handoff 给 Vision Pro 拿到完整景深。

底层可直接复用的 Apple 构件：
- `AVDepthData` / `AVCaptureDevice` 在 Pro 机上融合 LiDAR + 广角拿到**度量深度**；
- **Portrait Effects Matte** 做主体/背景分离；
- ARKit `sceneDepth` 60Hz + 场景几何 mesh；
- Core ML + Neural Engine 跑 Depth Anything 或自定义补全网络；
- SceneKit/RealityKit/Metal 渲染带纹理 LDI/mesh，陀螺仪驱动视差；
- spatial-photo handoff：iPhone 造的场景在 Vision Pro 上获得完整深度。

---

## 2. 完整技术管线详解

### 阶段 1：深度估计（Depth Estimation）

3D 照片视差**只需相对深度**（按相对视差扭曲像素即可），不需度量尺度——这决定了应优先选轻量相对深度模型。

| 来源 | 何时用 | 产出 |
|---|---|---|
| **Core ML 单目深度（首选通用路径）** | 任意单张照片（相册导入、非拍摄） | 相对逆深度，归一化到 0–1 视差 |
| `AVDepthData` / `sceneDepth`（快速路径） | LiDAR/双摄/TrueDepth 拍摄的照片 | 免费度量深度，无需带模型 |

**推荐模型：Depth Anything V2 Small（Apple 官方 Core ML, F16）**——DINOv2 ViT-S 编码器 + DPT 头，24.8M 参数，F16 包 **49.8MB**，iPhone ANE 上 **~31–34ms**，附 Swift 示例工程。固定输入 518×392（4:3），其它比例需重采样/letterbox。

> 边缘处理：深度边缘的"漏色/bleeding"是主要伪影。对深度图做 guided/bilateral 滤波，或对去遮挡缝隙做补全即可清理。

### 阶段 2：主体分割（Subject Segmentation）

| API | 版本 | 能力 | 备注 |
|---|---|---|---|
| **`VNGenerateForegroundInstanceMaskRequest`**（首选） | iOS 17+ | 类无关主体 mask（人/宠物/物体/食物） | 即"拷贝主体"背后的引擎；`generateScaledMaskForImage(forInstances:from:)` 拿源分辨率单通道 matte；**仅 ANE/GPU，不支持 CPU/模拟器** |
| `VNGeneratePersonSegmentationRequest` | iOS 15+ | 仅人物 matte，3 档质量（.accurate/.balanced/.fast） | 兼容更老 iOS，可实时 |
| `VNGeneratePersonInstanceMaskRequest` | iOS 17+ | 多人分离 | |

matte 本身就是软边的，正好利于视差合成。精度建议：升采样到源分辨率，再用 guided/joint-bilateral 滤波或 `CIMaskToAlpha` + 轻微羽化精修软边。

### 阶段 3：分层 / Mesh 表示（Representation）

两条主路线：

**(a) 深度位移 Mesh（连续面）**：一个细分网格平面，每个顶点沿视轴按深度位移。一张连续面，廉价、无需合成、单纹理；缺点是在深度断点处"橡皮膜"拉伸（轮廓涂抹进背景）——需在断边处切开并补全洞。

**(b) 分层 / LDI（Layered Depth Image）**：在深度边缘干净分离、硬遮挡边界正确。LDI 在每个像素格位存 0..N 个 (颜色,深度) 像素，并存显式连接关系；深度不连续处切断连接，分出前景轮廓边与背景边；把被遮挡的颜色+深度补全成前景之后的额外层，再导出标准 mesh。

**用几层？**
- 真 MPI：**~32 层**是说服力视差的标准（8–16 层显卡片化/纸板感，64 层只有边际提升且受内存带宽限制）；
- App 式 2.5D：**1 层 + 深度图（连续位移）+ 1 个补全背景层**足够手机轻量倾斜视差；
- LDI：在遮挡边通常 **2–4 个有效深度层**。

### 阶段 4：去遮挡补全（Disocclusion Inpainting）—— 用窄带 trick

见 §1.2。选项与适配：

| 方法 | 体积/延迟 | 适用 | 评价 |
|---|---|---|---|
| **OpenCV Telea / Navier-Stokes**（推荐） | 极小、薄带毫秒级 | 窄带 | 无模型、无内存尖峰、全设备+模拟器可用；窄带场景下经典法看起来很好 |
| **Metal push-pull / pyramid fill**（推荐） | GPU 实时 | 窄带、视频 | `MPSImageDilate` 一次膨胀；自定义补全 shader 是工程量 |
| **LaMa via Core ML**（可选高质量） | ~200MB / ~2s / 加载时 ~1.4GB 内存尖峰 | 较宽洞 | Fourier(FFC) 卷积、对大洞鲁棒；**iOS 上 fp16-on-ANE 不稳，需 pin 到 GPU**；4GB 设备 OOM 风险 |
| Stable Diffusion 补全 | ≥6GB RAM、逐步秒级 | 大/复杂洞 | ❌ 对窄带去遮挡过度，低 RAM 机崩溃，不推荐 |

### 阶段 5：渲染 + 运动视差（Rendering with Motion Parallax）

| 渲染方式 | 实现 | 质量/成本 |
|---|---|---|
| **POM（视差遮挡映射）** | 单张全屏 quad + 深度高度图，片元着色器沿视向 ray-march 偏移 UV | 最轻，60fps，1 个 draw call，无 mesh；`3dify-ios` 即此法。小运动很有说服力；轮廓涂抹、大倾角崩 |
| **深度位移细分 mesh** | SceneKit `SCNShaderModifierEntryPoint.geometry` 顶点位移 / Metal 硬件细分 | 真几何视差、遮挡顺序正确；断点处需裙边/clamp；先 bilateral 滤波深度去尖刺 |
| **分层平面/LDI** | 2–4 个补全后的层分别渲染 | 去遮挡最干净，最像 Facebook 3D photo |

**视差输入（怎么驱动）：** `CMMotionManager.startDeviceMotionUpdates` 读 `CMDeviceMotion.attitude`（pitch/roll/yaw 或四元数）；存一个初始参考姿态，把 delta（**钳位 + 低通滤波**避免抖动/yaw 漂移）喂给相机偏移 / POM 视向；再加 `UIPanGestureRecognizer` 支持触摸拖拽。

**导出：**
- **视频**：渲染视差循环到帧，`AVAssetWriter` + `AVAssetWriterInputPixelBufferAdaptor` 写出；SceneKit 可用 `SceneKitVideoRecorder`。
- **空间 HEIC**：渲染两个微偏相机得到左/右眼，`CGImageDestinationCreateWithURL(url, "public.heic", 2, ...)` + 立体元数据（相机内参、左右索引、baseline ~64mm、FOV ~60°）写出，可 handoff 到 Vision Pro。

---

## 3. 技术对比矩阵与推荐

### 3.1 表示法 / 方法对比矩阵

| 方法 | 输入 | 去遮挡处理 | 端侧实时? | 大视差 | 视角相关外观 | 工程量 | 对本任务推荐度 |
|---|---|---|---|---|---|---|---|
| **深度位移 mesh / POM** | 单张+深度 | 无(拉伸) | ✅ 120fps | ❌ 崩 | ❌ | 低 | ★★★★☆ Demo 默认 |
| **LDI + 窄带补全** (Shih CVPR'20) | 单张+深度 | ✅ 干净边+补全层 | ⚠️ 补全离线/一次性，渲染实时 | ◯ 中等 | ❌ | 中 | ★★★★★ **生产推荐** |
| **MPI 32 层** (Tucker&Snavely CVPR'20) | 单张 | ✅ 幻觉背景 | ⚠️ 导入时跑一次，缓存后实时 | ◯ 较大 | ❌ | 中高 | ★★★☆☆ 高保真离线导出 |
| **3D Ken Burns** (点云+补全) | 单张 | ✅ 强 | ❌ 离线/电影路径 | ◯ 大 | ❌ | 高 | ★★☆☆☆ 视频导出模式；非商用许可 |
| **One Shot 3D** (Tiefenrausch+LDI+atlas mesh) | 单张 | ✅ on-LDI 补全 | ✅ 几秒端侧 | ◯ | ❌ | 高(需自实现) | ★★★★☆ **端侧最佳蓝图** |
| **Flash3D** 场景级 3DGS | 单张真实照片 | ✅ 偏移层 | ⚠️ 取决于深度基座 | ✅ 强 | ✅ | 高 | ★★★☆☆ 差异化高级模式 |
| **Splatter Image** 物体级 3DGS | 单张物体 | 弱 | ✅(物体) | ✅ | ✅ | 中 | ★★☆☆☆ 仅物体、需重训 |
| **LGM / TriplaneGaussian** | 单张物体 | — | ❌ ~10GB 显存 | ✅ 360° | ✅ | 极高 | ★☆☆☆☆ 3D 资产生成才用 |

### 3.2 深度模型对比

| 模型 | 参数 | Core ML 体积 | 端侧延迟 | 度量? | 推荐度 |
|---|---|---|---|---|---|
| **Depth Anything V2 Small** | 24.8M | 49.8MB(F16) | ~30ms ANE | 相对 | ★★★★★ **首选** |
| Apple Depth Pro | — | 1.9GB / 745MB–1.1GB(量化) | 数秒 | ✅ 度量+焦距 | ★★☆☆☆ 仅需度量时 |
| MiDaS / DPT | ~344M(L) | 多种 | 较慢 | 相对 | ★★☆☆☆ 被 DA V2 超越 |
| ZoeDepth | 345M(BEiT-L) | 无官方 Core ML | 重 | 度量(域特定) | ★☆☆☆☆ |
| Marigold | ~1GB+ | — | 多步扩散秒级 | 相对 | ✗ 端侧不可行 |
| `AVDepthData`/`sceneDepth` | 0(硬件) | — | 实时 | ✅ 度量 | ★★★★☆ LiDAR 机快速路径 |

---

## 4. 可用的开源构件清单（含 URL / 许可 / 体积）

### 4.1 深度估计

| 项目 | URL | 语言 | 许可 | 体积/性能 | 用途 |
|---|---|---|---|---|---|
| **apple/coreml-depth-anything-v2-small** | https://huggingface.co/apple/coreml-depth-anything-v2-small | Core ML | Apple ASCL / Apache-2.0 | 49.8MB / ~30ms | **直接打包的最佳深度构件** |
| huggingface/coreml-examples (DepthSample) | https://github.com/huggingface/coreml-examples | Swift | Apache-2.0 | — | 现成 Swift/Xcode 集成样例 |
| DepthAnything/Depth-Anything-V2 | https://github.com/DepthAnything/Depth-Anything-V2 | Python | Apache-2.0(S/B); CC-BY-NC(L) | — | 自行转 Base/Large 的源 |
| isl-org/MiDaS | https://github.com/isl-org/MiDaS | Python | MIT | — | 基线，已被超越 |
| apple/ml-depth-pro | https://github.com/apple/ml-depth-pro | Python | 非商用权重 | — | 仅需度量深度 |

### 4.2 分割 + 补全

| 项目 | URL | 语言 | 许可 | 体积/性能 | 用途 |
|---|---|---|---|---|---|
| mallman/CoreMLaMa | https://github.com/mallman/CoreMLaMa | Python | Apache-2.0 | → ~200MB | Big LaMa → Core ML 转换脚本 |
| john-rocky/lama-cleaner-iOS | https://github.com/john-rocky/lama-cleaner-iOS | Swift | MIT | ~200MB / ~2s | 现成 LaMa 端侧补全 App 参考 |
| john-rocky/CoreML-Models | https://github.com/john-rocky/CoreML-Models | Swift/Core ML | 按模型(LaMa=Apache-2.0) | — | 已转好的 LaMa/AOT-GAN 模型 |
| advimman/lama | https://github.com/advimman/lama | Python | Apache-2.0 | — | LaMa 源模型 |
| Sanster/IOPaint | https://github.com/Sanster/IOPaint | Python | Apache-2.0 | — | 补全模型/预处理参考；Issue#405 记录 ~1.4GB 内存尖峰 |
| Ma-Dan/EdgeConnect-CoreML | https://github.com/Ma-Dan/EdgeConnect-CoreML | Swift/Core ML | 见仓库 | 小 | 证明补全网络可端侧 |

### 4.3 表示法参考实现（蓝图，非直接端侧运行）

| 项目 | URL | 许可 | 用途 |
|---|---|---|---|
| vt-vl-lab/3d-photo-inpainting | https://github.com/vt-vl-lab/3d-photo-inpainting | MIT(研究)/部分非商用 | **LDI 算法规范**（~2-3min/图，勿逐字移植） |
| facebookresearch/one_shot_3d_photography | https://facebookresearch.github.io/one_shot_3d_photography/ | 研究 | **端侧最佳架构蓝图**（Tiefenrausch+on-LDI 补全+atlas mesh） |
| google-research/single_view_mpi | https://github.com/google-research/google-research/tree/master/single_view_mpi | Apache-2.0 | 32 层 MPI 生成器，离线生成 |
| sniklaus/3d-ken-burns | https://github.com/sniklaus/3d-ken-burns | 非商用 | 点云+补全，电影路径；**许可限商用** |

### 4.4 渲染 / iOS 集成（最直接复用）

| 项目 | URL | 语言 | 许可 | 用途 |
|---|---|---|---|---|
| **3dify-ios** | https://github.com/3dify-app/3dify-ios | Swift/Metal/GLSL | **MIT** | **最对口**：单照片 Metal POM 视差 + 多模型深度管线，直接抄 POM shader |
| **shu223/iOS-Depth-Sampler** | https://github.com/shu223/iOS-Depth-Sampler | Swift/Metal | **MIT** | 所有原生深度 API（AVDepthData/Portrait Matte/ARKit/LiDAR）+ "2D in 3D" Metal 范例 |
| **scier/MetalSplatter** | https://github.com/scier/MetalSplatter | Swift/Metal | **MIT** | 生产级 3DGS 渲染器(iOS/macOS/visionOS)，载 PLY/SPZ/.splat；**用 Release 构建** |
| SceneKitVideoRecorder | https://github.com/svhawks/SceneKitVideoRecorder | Swift | MIT | SceneKit → mp4 导出 |
| DVParallaxView / MPParallaxView | https://github.com/denivip/DVParallaxView | ObjC/Swift | MIT | 最简多层平面陀螺视差近似 |
| laanlabs/metal-splats | https://github.com/laanlabs/metal-splats | Swift/Metal | 核心 Inria/MPII **非商用** | 教学用 AR splat；商用慎用 |

> **许可红线**：避免在可上架产品中依赖 `3d-ken-burns`、`laanlabs/metal-splats` 核心、以及 `3d-photo-inpainting` 的非商用组件——复用其**技术/规范**，而非代码。

---

## 5. 最佳技术栈（Best Stack）

> 综合体积/延迟/许可/质量，构建 Demo 的最优组合：

```
┌─────────────────────────────────────────────────────────────┐
│  导入时（一次性，缓存结果）                                    │
│                                                               │
│  RGB ──► Depth Anything V2 Small (Core ML, 50MB, ~30ms ANE)   │
│           └► 归一化为 0–1 视差，bilateral 滤波去边缘漏色       │
│      │     (LiDAR/人像照片走 AVDepthData 快速度量路径)         │
│      ▼                                                         │
│  VNGenerateForegroundInstanceMaskRequest ──► 主体 matte        │
│           └► generateScaledMaskForImage 升采源分辨率           │
│      ▼                                                         │
│  MPSImageDilate(按最大像素视差膨胀) − 原 mask = 去遮挡薄环      │
│      ▼                                                         │
│  仅对薄环补全：OpenCV Telea/NS（或 Metal push-pull）           │
│           └► 6GB+ 设备遇宽洞可切 LaMa Core ML(pin GPU)         │
│      ▼                                                         │
│  烘焙 2–3 层 LDI → atlas 域带纹理三角网格（One Shot 风格）     │
└─────────────────────────────────────────────────────────────┘
┌─────────────────────────────────────────────────────────────┐
│  渲染时（实时 60fps）                                          │
│                                                               │
│  SceneKit/Metal 渲染分层位移 mesh                              │
│      ◄── CMMotionManager attitude（钳位+低通）驱动相机         │
│      ◄── UIPanGestureRecognizer 触摸拖拽                       │
│                                                               │
│  导出：AVAssetWriter → mp4 ；双偏相机 → 立体 HEIC (handoff VP) │
└─────────────────────────────────────────────────────────────┘
```

**代码复用策略：** Fork/lift `3dify-ios`(MIT) 的 Metal POM shader 与多模型深度管线；深度读取代码取自 `iOS-Depth-Sampler`(MIT)；若加 3DGS 高级模式则接 `MetalSplatter`(MIT)。

**为何不照搬桌面方案：** `vt-vl-lab/3d-photo-inpainting` 是 2–3min/图 + CUDA，逐字移植不可行——取其 LDI 规范即可；`3d-ken-burns` 调成固定电影路径且非商用，不适合交互视差。

---

## 6. iOS Demo App 推荐架构

详见 [`02-architecture.md`](02-architecture.md)。要点：

| 层 | 选型 |
|---|---|
| 深度 | Core ML + Vision 跑 Depth Anything V2 Small；LiDAR 机 `AVDepthData` 快速路径兜底；模型缺失时伪深度兜底 |
| 分割 | Vision `VNGenerateForegroundInstanceMaskRequest`（iOS 17+）；人物/旧系统降级 `VNGeneratePersonSegmentationRequest .accurate` |
| 膨胀/合成 | Metal Performance Shaders `MPSImageDilate`；Core Image `blendWithMask` / `CIMaskToAlpha` |
| 补全 | **本 Demo：纯 Metal push-pull**（默认，无外部依赖）；LaMa Core ML 可选 |
| 表示 | 2 层（前景主体 + 补全背景）深度位移网格（可扩展到 N 层 LDI） |
| 渲染 | **本 Demo：自写 Metal 两层位移网格**（最贴近目标效果、完全可控）；3DGS 高级模式走 MetalSplatter |
| 视差驱动 | `CMMotionManager` device attitude（钳位+低通）+ 拖拽手势 |
| 导出 | `AVAssetWriter`（视差视频）；ImageIO `CGImageDestination` + 立体元数据（空间 HEIC） |
| 最低系统 | iOS 17.0（为 `VNGenerateForegroundInstanceMaskRequest`；人物场景可降级到 iOS 15/16） |

---

## 7. 参考资料（Sources）

**Apple 原生机制 / Spatial / 深度 API**
- Converting 2D photos to Spatial Photos (studiolanes): https://blog.studiolanes.com/posts/2d-to-spatial-photos
- Build compelling spatial photo and video experiences WWDC24 10166: https://developer.apple.com/videos/play/wwdc2024/10166/
- Reading and Writing Spatial Photos with Image I/O (Finn Voorhees): https://www.finnvoorhees.com/words/reading-and-writing-spatial-photos-with-image-io
- Creating spatial photos and videos with spatial metadata (Apple): https://developer.apple.com/documentation/imageio/creating-spatial-photos-and-videos-with-spatial-metadata
- Writing spatial photos (ImageIO / CGImageDestination): https://developer.apple.com/documentation/ImageIO/writing-spatial-photos
- VNGenerateForegroundInstanceMaskRequest: https://developer.apple.com/documentation/vision/vngenerateforegroundinstancemaskrequest
- VNGenerateForegroundInstanceMask (MszPro): https://mszpro.com/vision-foreground-instance-mask-request
- Removing image background using the Vision framework: https://www.createwithswift.com/removing-image-background-using-the-vision-framework/
- VNGeneratePersonSegmentationRequest.QualityLevel: https://developer.apple.com/documentation/vision/vngeneratepersonsegmentationrequest/qualitylevel
- Generating person segmentation with the Vision Framework: https://www.createwithswift.com/generating-person-segmentation-with-the-vision-framework/
- Depth Pro Apple ML Research: https://machinelearning.apple.com/research/depth-pro
- iOS 26 Spatial Scenes iPhone 12+ (9to5Mac): https://9to5mac.com/2025/06/10/psa-spatial-scenes-will-work-on-any-iphone-running-ios-26/
- iOS 26 Spatial Scenes — turn any photo into 3D (GadgetHacks): https://apple.gadgethacks.com/news/ios-26-spatial-scenes-turn-any-photo-into-3d-magic/
- Apple Support: Create a spatial photo / view a spatial scene (visionOS): https://support.apple.com/guide/apple-vision-pro/create-a-spatial-photo-view-scene-tan1be9a3a0b/visionos
- Spatial Video iPhone 15 Pro & Vision Pro (MV-HEVC): https://xreality.zone/en/post/what-is-spatial-video-on-iphone-15-pro-and-apple-vision-pro/
- Capturing Depth in iPhone Photography WWDC17 (507): https://developer.apple.com/videos/play/wwdc2017/507/
- AVDepthData (Apple): https://developer.apple.com/documentation/avfoundation/avdepthdata
- MPSImageDilate (Apple): https://developer.apple.com/documentation/metalperformanceshaders/mpsimagedilate
- Displaying a point cloud using scene depth (Apple): https://developer.apple.com/documentation/arkit/arkit_in_ios/environmental_analysis/displaying_a_point_cloud_using_scene_depth
- Demystifying the Parallax Effect in iOS 7: https://medium.com/chip-monks/demystifying-the-parallax-effect-used-in-ios-7-a96ddda96c7c

**LDI / 3D 照片补全**
- Shih et al., Context-aware Layered Depth Inpainting (CVPR 2020 PDF): https://openaccess.thecvf.com/content_CVPR_2020/papers/Shih_3D_Photography_Using_Context-Aware_Layered_Depth_Inpainting_CVPR_2020_paper.pdf
- Shih et al. project page: https://shihmengli.github.io/3D-Photo-Inpainting/
- arXiv 2004.04727: https://arxiv.org/abs/2004.04727
- vt-vl-lab/3d-photo-inpainting: https://github.com/vt-vl-lab/3d-photo-inpainting
- 3D Ken Burns (arXiv 1909.05483): https://arxiv.org/abs/1909.05483
- 3D Ken Burns project page: https://sniklaus.com/kenburns
- sniklaus/3d-ken-burns: https://github.com/sniklaus/3d-ken-burns
- One Shot 3D Photography (PDF): https://arxiv.org/pdf/2008.12298
- One Shot 3D Photography project page: https://facebookresearch.github.io/one_shot_3d_photography/
- Synced: Facebook One-Shot On-Device 3D: https://medium.com/syncedreview/facebook-one-shot-on-device-model-efficiently-transforms-smartphone-pics-into-3d-images-fe058d893fde
- How Facebook 3D Photos Work (akella): https://medium.com/@akella/how-facebook-3d-photos-work-8424cf48f061

**MPI / 2.5D / 视差着色器**
- Single-View MPI project page (Tucker & Snavely): https://single-view-mpi.github.io/
- arXiv 2004.11364 (HTML): https://ar5iv.labs.arxiv.org/html/2004.11364
- CVPR 2020 PDF: https://openaccess.thecvf.com/content_CVPR_2020/papers/Tucker_Single-View_View_Synthesis_With_Multiplane_Images_CVPR_2020_paper.pdf
- Stereo Magnification (Zhou et al., SIGGRAPH 2018 PDF): https://arxiv.org/pdf/1805.09817
- google/stereo-magnification: https://github.com/google/stereo-magnification
- google-research/single_view_mpi: https://github.com/google-research/google-research/tree/master/single_view_mpi
- Parallax Shaders & Depth Maps (Alan Zucconi): https://www.alanzucconi.com/2019/01/01/parallax-shader/
- Inside Facebook 3D Photos: Parallax Shaders (Zucconi): https://www.alanzucconi.com/2019/01/01/facebook-3d-photos/
- Parallax Occlusion Mapping (LearnOpenGL): https://learnopengl.com/Advanced-Lighting/Parallax-Mapping
- Parallax Occlusion Mapping Node (Unity): https://docs.unity3d.com/Packages/com.unity.shadergraph@17.2/manual/Parallax-Occlusion-Mapping-Node.html
- LucidPix (PetaPixel): https://petapixel.com/2020/01/10/the-lucidpix-app-uses-ai-to-transform-regular-photos-into-3d-images/

**3D Gaussian Splatting**
- Splatter Image (CVPR 2024): https://openaccess.thecvf.com/content/CVPR2024/html/Szymanowicz_Splatter_Image_Ultra-Fast_Single-View_3D_Reconstruction_CVPR_2024_paper.html
- szymanowiczs/splatter-image: https://github.com/szymanowiczs/splatter-image
- Flash3D (arXiv 2406.04343): https://arxiv.org/abs/2406.04343
- Flash3D PDF (Oxford VGG): https://www.robots.ox.ac.uk/~vgg/publications/2025/Szymanowicz25/szymanowicz25.pdf
- LGM (ECCV 2024) — 3DTopia/LGM: https://github.com/3DTopia/LGM
- LGM (arXiv 2402.05054): https://arxiv.org/abs/2402.05054
- TriplaneGaussian (CVPR 2024): https://zouzx.github.io/TriplaneGaussian/
- pixelSplat: https://github.com/dcharatan/pixelsplat
- scier/MetalSplatter: https://github.com/scier/MetalSplatter
- laanlabs/metal-splats: https://github.com/laanlabs/metal-splats
- rayanht/msplat: https://github.com/rayanht/msplat
- Scaniverse (radiancefields): https://radiancefields.com/platforms/scaniverse
- Niantic Scaniverse 4: https://scaniverse.com/news/scaniverse-4
- awesome-gaussian-splatting: https://github.com/tomiwaAdey/awesome-gaussian-splatting

**单目深度 / Core ML 模型**
- apple/coreml-depth-anything-v2-small: https://huggingface.co/apple/coreml-depth-anything-v2-small
- huggingface/coreml-examples (depth-anything): https://github.com/huggingface/coreml-examples
- DepthAnything/Depth-Anything-V2: https://github.com/DepthAnything/Depth-Anything-V2
- Depth Anything V2 (arXiv 2406.09414): https://arxiv.org/pdf/2406.09414
- apple/ml-depth-pro: https://github.com/apple/ml-depth-pro
- Depth Pro (arXiv 2410.02073): https://arxiv.org/pdf/2410.02073
- KeighBee/coreml-DepthPro: https://huggingface.co/KeighBee/coreml-DepthPro
- isl-org/MiDaS: https://github.com/isl-org/MiDaS
- ZoeDepth (arXiv 2302.12288): https://arxiv.org/pdf/2302.12288
- isl-org/ZoeDepth: https://github.com/isl-org/ZoeDepth
- Apple Core ML Models gallery: https://developer.apple.com/machine-learning/models/
- apple/coremltools: https://github.com/apple/coremltools

**分割 + 补全 (端侧)**
- mallman/CoreMLaMa: https://github.com/mallman/CoreMLaMa
- john-rocky/lama-cleaner-iOS: https://github.com/john-rocky/lama-cleaner-iOS
- john-rocky/CoreML-Models: https://github.com/john-rocky/CoreML-Models
- advimman/lama: https://github.com/advimman/lama
- Sanster/IOPaint: https://github.com/Sanster/IOPaint
- Ma-Dan/EdgeConnect-CoreML: https://github.com/Ma-Dan/EdgeConnect-CoreML
- Image Inpainting with OpenCV (Telea/NS, LearnOpenCV): https://learnopencv.com/image-inpainting-with-opencv-c-python/
- OpenCV Inpainting docs: https://docs.opencv.org/4.x/d7/d8b/group__photo__inpaint.html
- apple/ml-stable-diffusion: https://github.com/apple/ml-stable-diffusion

**iOS 渲染 / 集成**
- 3dify-app/3dify-ios: https://github.com/3dify-app/3dify-ios
- shu223/iOS-Depth-Sampler: https://github.com/shu223/iOS-Depth-Sampler
- svhawks/SceneKitVideoRecorder: https://github.com/svhawks/SceneKitVideoRecorder
- denivip/DVParallaxView: https://github.com/denivip/DVParallaxView
- DroidsOnRoids/MPParallaxView: https://github.com/DroidsOnRoids/MPParallaxView
- Using SceneKit and CoreMotion in Swift: https://iosdeveloperzone.com/2016/05/02/using-scenekit-and-coremotion-in-swift/

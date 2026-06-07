# 单图转 3D / 视差：我们的方案 vs 全行业 — 决策报告

> 面向 iOS 工程师的竞品技术裁决报告
> 我们的方案（基线）：全端上离线管线 = Depth Anything V2 Small（Core ML，单目相对深度）→ Vision `VNGenerateForegroundInstanceMask` 主体分割 → LaMa-Dilated（Core ML，512×512，~40MB）背景去遮挡修补 → 烘焙 2 层（前景主体 RGBA + 修补背景，各自带深度）→ Metal 单 pass 双层屏幕空间深度位移视差，陀螺仪（CoreMotion）+ 触摸驱动 → 导出视差视频 mp4 + 立体 spatial HEIC（Vision Pro）。100% 离线、零服务端、端上 ~0.5–0.8s、除两个 Core ML 模型外零三方依赖。表示法是分层 / 2.5D（**不是** 3DGS）。已知短板：仅 2 层 → 极端机位仍拉伸；背景修补质量受 LaMa@512 上限约束。

---

## 1. 行业全景分类与对比

我把全行业分成四类：**端上 App**、**开源工程/研究代码**、**商业云平台**、**前沿研究**。下面是一张总表（"vs ours" 列：✅=我们赢、⚠️=平手/取舍、❌=我们输）。

### 1.1 端上 App（与我们同生态位）

| 产品 | 核心做法 | 端上? | 去遮挡 inpaint | 表示法 | vs ours |
|---|---|---|---|---|---|
| **Apple iOS 26 Spatial Scenes** | Neural Engine 单目深度 + 生成式前后景分离 + 陀螺/加速度计视差 | ✅ 100% 端上 | ❌ 无显式 inpaint，靠 2D 位移容差 | 2.5D 视差 | ⚠️ 集成/隐私持平；我们赢在**显式 inpaint + 导出（mp4/spatial HEIC）+ 深度模型透明可控** |
| **3dify-ios**（开源·已归档） | FCRN+FastDepth+Pydnet 多模型集成，RMS 选优 + 双边滤波 + Metal POM 视差 | ✅ 100% 端上 | ❌ 无，用 POM shader 遮丑 | 单一深度图 | ✅ 我们有真 inpaint、单一基模架构更干净、有主体 RGBA + 立体导出；可借鉴其**多模型选优 + 双边滤波后处理** |
| **TheParallaxView** | TrueDepth 人头追踪 + ARKit 离轴透视渲染（真 3D） | ✅ 100% 端上 | ❌ 无深度图/inpaint | 离轴投影 | ⚠️ 它真 3D 更沉浸但**强依赖 TrueDepth + 需人脸在框**；我们赢在通用性（任意 iPhone 12+）、可分享、隐私 |
| **Zoetropic** | 手动分层 / wiggle 立体，陀螺视差 | ✅ 100% 端上 | ❌ 无（用户自备图层） | 手工多层 | ✅ 我们全自动（单图→3D），它需人工搭层 |
| **Meta/FB 3D Photos**（2018·废弃） | 双摄/CNN 深度 → mesh 撕裂分层 → 服务端 CNN 幻觉填洞 → Three.js | 混合（深度端上，填洞云） | ⚠️ 服务端 CNN hallucination | 撕裂 mesh | ✅ 我们端上 inpaint（LaMa 优于旧 CNN）、不依赖双摄、仍在维护 |

### 1.2 开源工程 / 研究代码

| 产品 | 核心做法 | 端上? | 去遮挡 inpaint | 表示法 | vs ours |
|---|---|---|---|---|---|
| **3d-photo-inpainting**（Shih, CVPR'20） | MiDaS 深度 → 带像素连通性的 **LDI** → 迭代 context-aware 修补 → LDI mesh 视差 | ❌ 云/GPU（2–3 分钟） | ✅ 全图 context-aware（重） | **多层 LDI**（带连通性） | ⚠️ 它深区背景补全更好、电影级输出；我们快 100×、端上、实时交互。**最值得抄的是 LDI 连通性 + 窄带掩膜逻辑** |
| **3d-ken-burns**（Niklaus, TOG'19） | 语义深度 + 分割精修 → 点云 → 新机位渲染 + context inpaint | ❌ 离线 GPU | ✅ context-aware | 点云 | ⚠️ 电影级，但**非商用许可** + 不可实时；可借鉴分割引导深度精修 |
| **one_shot_3d_photography**（FB, SIGGRAPH'20） | Tiefenrausch 移动深度 → **LDI** → 移动版 inpaint 网络 → atlas mesh，VR-ready | ✅ 移动优化（数秒） | ✅ 移动 inpaint 网络 | **N 层 LDI + atlas mesh** | ⚠️ **最接近我们的"对手参考系"**：它多层 LDI 处理中等机位更好、atlas mesh 适配 VR。我们用更新的 DA V2、管线更简、零依赖。**强烈建议抄 atlas mesh 做 spatial HEIC 几何** |
| **Depthy**（web） | 仅读 Google Lens Blur 内嵌深度 → WebGL 视差 | ✅ 端上（浏览器） | ❌ 无（纯位移） | 单深度图 | ✅ 它只吃特定格式、无去遮挡有边缘瑕疵；我们吃任意图。可借鉴：**有 AVDepthData/LiDAR 时跳过推理** |

### 1.3 商业云平台

| 产品 | 核心做法 | 端上? | 去遮挡 inpaint | 表示法 | vs ours |
|---|---|---|---|---|---|
| **Immersity AI / LeiaPix** | 私有 Neural Depth Engine → **3+ 层**深度 → MP4 视差 + LIF 光场格式 | ❌ 云 SaaS（分钟级） | ❌ 无 inpaint（忽略去遮挡） | 3+ 层 | ⚠️ 它多层更丰富、VR/光场原生；我们赢在端上/隐私/速度/有 inpaint/免订阅。**3+ 层是明确信号** |
| **Owl3D** | 单目深度 → **DIBR** 像素位移生成左右眼 → SBS/MV-HEVC，帧间时序平滑 | ❌ 云+桌面 | ❌ 无（边界出黑边/畸变） | 单深度图 stereo | ✅ 我们有 inpaint（它边界有洞）、端上、实时。可借鉴：**视频时序平滑 + MV-HEVC 立体编码** |
| **Google Cinematic Photos** | 自训深度 CNN + DeepLab 分割精修 → RGB 挤出 mesh → **逐图轨迹优化**最小化拉伸 | ❌ 云 | ⚠️ 隐式（显著性感知机位，非显式模型） | 挤出 mesh | ⚠️ 它逐图轨迹优化很妙；我们赢在端上/隐私/显式主体保留/立体导出。**可抄：逐图机位轨迹优化做视频导出裁切** |
| **LucidPix** | 海量私有深度模型 → 点云 → POM 渲染，CNN 隐式填洞 | ❌ 云（1–5s + 订阅） | ⚠️ 隐式 | 点云 | ✅ 我们隐私/延迟/免费/可复现 |
| **CapCut / Wonder3D** | 跨域扩散生成 6 视角 normal+color → mesh（Instant-NSR/NeuS） | ❌ 云（2–3 分钟） | ❌ 无 | **生成式 mesh/3D 物体** | ⚠️ 它出可编辑 3D 网格，但正交、慢、仅正面图友好；不同赛道 |
| **Luma AI** | NeRF→**3DGS**，多视频输入，光度一致性隐式深度 | ❌ 云（分钟–小时） | ❌ 无 | **体积/3DGS** | ⚠️ 它需多视角输入、出体积资产；我们单图、实时、有 inpaint。不同输入前提 |
| **Pika / Runway** | 视频扩散，潜空间隐式 3D 理解，出 MP4 | ❌ 云 GPU | ❌ 无 | 潜空间隐式 | ⚠️ 创意特效赛道，非几何保真视差 |
| **Spline** | 文/图→生成式 3D mesh（OBJ/GLB/USD） | ❌ 云 | ❌ 无 | 生成式 mesh | ⚠️ 文生 3D 赛道，不同任务 |

### 1.4 前沿研究

| 产品 | 核心做法 | 端上? | 去遮挡 inpaint | 表示法 | vs ours |
|---|---|---|---|---|---|
| **Flash3D**（Oxford VGG, 3DV'25） | **前馈 3DGS**：UniDepth(ViT-L) 主体 + **偏移高斯层**重建遮挡后几何，单 pass ~0.5–1M 高斯 | ❌ 离线 GPU（无移动版） | ✅ **学到的 3D 空间偏移**（非 2D inpaint） | **3DGS + 偏移层** | ⚠️ **我们最直接的 SOTA 对手**：极端机位（~60°）、遮挡几何赢；我们端上/速度/兼容性/交互/电量决定性赢。UniDepth 800MB–2GB + 每帧 150–300M 高斯运算 → 几乎不可端上 |
| **ViewCrafter / MotionCtrl / WonderJourney / LucidDreamer** | 扩散视频/场景合成，参数化机位/文本控制 | ❌ 云 GPU（5–60s/视角） | ✅ 生成式幻觉 | 扩散视频/3DGS/NeRF | ⚠️ 视角相关外观（反射/光照）赢，但慢、非实时、非端上。**定位是"服务端电影级回放"升级，不与端上核心竞争** |
| **MetalSplatter**（iOS, MIT） | iOS/Metal 端 3DGS 渲染器（仅渲染，非重建），60+ FPS | ✅ 端上（仅渲染） | — | 3DGS 渲染 | ⚠️ 它解决"端上渲染高斯"，**瓶颈在 Flash3D 推理而非渲染**。若未来上 3DGS，它是现成渲染层 |
| **LaMa**（FFC inpaint, Apache-2.0） | 傅里叶卷积长程上下文，单 pass 填洞 | ✅（我们已用） | ✅ content-aware | — | 行业共识：**LaMa 在速度/显存/content-aware 上仍是端上 inpaint 最优解**，胜过 SD |

---

## 2. 两个核心问题：我们站在哪

### (a) 分层 / 2.5D 还是正确的选择吗？竞品是否在用 3DGS/MPI/扩散赢？

**裁决：在"端上 + 实时 + 单图 + 任意机型"这个约束盒子里，分层 / 2.5D 仍然是 2026 年唯一正确的工程选择。但"2 层"是落后的，应升级到 N 层 LDI。**

理由分三层：

1. **3DGS（Flash3D）是表示法上的真 SOTA，但端上不可行。** Flash3D 用偏移高斯层处理去遮挡，~60° 机位无拉伸 —— 这是我们 2 层方案 >30° 就拉伸的根因。但它扛着 UniDepth（800MB–2GB）+ 每帧数亿次高斯运算，研究界自己都没出移动版，实测只能 iPhone Pro Max 勉强跑且非实时。**MetalSplatter 证明端上"渲染"高斯可行，但瓶颈在"推理"高斯。** 所以 3DGS 是我们的**高端可选路径（Path 2）**，不是替换核心的理由。

2. **MPI/LDI 才是和我们同表示族、且被验证能上移动端的。** `one_shot_3d_photography`（FB）已经证明：移动优化的 N 层 LDI + atlas mesh 在数秒内可端上跑，处理中等机位明显优于 2 层。Immersity/LeiaPix 商业上直接用 3+ 层。**这是行业给我们最强的信号：分层方向没错，是层数太少。**

3. **扩散（ViewCrafter/Runway/Pika）赢在视角相关外观（反射、镜面、光照变化），但代价是 5–60s/视角、纯云、非交互。** 这与我们"实时陀螺视差"是不同产品形态，不构成对端上核心的直接威胁，**只适合做服务端"电影级回放"增值**。

> 一句话：**别动表示法的根（保留 LDI + Metal 屏幕空间位移），把 2 层升级成 3–4 层，就能吃掉竞品 70% 的极端机位优势，且仍保住 <1s 端上。** 3DGS 留作高端机付费档。

### (b) 最好的产品怎么做去遮挡背景补全？vs 我们的 LaMa@512

**裁决：我们的 LaMa@512 是端上的正确且有竞争力的选择；行业大多数产品在这一步反而更弱（要么没有，要么是慢的服务端方案）。真正的差距不在"用什么模型"，而在"窄带掩膜 + 多层 LDI 让需要补的洞更小"。**

行业去遮挡策略光谱：

| 策略 | 代表 | 评价 |
|---|---|---|
| **完全不做** | Immersity、Owl3D、Depthy、iOS 26、Pika/Runway/Luma | 边界出黑边/拉伸/畸变，靠机位容差遮丑 |
| **隐式（机位规避）** | Google Cinematic（显著性机位）、LucidPix（POM） | 不补洞，靠优化轨迹让洞不暴露 —— 聪明但治标 |
| **服务端生成式 inpaint** | 3d-photo-inpainting、3d-ken-burns、FB 旧版 CNN | 质量高但 2–3 分钟、云端、不可实时 |
| **学到的 3D 偏移（非 2D 补）** | Flash3D 偏移高斯 | 几何正确，但端上不可行 |
| **端上 content-aware（我们）** | **LaMa-Dilated@512 + Metal push-pull 窄带** | **少数真正在端上做显式 content-aware 填洞的，且 LaMa 在速度/显存上胜 SD** |

**关键研究洞察（Shih CVPR'20，全行业通用）：视差只暴露 ~5–10px 宽的窄带 rim，不是整张背景。** 所以窄带 inpaint（Telea/NS/LaMa crop）就够，全图生成是浪费。我们的"Metal push-pull 窄带优先（<100ms）+ LaMa Core ML fp16 兜底宽洞"已经是教科书式的端上最优组合。

**真正的瓶颈与升级方向：**
- LaMa@512 在**大块、强纹理**背景上分辨率不足 → 用 **tiled LaMa（512 滑窗拼接）** 提升有效分辨率，而非换模型。
- **更应该投资的是"让洞变小"**：N 层 LDI 把单一大洞拆成多个窄带，每个洞都落进 LaMa 舒适区，质量自然上去。
- 借鉴 DeepLab/分割引导的**掩膜边界精修**（Google、Ken Burns）改进 inpaint 输入掩膜。

---

## 3. 诚实裁决：我们在哪些轴赢、哪些轴输

### ✅ 我们决定性赢的轴

| 轴 | 证据 |
|---|---|
| **端上 / 离线** | 全行业除 iOS 26、3dify、TheParallaxView、FB one-shot 外几乎全是云。商业平台 100% 云 |
| **速度** | 0.5–0.8s vs 云分钟级 / Flash3D 30s+ / 扩散 5–60s/视角 |
| **隐私** | 零服务端，照片不离机；云方案全有隐私暴露 |
| **成本** | 零订阅、零 GPU 账单 vs LucidPix $5.99/月、Immersity/Owl3D 订阅、云 GPU 成本 |
| **简洁性 / 依赖** | 单基模 + 单 inpaint，零三方依赖 vs 3dify 三模型集成、研究方案重 PyTorch/CUDA |
| **机型兼容** | iPhone 12+ vs Flash3D 仅 Pro Max、TheParallaxView 仅 TrueDepth、FB 旧版需双摄 |
| **交互性** | 实时陀螺+触摸 vs 几乎所有竞品是预渲染视频/固定轨迹 |
| **显式去遮挡** | 我们真做 content-aware 填洞；多数竞品根本不做或隐式规避 |
| **导出格式** | mp4 + 立体 spatial HEIC（Vision Pro）vs 多数竞品无立体导出 |

### ❌ 我们输的轴

| 轴 | 谁赢 | 根因 |
|---|---|---|
| **极端机位质量** | Flash3D（~60°）、one-shot LDI、Immersity 3+ 层 | **只有 2 层** → >30° 纹理拉伸 |
| **多层遮挡 / 复杂场景** | LDI 家族、点云（Ken Burns/LucidPix）、3DGS | 2 层无法表达多重深度断层 |
| **生成式背景可信度** | 服务端 SD/扩散 inpaint、3d-photo-inpainting | **LaMa@512 分辨率与生成能力上限** |
| **真·新视角（视角相关外观）** | 3DGS（Flash3D/Luma）、扩散（ViewCrafter/MotionCtrl） | 屏幕空间位移无法表达反射/镜面/光照随视角变化 |
| **可编辑 3D 资产输出** | Wonder3D、Spline、Luma | 我们出的是效果，不是可导出 mesh/splat |

---

## 4. 优先级迭代路线图（不放弃端上）

按 **ROI（收益/成本）** 排序。P0/P1 关闭最大缺口且风险最低，P2/P3 为高端档与探索。

| 优先级 | 动作 | 关闭的缺口 | 实现要点 | 预期代价 | 风险 |
|---|---|---|---|---|---|
| **P0** | **2 层 → N 层 LDI（3–4 层）** | 极端机位拉伸 + 多层遮挡 | 对深度图做 3–4 段量化分层，复用现有 Metal 屏幕空间位移 shader（只是更多 quad/层）；每层独立深度+RGBA。参考 FB `one_shot_3d_photography` 的 LDI 层管理 | 渲染 +1–2 层 draw call，仍 <1s | **低**。表示法不变，最高 ROI |
| **P0** | **edge matting 精修** | 主体边缘发丝/半透明区域漏光、边界 inpaint 掩膜脏 | 在 `VNGenerateForegroundInstanceMask` 后接 guided filter / DeepLab 风格边界精修（Google、Ken Burns 都这么做）改善 alpha 与 inpaint 掩膜 | 端上 +几十 ms | **低** |
| **P1** | **tiled LaMa（512 滑窗）提升有效分辨率** | 大块强纹理背景修补质量受 512 上限 | 对大洞做 512 重叠分块 → LaMa 逐块 → 羽化拼接；窄带仍走 push-pull。配合 N 层后洞更小，质量进一步上去 | 大洞场景多几次推理（仍 <2s） | **低–中** |
| **P1** | **DA V2 Small → Base 可选档（质量档）** | 深度精度 → 拉伸/边界瑕疵根因 | 高端机（A16+/M 系）默认 Base，低端回退 Small；分层质量直接受深度边界质量影响 | Base 推理更慢更大，需分机型 gating | **中**。需 Core ML 量化 + 机型分档 |
| **P1** | **MPI/atlas mesh 导出 + MV-HEVC 立体** | VR 互操作 + 立体编码标准化 | 把 N 层 LDI 烘成 atlas mesh（抄 FB one-shot），spatial HEIC 用 MV-HEVC（抄 Owl3D/Immersity LIF 思路） | 导出管线扩展 | **中** |
| **P2** | **逐图机位轨迹优化（视频导出）** | 视频导出时拉伸暴露 | 抄 Google Cinematic：显著性感知 + 最小化拉伸的 loss 优化机位路径，仅用于 mp4 导出裁切，不影响实时 | 导出时一次性优化 | **低**（离线于实时路径） |
| **P2** | **视频 / 时序一致性扩展** | 静图→视频赛道 | 帧间深度平滑（抄 Owl3D）+ 复用 N 层管线 | 新管线分支 | **中** |
| **P3（高端付费档）** | **Flash3D 风格前馈 3DGS（Premium 模式）** | 真·新视角 + ~60° 机位 + 视角相关外观 | 仅 Pro/M 系机型；推理走量化 + Core ML，渲染用 **MetalSplatter**（现成 iOS 3DGS 渲染器）。偏移高斯层处理去遮挡 | UniDepth 太大需大幅蒸馏/量化；推理是瓶颈 | **高**。研究级风险，仅作差异化高端档 |
| **P3（探索）** | **服务端"电影级回放"可选增值** | 视角相关外观（反射/光照） | 用 ViewCrafter/MotionCtrl 风格扩散在云端渲染电影级轨道，端上播放；保持核心 100% 端上 | 引入可选服务端 | **高**（破坏纯端上叙事，需谨慎定位为可选） |

**路线总结：** P0（N 层 LDI + edge matting）是必做、低风险、最高 ROI，单这一步就吃掉竞品大部分极端机位优势且保住 <1s 端上。P1 巩固 inpaint 与深度质量、补齐 VR/立体导出标准。P3 的 3DGS 留作高端机付费差异化，不作为主线 —— **核心原则始终是：保住"端上 + 实时 + 任意机型"这块没人能同时占住的高地。**

---

## 参考资料

**端上 App / 平台特性**
- iOS 26 Spatial Scenes — MacRumors: https://www.macrumors.com/how-to/ios-3d-lock-screen-effect-spatial-scenes/ ; Techi: https://www.techi.com/ios-26-spatial-scenes-3d-photo-ai-feature-explained/
- LucidPix — PetaPixel: https://petapixel.com/2020/01/10/the-lucidpix-app-uses-ai-to-transform-regular-photos-into-3d-images/
- Google Cinematic Photos — Google Research: https://research.google/blog/the-technology-behind-cinematic-photos/
- Meta/Facebook 3D Photos — TechCrunch: https://techcrunch.com/2018/06/07/how-facebooks-new-3d-photos-work/
- 3dify-ios（开源·归档）: https://github.com/3dify-app/3dify-ios
- TheParallaxView（TrueDepth 头追）: https://www.anxious-bored.com/blog/2018/2/25/theparallaxview-illusion-of-depth-by-3d-head-tracking-on-iphone-x
- Zoetropic: https://apps.apple.com/us/app/zoetropic-photo-in-motion/id1365268892

**开源工程 / LDI / 点云**
- 3d-photo-inpainting（CVPR 2020）: https://github.com/vt-vl-lab/3d-photo-inpainting ; 论文: https://arxiv.org/abs/2004.04727 ; PDF: https://openaccess.thecvf.com/content_CVPR_2020/papers/Shih_3D_Photography_Using_Context-Aware_Layered_Depth_Inpainting_CVPR_2020_paper.pdf
- 3d-ken-burns（TOG 2019）: https://github.com/sniklaus/3d-ken-burns ; 项目页: https://sniklaus.com/kenburns
- one_shot_3d_photography（SIGGRAPH 2020）: https://github.com/facebookresearch/one_shot_3d_photography ; 项目页: https://facebookresearch.github.io/one_shot_3d_photography/ ; arXiv: https://arxiv.org/pdf/2008.12298 ; Synced 解读: https://medium.com/syncedreview/facebook-one-shot-on-device-model-efficiently-transforms-smartphone-pics-into-3d-images-fe058d893fde
- Depthy: https://github.com/panrafal/depthy ; http://depthy.stamina.pl/

**商业云平台**
- Immersity AI / LeiaPix: https://immersity.ai/ ; https://app.immersity.ai/image/depth-map ; 2025 指南: https://skywork.ai/skypage/en/From-LeiaPix-to-Immersity-AI-The-Ultimate-2025-Guide-to-AI-Powered-3D-Conversion/1975016245503389696
- Owl3D: https://www.owl3d.com/ ; 2D→stereo 博客: https://www.owl3d.com/blog/2d-to-stereoscopic-3d-with-ai-depth-map-from-a-single-image ; 故事: https://www.owl3d.com/blog/the-story-behind-owl3d-part-i
- Wonder3D / CapCut: https://www.xxlong.site/Wonder3D/ ; https://github.com/xxlong0/Wonder3D ; Wonder3D++: https://arxiv.org/abs/2511.01767
- Luma AI: https://lumalabs.ai/ ; 评测: https://www.thefuture3d.com/software/luma-ai/ ; 3DGS 工具对比: https://www.thefuture3d.com/blog/gaussian-splatting-software-tools-compared-2026/
- Spline AI: https://docs.spline.design/spline-ai/ai-3d-generation
- Pika: https://pikalabs.org/ ; Runway: https://runwayml.com/ ; Runway vs Pika vs Luma: https://genesysgrowth.com/blog/runway-vs-pika-vs-luma-ai
- Depthify.ai: https://www.depthify.ai/

**前沿研究**
- Flash3D（3DV 2025）: https://arxiv.org/abs/2406.04343 ; 项目页: https://www.robots.ox.ac.uk/~vgg/research/flash3d/ ; PDF: https://www.robots.ox.ac.uk/~vgg/publications/2025/Szymanowicz25/szymanowicz25.pdf
- ViewCrafter（2024）: https://arxiv.org/abs/2403.12255
- MotionCtrl（CVPR 2024）: https://arxiv.org/abs/2404.18955
- WonderJourney（2023）: https://arxiv.org/abs/2312.08132
- LucidDreamer（ICCV 2024）: https://arxiv.org/abs/2401.01947
- Text2Room: https://arxiv.org/abs/2304.09637
- Single-View View Synthesis with MPI（CVPR 2020）: https://arxiv.org/abs/2004.11364
- DepthSplat: https://arxiv.org/abs/2410.13862

**底层组件（我们已用 / 候选）**
- Depth Anything V2（NeurIPS 2024）: https://github.com/DepthAnything/Depth-Anything-V2 ; 论文: https://arxiv.org/abs/2406.09414 ; Apple Core ML Small: https://huggingface.co/apple/coreml-depth-anything-v2-small ; 解读: https://www.maginative.com/article/tiktoks-depth-anything-models-sets-new-standards-for-robust-image-based-depth-estimation
- LaMa（FFC inpaint）: https://arxiv.org/abs/2109.07161
- MiDaS v3.1: https://arxiv.org/abs/2307.14460
- Apple Depth Pro: https://machinelearning.apple.com/research/depth-pro ; https://github.com/apple/ml-depth-pro
- MetalSplatter（iOS 3DGS 渲染器）: https://github.com/scier/MetalSplatter
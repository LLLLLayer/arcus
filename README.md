# Arcus — 端侧把一张照片变成 3D 照片

一个 iOS demo：在 **iPhone 本地**（离线、无服务端）把任意一张 2D 照片，转成可交互的 **3D 照片**——倾斜手机或拖动画面会产生**运动视差**，而且**移动主体后能看到主体背后被补全的背景**，达到接近 Apple「空间场景 / 景深效果」的观感。在此之上还有两个进阶玩法：

- **重拍（Spatial Reframe）**：拍完之后拖动画面**重新选机位**，露出的区域由端侧 AI 补全成一张新照片（对 WWDC26 Spatial Reframing 的轻量复刻）；
- **出框（裸眼 3D）**：在背景与主体之间夹一对屏幕空间静止的画框条，主体随视差跨到条前，产生经典「裸眼 3D 出框」错觉；开启后导出的视差视频就是一支出框视频。

| 3D 合成（正常） | 深度图 | 去除主体后补全的背景 | 出框 |
|---|---|---|---|
| ![3D](assets/screenshot-3d.png) | ![depth](assets/screenshot-depth.png) | ![bg](assets/screenshot-background-inpaint.png) | ![bars](assets/screenshot-frame-bars.png) |

> 第三张是关键：前景主体被抠除后，原位置由周围背景补全。当视差让主体「滑开」时，露出的就是这块补全像素——这正是「看到人背后」的效果来源。第四张：主体盖在静止白条之前、背景被框在条后，遮挡关系由绘制顺序免费保证。

## 两个核心问题的结论

1. **高斯泼溅（3DGS） vs 切片分层？** → 单图端侧 3D 照片用**分层（深度位移 / LDI）+ 去遮挡补全**，不要用 3DGS。3DGS 是「杀鸡用牛刀」，只在大幅环绕 / 视角相关反射时才值得；分层方案更轻、更快、效果对等。
2. **Apple 怎么做到「移动主体仍见背后」？** → **深度分层 + 去遮挡窄带补全**。关键洞察：视差只会沿主体轮廓暴露**一条与像素视差等宽的窄带**，所以只需补这条「膨胀边缘环带」，因此能端侧秒级、低内存出片。

## 技术管线（全部端侧、一次性、结果缓存）

```
照片 ─► 单目深度(AVDepthData / Depth Anything V2 Core ML / 伪深度兜底)
      ─► 主体分割(VNGenerateForegroundInstanceMaskRequest / 人物分割 / 深度阈值兜底)
        ─► 剪影抗锯齿(RGB 彩色 guided filter 把低分辨率 matte 吸附到真实边缘)
      ─► 去遮挡补全(三档可选：快速竖直延续 / PatchMatch / MI-GAN 神经生成，全部深度感知)
      ─► 烘焙：前景 + 背景(+可选的近/远两层背景)的颜色与视差纹理 + 连续深度网格
      ─► Metal 实时渲染：连续网格前向 warp(无洋葱环/无橡皮膜)，陀螺仪 + 拖拽驱动
      ─► 导出 视差循环视频(mp4) / 空间照片(立体 HEIC, 可上 Vision Pro) / 重拍补全成片
```

渲染不是「平面沿 Z 位移」：每层是一张连续 (u,v) 网格，顶点着色器按逐像素视差**前向 warp 屏幕位置**；前景网格在剪影深度断层处切开，露出补全背景。主体绕质心整体放大盖住去遮挡过渡带。

> 另有深度估计、补全算法选型、渲染重构、抗锯齿、重拍、出框等的完整调研与设计笔记，属内部研究记录，未纳入版本库。

## 快速开始

```bash
# 1) 下载 Core ML 模型（深度 ~48MB + LaMa 补全 ~38MB，未纳入 git）
./scripts/download_models.sh

# 2) (可选) 本地转换 MI-GAN，启用「AI 补全」档（见 scripts/convert_migan.py 顶部说明）

# 3) 打开工程，选 iOS 17+ 真机或模拟器，⌘R 运行
open Arcus.xcodeproj
```

命令行编译校验：

```bash
xcodebuild -project Arcus.xcodeproj -scheme Arcus \
  -destination 'generic/platform=iOS Simulator' -configuration Debug build
```

陀螺仪视差与系统主体分割需要真机（ANE/GPU）；模拟器自动回退到深度阈值分割、无陀螺仪。

## 特点

- **纯系统框架，零第三方依赖**（SwiftUI / Vision / CoreML / Metal / CoreMotion / AVFoundation / ImageIO / Photos）。唯一外部资产是按需下载/转换的 Core ML 模型。
- **健壮兜底**：无深度模型→伪深度；无分割→深度阈值近似；LaMa 缺→push-pull；MI-GAN 缺→PatchMatch；人像/LiDAR 照片→优先用自带 `AVDepthData`（已按 EXIF 方向对齐）。任何情况都能出 3D，不崩。
- **快**：Release 下整条管线在 768×1024 约 **0.3s**（真机带 ANE 模型 ~0.5–0.8s；PatchMatch/MI-GAN 档更慢但可中途取消）。
- **可导出**：视差循环视频（开「出框」即出框视频）+ 可在 Apple Vision Pro 查看的立体空间照片 + 重拍补全成片。

## 工程结构

```
assets/              README 截图（真机实拍）
scripts/             模型下载 / MI-GAN 转换脚本
Arcus.xcodeproj      Xcode 工程（文件系统同步组）
Arcus/
  App/               入口
  Core/              Metal 上下文 / Float 图像缓冲 / 纹理与图像 IO / 示例图
  Pipeline/          深度 / 分割 / 去遮挡补全(竖直·PatchMatch·LaMa·MI-GAN) / 烘焙编排
  Rendering/         连续深度网格 warp 渲染器 + 出框条 + 运动控制 + 着色器 + 重拍桥接
  Export/            视差视频 / 空间照片 / 相册保存
  UI/                SwiftUI 界面（首页 / 处理 / 编辑器 / 重拍 / 导出）
  Resources/         Assets + (运行时) Core ML 模型
```

## 致谢 / 复用的开源工作

技术与规范参考（非逐字搬运代码）：Depth Anything V2（Apple Core ML 转换）、LaMa (Suvorov et al. WACV'22)、MI-GAN (Sargsyan et al. ICCV'23)、PatchMatch (Barnes et al. SIGGRAPH'09)、3D Photo Inpainting (Shih et al. CVPR'20) 的 LDI 思路、One Shot 3D Photography 的端侧蓝图、`iOS-Depth-Sampler`（shu223）的 iOS 深度采样集成范式。

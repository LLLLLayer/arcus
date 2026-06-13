# research

这个目录放外部项目和论文实现的本地调研材料，不直接参与 Arcus 编译。

## OpenReshot

本地路径：`research/OpenReshot/`

来源：[kellyvv/OpenReshot](https://github.com/kellyvv/OpenReshot)

OpenReshot 是一个原生 iOS App，目标是“把一张普通照片换个角度重新拍出来”。它的路线更接近 Apple SHARP / 3DGS：先用 SHARP Core ML 模型从单张照片预测一组 3D Gaussian，再把这些高斯转成 MetalSplatter 可渲染的 splat 点云，用 Metal 做实时新视角预览；用户确认角度后，再把当前视角截图交给 Gemini 修复高斯渲染中的模糊、拉伸、空洞和破碎区域。

对 Arcus 的参考价值：

1. **空间重构方向**：OpenReshot 更接近“大视角重拍”，Arcus 当前更偏“小视角 2.5D 空间照片”。后续集成可把它作为 3DGS / SHARP 路线的对照样本。
2. **端侧渲染链路**：`SharpModel.swift` 负责 Core ML 推理，`GaussianCloud.swift` 负责把模型输出转成 metric splats，`ReshootRenderer.swift` 负责 MetalSplatter 实时渲染。
3. **工程代价**：模型权重超过 1GB，iOS 端依赖 MetalSplatter，最终成图依赖 Gemini API Key；这和 Arcus “轻量、离线、零第三方依赖”的定位差异很大。

注意：`research/OpenReshot/` 是外部 Git 仓库，已在根 `.gitignore` 中忽略，避免误提交成 submodule。

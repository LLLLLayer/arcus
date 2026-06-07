# docs —— 文档索引

单张 2D 照片 → Apple 级别端侧 3D 照片 的调研与 iOS Demo 文档。

| 文档 | 内容 |
|---|---|
| [01-research.md](01-research.md) | **技术调研报告**：直接回答两个核心问题（高斯泼溅 vs 分层；苹果如何"移动主体见背后"）、完整管线、对比矩阵、开源构件清单、参考资料 |
| [02-architecture.md](02-architecture.md) | **Arcus Demo 架构**：模块划分、端侧数据流、渲染、导出、兜底策略与关键决策 |
| [03-build-and-run.md](03-build-and-run.md) | **构建与运行**：下模型、Xcode 打开、命令行编译、使用流程、FAQ |
| [04-competitive-analysis.md](04-competitive-analysis.md) | **竞品调研**：30 个产品/项目对比，我们在哪赢/输，优先级迭代路线图 |
| [05-roadmap-status.md](05-roadmap-status.md) | **路线图执行状态**：已实现(N层LDI/边缘精修/裁剪LaMa/Base插槽)、刻意未做(P3 3DGS 端上不可行)及原因 |

## 两句话结论

1. **不要用高斯泼溅做核心**。单图端侧 3D 照片用**分层（深度位移 mesh / LDI）+ 去遮挡窄带补全**，更轻、更快、效果对等；3DGS 只在大幅环绕时才值得。
2. **苹果"移动主体仍见背后"= 深度分层 + 去遮挡补全**。关键 trick：视差只沿轮廓暴露一条**与像素视差等宽的窄带**，只需补这条"膨胀边缘环带"，所以能端侧秒级、低内存出片。

实现见仓库根的 `Arcus/`。

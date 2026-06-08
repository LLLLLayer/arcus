#include <metal_stdlib>
using namespace metal;

// 与 Swift 端 MeshUniforms 内存布局严格对应。
struct MeshUniforms {
    float2 offset;          // 0   视差偏移(陀螺/拖拽)
    float2 viewScale;       // 8   几何 cover 缩放(保持图像比例 + overscan)
    float  parallaxAmp;     // 16  最大 uv 位移幅度
    float  depthPivot;      // 20  视差支点(此深度处不动)
    float  flatten;         // 24  0=3D,1=2D
    float  layerFactor;     // 28  warp 缩放：前景=1, 背景=bgParallaxFactor
    float  fgFlag;          // 32  1=前景(用 matte alpha), 0=背景(不透明)
    float  fgScale;         // 36  前景整体放大(支点=主体质心)；1=原尺寸，其它层恒为 1
    int    debugMode;       // 40  0正常,1深度,2主体,3背景
    float2 fgCenter;        // 48  主体质心(uv)，放大支点
};

struct VOut {
    float4 pos [[position]];
    float2 uv;
};

// 顶点 = 图像 (u,v) 栅格；按"该顶点处逐像素视差"做连续屏幕空间位移。
// 连续位移 ⇒ 没有离散平面 ⇒ 没有洋葱环；前景网格已在剪影断层处切开 ⇒ 不会橡皮膜拉伸。
vertex VOut mesh_vertex(uint vid [[vertex_id]],
                        const device float2* gridUV [[buffer(0)]],
                        constant MeshUniforms& u     [[buffer(1)]],
                        texture2d<float> dispTex      [[texture(0)]]) {
    constexpr sampler s(address::clamp_to_edge, filter::linear);
    float2 uv0  = gridUV[vid];                       // 图像 uv(0..1)，纹理就在此处采样
    float  d    = dispTex.sample(s, uv0).r;
    // 前景整体放大：把几何按 fgScale 绕主体质心放大（纹理仍按 uv0 采样 ⇒ 人物变大而非平移），
    // 放大后的剪影盖住身后那条去遮挡过渡带。背景/中间层 fgScale=1 ⇒ 此式恒等、不受影响。
    float2 base = u.fgCenter + (uv0 - u.fgCenter) * u.fgScale;
    float2 off  = u.offset * u.parallaxAmp * (1.0 - u.flatten) * u.layerFactor;
    float2 uvW  = base + off * (d - u.depthPivot);   // 前向 warp：屏幕位置按视差位移
    // uv→NDC，并乘 viewScale 做 cover（保持图像比例，不拉伸；溢出部分裁掉）。
    float2 ndc  = (uvW * 2.0 - 1.0) * float2(1.0, -1.0) * u.viewScale;
    VOut o;
    o.pos = float4(ndc, 0.0, 1.0);
    o.uv  = uv0;
    return o;
}

fragment float4 mesh_fragment(VOut in [[stage_in]],
                              texture2d<float> colorTex [[texture(0)]],
                              texture2d<float> dispTex  [[texture(1)]],
                              constant MeshUniforms& u  [[buffer(1)]]) {
    constexpr sampler s(address::clamp_to_edge, filter::linear);
    float4 c = colorTex.sample(s, in.uv);
    bool fg = u.fgFlag > 0.5;

    if (u.debugMode == 1) { float d = dispTex.sample(s, in.uv).r; return float4(d, d, d, 1.0); }
    if (u.debugMode == 2) { return fg ? float4(c.a, c.a, c.a, 1.0) : float4(0.0, 0.0, 0.0, 1.0); }
    if (u.debugMode == 3) { return fg ? float4(0.0)               : float4(c.rgb, 1.0); }

    // 前景剪影抗锯齿：4×MSAA 只抗「几何切口」边，抗不了「matte alpha 阈值」这条真正的剪影
    // （前景四边形内 4 个子样本 alpha 几乎一致 ⇒ MSAA 对剪影零作用）。
    // 改用屏幕空间导数 fwidth(c.a) 自适应阈宽：无论 fgScale 放大与否，剪影恒得 ~1px 软 coverage ⇒ 消锯齿。
    float aa = max(fwidth(c.a) * 0.7, 0.0015);
    float a  = fg ? smoothstep(0.5 - aa, 0.5 + aa, c.a) : 1.0;
    return float4(c.rgb * a, a);                 // 预乘，配合 over 混合 (one / 1-srcAlpha)
}

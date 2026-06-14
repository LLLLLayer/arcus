#include <metal_stdlib>
using namespace metal;

// 与 Swift 端 GaussianSplat / GaussianUniforms 内存布局严格对应。
struct GSplat {
    float px, py, pz;          // 位置
    float c0, c1, c2, c3, c4, c5;  // cov 上三角 [[c0 c1 c2],[c1 c3 c4],[c2 c4 c5]]
    float r, g, b;             // 颜色
    float opacity;             // 0…1
};

struct GaussianUniforms {
    float4x4 viewProj;   // 0    proj·view（投影 splat 中心）
    float4x4 view;       // 64   world→camera
    float2 viewportPx;   // 128  视口像素尺寸
    float  g;            // 136  有效 1/tan(fovY/2)（含推轨 FOV 补偿）
    float  aspect;       // 140  图像宽高比
    float  nearZ;        // 144  近裁剪
    float  lowpass;      // 148  2D 协方差膨胀（像素²）
    float  maxAlpha;     // 152  alpha 上限
    float  _pad;         // 156  → stride 160
};

struct GVOut {
    float4 pos [[position]];
    float2 d;            // 距中心的合成像素偏移
    float3 conic;        // 2D 逆协方差
    float3 color;
    float  opacity;
    float  viewz;        // 相机空间深度（景深用）
};

// MRT：color(预乘 over) + depth((z·α, α) over，用于解算每像素期望深度做景深)
struct GFragOut {
    float4 color [[color(0)]];
    float4 depth [[color(1)]];
};

vertex GVOut gs_vertex(uint vid [[vertex_id]],
                       uint iid [[instance_id]],
                       const device GSplat* splats [[buffer(0)]],
                       const device uint* order    [[buffer(1)]],
                       constant GaussianUniforms& u [[buffer(2)]]) {
    GVOut o;
    o.d = float2(0); o.conic = float3(1, 0, 1); o.color = float3(0); o.opacity = 0; o.viewz = 0;

    GSplat s = splats[order[iid]];
    float3 P = float3(s.px, s.py, s.pz);
    float3 pc = (u.view * float4(P, 1.0)).xyz;
    if (pc.z < u.nearZ) { o.pos = float4(2, 2, 2, 1); return o; }
    o.viewz = pc.z;

    float3x3 M = float3x3(float3(s.c0, s.c1, s.c2),
                          float3(s.c1, s.c3, s.c4),
                          float3(s.c2, s.c4, s.c5));
    float3x3 Rv = float3x3(u.view[0].xyz, u.view[1].xyz, u.view[2].xyz);
    float3x3 Vc = Rv * M * transpose(Rv);

    float invz = 1.0 / pc.z;
    float ga = u.g / u.aspect;
    float3 J0 = float3(ga * invz, 0.0, -ga * pc.x * invz * invz);
    float3 J1 = float3(0.0, u.g * invz, -u.g * pc.y * invz * invz);
    float3 VcJ0 = Vc * J0;
    float3 VcJ1 = Vc * J1;
    float a_ndc = dot(J0, VcJ0);
    float b_ndc = dot(J0, VcJ1);
    float c_ndc = dot(J1, VcJ1);

    float sx = u.viewportPx.x * 0.5, sy = u.viewportPx.y * 0.5;
    float a = a_ndc * sx * sx + u.lowpass;
    float b = b_ndc * sx * sy;
    float c = c_ndc * sy * sy + u.lowpass;

    // 各向异性钳制：限制屏幕空间长短轴比（特征值比 ≤ kMaxRatio）。薄片高斯在斜视角/画面边缘经
    // 透视雅可比投影会被拉成极扁的 2D 锥面 ⇒ 渲染成穿出剪影的「针状」拉丝。这里抬高次特征值，
    // 在保留特征向量(朝向)的前提下把针压成有界椭圆，从根上消除拉丝，同时允许合理的透视收缩。
    {
        float mid = 0.5 * (a + c);
        float r = sqrt(max(0.0, mid * mid - (a * c - b * b)));   // (λ1-λ2)/2
        float l1 = mid + r;                                      // 主特征值
        float l2 = mid - r;                                      // 次特征值
        const float kMaxRatio = 9.0;                             // 轴长比² 上限 ⇒ 最长 3:1
        float l2min = l1 / kMaxRatio;
        if (l2 < l2min && r > 1e-6) {
            float midN = 0.5 * (l1 + l2min);
            float scale = (0.5 * (l1 - l2min)) / r;             // 仅缩放偏离量 ⇒ 保朝向、抬次轴
            a = midN + (a - mid) * scale;
            c = midN + (c - mid) * scale;
            b = b * scale;
        }
    }

    float det = a * c - b * b;
    if (det <= 1e-9) { o.pos = float4(2, 2, 2, 1); return o; }
    float idet = 1.0 / det;
    o.conic = float3(c * idet, -b * idet, a * idet);

    float mid = 0.5 * (a + c);
    float lam = mid + sqrt(max(0.01, mid * mid - det));
    float radius = ceil(3.0 * sqrt(lam));

    float4 clip = u.viewProj * float4(P, 1.0);
    float2 centerNdc = clip.xy / clip.w;
    float2 centerPx = (centerNdc * 0.5 + 0.5) * u.viewportPx;

    float2 corners[6] = { float2(-1, -1), float2(1, -1), float2(-1, 1),
                          float2(-1, 1), float2(1, -1), float2(1, 1) };
    float2 offPx = corners[vid] * radius;
    float2 vpx = centerPx + offPx;
    float2 vndc = (vpx / u.viewportPx) * 2.0 - 1.0;

    o.pos = float4(vndc, 0.0, 1.0);
    o.d = offPx;
    o.color = float3(s.r, s.g, s.b);
    o.opacity = s.opacity;
    return o;
}

fragment GFragOut gs_fragment(GVOut in [[stage_in]],
                              constant GaussianUniforms& u [[buffer(2)]]) {
    float dx = in.d.x, dy = in.d.y;
    float power = -0.5 * (in.conic.x * dx * dx + 2.0 * in.conic.y * dx * dy + in.conic.z * dy * dy);
    if (power > 0.0) discard_fragment();
    float alpha = min(u.maxAlpha, in.opacity * exp(power));
    if (alpha < 0.0039) discard_fragment();
    GFragOut o;
    o.color = float4(in.color * alpha, alpha);                 // 预乘
    o.depth = float4(in.viewz * alpha, alpha, 0.0, alpha);     // (z·α, α) over ⇒ 期望深度=r/g
    return o;
}

// ---- 景深 + 合成 pass：离屏 splat → drawable（透明处保留 alpha=0，露出 SwiftUI 云状背景）----

struct DOFUniforms {
    float2 texel;        // 1/视口
    float  focusDepth;   // 相机空间对焦距离
    float  aperture;     // 2.8/fNumber
    float  maxRadius;    // 最大模糊半径(px)
    float  blurScale;    // 0=关景深(直通)
    float  _p0, _p1;     // 对齐到 32 字节
};

vertex float4 gs_dof_vertex(uint vid [[vertex_id]]) {
    float2 p[3] = { float2(-1, -1), float2(3, -1), float2(-1, 3) };  // 全屏三角
    return float4(p[vid], 0.0, 1.0);
}

fragment float4 gs_dof_fragment(float4 pos [[position]],
                                constant DOFUniforms& u [[buffer(0)]],
                                texture2d<float> colorT [[texture(0)]],
                                texture2d<float> depthT [[texture(1)]]) {
    constexpr sampler s(address::clamp_to_edge, filter::linear);
    float2 uv = pos.xy * u.texel;
    float4 c = colorT.sample(s, uv);
    float4 da = depthT.sample(s, uv);
    float cov = da.y;
    if (cov < 1e-4) return float4(0.0);                 // 无 splat ⇒ 透明，露出背景
    float depth = da.x / cov;

    float coc = fabs(depth - u.focusDepth) / max(depth, 1e-3);
    float radius = clamp(coc * u.maxRadius * u.aperture, 0.0, u.maxRadius) * u.blurScale;
    if (radius < 0.6) return c;                          // 焦内：直通(锐利)

    // 16-tap 双环模糊（采样预乘色，按覆盖加权）。
    const float2 taps[16] = {
        float2( 1, 0), float2( 0.92, 0.38), float2( 0.71, 0.71), float2( 0.38, 0.92),
        float2( 0, 1), float2(-0.38, 0.92), float2(-0.71, 0.71), float2(-0.92, 0.38),
        float2(-1, 0), float2(-0.92,-0.38), float2(-0.71,-0.71), float2(-0.38,-0.92),
        float2( 0,-1), float2( 0.38,-0.92), float2( 0.71,-0.71), float2( 0.92,-0.38)
    };
    float4 sum = c * 2.0;
    float wsum = 2.0;
    for (int i = 0; i < 16; i++) {
        float ring = (i & 1) == 0 ? 1.0 : 0.62;
        float2 o = taps[i] * radius * ring * u.texel;
        float4 sc = colorT.sample(s, uv + o);
        float4 sd = depthT.sample(s, uv + o);
        float sDepth = sd.y > 1e-4 ? sd.x / sd.y : depth;
        // 遮挡感知：样本明显比中心更近(前景) ⇒ 降权，避免前景渗入背景模糊带。
        float w = (sDepth < depth - 0.02 * depth) ? 0.35 : 1.0;
        sum += sc * w;
        wsum += w;
    }
    return sum / wsum;
}

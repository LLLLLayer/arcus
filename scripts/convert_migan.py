# MI-GAN ONNX -> Core ML (FP16) 转换器 + 自验证。
# 产物：Arcus/Resources/MiGAN.mlpackage（~14MB，已被 .gitignore 排除，不入库）。
#
# 用法（需要 Python 3.12 + torch + coremltools；torch 不支持 3.13）：
#   uv venv --python 3.12 /tmp/migan-venv
#   uv pip install --python /tmp/migan-venv/bin/python torch coremltools numpy onnx onnx2torch
#   curl -sL https://huggingface.co/andraniksargsyan/migan/resolve/main/migan.onnx -o /tmp/migan.onnx
#   /tmp/migan-venv/bin/python scripts/convert_migan.py
#   cp -R /tmp/MiGAN.mlpackage Arcus/Resources/
#
# 模型 I/O（固定 512×512）：image[1,3,512,512] f32 [0,255] + mask[1,1,512,512] f32(255=已知/0=洞)
#                          -> result[1,3,512,512] f32 [0,255]（已合成：已知区保留、洞内为生成内容）

import onnx, torch, numpy as np, coremltools as ct
from onnx2torch import convert

ONNX = "/tmp/migan.onnx"
OUT = "/tmp/MiGAN.mlpackage"
S = 512

m = onnx.load(ONNX)
tm = convert(m).eval()

# image + mask, fixed 512x512, float32 in [0,255]; mask 255=known, 0=hole (MI-GAN convention)
ex_img = (torch.rand(1, 3, S, S) * 255.0)
ex_mask = (torch.rand(1, 1, S, S) > 0.5).float() * 255.0

with torch.no_grad():
    out = tm(ex_img, ex_mask)
if isinstance(out, (list, tuple)):
    out = out[0]
print("torch out shape:", tuple(out.shape), "range", float(out.min()), float(out.max()))

traced = torch.jit.trace(tm, (ex_img, ex_mask), check_trace=False)
mlmodel = ct.convert(
    traced,
    inputs=[ct.TensorType(name="image", shape=(1, 3, S, S), dtype=np.float32),
            ct.TensorType(name="mask", shape=(1, 1, S, S), dtype=np.float32)],
    outputs=[ct.TensorType(name="result", dtype=np.float32)],
    compute_precision=ct.precision.FLOAT16,
    minimum_deployment_target=ct.target.iOS16,
    convert_to="mlprogram",
)
mlmodel.save(OUT)
spec = mlmodel.get_spec()
in_names = [f.name for f in spec.description.input]
out_names = [f.name for f in spec.description.output]
print("SAVED", OUT)
print("CoreML inputs:", in_names)
print("CoreML outputs:", out_names)

# ---- VALIDATION on a real synthetic hole ----
# build a structured test image (diagonal color gradient + stripes) so we can SEE if the hole is filled
yy, xx = np.meshgrid(np.arange(S), np.arange(S), indexing="ij")
img = np.zeros((3, S, S), np.float32)
img[0] = (xx / S * 255)
img[1] = (yy / S * 255)
img[2] = (((xx // 16 + yy // 16) % 2) * 200 + 30)
mask = np.full((1, S, S), 255.0, np.float32)        # 255 = known
mask[:, 200:312, 200:312] = 0                        # center hole
img_in = img.copy()
img_in[:, 200:312, 200:312] = 0                      # zero the hole in input (typical)

import coremltools.models as ctm
pred = mlmodel.predict({"image": img[None], "mask": mask[None]})
res = np.array(list(pred.values())[0]).reshape(3, S, S)
print("coreml result range", float(res.min()), float(res.max()))

# torch reference on same input
with torch.no_grad():
    tref = tm(torch.from_numpy(img[None]).float(), torch.from_numpy(mask[None]).float())
if isinstance(tref, (list, tuple)): tref = tref[0]
tref = tref.numpy().reshape(3, S, S)

hole = mask[0] == 0
known = mask[0] == 255
# fidelity torch vs coreml
diff = np.abs(res - tref)
print(f"torch-vs-coreml maxdiff={diff.max():.2f} meandiff={diff.mean():.3f}")
# known region preserved? (model should composite -> ~= original img)
known_err = np.abs(res[:, known] - img[:, known]).mean()
print(f"known-region mean|result-original| = {known_err:.2f}  (small => model composites/preserves known)")
# hole filled? (result in hole should be non-trivial, not all zero/constant)
hole_std = res[:, hole].std()
print(f"hole-region std = {hole_std:.2f}  (>5 => content generated, not blank)")
print("VALIDATION:", "PASS" if (diff.max() < 8 and hole_std > 5) else "CHECK")

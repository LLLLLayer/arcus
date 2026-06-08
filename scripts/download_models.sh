#!/usr/bin/env bash
# 下载端侧模型到 App 资源目录（未纳入 git）：
#   1) Depth Anything V2 Small (单目深度, ~48MB)
#   2) LaMa-Dilated (学习型去遮挡补全, ~38MB)
# 首次构建前运行本脚本即可获得最佳画质（背景由 LaMa 补全，而非 push-pull 扩散糊）。
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEST="$ROOT/Arcus/Resources"
mkdir -p "$DEST"

have_hf() { command -v huggingface-cli >/dev/null 2>&1; }
have_git_lfs() { command -v git >/dev/null 2>&1 && command -v git-lfs >/dev/null 2>&1; }

# download_pkg <repo> <subpath-in-repo> <final-name-in-Resources>
download_pkg() {
  local repo="$1" sub="$2" name="$3"
  if [ -d "$DEST/$name" ]; then
    echo "✅ 已存在：$name"
    return 0
  fi
  local tmp; tmp="$(mktemp -d)"
  echo "⬇️  从 huggingface.co/$repo 下载 $name ..."
  if have_hf; then
    huggingface-cli download "$repo" --include "$sub/*" --local-dir "$tmp" >/dev/null
  elif have_git_lfs; then
    git clone --depth 1 "https://huggingface.co/$repo" "$tmp/repo" >/dev/null 2>&1
    ( cd "$tmp/repo" && git lfs pull >/dev/null 2>&1 || true )
    mkdir -p "$tmp/$(dirname "$sub")"
    cp -R "$tmp/repo/$sub" "$tmp/$sub"
  else
    echo "❌ 需要 huggingface-cli 或 git(+git-lfs)。安装：pip install -U \"huggingface_hub[cli]\" 或 brew install git-lfs" >&2
    rm -rf "$tmp"; return 1
  fi
  if [ ! -d "$tmp/$sub" ]; then
    echo "❌ 下载后未找到 $sub" >&2; rm -rf "$tmp"; return 1
  fi
  cp -R "$tmp/$sub" "$DEST/$name"
  rm -rf "$tmp"
  local size; size="$(du -sm "$DEST/$name" 2>/dev/null | awk '{print $1}')"
  echo "✅ 完成：$name (~${size}MB)"
}

download_pkg "apple/coreml-depth-anything-v2-small" "DepthAnythingV2SmallF16.mlpackage" "DepthAnythingV2SmallF16.mlpackage"
download_pkg "Dadm-n/lama-dilated-coreml"          "Resources/LaMa.mlpackage"          "LaMa.mlpackage"

echo ""
echo "🎉 模型就绪于 $DEST"
echo "   用 Xcode 打开 Arcus.xcodeproj 构建，Xcode 会自动把 .mlpackage 编译进 App。"
echo "   深度缺失→伪深度兜底；LaMa 缺失→push-pull 兜底（都不会崩，但画质下降）。"

# ── MI-GAN（AI 补全，可选）──────────────────────────────────────────────
# MI-GAN 需本地转换（非现成 Core ML）。见 scripts/convert_migan.py 顶部说明：
#   下载 migan.onnx → onnx2torch + coremltools FP16 → Arcus/Resources/MiGAN.mlpackage
# 缺失时「AI 补全」会自动回退 PatchMatch（不崩）。

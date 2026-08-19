# matte —— 白底视频 → 带 alpha 的 HEVC .mov

素材管线的抠像环节。用 macOS 自带的 Vision 人像分割生成遮罩，
输出 AVFoundation 可直接透明合成的 HEVC-with-alpha `.mov`。

## 为什么不用 colorkey

先试过 `ffmpeg colorkey`，失败了，而且失败方式很有欺骗性：背景颜色方差只有 8.6
（接近纯色，看起来完全适合 colorkey），但抠出来**人脸的额头、鼻梁、眼下会出现空洞**
—— 那些皮肤高光区域的颜色与白背景太接近，而 colorkey 只比颜色、不认语义。

Vision 的 `VNGeneratePersonSegmentationRequest` 是语义分割，知道什么是人，不会打洞。

## 为什么不用 MatAnyone2 / RVM / rembg

不需要。Vision 是系统框架，零依赖、零安装、跑 ANE。
实测 604×1080 / 145 帧耗时 **8.6 秒**。

## 关键参数

`kVTCompressionPropertyKey_TargetQualityForAlpha = 1.0`

**必须是 1.0，不能是 0.1。** 技术调研初稿给的 ffmpeg 命令写的是 `-alpha_quality 0.1`，
经一手核查 Apple 文档纠正：该值域为 0–1 且 **1 接近无损**。
0.1 会让发丝边缘出现锯齿、半透明区块状、边缘暗环 —— 对一个全屏常驻的人像是致命的。

## 用法

```bash
swiftc -O -framework AVFoundation -framework Vision -framework CoreImage \
       -framework VideoToolbox matte.swift -o matte
./matte input.mp4 output.mov

# 验证产物确实带 alpha（唯一权威的检查方式）
swiftc -O checkalpha.swift -o checkalpha
./checkalpha output.mov
```

`ffprobe` 在这里会骗人：它对 HEVC-alpha 报 `pix_fmt=yuv420p`，因为 alpha 走的是
**辅助图层**（auxiliary picture layer），不在主层的像素格式里。
只有 AVFoundation 的 `.containsAlphaChannel` 说了算。

## 已知待改进

Vision 的遮罩分辨率低于原帧，放大插值后边缘过渡区会混入背景色，
在深色背景上表现为头发外围一圈暗边。修法是对遮罩做轻微腐蚀 + 边缘去溢色。

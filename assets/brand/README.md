# akari 品牌资源

## 标志

一弯暖色月牙，背后跟着一道冷色蓝紫的回声。

意象取自项目名 **akari（明かり）**——一盏留着的灯。冷暖对比不是装饰：
产品本身就是「深色桌面上的一个温暖存在」，而形象素材用的正是冷色轮廓光
（见 `docs/avatar-states.md` §2.1），标志里的暖光与之呼应。

## 为什么是全幅方形、不带圆角

macOS 会自己给应用磁贴做圆角。素材若已经带了圆角，会被**圆两次**，
在四角留下一圈浅色的接缝。

所以 `akari-logo-2048.png` 是**边到边铺满**的正方形：深色背景一直画到四个角。
实测四角与四边的最亮值为 39（近黑），没有任何浅边或投影。

生成时踩过这个坑：模型默认会把图标画成「一块带圆角和投影的磁贴浮在浅色底上」。
试过事后把浅色底填掉，失败了 —— 方块外有一圈**投影过渡带**，
按亮度阈值找边界会停在阴影上，于是拿浅灰去填充，四角反而更脏。
正确做法是让模型直接出全幅版（明确否定 rounded corners / border / margin / shadow / surround）。

## 为什么选了月牙最粗的那一版

三版候选的差别只在月牙大小。判据不是大图好不好看，而是**16px 下还剩什么** ——
把三版缩到 128 / 64 / 32 / 16px 再放大回来比对，月牙最粗的那版在 16px
仍然笔画完整，另外两版开始变细发虚。菜单栏和 Finder 列表就在这个尺寸。

## 文件

| 文件 | 用途 |
| --- | --- |
| `akari-logo-2048.png` | 母版，全幅方形 |
| `akari-logo-{1024,512,256,128}.png` | 常用单尺寸 |
| `AppIcon.icns` | macOS 应用图标，含 16→1024 十档（`make app-bundle` 会拷进包） |

重新生成 `.icns`：

```bash
ICON=/tmp/AkariIcon.iconset && rm -rf $ICON && mkdir -p $ICON
for pair in "16 16x16" "32 16x16@2x" "32 32x32" "64 32x32@2x" "128 128x128" \
            "256 128x128@2x" "256 256x256" "512 256x256@2x" "512 512x512" "1024 512x512@2x"; do
  sips -s format png -z ${pair%% *} ${pair%% *} assets/brand/akari-logo-2048.png \
       --out "$ICON/icon_${pair##* }.png" >/dev/null
done
iconutil -c icns $ICON -o assets/brand/AppIcon.icns
```

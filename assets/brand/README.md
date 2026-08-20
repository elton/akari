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

## 配套壁纸

`WallpaperCatalog`（`app/Sources/AkariApp/Wallpaper.swift`）按这套约定找图，
目录是 `assets/brand/wallpaper/`（`make app-bundle` 会拷进 `Contents/Resources/wallpaper`）：

| 文件名 | 用途 |
| --- | --- |
| `akari-wallpaper-light.{heic,png,jpg}` | 浅色外观 |
| `akari-wallpaper-dark.{heic,png,jpg}` | 深色外观 |
| `akari-wallpaper.{heic,png,jpg}` | 两种外观通用（只放一张时用这个） |

精确命中优先；都没有的时候退回按「文件名以 `akari-wallpaper` 开头 + 像素数最接近母版」
挑一张。母版是 **5120×2880**（5K 屏物理像素，16:9，sRGB）；比它小会照用，
但会在日志里说一声「放大后会发虚」。`.heic` 排在最前 —— 同一张图约 1/3 的字节数，
而且是硬件解码。

**这些文件不进 git**（见 `.gitignore` 里那段）：一张 5K PNG 就有 16MB，
和这个仓库不收 `*.mov` 是同一条理由。缺图不致命 —— `WallpaperController` 会报
「找不到配套壁纸」，桌面原样留给用户。要用就把图放进上面那个目录，
或者用 `AKARI_WALLPAPER_DIR` 指到别处。


---

## 配套壁纸

`wallpaper/akari-wallpaper-5120x2880.heic` —— 深夜湖面与一弯暖月。
构图刻意把视觉重心压在左侧与上方，**右下角留空给形象**
（默认锚点 bottomTrailing，在 2560×1440 上占 594×792）。天上那弯月与 app 图标是同一个母题。

### 为什么是 HEIC，为什么随代码走

它和图标是同一类资产：一次性的、不可再生成的，所以**必须随代码交付** ——
一份没有它的检出会构建出一个「声称有配套壁纸、实际找不到素材」的 app。

HEIC 让这件事没有代价：同一张图 PNG 15.3 MB、HEIC 0.9 MB（PSNR 46 dB，视觉无损），
比 `AppIcon.icns` 还小。质量档取 85 —— 70 只省 0.27 MB 却掉 0.37 dB，
95 要大 4.3 倍才多 1.28 dB。

**只入库这一张。** `WallpaperCatalog` 挑的是能盖住 5120×2880 的那个，
其余尺寸在任何显示器上都轮不到，留着只会让人以为它们有用。

### `.gitignore` 里的一个陷阱

排除 PNG 母版要写 `assets/brand/wallpaper/*.png`，**不能写 `assets/brand/wallpaper/`**。

排除一个**目录**会让目录内所有 `!` 否定规则失效 —— git 不会递归进被排除的目录，
否定规则根本没有机会匹配，而且**不报任何错**。这个坑真实发生过：
`!assets/brand/wallpaper/*.heic` 写了，看起来没问题，壁纸却一直没进仓库，
直到一次外部代码审查指出「配套静态壁纸无法随代码交付」才暴露。

### 重新生成

母版 PNG 不入库。要出别的尺寸，从 HEIC 缩即可；要重制原图，
用 Nano Banana 2、16:9、4k，提示词的要点是：深夜湖面、左上一弯暖月、
**右侧三分之一保持空旷无细节**、低调冷色、胶片颗粒、无人无建筑。

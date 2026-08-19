# retime —— 调整循环片段的动作速度

## 为什么需要它

Seedance 对"慢一点""幅度小一点"这类指令的服从度很差 —— 提示词里写
`gentle` / `subtle` / `barely perceptible`，出来的动作幅度仍可能偏大偏快。
靠反复重生成来碰运气，每次 2,640–4,740 积分，且不可控。

改在后期调，速度就从**生成时的赌博**变成**可无级微调的旋钮**，且零成本。

## 附带收益：补帧

Seedance 输出固定 24fps，对常驻桌面的微动作略显顿挫。
`minterpolate` 顺带把帧率补到 30fps（或 60fps），运动更顺滑。

## 首尾闭合不受影响

放慢会不会破坏 `keyframes.start == keyframes.end` 得来的无缝循环？
实测不会：放慢 1.5 倍后首尾帧平均像素差 1.31 → **1.44**，仍远低于阈值 4。

## 用法

```bash
./retime.sh listening.mp4 listening-slow.mp4 1.5 30
```

抠像应在 retime **之后**执行，避免对插值出来的中间帧重复做分割。

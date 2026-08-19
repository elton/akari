#!/usr/bin/env bash
# akari 素材工具：调整循环片段的动作速度与帧率
#
# 生成模型对"慢一点"这类指令的服从度很差，反复重生成既贵又不可控。
# 改在后期调：速度变成一个可以无级微调的旋钮，且不花积分。
# 实测放慢后首尾闭合仍然成立（1.31 → 1.44，阈值 4），无缝循环不受影响。
#
# 用法: retime.sh <输入.mp4> <输出.mp4> [倍率] [目标帧率]
#   倍率 >1 变慢（1.5 = 慢 1.5 倍，时长 ×1.5）
#
# 例: ./retime.sh listening.mp4 listening-slow.mp4 1.5 30

set -euo pipefail
IN="$1"; OUT="$2"; FACTOR="${3:-1.5}"; FPS="${4:-30}"

ffmpeg -v error -i "$IN" \
  -vf "setpts=${FACTOR}*PTS,minterpolate=fps=${FPS}:mi_mode=mci:mc_mode=aobmc:vsbmc=1" \
  -an "$OUT" -y

echo "$IN → $OUT   慢 ${FACTOR}×   ${FPS}fps"
ffprobe -v error -show_entries format=duration -of csv=p=0 "$OUT" | xargs printf "时长 %.2fs\n"

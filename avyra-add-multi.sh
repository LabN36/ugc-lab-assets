#!/usr/bin/env bash
# Add InfiniteTalk-Multi (2-3 speaker model, ~2.4GB) to the volume. Runs ON a CPU pod AFTER finalize is done.
set -uo pipefail
V=/workspace; M=$V/ComfyUI/models/diffusion_models; mkdir -p "$M"
URL=https://huggingface.co/Kijai/WanVideo_comfy/resolve/main/InfiniteTalk/Wan2_1-InfiniteTalk-Multi_fp16.safetensors
OUT=$M/Wan2_1-InfiniteTalk-Multi_fp16.safetensors
echo "== add Multi  [$(date -u +%H:%M:%S)]"
for i in $(seq 1 10); do
  curl -fL -C - --retry 6 --retry-delay 5 --retry-all-errors -o "$OUT" "$URL" 2>/dev/null
  sz=$(stat -c %s "$OUT" 2>/dev/null || echo 0); [ "$sz" -gt 2000000000 ] && { echo "ok $OUT ($sz bytes)"; break; }
  echo "  attempt $i: $sz bytes — resuming"; sleep 10
done
[ "$(stat -c %s "$OUT" 2>/dev/null || echo 0)" -gt 2000000000 ] || { echo "ADD_MULTI_FAIL"; exit 3; }
printf 'it     %10s  diffusion_models/Wan2_1-InfiniteTalk-Multi_fp16.safetensors\n' "$(numfmt --to=iec "$(stat -c %s "$OUT")")" >> "$V/MANIFEST.txt"
# also close the loop on wav2vec2: verify by BYTES (base model ~190MB) and add its manifest line
W=$(find /workspace/ComfyUI/models -type f -name wav2vec2-chinese-base_fp16.safetensors | head -n1)
if [ -n "$W" ] && [ "$(stat -c %s "$W")" -gt 150000000 ]; then
  grep -q wav2vec2-chinese-base "$V/MANIFEST.txt" 2>/dev/null || printf 'it     %10s  %s\n' "$(numfmt --to=iec "$(stat -c %s "$W")")" "${W#/workspace/ComfyUI/models/}" >> "$V/MANIFEST.txt"
  echo "wav2vec2 ok ($(stat -c %s "$W") bytes) — manifest line present"
else echo "WAV2VEC2_BAD_OR_MISSING"; fi
echo "== final manifest =="; cat "$V/MANIFEST.txt"; df -h /workspace | tail -1
echo "ADD_MULTI_OK"; runpodctl remove pod "$RUNPOD_POD_ID" 2>/dev/null || true

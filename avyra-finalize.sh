#!/usr/bin/env bash
# FINALIZE the Avyra volume from a crashed populate: uses what's already there, no re-download.
# State on entry: env/{venv,comfyui}.tgz OK; opt/models-baked has intact LC files (+ truncated IT/shared
# partials from the failed extract); it_models.tgz complete. Volume resized 110->150GB (peak ~129GB).
set -uo pipefail
V=/workspace; M=$V/ComfyUI/models; R=https://ghcr.io/v2/labn36/avyra-talk
LC_MODELS=sha256:6365ac0b8d92a86f97bac2e35045b098f5640dfd8e7a2f7f667b6b9b36b0b6b3
ESR=https://github.com/xinntao/Real-ESRGAN/releases/download/v0.2.1/RealESRGAN_x2plus.pth
say(){ printf '\n== %s  [%s]\n' "$*" "$(date -u +%H:%M:%S)"; }
tok(){ curl -fsSL "https://ghcr.io/token?scope=repository:labn36/avyra-talk:pull" | python3 -c 'import json,sys;print(json.load(sys.stdin)["token"])'; }
dl(){ local dg=$1 out=$2 t want have; for i in $(seq 1 15); do t=$(tok) || { sleep 10; continue; }
    want=$(curl -sIL -H "Authorization: Bearer $t" "$R/blobs/$dg" | tr -d '\r' | grep -i '^content-length:' | tail -1 | tr -dc 0-9)
    curl -fL -C - --retry 6 --retry-delay 5 --retry-all-errors --speed-time 60 --speed-limit 100000 -H "Authorization: Bearer $t" -o "$out" "$R/blobs/$dg" 2>/dev/null
    have=$(stat -c %s "$out" 2>/dev/null || echo 0)
    { [ -n "$want" ] && [ "$have" = "$want" ]; } && { echo "  ok $out ($have)"; return 0; }
    echo "  attempt $i: $have/${want:-?} — resuming"; sleep 10; done; return 1; }
# minimum byte sizes: anything smaller = truncated
declare -A MIN=( [LongCat-Avatar-15_bf16.safetensors]=29000000000 [wan2.1_i2v_480p_14B_fp16.safetensors]=27000000000
 [umt5-xxl-enc-bf16.safetensors]=10000000000 [Wan2_1-InfiniTetalk-Single_fp16.safetensors]=2000000000
 [whisper_large_v3_encoder_fp16.safetensors]=1400000000 [clip_vision_h.safetensors]=1100000000
 [LongCat-Avatar-15_dmd_distill_lora_rank128_bf16.safetensors]=1000000000 [lightx2v_I2V_14B_480p_cfg_step_distill_rank64_bf16.safetensors]=500000000
 [wav2vec2-chinese-base_fp16.safetensors]=150000000 [Wan2_1_VAE_bf16.safetensors]=200000000 [RealESRGAN_x2plus.pth]=60000000 )
bad(){ local f; f=$(find "$M" -type f -name "$1" | head -n1); [ -z "$f" ] && return 0; [ "$(stat -c %s "$f")" -lt "${MIN[$1]}" ]; }

say "state"; df -h "$V" | tail -1; du -sh "$V/opt" "$V/it_models.tgz" "$V/env" "$M" 2>/dev/null
[ -s "$V/it_models.tgz" ] || { echo "!! it_models.tgz missing — cannot finalize"; exit 3; }
say "1/5 place intact LC files (rename, zero space)"
rm -rf "$M"; mkdir -p "$V/ComfyUI"
if [ -d "$V/opt/models-baked" ]; then mv "$V/opt/models-baked" "$M"; else mkdir -p "$M"; fi
say "2/5 extract IT archive straight into models/ (rewrites truncated shared files)"
tar -xzf "$V/it_models.tgz" --strip-components=2 -C "$M" --no-same-owner --overwrite || { echo "!! IT extract failed"; exit 3; }
say "3/5 size-check; re-extract any short IT/shared file from the archive"
for n in wan2.1_i2v_480p_14B_fp16.safetensors Wan2_1-InfiniTetalk-Single_fp16.safetensors clip_vision_h.safetensors lightx2v_I2V_14B_480p_cfg_step_distill_rank64_bf16.safetensors wav2vec2-chinese-base_fp16.safetensors umt5-xxl-enc-bf16.safetensors Wan2_1_VAE_bf16.safetensors; do
  if bad "$n"; then echo "  short: $n — re-extracting"; tar -xzf "$V/it_models.tgz" --strip-components=2 -C "$M" --no-same-owner --overwrite --wildcards "*/$n" || exit 3; fi
done
rm -f "$V/it_models.tgz"; rm -rf "$V/opt"
lcbad=0; for n in LongCat-Avatar-15_bf16.safetensors LongCat-Avatar-15_dmd_distill_lora_rank128_bf16.safetensors whisper_large_v3_encoder_fp16.safetensors; do bad "$n" && { echo "  short: $n (LC)"; lcbad=1; }; done
if [ "$lcbad" = 1 ]; then say "   LC files damaged — re-downloading LC blob (36GB, resumable)"
  dl "$LC_MODELS" "$V/lc_models.tgz" && tar -xzf "$V/lc_models.tgz" --strip-components=2 -C "$M" --no-same-owner --overwrite && rm -f "$V/lc_models.tgz" || exit 3; fi
say "4/5 RealESRGAN"; mkdir -p "$M/upscale_models"
bad RealESRGAN_x2plus.pth && rm -f "$M/upscale_models/RealESRGAN_x2plus.pth"
[ -s "$M/upscale_models/RealESRGAN_x2plus.pth" ] || curl -fL --retry 6 --retry-all-errors "$ESR" -o "$M/upscale_models/RealESRGAN_x2plus.pth" || exit 3
say "5/5 verify manifest (presence + minimum size)"; missing=0; : > "$V/MANIFEST.txt"
while read -r eng sub base; do case "$eng" in ''|\#*) continue;; esac
  hit=$(find "$M" -type f -name "$base" | head -n1)
  if [ -z "$hit" ] || bad "$base"; then echo "BAD/MISSING: $base"; missing=$((missing+1))
  else printf '%-6s %10s  %s\n' "$eng" "$(numfmt --to=iec "$(stat -c %s "$hit")")" "${hit#$M/}" | tee -a "$V/MANIFEST.txt"; fi
done < "$V/avyra-manifest.txt"
du -sh "$M" "$V/env" "$V" 2>/dev/null | tee -a "$V/MANIFEST.txt"; df -h "$V" | tail -1
if [ "$missing" -eq 0 ]; then echo "POPULATE_OK"; runpodctl remove pod "$RUNPOD_POD_ID" 2>/dev/null || true
else echo "POPULATE_FAIL missing=$missing"; exit 3; fi

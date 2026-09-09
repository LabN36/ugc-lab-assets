#!/usr/bin/env bash
# avyra-populate-i2v.sh — add Wan 2.2 I2V A14B (kijai fp8 HIGH + LOW) and the Wan 2.2 lightx2v 4-step I2V LoRAs
# to the mounted avyra volume (round B1: product hero / B-roll shots). Same contract as avyra-populate-motion.sh:
# runs ON a CPU (or fallback GPU) pod as the startup command, resumable byte-verified curl, self-removes the pod
# on POPULATE_MOTION_OK, watchdog kills it after WATCHDOG_MIN. Progress: `runpodctl pod logs <id>` or
# /workspace/logs/populate-i2v.log on the volume.
# Already on both volumes and reused: Wan2_1_VAE_bf16, umt5-xxl-enc-bf16, lightx2v_I2V_14B_480p (Wan 2.1) LoRA.
set -uo pipefail
V=/workspace; M="$V/ComfyUI/models"; mkdir -p "$V/logs"; exec > >(tee -a "$V/logs/populate-i2v.log") 2>&1
WATCHDOG_MIN="${WATCHDOG_MIN:-240}"
( sleep "${WATCHDOG_MIN}m"; echo "WATCHDOG: ${WATCHDOG_MIN} min — removing pod"; runpodctl remove pod "$RUNPOD_POD_ID" 2>/dev/null || true ) &
say(){ echo "== $*  [$(date +%H:%M:%S)]"; }
FAILS=0
size_of(){ curl -fsS "https://huggingface.co/api/models/$1/tree/main/$(dirname "$2")" 2>/dev/null \
  | python3 -c 'import sys,json,os; n=sys.argv[1]; print(next((x.get("size",0) for x in json.load(sys.stdin) if os.path.basename(x["path"])==n),0))' "$(basename "$2")" 2>/dev/null || echo 0; }
get(){
  local repo="$1" file="$2" dest="$3" url out want have i
  url="https://huggingface.co/$repo/resolve/main/$file"; out="$M/$dest/$(basename "$file")"; mkdir -p "$M/$dest"
  want="$(size_of "$repo" "$file")"; have="$(stat -c %s "$out" 2>/dev/null || echo 0)"
  if [ "${want:-0}" -gt 0 ] && [ "$have" -eq "$want" ]; then
    echo "skip  $dest/$(basename "$file")  ($have bytes, complete)"
  else
    for i in $(seq 1 12); do
      curl -fL -C - --retry 6 --retry-delay 5 --retry-all-errors --speed-time 60 --speed-limit 100000 -o "$out" "$url" 2>/dev/null
      have="$(stat -c %s "$out" 2>/dev/null || echo 0)"
      if [ "${want:-0}" -gt 0 ]; then [ "$have" -eq "$want" ] && break
      else [ "$have" -gt 1000000 ] && break; fi
      echo "  attempt $i: $have/$want bytes — resuming in 10s"; sleep 10
    done
    have="$(stat -c %s "$out" 2>/dev/null || echo 0)"
    if { [ "${want:-0}" -gt 0 ] && [ "$have" -ne "$want" ]; } || { [ "${want:-0}" -eq 0 ] && [ "$have" -le 1000000 ]; }; then
      echo "FAIL  $dest/$(basename "$file")  $have/$want bytes"; FAILS=$((FAILS+1)); return 1
    fi
    echo "ok    $dest/$(basename "$file")  ($have bytes)"
  fi
  printf 'i2v %10s  %s\n' "$(numfmt --to=iec "$have")" "$dest/$(basename "$file")" >> "$V/MANIFEST-i2v.txt"
}

say "0/3 volume: $(df -h "$V" | tail -1)"
say "1/3 Wan 2.2 I2V A14B fp8 e4m3fn (kijai) HIGH + LOW, 15.0 GB each"
get Kijai/WanVideo_comfy_fp8_scaled "I2V/Wan2_2-I2V-A14B-HIGH_fp8_e4m3fn_scaled_KJ.safetensors" diffusion_models
get Kijai/WanVideo_comfy_fp8_scaled "I2V/Wan2_2-I2V-A14B-LOW_fp8_e4m3fn_scaled_KJ.safetensors" diffusion_models
say "2/3 Wan 2.2 lightx2v 4-step I2V LoRAs (rank 64, 260412), 630 MB each"
get Kijai/WanVideo_comfy "LoRAs/Wan22_Lightx2v/Wan_2_2_I2V_A14B_HIGH_lightx2v_4step_lora_260412_rank_64_fp16.safetensors" loras
get Kijai/WanVideo_comfy "LoRAs/Wan22_Lightx2v/Wan_2_2_I2V_A14B_LOW_lightx2v_4step_lora_260412_rank_64_fp16.safetensors" loras
say "3/3 shared files present? (not downloaded here)"
for f in vae/Wan2_1_VAE_bf16.safetensors text_encoders/umt5-xxl-enc-bf16.safetensors loras/lightx2v_I2V_14B_480p_cfg_step_distill_rank64_bf16.safetensors; do
  [ -s "$M/$f" ] && echo "present $f ($(stat -c %s "$M/$f") bytes)" || { echo "MISSING $f"; FAILS=$((FAILS+1)); }
done
say "manifest + space: $(df -h "$V" | tail -1)"
if [ "$FAILS" -eq 0 ]; then echo "POPULATE_MOTION_OK"; sleep 20; runpodctl remove pod "$RUNPOD_POD_ID" 2>/dev/null || true
else echo "POPULATE_I2V_FAILED ($FAILS)"; sleep 900; fi

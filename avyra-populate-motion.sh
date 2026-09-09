#!/usr/bin/env bash
# avyra-populate-motion.sh — add the MOTION-ROADMAP models to the avyra-models volume.
# Runs ON a CPU pod (no GPU, no IP) as the startup command; read progress via `runpodctl pod logs`
# or /workspace/logs/populate-motion.log. Every file is downloaded straight onto the volume with
# resumable curl and verified against the exact byte size the Hugging Face API reports.
# Self-removes the pod on POPULATE_MOTION_OK; an in-container watchdog kills it after WATCHDOG_MIN.
#
# Layout (same tree the run pods symlink to /opt/ComfyUI/models):
#   diffusion_models/  Wan2.2-Animate fp8 (kijai), SCAIL-2 fp8 (Comfy-Org, core nodes), HuMo 14B fp8 + 1.7B
#   loras/             WanAnimate relight, SCAIL-2 DPO (hands)
#   text_encoders/     whisper_large_v3 encoder (HuMo)          [umt5 already present]
#   detection/         yolov10m + ViTPose-H wholebody (Animate/SCAIL preprocess), NLF (SCAIL-Pose)
#   latentsync/        LatentSync-1.6 unet, whisper tiny, sfd face detector
# Already on the volume and reused: Wan2_1_VAE_bf16, umt5-xxl-enc-bf16, clip_vision_h, lightx2v I2V lora.
set -uo pipefail
V=/workspace; M=$V/ComfyUI/models; mkdir -p "$M" "$V/logs"
exec > >(tee -a "$V/logs/populate-motion.log") 2>&1
WATCHDOG_MIN="${WATCHDOG_MIN:-420}"
nohup bash -c "sleep ${WATCHDOG_MIN}m; runpodctl remove pod \$RUNPOD_POD_ID" >/dev/null 2>&1 </dev/null &
say(){ printf '\n== %s  [%s]\n' "$*" "$(date -u +%H:%M:%S)"; }

# exact byte size of <file> in <repo> from the HF API (0 if unknown)
size_of(){ curl -fsSL --retry 3 "https://huggingface.co/api/models/$1?blobs=true" 2>/dev/null \
  | python3 -c 'import sys,json
f=sys.argv[1]
try: print(next((s.get("size") or 0) for s in json.load(sys.stdin)["siblings"] if s["rfilename"]==f))
except Exception: print(0)' "$2"; }

FAILS=0; : > "$V/MANIFEST-motion.txt"
# get <repo> <file-in-repo> <dest-subdir-under-models>
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
    if { [ "${want:-0}" -gt 0 ] && [ "$have" -ne "$want" ]; } || [ "$have" -le 1000000 ]; then
      echo "FAIL  $dest/$(basename "$file")  $have/$want bytes"; FAILS=$((FAILS+1)); return 1
    fi
    echo "ok    $dest/$(basename "$file")  ($have bytes)"
  fi
  printf 'motion %10s  %s\n' "$(numfmt --to=iec "$have")" "$dest/$(basename "$file")" >> "$V/MANIFEST-motion.txt"
}

say "free space before"; df -h "$V" | tail -1

say "1/5 Wan2.2-Animate (kijai fp8 v2, 17.3 GB) + relight lora (replacement mode)"
get Kijai/WanVideo_comfy_fp8_scaled "Wan22Animate/Wan2_2-Animate-14B_fp8_scaled_e4m3fn_KJ_v2.safetensors" diffusion_models
get Kijai/WanVideo_comfy "LoRAs/Wan22_relight/WanAnimate_relight_lora_fp16.safetensors" loras

say "2/5 SCAIL-2 (Comfy-Org fp8, core ComfyUI nodes, 17.7 GB) + DPO hand-fix lora"
get Comfy-Org/SCAIL-2 "diffusion_models/wan2.1_14B_SCAIL_2_fp8_scaled.safetensors" diffusion_models
get Comfy-Org/SCAIL-2 "loras/wan2.1_SCAIL_2_DPO_lora_bf16.safetensors" loras

say "3/5 HuMo: 14B fp8 (17.9 GB) + 1.7B fp16 (3.5 GB) + Whisper-large-v3 encoder (1.7 GB)"
get Kijai/WanVideo_comfy_fp8_scaled "HuMo/Wan2_1-HuMo-14B_fp8_e4m3fn_scaled_KJ.safetensors" diffusion_models
get Kijai/WanVideo_comfy "HuMo/Wan2_1-HuMo-1_7B_fp16.safetensors" diffusion_models
get Kijai/WanVideo_comfy "HuMo/whisper_large_v3_encoder_fp16.safetensors" text_encoders

say "4/5 pose/detection: yolov10m, ViTPose-H wholebody (2.6 GB), NLF for SCAIL-Pose"
get Wan-AI/Wan2.2-Animate-14B "process_checkpoint/det/yolov10m.onnx" detection
get Kijai/vitpose_comfy "onnx/vitpose_h_wholebody_model.onnx" detection
get Kijai/vitpose_comfy "onnx/vitpose_h_wholebody_data.bin" detection
get Kijai/WanVideo_comfy "SCAIL/nlf_l_multi_0.3.2_fp16.safetensors" detection

say "5/5 LatentSync-1.6: unet (5.1 GB), whisper tiny, sfd face detector"
get ByteDance/LatentSync-1.6 "latentsync_unet.pt" latentsync
get ByteDance/LatentSync-1.6 "whisper/tiny.pt" latentsync
get ByteDance/LatentSync-1.6 "auxiliary/sfd_face.pth" latentsync

say "6/7 shared Wan files (this is a SEPARATE volume from avyra-models, so they are fetched again): umt5 11.4 GB, VAE, clip_vision_h, lightx2v lora"
get Kijai/WanVideo_comfy "umt5-xxl-enc-bf16.safetensors" text_encoders
get Kijai/WanVideo_comfy "Wan2_1_VAE_bf16.safetensors" vae
get Comfy-Org/Wan_2.1_ComfyUI_repackaged "split_files/clip_vision/clip_vision_h.safetensors" clip_vision
get Kijai/WanVideo_comfy "Lightx2v/lightx2v_I2V_14B_480p_cfg_step_distill_rank64_bf16.safetensors" loras

say "7/7 env tarballs (venv + ComfyUI) from the GHCR image layers — the proven resumable blob download"
R=https://ghcr.io/v2/labn36/avyra-talk
VENV=sha256:48f19b351e2aa38a06e41e33b78d281364f4bdf8d41a3af4368db4082ddcff79    # 0.9GB gz: opt/venv
COMFY=sha256:fa2ecb7af8a319bd2a7a69e961d625cc3698eb9791ab9ff738f65a9cdd580d94   # 0.07GB gz: opt/ComfyUI
tok(){ curl -fsSL "https://ghcr.io/token?scope=repository:labn36/avyra-talk:pull" | python3 -c 'import json,sys;print(json.load(sys.stdin)["token"])'; }
blob(){ local dg=$1 out=$2 t want have i
  for i in $(seq 1 10); do
    t=$(tok) || { sleep 10; continue; }
    want=$(curl -sIL -H "Authorization: Bearer $t" "$R/blobs/$dg" | tr -d '\r' | grep -i '^content-length:' | tail -1 | tr -dc 0-9)
    have=$(stat -c %s "$out" 2>/dev/null || echo 0)
    [ -n "$want" ] && [ "$have" -eq "$want" ] && { echo "ok    $(basename "$out") ($have bytes)"; return 0; }
    curl -fL -C - --retry 6 --retry-delay 5 --retry-all-errors --speed-time 60 --speed-limit 100000 \
         -H "Authorization: Bearer $t" -o "$out" "$R/blobs/$dg" 2>/dev/null
    have=$(stat -c %s "$out" 2>/dev/null || echo 0)
    [ -n "$want" ] && [ "$have" -eq "$want" ] && { echo "ok    $(basename "$out") ($have bytes)"; return 0; }
    echo "  attempt $i: $have/$want — resuming"; sleep 10
  done
  echo "FAIL  $(basename "$out")"; FAILS=$((FAILS+1)); return 1; }
mkdir -p "$V/env"; blob "$VENV" "$V/env/venv.tgz"; blob "$COMFY" "$V/env/comfyui.tgz"

say "env inventory (for the custom-nodes step): ComfyUI version + custom_nodes in env/comfyui.tgz"
tar -xzOf "$V/env/comfyui.tgz" opt/ComfyUI/comfyui_version.py 2>/dev/null | grep -i version || echo "comfyui_version.py not found"
tar -tzf "$V/env/comfyui.tgz" 2>/dev/null | grep -E '^opt/ComfyUI/custom_nodes/[^/]+/$' | sed 's#opt/ComfyUI/custom_nodes/##' | tr '\n' ' '; echo
tar -tzf "$V/env/comfyui.tgz" 2>/dev/null | grep -q 'comfy_extras/nodes_scail.py' && echo "core SCAIL nodes: present" || echo "core SCAIL nodes: ABSENT (ComfyUI older than 2026-06-17 → update needed for SCAIL-2)"

say "manifest + space"; cat "$V/MANIFEST-motion.txt"; df -h "$V" | tail -1
if [ "$FAILS" -eq 0 ]; then echo "POPULATE_MOTION_OK"; runpodctl remove pod "$RUNPOD_POD_ID" 2>/dev/null || true
else echo "POPULATE_MOTION_FAIL fails=$FAILS (pod kept for inspection; watchdog will remove it)"; exit 3; fi

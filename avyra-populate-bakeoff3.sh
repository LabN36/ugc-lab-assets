#!/bin/bash
# avyra-populate-bakeoff3.sh — add MiniMax H3 ref2va (reference-to-video+audio) to the avyra-models volume.
# Runs on a CPU pod with the volume mounted at /workspace. NOTHING is removed from the volume (user rule).
# Adds: ref2va transformer pruned int8 (21 GB) + ref2v turbo 4-step LoRA (2 GB). TE/VAEs already present from bakeoff #1.
set -uo pipefail
V=/workspace; M="$V/ComfyUI/models"; mkdir -p "$V/logs"; exec > >(tee -a "$V/logs/populate-bakeoff3.log") 2>&1
WATCHDOG_MIN="${WATCHDOG_MIN:-90}"
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
  printf 'bakeoff3 %10s  %s\n' "$(numfmt --to=iec "$have")" "$dest/$(basename "$file")" >> "$V/MANIFEST-bakeoff3.txt"
}
used_gb=$(du -sBG "$V" 2>/dev/null | cut -f1 | tr -dc '0-9')
say "0/2 SPACE: volume ${VOL_GB:-?} GB, used ${used_gb:-?} GB, need 23 GB more (no removals in this script)"
say "1/2 MiniMax H3 ref2va transformer pruned int8 (21 GB)"
get Comfy-Org/MiniMax-H3 "diffusion_models/minimax_h3_ref2va_pruned_int8_convrot.safetensors" diffusion_models
say "2/2 ref2v turbo 4-step LoRA (2 GB)"
get Comfy-Org/MiniMax-H3 "loras/minimax_h3_ref2v_turbo_4step_v0.1_comfyui_bf16.safetensors" loras
say "H3 files now on the volume:"; ls -la "$M/diffusion_models" "$M/loras" | grep -i minimax
used_gb=$(du -sBG "$V" 2>/dev/null | cut -f1 | tr -dc '0-9'); say "DONE fails=$FAILS  used ${used_gb} GB of ${VOL_GB:-?}"
echo "POPULATE_EXIT=$FAILS"
sleep 20; runpodctl remove pod "$RUNPOD_POD_ID" 2>/dev/null || runpodctl stop pod "$RUNPOD_POD_ID"

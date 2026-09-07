#!/usr/bin/env bash
# Populate the Avyra volume by downloading the exact GHCR image LAYER BLOBS as files
# (resumable, size-verified, token-refreshing) — NOT crane export (single-shot, dies on reset).
# Runs ON a CPU pod. Everything lands on the volume; no local disk needed. Self-removes on OK.
set -uo pipefail
V=/workspace; M=$V/ComfyUI/models; R=https://ghcr.io/v2/labn36/avyra-talk
LC_MODELS=sha256:6365ac0b8d92a86f97bac2e35045b098f5640dfd8e7a2f7f667b6b9b36b0b6b3   # 36.4GB gz: opt/models-baked (LongCat)
IT_MODELS=sha256:7c8758d047f23f690c48f1080fcdcf5c567fc9ca2005e90a23f799b2e632a8ac   # 45.6GB gz: opt/models-baked (InfiniteTalk)
VENV=sha256:48f19b351e2aa38a06e41e33b78d281364f4bdf8d41a3af4368db4082ddcff79        # 0.9GB gz: opt/venv
COMFY=sha256:fa2ecb7af8a319bd2a7a69e961d625cc3698eb9791ab9ff738f65a9cdd580d94       # 0.07GB gz: opt/ComfyUI
ESR=https://github.com/xinntao/Real-ESRGAN/releases/download/v0.2.1/RealESRGAN_x2plus.pth
say(){ printf '\n== %s  [%s]\n' "$*" "$(date -u +%H:%M:%S)"; }
tok(){ curl -fsSL "https://ghcr.io/token?scope=repository:labn36/avyra-talk:pull" | python3 -c 'import json,sys;print(json.load(sys.stdin)["token"])'; }
# dl <digest> <outfile>: resumable, refreshes token per attempt, verifies byte size against server
dl(){ local dg=$1 out=$2 t want have
  for i in $(seq 1 15); do
    t=$(tok) || { sleep 10; continue; }
    want=$(curl -sIL -H "Authorization: Bearer $t" "$R/blobs/$dg" | tr -d '\r' | grep -i '^content-length:' | tail -1 | tr -dc 0-9)
    curl -fL -C - --retry 6 --retry-delay 5 --retry-all-errors --speed-time 60 --speed-limit 100000 \
         -H "Authorization: Bearer $t" -o "$out" "$R/blobs/$dg" 2>/dev/null
    have=$(stat -c %s "$out" 2>/dev/null || echo 0)
    if [ -n "$want" ] && [ "$have" = "$want" ]; then echo "  ok $out ($have bytes)"; return 0; fi
    [ -z "$want" ] && [ "$have" -gt 1000000 ] && { echo "  ok $out ($have bytes, size unverified)"; return 0; }
    echo "  attempt $i: $have/${want:-?} bytes — resuming in 10s"; sleep 10
  done; echo "!! FAILED $out"; return 1; }
merge(){ cp -al "$V/opt/models-baked/." "$M/" 2>/dev/null || cp -a "$V/opt/models-baked/." "$M/"; rm -rf "$V/opt/models-baked"; }

say "0/5 clean partial state"; rm -rf "$V/opt" "$V"/*.tgz; mkdir -p "$M" "$V/env"; df -h "$V" | tail -1
say "1/5 env blobs -> volume (venv.tgz, comfyui.tgz — used as-is by gpu_session)"
dl "$VENV"  "$V/env/venv.tgz"    || exit 3
dl "$COMFY" "$V/env/comfyui.tgz" || exit 3
say "2/5 LC models blob -> volume (36GB, resumable)"
dl "$LC_MODELS" "$V/lc_models.tgz" || exit 3
say "   extract LC into models/"; tar -xzf "$V/lc_models.tgz" -C "$V" --no-same-owner && merge && rm -f "$V/lc_models.tgz" || exit 3
say "3/5 IT models blob -> volume (46GB, resumable)"
dl "$IT_MODELS" "$V/it_models.tgz" || exit 3
say "   extract IT into models/"; tar -xzf "$V/it_models.tgz" -C "$V" --no-same-owner && merge && rm -f "$V/it_models.tgz" || exit 3
say "4/5 RealESRGAN"; mkdir -p "$M/upscale_models"
[ -s "$M/upscale_models/RealESRGAN_x2plus.pth" ] || curl -fL --retry 6 --retry-all-errors "$ESR" -o "$M/upscale_models/RealESRGAN_x2plus.pth" || exit 3
say "5/5 verify manifest"; missing=0; : > "$V/MANIFEST.txt"
while read -r eng sub base; do case "$eng" in ''|\#*) continue;; esac
  hit=$(find "$M" -type f -name "$base" | head -n1)
  if [ -z "$hit" ] || [ ! -s "$hit" ]; then echo "MISSING: $base"; missing=$((missing+1))
  else printf '%-6s %10s  %s\n' "$eng" "$(numfmt --to=iec "$(stat -c %s "$hit")")" "${hit#$M/}" | tee -a "$V/MANIFEST.txt"; fi
done < "$V/avyra-manifest.txt"
du -sh "$M" "$V/env" "$V" 2>/dev/null | tee -a "$V/MANIFEST.txt"
if [ "$missing" -eq 0 ]; then echo "POPULATE_OK"; runpodctl remove pod "$RUNPOD_POD_ID" 2>/dev/null || true
else echo "POPULATE_FAIL missing=$missing"; exit 3; fi

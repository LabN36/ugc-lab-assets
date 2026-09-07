#!/usr/bin/env bash
# Populate the Avyra network volume from a CPU pod using crane — NO GPU, NO big disk.
# Models (few huge files) stream straight onto the volume; env (many small files)
# stages on local disk briefly, then is tarred onto the volume. Runs ON the pod.
set -euo pipefail
V=/workspace; M=$V/ComfyUI/models; ST=/root/stage
LC=ghcr.io/labn36/avyra-talk:v2-lc; IT=ghcr.io/labn36/avyra-talk:v2-it
ESR=https://github.com/xinntao/Real-ESRGAN/releases/download/v0.2.1/RealESRGAN_x2plus.pth
say(){ printf '\n== %s  [%s]\n' "$*" "$(date -u +%H:%M:%S)"; }
mkdir -p "$M" "$V/env" "$ST"
command -v crane >/dev/null 2>&1 || curl -fsSL https://github.com/google/go-containerregistry/releases/download/v0.20.2/go-containerregistry_Linux_x86_64.tar.gz | tar -xz -C /usr/local/bin crane
merge(){ cp -al "$V/opt/models-baked/." "$M/" 2>/dev/null || cp -a "$V/opt/models-baked/." "$M/"; rm -rf "$V/opt/models-baked"; }

say "1/4 LC models -> volume (direct stream)"
crane export "$LC" - | tar -x -C "$V" --no-same-owner --wildcards '*opt/models-baked/*'; merge
say "2a/4 LC venv -> local stage -> tar on volume (peak local ~11GB, fits 20GB cap)"
crane export "$LC" - | tar -x -C "$ST" --no-same-owner --wildcards '*opt/venv/*'
tar -cf "$V/env/venv.tar" -C "$ST/opt" venv; rm -rf "${ST:?}"/*
say "2b/4 LC ComfyUI -> local stage -> tar on volume"
crane export "$LC" - | tar -x -C "$ST" --no-same-owner --wildcards '*opt/ComfyUI/*' --exclude='*opt/ComfyUI/models/*'
tar -cf "$V/env/comfyui.tar" -C "$ST/opt" --exclude='ComfyUI/models' ComfyUI; rm -rf "${ST:?}"/*
say "3/4 IT models -> volume (direct stream)"
crane export "$IT" - | tar -x -C "$V" --no-same-owner --wildcards '*opt/models-baked/*'; merge
say "4/4 ESRGAN + verify"
mkdir -p "$M/upscale_models"; [ -s "$M/upscale_models/RealESRGAN_x2plus.pth" ] || curl -fsSL "$ESR" -o "$M/upscale_models/RealESRGAN_x2plus.pth"
missing=0; : > "$V/MANIFEST.txt"
while read -r eng sub base; do case "$eng" in ''|\#*) continue;; esac
  hit=$(find "$M" -type f -name "$base" | head -n1)
  if [ -z "$hit" ] || [ ! -s "$hit" ]; then echo "MISSING: $base"; missing=$((missing+1))
  else printf '%-6s %10s  %s\n' "$eng" "$(numfmt --to=iec "$(stat -c %s "$hit")")" "${hit#$M/}" | tee -a "$V/MANIFEST.txt"; fi
done < /workspace/avyra-manifest.txt
du -sh "$M" "$V/env" "$V" | tee -a "$V/MANIFEST.txt"
[ "$missing" -eq 0 ] && echo "POPULATE_OK" || { echo "POPULATE_FAIL missing=$missing"; exit 3; }

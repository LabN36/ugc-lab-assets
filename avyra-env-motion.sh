#!/usr/bin/env bash
# avyra-env-motion.sh — build ENV v3 for the motion roadmap on a pod (CPU is enough) that runs the SAME base
# image as the workers (runpod/pytorch:1.1.0-cu1281-torch280-ubuntu2404 — the venv borrows its python/torch).
# Restores env/venv.tgz + env/comfyui.tgz from the motion volume, adds the custom nodes the Animate / SCAIL /
# HuMo / LatentSync workflows need, then writes NEW tarballs env/venv_v3.tgz + env/comfyui_v3.tgz. The v2
# tarballs are never touched, so LongCat/InfiniteTalk keep working if v3 turns out broken.
# Run as the pod's startup command (no IP on CPU pods); progress in `runpodctl pod logs` and /workspace/logs/env-motion.log.
set -uo pipefail
V=/workspace; mkdir -p "$V/logs"; exec > >(tee -a "$V/logs/env-motion.log") 2>&1
WATCHDOG_MIN="${WATCHDOG_MIN:-120}"
nohup bash -c "sleep ${WATCHDOG_MIN}m; runpodctl remove pod \$RUNPOD_POD_ID" >/dev/null 2>&1 </dev/null &
say(){ printf '\n== %s  [%s]\n' "$*" "$(date -u +%H:%M:%S)"; }
FAILS=0; PY=/opt/venv/bin/python; PIP="$PY -m pip"

say "0/6 restore v2 env from the volume"
[ -s "$V/env/venv.tgz" ] && [ -s "$V/env/comfyui.tgz" ] || { echo "ENV_TARBALLS_MISSING"; exit 3; }
tar -xzf "$V/env/venv.tgz" -C / && tar -xzf "$V/env/comfyui.tgz" -C / || { echo "ENV_RESTORE_FAIL"; exit 3; }
$PY -c 'import torch,sys;print("python",sys.version.split()[0],"torch",torch.__version__)' || { echo "VENV_PYTHON_BROKEN (wrong base image?)"; exit 3; }
apt-get -qq update >/dev/null 2>&1; apt-get -qq install -y git ffmpeg >/dev/null 2>&1
cd /opt/ComfyUI && echo "ComfyUI: $(git log -1 --format='%h %cd' --date=short 2>/dev/null || cat comfyui_version.py 2>/dev/null)"
[ -f comfy_extras/nodes_scail.py ] && echo "core SCAIL-2 nodes: present" || echo "core SCAIL-2 nodes: ABSENT"

say "1/6 ComfyUI core update if the SCAIL-2 nodes are missing (kept on a branch; v2 tarball untouched)"
if [ ! -f comfy_extras/nodes_scail.py ]; then
  if git -C /opt/ComfyUI rev-parse --git-dir >/dev/null 2>&1 && git -C /opt/ComfyUI fetch --depth 1 origin master 2>/dev/null && git -C /opt/ComfyUI checkout -q FETCH_HEAD 2>/dev/null; then
    echo "core updated in place"
  else
    # v2 image ships ComfyUI as a plain copy (no .git): clone current master beside it and carry over custom_nodes
    echo "no git checkout — cloning current ComfyUI master and carrying custom_nodes over"
    git clone -q --depth 1 https://github.com/comfyanonymous/ComfyUI /opt/ComfyUI_new \
      && cp -a /opt/ComfyUI/custom_nodes/. /opt/ComfyUI_new/custom_nodes/ \
      && mv /opt/ComfyUI /opt/ComfyUI_v2 && mv /opt/ComfyUI_new /opt/ComfyUI && cd /opt/ComfyUI \
      || { echo "CORE_CLONE_FAILED"; FAILS=$((FAILS+1)); }
  fi
  $PIP install -q -r /opt/ComfyUI/requirements.txt 2>&1 | grep -iE 'error' | head -n 3
  [ -f /opt/ComfyUI/comfy_extras/nodes_scail.py ] && echo "core now $(git -C /opt/ComfyUI log -1 --format='%h %cd' --date=short 2>/dev/null): SCAIL-2 nodes present" || { echo "CORE_UPDATE_NO_SCAIL"; FAILS=$((FAILS+1)); }
fi

say "2/6 custom nodes (git clone --depth 1)"
cd /opt/ComfyUI/custom_nodes
clone(){ local repo="$1" dir; dir="$(basename "$repo")"
  if [ -d "$dir" ]; then echo "present $dir"; else git clone -q --depth 1 "https://github.com/$repo" "$dir" && echo "cloned  $dir" || { echo "CLONE_FAIL $repo"; FAILS=$((FAILS+1)); return 1; }; fi
  [ -f "$dir/requirements.txt" ] && { $PIP install -q -r "$dir/requirements.txt" 2>&1 | grep -iE 'error|conflict' | head -n 3; echo "deps    $dir"; }; return 0; }
clone kijai/ComfyUI-WanAnimatePreprocess      # OnnxDetectionModelLoader (yolov10m + ViTPose) for Animate/SCAIL pose
clone kijai/ComfyUI-segment-anything-2        # DownloadAndLoadSAM2Model masks (Animate replacement / SCAIL masks)
clone kijai/ComfyUI-SCAIL-Pose                # NLF pose renders for SCAIL-2
clone kijai/ComfyUI-KJNodes                   # helper nodes used throughout kijai's example workflows
clone Kosinkadink/ComfyUI-VideoHelperSuite    # VHS load/combine (present in v2 already, harmless if so)
$PIP install -q onnxruntime-gpu 2>&1 | grep -iE 'error' | head -n 2; echo "onnxruntime: $($PY -c 'import onnxruntime as o;print(o.__version__)' 2>&1 | tail -n1)"

say "3/6 LatentSync 1.6 wrapper (last, non-fatal: its pins may fight the WanVideo wrapper)"
if clone ShmuelRonen/ComfyUI-LatentSyncWrapper; then
  ln -sfn "$V/ComfyUI/models/latentsync" /opt/ComfyUI/custom_nodes/ComfyUI-LatentSyncWrapper/checkpoints
  $PY -c 'import diffusers,transformers;print("diffusers",diffusers.__version__,"transformers",transformers.__version__)' 2>&1 | tail -n1
fi

say "4/6 import smoke test of the WanVideo wrapper + new nodes (CPU)"
cd /opt/ComfyUI && timeout 600 $PY - <<'EOF' 2>&1 | tail -n 12
import sys, importlib, traceback
sys.path.insert(0, "/opt/ComfyUI")
ok = 0
for name in ["ComfyUI-WanVideoWrapper", "ComfyUI-WanAnimatePreprocess", "ComfyUI-segment-anything-2", "ComfyUI-SCAIL-Pose", "ComfyUI-KJNodes", "ComfyUI-LatentSyncWrapper"]:
    try:
        sys.path.insert(0, f"/opt/ComfyUI/custom_nodes/{name}")
        importlib.import_module(name.replace("-", "_")) if False else __import__("importlib").import_module("nodes") if False else None
        # importing custom_nodes outside ComfyUI is unreliable; just check the package dir + its __init__ parses
        import ast, os
        p = f"/opt/ComfyUI/custom_nodes/{name}/__init__.py"
        ast.parse(open(p).read()); print("parse ok ", name); ok += 1
    except Exception as e:
        print("PARSE FAIL", name, repr(e)[:120])
print("parsed", ok, "of 6")
EOF

say "5/6 write v3 tarballs (v2 untouched)"
tar -czf "$V/env/venv_v3.tgz" -C / opt/venv && tar -czf "$V/env/comfyui_v3.tgz" -C / --exclude='opt/ComfyUI/models/*' opt/ComfyUI \
  && ls -l "$V/env/" || { echo "TAR_FAIL"; FAILS=$((FAILS+1)); }

say "6/6 summary + manifest touch-up (populate run 1 skipped the tiny .onnx manifest line on a false alarm)"
M=$V/ComfyUI/models
for f in detection/vitpose_h_wholebody_model.onnx detection/vitpose_h_wholebody_data.bin detection/yolov10m.onnx detection/nlf_l_multi_0.3.2_fp16.safetensors; do
  if [ -s "$M/$f" ]; then grep -q "$f" "$V/MANIFEST-motion.txt" 2>/dev/null || printf 'motion %10s  %s\n' "$(numfmt --to=iec "$(stat -c %s "$M/$f")")" "$f" >> "$V/MANIFEST-motion.txt"; echo "present $f ($(stat -c %s "$M/$f") bytes)"
  else echo "MISSING $f"; FAILS=$((FAILS+1)); fi
done
ls /opt/ComfyUI/custom_nodes; df -h "$V" | tail -1
if [ "$FAILS" -eq 0 ]; then echo "ENV_MOTION_OK"; runpodctl remove pod "$RUNPOD_POD_ID" 2>/dev/null || true
else echo "ENV_MOTION_PARTIAL fails=$FAILS (v3 tarballs may still be usable for Animate/HuMo; pod kept for the watchdog)"; exit 3; fi

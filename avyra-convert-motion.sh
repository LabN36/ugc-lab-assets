#!/usr/bin/env bash
# avyra-convert-motion.sh — on a CPU pod with the workers' base image: restore env v3 from the motion volume,
# start ComfyUI in --cpu mode (no GPU needed to load node definitions), dump /object_info, and convert kijai's
# UI example workflows (Animate, Animate-preprocess, HuMo, SCAIL) to API graphs with bench/ui2api.py.
# Doubles as the v3 environment boot test: any custom-node import failure shows up here for $0.03.
# Outputs: /workspace/workflows_v3/*.api.json + /workspace/object_info_v3.json (+ each API graph echoed to the log).
set -uo pipefail
V=/workspace; mkdir -p "$V/logs" "$V/workflows_v3"; exec > >(tee -a "$V/logs/convert-motion.log") 2>&1
WATCHDOG_MIN="${WATCHDOG_MIN:-60}"
nohup bash -c "sleep ${WATCHDOG_MIN}m; runpodctl remove pod \$RUNPOD_POD_ID" >/dev/null 2>&1 </dev/null &
say(){ printf '\n== %s  [%s]\n' "$*" "$(date -u +%H:%M:%S)"; }
RAW=https://raw.githubusercontent.com/LabN36/ugc-lab-assets/main
PY=/opt/venv/bin/python; FAILS=0

say "1/4 restore env v3"
tar -xzf "$V/env/venv_v3.tgz" -C / && tar -xzf "$V/env/comfyui_v3.tgz" -C / || { echo "ENV_V3_RESTORE_FAIL"; exit 3; }
rm -rf /opt/ComfyUI/models; ln -sfn "$V/ComfyUI/models" /opt/ComfyUI/models
apt-get -qq update >/dev/null 2>&1; apt-get -qq install -y ffmpeg >/dev/null 2>&1
ls /opt/ComfyUI/custom_nodes | tr '\n' ' '; echo

say "2/4 start ComfyUI on CPU and wait for it"
cd /opt/ComfyUI && setsid bash -c "$PY main.py --cpu --listen 127.0.0.1 --port 8188 --disable-auto-launch" >"$V/logs/comfy_v3_cpu.log" 2>&1 </dev/null &
for i in $(seq 1 120); do curl -sf http://127.0.0.1:8188/system_stats >/dev/null 2>&1 && break; sleep 5; done
curl -sf http://127.0.0.1:8188/system_stats >/dev/null 2>&1 || { echo "COMFY_V3_DID_NOT_START"; tail -n 40 "$V/logs/comfy_v3_cpu.log"; exit 3; }
echo "comfy v3 up on CPU"; grep -iE 'IMPORT FAILED|Cannot import|Traceback|Error' "$V/logs/comfy_v3_cpu.log" | head -n 20
grep -E 'Import times|seconds.*custom_nodes' -A 40 "$V/logs/comfy_v3_cpu.log" | grep -E 'custom_nodes' | head -n 20

say "3/4 object_info + convert"
curl -sf http://127.0.0.1:8188/object_info -o "$V/object_info_v3.json" && echo "object_info: $(stat -c %s "$V/object_info_v3.json") bytes"
curl -fsSL "$RAW/ui2api.py" -o /root/ui2api.py || { echo "UI2API_FETCH_FAIL"; exit 3; }
for w in anim_ui anim_pre_ui humo_ui scail_ui; do
  curl -fsSL "$RAW/$w.json" -o "/root/$w.json" || { echo "FETCH_FAIL $w"; FAILS=$((FAILS+1)); continue; }
  if $PY /root/ui2api.py "/root/$w.json" "$V/workflows_v3/${w%_ui}.api.json" --host=http://127.0.0.1:8188 2>&1 | tail -n 3; then
    n=$($PY -c "import json,sys;print(len(json.load(open(sys.argv[1]))))" "$V/workflows_v3/${w%_ui}.api.json" 2>/dev/null || echo 0)
    echo "converted ${w%_ui}.api.json: $n nodes"; echo "APIJSON ${w%_ui} $(base64 -w0 "$V/workflows_v3/${w%_ui}.api.json")"
  else echo "CONVERT_FAIL $w"; FAILS=$((FAILS+1)); fi
done

say "4/4 done"; ls -l "$V/workflows_v3/"
if [ "$FAILS" -eq 0 ]; then echo "CONVERT_OK"; runpodctl remove pod "$RUNPOD_POD_ID" 2>/dev/null || true
else echo "CONVERT_PARTIAL fails=$FAILS"; exit 3; fi

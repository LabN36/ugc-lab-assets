#!/usr/bin/env python3
"""Avyra serverless worker: InfiniteTalk / LongCat talking-video endpoint.
Boot: untar the proven venv+ComfyUI env from the attached network volume, start
ComfyUI headless, then serve Runpod jobs. MODEL env picks the engine.
Input: {"image_url": ..., "audio_url": ..., "prompt": ..., "trim_s": optional}
Output: {"video_b64": ..., "seconds": float, "engine": str}
"""
import base64, json, os, subprocess, sys, time, urllib.request

VOL = "/runpod-volume"
MODEL = os.environ.get("MODEL", "infinitetalk")

def sh(cmd): subprocess.run(cmd, shell=True, check=True)

def boot():
    if not os.path.exists("/opt/ComfyUI"):
        sh(f"tar xzf {VOL}/env/venv.tgz -C /")
        sh(f"tar xzf {VOL}/env/comfyui.tgz -C /")
    # models come from the volume via symlinked dirs (same layout gpu_session.sh used)
    sh(f"bash -c 'cd /opt/ComfyUI/models && for d in {VOL}/ComfyUI/models/*; do ln -sfn $d $(basename $d); done' || true")
    subprocess.Popen(["/opt/venv/bin/python", "main.py", "--listen", "127.0.0.1", "--port", "8188",
                      "--disable-auto-launch"], cwd="/opt/ComfyUI",
                     stdout=open("/tmp/comfy.log", "w"), stderr=subprocess.STDOUT)
    for _ in range(120):
        try:
            urllib.request.urlopen("http://127.0.0.1:8188/system_stats", timeout=3); return
        except Exception: time.sleep(3)
    raise RuntimeError("comfyui did not start: " + open("/tmp/comfy.log").read()[-800:])

def build_graph(image_f, audio_f, prompt, secs):
    sys.path.insert(0, f"{VOL}/bench")
    import importlib, build_jobs
    importlib.reload(build_jobs)
    B = build_jobs
    B.AUDIO_S[audio_f] = secs
    jid = f"job_{int(time.time())}"
    if MODEL == "longcat":
        g = B.lc15_long(jid, image_f, audio_f, prompt, B.segs(secs))
    else:
        g = B.it_i2v(jid, image_f, audio_f, prompt)
    return B.finalize(g), jid

def run(job):
    inp = job["input"]
    t0 = time.time()
    image_f, audio_f = "in_img.png", "in_aud.wav"
    for url, fn in [(inp["image_url"], image_f), (inp["audio_url"], audio_f)]:
        urllib.request.urlretrieve(url, f"/opt/ComfyUI/input/{fn}")
    probe = subprocess.run(["ffprobe", "-v", "error", "-show_entries", "format=duration",
                            "-of", "csv=p=0", f"/opt/ComfyUI/input/{audio_f}"], capture_output=True, text=True)
    secs = float(probe.stdout.strip())
    prompt = inp.get("prompt", "A person talking naturally to the camera, subtle natural movement")
    g, jid = build_graph(image_f, audio_f, prompt, secs)
    req = urllib.request.Request("http://127.0.0.1:8188/prompt",
        data=json.dumps({"prompt": g}).encode(), headers={"Content-Type": "application/json"})
    pid = json.load(urllib.request.urlopen(req, timeout=60))["prompt_id"]
    deadline = time.time() + 900
    outfile = None
    while time.time() < deadline:
        h = json.load(urllib.request.urlopen(f"http://127.0.0.1:8188/history/{pid}", timeout=30))
        if pid in h:
            st = h[pid]
            if st.get("status", {}).get("status_str") == "error":
                return {"error": json.dumps(st.get("status", {}))[:800]}
            for node in st.get("outputs", {}).values():
                for v in node.get("gifs", []) + node.get("videos", []):
                    if v.get("filename", "").startswith(jid):
                        outfile = os.path.join("/opt/ComfyUI/output", v.get("subfolder", ""), v["filename"])
            if outfile: break
        time.sleep(5)
    if not outfile:
        return {"error": "timeout waiting for output"}
    trim = inp.get("trim_s") or secs
    trimmed = "/tmp/out.mp4"
    subprocess.run(["ffmpeg", "-y", "-loglevel", "error", "-i", outfile, "-t", str(trim),
                    "-c:v", "libx264", "-crf", "20", "-pix_fmt", "yuv420p", "-c:a", "aac", trimmed], check=True)
    data = open(trimmed, "rb").read()
    return {"video_b64": base64.b64encode(data).decode(), "seconds": trim,
            "engine": MODEL, "gen_time_s": round(time.time() - t0, 1)}

if __name__ == "__main__":
    boot()
    import runpod
    runpod.serverless.start({"handler": run})

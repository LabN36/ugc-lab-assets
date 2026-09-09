#!/usr/bin/env python3
"""ComfyUI UI-workflow JSON -> API prompt JSON, via /object_info of a running ComfyUI.
Handles: new-frontend subgraphs (recursive), KJNodes SetNode/GetNode, Reroute, bypassed nodes,
optional pass-through nodes (vocal separator) that we don't install.
usage: ui2api.py <ui.json> <out.api.json> [--host=http://127.0.0.1:8188]"""
import json, sys, urllib.request
host = next((a.split("=",1)[1] for a in sys.argv if a.startswith("--host=")), "http://127.0.0.1:8188")
src, dst = [a for a in sys.argv[1:] if not a.startswith("--")][:2]
ui = json.load(open(src))
oi = next((a.split("=",1)[1] for a in sys.argv if a.startswith("--object-info=")), None)
info = json.load(open(oi)) if oi else json.load(urllib.request.urlopen(host + "/object_info"))
PRIM = {"INT","FLOAT","STRING","BOOLEAN","COMBO"}
PASSTHROUGH = {"MelBandRoFormerSampler": "audio"}       # node -> input name whose value flows to output 0
warn = []
subdefs = {s["id"]: s for s in ui.get("definitions", {}).get("subgraphs", [])}

# ---------- flatten: nodes{id:node}, links{id:{origin_id,origin_slot,target_id,target_slot}} ----------
nodes, links, alias = {}, {}, {}
def norm_link(l):
    return {"id": l[0], "origin_id": l[1], "origin_slot": l[2], "target_id": l[3], "target_slot": l[4], "type": l[5] if len(l) > 5 else None} if isinstance(l, list) else dict(l)

def add_graph(gnodes, glinks, prefix, ext_in=None, ext_out=None, sdef=None):
    """ext_in: subgraph input slot -> external (node_id, slot) or None; fills ext_out: output slot -> inner (node_id, slot)"""
    in_id = sdef["inputNode"]["id"] if sdef else None; out_id = sdef["outputNode"]["id"] if sdef else None
    pending = []
    for n in gnodes:
        nid = f"{prefix}{n['id']}"; n = dict(n); n["_id"] = nid; nodes[nid] = n
        if n["type"] in subdefs: pending.append(n)
    for l in glinks:
        l = norm_link(l); lid = f"{prefix}{l['id']}" if "id" in l else f"{prefix}L{len(links)}"
        o, t = l["origin_id"], l["target_id"]
        if sdef and o == in_id:
            src_ext = (ext_in or {}).get(l["origin_slot"])
            if src_ext is None: continue                         # unlinked promoted widget -> inner node keeps its own widget value
            links[lid] = {"origin_id": src_ext[0], "origin_slot": src_ext[1], "target_id": f"{prefix}{t}", "target_slot": l["target_slot"]}
        elif sdef and t == out_id:
            ext_out[l["target_slot"]] = (f"{prefix}{o}", l["origin_slot"])
        else:
            links[lid] = {"origin_id": f"{prefix}{o}", "origin_slot": l["origin_slot"], "target_id": f"{prefix}{t}", "target_slot": l["target_slot"]}
    # expand nested subgraph instances found in this graph
    for inst in pending:
        if inst.get("mode") in (2, 4): continue            # bypassed/muted instance: leave as a pass-through node
        sd = subdefs[inst["type"]]; ipfx = f"{inst['_id']}_"
        sg_index = {i["name"]: k for k, i in enumerate(sd.get("inputs", []))}
        ext_in = {}
        for inp in inst.get("inputs", []):
            if inp.get("link") is not None and inp["name"] in sg_index:
                L = links.get(f"{prefix}{inp['link']}")
                if L: ext_in[sg_index[inp["name"]]] = (L["origin_id"], L["origin_slot"])
        ext_out = {}
        add_graph(sd["nodes"], sd["links"], ipfx, ext_in, ext_out, sd)
        for k, v in ext_out.items(): alias[(inst["_id"], k)] = v
        nodes[inst["_id"]]["_expanded"] = True

add_graph(ui["nodes"], ui.get("links", []), "")
for L in links.values():                       # resolve subgraph-output aliases (possibly chained)
    n = 0
    while (L["origin_id"], L["origin_slot"]) in alias and n < 20:
        L["origin_id"], L["origin_slot"] = alias[(L["origin_id"], L["origin_slot"])]; n += 1
# index links by target
in_links = {}
for lid, L in links.items(): in_links.setdefault(L["target_id"], {})[L["target_slot"]] = L
setnodes = {n["widgets_values"][0]: n for n in nodes.values() if n["type"] == "SetNode"}

def first_in(nid):
    d = in_links.get(nid, {}); return d[min(d)] if d else None
def origin(nid, slot, depth=0):
    n = nodes[nid]; t = n["type"]
    if depth > 50: warn.append(f"loop at {nid}"); return (nid, slot)
    if t == "GetNode":
        s = setnodes.get(n["widgets_values"][0])
        if not s: warn.append(f"GetNode {nid} has no SetNode"); return (nid, slot)
        L = first_in(s["_id"]); return origin(L["origin_id"], L["origin_slot"], depth+1) if L else (nid, slot)
    if t == "Reroute" or n.get("mode") == 4 or t in PASSTHROUGH or t not in info and not n.get("_expanded"):
        L = None
        if t in PASSTHROUGH:
            names = [i["name"] for i in n.get("inputs", [])]
            k = names.index(PASSTHROUGH[t]) if PASSTHROUGH[t] in names else 0
            L = in_links.get(nid, {}).get(k) or first_in(nid)
        elif n.get("mode") == 4:
            want = (n.get("outputs") or [{}])[slot].get("type") if slot < len(n.get("outputs") or []) else None
            L = None
            for k, inp in enumerate(n.get("inputs", [])):
                if inp.get("type") == want and k in in_links.get(nid, {}): L = in_links[nid][k]; break
            L = L or first_in(nid)
        else: L = first_in(nid)
        if L: return origin(L["origin_id"], L["origin_slot"], depth+1)
        warn.append(f"{t} #{nid}: nothing upstream"); return (nid, slot)
    return (nid, slot)

def is_widget(spec):
    t, o = spec[0], (spec[1] if len(spec) > 1 and isinstance(spec[1], dict) else {})
    return not o.get("forceInput") and (isinstance(t, list) or t in PRIM or t == "COMFY_DYNAMICCOMBO_V3")

def consume(spec, name, wv, wi, inputs):
    """assign widgets_values[wi] to inputs[name]; dynamic combos also consume their selected option's sub-widgets (dotted names)"""
    t, o = spec[0], (spec[1] if len(spec) > 1 and isinstance(spec[1], dict) else {})
    if wi < len(wv): inputs[name] = wv[wi]
    wi += 1
    if o.get("control_after_generate"): wi += 1
    if o.get("image_upload") or o.get("audio_upload") or o.get("video_upload"): wi += 1
    if t == "COMFY_DYNAMICCOMBO_V3":
        sel = next((x for x in o.get("options", []) if x["key"] == inputs.get(name)), None)
        if sel:
            for sec in ("required", "optional"):
                for sub, sspec in sel["inputs"].get(sec, {}).items():
                    if is_widget(sspec): wi = consume(sspec, f"{name}.{sub}", wv, wi, inputs)
    return wi

out = {}
for nid, n in nodes.items():
    t = n["type"]
    if n.get("_expanded") or t in ("Note","MarkdownNote","PrimitiveNode","Reroute","SetNode","GetNode") or t in PASSTHROUGH or n.get("mode") in (2,4): continue
    if t not in info: warn.append(f"unknown node class {t} (#{nid})"); continue
    inputs = {}; raw = n.get("widgets_values") or []; wi = 0
    wv = raw if isinstance(raw, list) else None
    for section in ("required", "optional"):
        for name, spec in info[t].get("input", {}).get(section, {}).items():
            if not is_widget(spec): continue
            o = spec[1] if len(spec) > 1 and isinstance(spec[1], dict) else {}
            if wv is None:
                if name in raw: inputs[name] = raw[name]
                continue
            wi = consume(spec, name, wv, wi, inputs)
    # coerce: a value of the wrong type (example saved with an older node layout) -> node default
    for name, spec in [(k, v) for sec in ("required","optional") for k, v in info[t].get("input", {}).get(sec, {}).items()]:
        if name not in inputs or not is_widget(spec): continue
        ty, o = spec[0], (spec[1] if len(spec) > 1 and isinstance(spec[1], dict) else {})
        if ty == "COMFY_DYNAMICCOMBO_V3": continue
        v = inputs[name]; ok = True
        if ty == "INT": ok = isinstance(v, (int, float)) and not isinstance(v, bool)
        elif ty == "FLOAT": ok = isinstance(v, (int, float)) and not isinstance(v, bool)
        elif ty == "BOOLEAN": ok = isinstance(v, bool)
        elif ty == "STRING": ok = isinstance(v, str)
        elif isinstance(ty, list) or ty == "COMBO":
            opts = ty if isinstance(ty, list) else o.get("options", [])
            filelike = any(isinstance(x, str) and x.lower().endswith((".safetensors",".pt",".pth",".gguf",".ckpt",".bin",".onnx",".png",".jpg",".mp3",".wav",".mp4")) for x in opts) or name in ("model","lora","vae","clip_name","unet_name","lora_name","clip_vision","audio_encoder_name","image","audio","video","vae_name","model_name","ckpt_name")
            ok = filelike or (v in opts) or not opts
        if not ok:
            warn.append(f"coerced {t}#{nid}.{name} {v!r}->default")
            if "default" in o: inputs[name] = o["default"]
            elif isinstance(ty, list) and ty: inputs[name] = ty[0]
            else: inputs.pop(name, None)
    for k, inp in enumerate(n.get("inputs", [])):
        L = in_links.get(nid, {}).get(k)
        if L is None: continue
        inputs[inp["name"]] = list(origin(L["origin_id"], L["origin_slot"]))
    out[nid] = {"class_type": t, "inputs": inputs, "_meta": {"title": n.get("title") or t}}
json.dump(out, open(dst, "w"), indent=1)
print(f"{src.split('/')[-1]}: {len(out)} nodes -> {dst.split('/')[-1]}" + (f"  WARN: {'; '.join(sorted(set(warn)))}" if warn else ""))

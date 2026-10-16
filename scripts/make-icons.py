#!/usr/bin/env python3
"""Generate the UI glyphs with gemini-3-pro-image (GEMINI_API_KEY). Usage: scripts/make-icons.py icons.json  (name -> subject), writes raw/<name>.png; then scripts/normalize-icons.py."""
import os, sys, json, base64, requests, concurrent.futures as cf
KEY=os.environ["GEMINI_API_KEY"]
URL=f"https://generativelanguage.googleapis.com/v1beta/models/gemini-3-pro-image:generateContent?key={KEY}"
STYLE=("A single flat, minimalist black glyph icon on a pure white background, centered, filling about 70% of a square canvas. "
       "Solid black (#111111) shapes with thick rounded strokes and rounded corners, no outline-only thin lines, no gradients, no shadow, "
       "no text, no border, no frame. Same visual language as a simple waveform app icon: bold geometric, few shapes, instantly readable at 16 pixels. Subject: ")
def gen(name, subject):
    body={"contents":[{"parts":[{"text":STYLE+subject}]}],"generationConfig":{"responseModalities":["IMAGE"],"imageConfig":{"aspectRatio":"1:1"}}}
    for attempt in range(3):
        r=requests.post(URL,json=body,timeout=180)
        if r.status_code!=200: print(name, r.status_code, r.text[:200]); continue
        for p in r.json()["candidates"][0]["content"]["parts"]:
            if "inlineData" in p:
                open(f"raw/{name}.png","wb").write(base64.b64decode(p["inlineData"]["data"])); print("ok", name); return
    print("FAILED", name)
items=json.load(open(sys.argv[1]))
with cf.ThreadPoolExecutor(8) as ex: list(ex.map(lambda kv: gen(*kv), items.items()))

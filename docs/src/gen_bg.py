#!/usr/bin/env python3
"""Generate abstract marketing backgrounds via OpenRouter (key: OPENROUTER_API_KEY env var). Output: bg_*.jpg"""
import base64, io, json, os, sys, urllib.request
from PIL import Image
KEY = os.environ["OPENROUTER_API_KEY"]
MODEL = "google/gemini-2.5-flash-image"
BASE = ("Abstract premium tech-marketing background, NO text, NO letters, NO logos, NO people, NO UI, "
        "edge-to-edge, no border or frame. ")
JOBS = {
 "bg_hero": BASE + "Deep navy to royal blue gradient with soft glowing bokeh light, elegant floating translucent paper sheets and a graceful feather-pen swoosh in light blue and gold, depth of field, cinematic, wide 16:9.",
 "bg_story": BASE + "Soft warm cream and pale blue gradient, subtle watercolor paper texture, delicate floating feathers and tiny golden sparkles, calm and bright, wide 16:9.",
 "bg_dark": BASE + "Dark midnight blue with subtle blue-violet aurora light streaks and fine grid lines, minimal, elegant, wide 16:9.",
}
def gen(name, prompt):
    body = {"model": MODEL, "messages": [{"role": "user", "content": prompt}],
            "modalities": ["image", "text"], "image_config": {"aspect_ratio": "16:9"}}
    req = urllib.request.Request("https://openrouter.ai/api/v1/chat/completions", json.dumps(body).encode(),
        {"Authorization": "Bearer " + KEY, "Content-Type": "application/json"})
    r = json.load(urllib.request.urlopen(req, timeout=180))
    url = r["choices"][0]["message"]["images"][0]["image_url"]["url"]
    im = Image.open(io.BytesIO(base64.b64decode(url.split(",", 1)[1]))).convert("RGB")
    im.save(f"{name}.jpg", quality=88); print(name, im.size)
for n, p in JOBS.items():
    try: gen(n, p)
    except Exception as e: print(n, "failed", e)

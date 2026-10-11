#!/usr/bin/env python3
import json, pathlib, sys

def candidate_text(raw, provider):
    if provider != "codex":
        return raw
    parts = []
    for line in raw.splitlines():
        try:
            event = json.loads(line)
        except Exception:
            continue
        item = event.get("item") if isinstance(event, dict) else None
        if isinstance(item, dict) and item.get("type") == "agent_message":
            value = item.get("text") or item.get("content")
            if isinstance(value, str):
                parts.append(value)
        if event.get("type") == "response.output_text.done" and isinstance(event.get("text"), str):
            parts.append(event["text"])
    return "\n".join(parts) or raw

def find_report(text):
    decoder = json.JSONDecoder()
    for i, char in enumerate(text):
        if char != "{":
            continue
        try:
            value, _ = decoder.raw_decode(text[i:])
        except Exception:
            continue
        if isinstance(value, dict) and isinstance(value.get("applyNow"), list) and isinstance(value.get("reachOut"), list):
            return value
    raise ValueError("no Career Scout JSON object found")

raw_path, provider, out_path = sys.argv[1:4]
raw = pathlib.Path(raw_path).read_text(encoding="utf-8", errors="replace")
report = find_report(candidate_text(raw, provider))
for key in ("applyNow", "reachOut", "experiments", "questions"):
    if not isinstance(report.get(key), list):
        report[key] = []
allowed_tracks = {"job", "internship", "apprenticeship", "contract", "freelance", "fellowship", "phd", "volunteer", "other"}
allowed_fit_types = {"strong", "adjacent", "stretch"}
def infer_track(item):
    explicit = item.get("track")
    if explicit in allowed_tracks:
        return explicit
    text = " ".join(str(item.get(key) or "") for key in ("title", "kind", "type", "description")).lower()
    if "phd" in text or "doctoral" in text:
        return "phd"
    if "intern" in text or "residency" in text:
        return "internship"
    if "apprentice" in text:
        return "apprenticeship"
    if "contract" in text:
        return "contract"
    if "freelance" in text:
        return "freelance"
    if "fellow" in text or "predoc" in text:
        return "fellowship"
    if "volunteer" in text:
        return "volunteer"
    return "job"
for item in report["applyNow"]:
    if not isinstance(item, dict):
        raise ValueError("every Career Scout opportunity must be an object")
    # Older saved cards and otherwise-valid agent results may not supply the UI
    # classification. Infer it rather than discarding the entire curated run.
    item["track"] = infer_track(item)
    fit_type = str(item.get("fitType") or "").lower()
    if fit_type not in allowed_fit_types:
        try:
            score = float(item.get("fitScore") or 0)
        except (TypeError, ValueError):
            score = 0
        item["fitType"] = "strong" if score >= 85 else "adjacent" if score >= 70 else "stretch"
report["summary"] = str(report.get("summary") or "")[:2400]
pathlib.Path(out_path).write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")

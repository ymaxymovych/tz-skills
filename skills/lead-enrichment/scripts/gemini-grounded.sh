#!/usr/bin/env bash
# gemini-grounded.sh — один запит до Gemini API з Google-пошуком (grounding).
#
# Використання:
#   GEMINI_API_KEY="k1,k2" bash gemini-grounded.sh "<промпт>"            > answer.json
#   GEMINI_API_KEY=... bash gemini-grounded.sh --file prompt.txt          > answer.json
# Вивід (stdout, JSON): {"text": "...", "sources": [{"url","title"}], "queries": [...],
#                        "usage": {...}, "model": "...", "finishReason": "..."}
# Код виходу: 0 — відповідь є; 2 — усі ключі без квоти (429); 1 — інша помилка.
#
# Пастки, зняті тут (усі виміряні 09.09.2026):
#   • gemini-2.5-flash → 404 для нових користувачів; дефолт gemini-3.6-flash.
#   • thinkingBudget:0 → 400 на 3.x; працює thinkingLevel:"low". Без нього роздуми
#     зʼїдають maxOutputTokens і текст приходить порожнім при HTTP 200.
#   • URL джерел — редіректи vertexaisearch…; справжня адреса у Location (302).
#   • Кілька ключів через кому: на 429 береться наступний.
# Потрібні: bash, curl, python3 (або python).
set -u
MODEL="${GEMINI_ENRICH_MODEL:-gemini-3.6-flash}"
PY="$(command -v python3 || command -v python)"
[ -n "$PY" ] || { echo "python не знайдено" >&2; exit 1; }
[ -n "${GEMINI_API_KEY:-}" ] || { echo "GEMINI_API_KEY порожній" >&2; exit 1; }

if [ "${1:-}" = "--file" ]; then PROMPT="$(cat "$2")"; else PROMPT="${1:-}"; fi
[ -n "$PROMPT" ] || { echo "порожній промпт" >&2; exit 1; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
printf '%s' "$PROMPT" > "$TMP/prompt.txt"
"$PY" - "$TMP/prompt.txt" "$TMP/req.json" <<'EOF'
import json, sys
p = open(sys.argv[1], encoding="utf-8").read()
body = {"contents": [{"parts": [{"text": p}]}],
        "tools": [{"google_search": {}}],
        "generationConfig": {"temperature": 0.2, "maxOutputTokens": 8192,
                             "thinkingConfig": {"thinkingLevel": "low"}}}
json.dump(body, open(sys.argv[2], "w", encoding="utf-8"), ensure_ascii=False)
EOF

IFS=',' read -r -a KEYS <<< "$GEMINI_API_KEY"
quota_exhausted=0
for KEY in "${KEYS[@]}"; do
  KEY="$(printf '%s' "$KEY" | tr -d '[:space:]')"; [ -n "$KEY" ] || continue
  code=$(curl -s -m 120 -H "Content-Type: application/json" -H "x-goog-api-key: $KEY" \
    -d @"$TMP/req.json" \
    "https://generativelanguage.googleapis.com/v1beta/models/$MODEL:generateContent" \
    -o "$TMP/resp.json" -w '%{http_code}')
  # Ключ непридатний → наступний: 429 без квоти, 400 «API key not valid», 403 без прав.
  if [ "$code" = "429" ]; then quota_exhausted=1; continue; fi
  if [ "$code" = "403" ] || { [ "$code" = "400" ] && grep -qi "api key not valid" "$TMP/resp.json"; }; then
    echo "ключ ${KEY:0:6}… непридатний (HTTP $code), пробую наступний" >&2; quota_exhausted=1; continue
  fi
  if [ "$code" != "200" ]; then
    echo "Gemini HTTP $code: $(head -c 300 "$TMP/resp.json")" >&2; exit 1
  fi
  # Розбір + резолв редіректів джерел (HEAD без follow → Location).
  "$PY" - "$TMP/resp.json" "$MODEL" <<'EOF'
import json, sys, urllib.request, urllib.error
d = json.load(open(sys.argv[1], encoding="utf-8"))
c = (d.get("candidates") or [{}])[0]
text = "".join(p.get("text", "") for p in (c.get("content") or {}).get("parts", []))
gm = c.get("groundingMetadata") or {}
seen, sources = set(), []
for ch in gm.get("groundingChunks", []):
    w = ch.get("web") or {}; uri = (w.get("uri") or "").strip()
    if not uri.startswith("http") or uri in seen: continue
    seen.add(uri)
    real = uri
    if "vertexaisearch.cloud.google.com" in uri:
        class NoRedirect(urllib.request.HTTPRedirectHandler):
            def redirect_request(self, *a, **k): return None
        try:
            urllib.request.build_opener(NoRedirect).open(urllib.request.Request(uri, method="HEAD"), timeout=8)
        except urllib.error.HTTPError as e:
            loc = e.headers.get("Location")
            if loc and loc.startswith("http"): real = loc
        except Exception:
            pass
    sources.append({"url": real, "title": w.get("title")})
    if len(sources) >= 10: break
u = d.get("usageMetadata") or {}
out = {"text": text.strip(), "sources": sources, "queries": gm.get("webSearchQueries", []),
       "usage": {"prompt": u.get("promptTokenCount", 0), "output": u.get("candidatesTokenCount", 0),
                 "thoughts": u.get("thoughtsTokenCount", 0), "total": u.get("totalTokenCount", 0)},
       "model": d.get("modelVersion") or sys.argv[2], "finishReason": c.get("finishReason", "UNKNOWN")}
print(json.dumps(out, ensure_ascii=False))
sys.exit(0 if out["text"] else 1)
EOF
  exit $?
done
if [ "$quota_exhausted" = "1" ]; then echo "усі ключі Gemini непридатні (429 без квоти / 400 невалідний / 403)" >&2; exit 2; fi
echo "жодного придатного ключа" >&2; exit 1

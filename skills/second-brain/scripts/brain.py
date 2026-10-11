"""Другий мозок: щотижневий ресьорч, сторінки тем, індекс, експорт HTML.

Лежить у <проєкт>/brain/brain.py. Усі шляхи — від розташування цього файлу, тому
робочий каталог планувальника не має значення. Лише стандартна бібліотека Python 3.9+.

  py -3 brain/brain.py weekly            тижневий прогін (ресьорч → дайджест → теми → індекс → доставка)
  py -3 brain/brain.py weekly --no-send  те саме без доставки (перший ручний прогін, перевірка)
  py -3 brain/brain.py export            brain-export/brain.html — одна сторінка для колег
  py -3 brain/brain.py check             перевірка структури (приймання)

Ресьорч робить headless Claude Code (`claude -p` з WebSearch/WebFetch) — підписка, не API.
"""
import datetime as dt
import html
import json
import os
import re
import shutil
import subprocess
import sys
import urllib.error
import urllib.parse
import urllib.request
import xml.etree.ElementTree as ET
from pathlib import Path

BRAIN = Path(__file__).resolve().parent
ROOT = BRAIN.parent
TG_LIMIT = 4000  # Telegram ріже на 4096; запас під підпис і розмітку
UA = "Mozilla/5.0 (second-brain weekly digest)"

NO_WINDOW = getattr(subprocess, "CREATE_NO_WINDOW", 0)  # Windows: планувальник не блимає консоллю

for stream in (sys.stdout, sys.stderr):
    if stream:  # під pyw.exe потоків немає — лишається лише лог
        stream.reconfigure(encoding="utf-8")


def log(msg):
    line = f"{dt.datetime.now():%Y-%m-%d %H:%M} {msg}"
    print(line)
    (BRAIN / "logs").mkdir(exist_ok=True)
    with open(BRAIN / "logs" / "weekly.log", "a", encoding="utf-8") as f:
        f.write(line + "\n")


def load_env():
    env = {}
    p = BRAIN / ".env"
    if p.exists():
        for line in p.read_text(encoding="utf-8").splitlines():
            if "=" in line and not line.strip().startswith("#"):
                k, v = line.split("=", 1)
                env[k.strip()] = v.strip().strip('"')
    env.update({k: v for k, v in os.environ.items() if k.startswith(("TELEGRAM_", "TG_", "CLAUDE_BIN"))})
    return env


def slug(name):
    s = re.sub(r"[^\w]+", "-", name.lower(), flags=re.UNICODE).strip("-")
    return s[:60] or "tema"


def parse_topics():
    """TOPICS.md: рядки `Ключ: значення` до першого `## ` — налаштування; далі `## Тема` + `- поле: …`."""
    text = (BRAIN / "TOPICS.md").read_text(encoding="utf-8")
    settings, topics, cur = {}, [], None
    for line in text.splitlines():
        if line.startswith("## "):
            cur = {"name": line[3:].strip(), "question": "", "sources": "", "rss": [], "keywords": ""}
            topics.append(cur)
            continue
        m = re.match(r"^\s*-?\s*([^:]{2,40}):\s*(.*)$", line)
        if not m:
            continue
        key, val = m.group(1).strip().lower(), m.group(2).strip()
        if cur is None:
            settings[key] = val
        elif key.startswith("питання"):
            cur["question"] = val
        elif key.startswith("джерела"):
            cur["sources"] = val
        elif key.startswith("rss"):
            cur["rss"] = [u for u in re.split(r"[\s,]+", val) if u.startswith("http")]
        elif key.startswith("ключові"):
            cur["keywords"] = val
    for t in topics:
        t["slug"] = slug(t["name"])
    if not topics:
        sys.exit("TOPICS.md без жодної теми `## …` — нема що шукати")
    return settings, topics


def week_id(day=None):
    y, w, _ = (day or dt.date.today()).isocalendar()
    return f"{y}-{w:02d}"


def norm_url(u):
    p = urllib.parse.urlsplit(u.strip())
    q = [(k, v) for k, v in urllib.parse.parse_qsl(p.query) if not k.lower().startswith(("utm_", "fbclid", "gclid"))]
    path = p.path.rstrip("/") or "/"
    return urllib.parse.urlunsplit((p.scheme.lower(), p.netloc.lower().removeprefix("www."), path, urllib.parse.urlencode(q), ""))


def seen_urls():
    p = BRAIN / "sources" / "urls.tsv"
    if not p.exists():
        return set()
    return {line.split("\t")[0] for line in p.read_text(encoding="utf-8").splitlines() if line}


def fetch_rss(urls, since):
    items = []
    for u in urls:
        try:
            req = urllib.request.Request(u, headers={"User-Agent": UA})
            root = ET.fromstring(urllib.request.urlopen(req, timeout=20).read())
        except Exception as e:  # стрічка лягла — тема все одно йде через веб-пошук
            log(f"  RSS недоступна {u}: {e}")
            continue
        for it in root.iter():
            tag = it.tag.split("}")[-1]
            if tag not in ("item", "entry"):
                continue
            get = lambda n: next((c for c in it if c.tag.split("}")[-1] == n), None)
            title = (get("title").text or "").strip() if get("title") is not None else ""
            link_el = get("link")
            link = (link_el.get("href") or link_el.text or "").strip() if link_el is not None else ""
            # не `or`: елемент без дочірніх вузлів у ElementTree — хибний
            date_el = next((e for e in (get("pubDate"), get("published"), get("updated")) if e is not None), None)
            date = parse_date(date_el.text if date_el is not None else "")
            if link and date and date >= since:
                items.append({"title": title, "url": link, "date": date.isoformat()})
    return items[:40]


def parse_date(s):
    s = (s or "").strip()
    if not s:
        return None
    try:
        return dt.date.fromisoformat(s[:10])
    except ValueError:
        pass
    try:
        from email.utils import parsedate_to_datetime
        return parsedate_to_datetime(s).date()
    except Exception:
        return None


def claude(prompt, tools=True, timeout=900):
    env = load_env()
    exe = env.get("CLAUDE_BIN") or shutil.which("claude") or shutil.which("claude.cmd")
    if not exe:
        raise RuntimeError("не знайдено `claude` — впиши повний шлях у brain/.env як CLAUDE_BIN=")
    cmd = [exe, "-p", "--output-format", "text"]
    if tools:
        cmd += ["--allowedTools", "WebSearch", "WebFetch"]
    r = subprocess.run(cmd, input=prompt, capture_output=True, text=True, encoding="utf-8",
                       timeout=timeout, cwd=ROOT, creationflags=NO_WINDOW)
    if r.returncode != 0 or not r.stdout.strip():
        raise RuntimeError(f"claude -p код {r.returncode}: {(r.stderr or r.stdout)[-400:]}")
    return r.stdout


def extract_json(text):
    m = re.search(r"\[.*\]", text, re.S)
    if not m:
        raise ValueError("у відповіді немає JSON-масиву")
    return json.loads(m.group(0))


def url_alive(u):
    """True — відкривається; None — сайт не пускає робота (403/429/5xx), лишаємо з позначкою; False — мертве."""
    try:
        req = urllib.request.Request(u, headers={"User-Agent": UA, "Range": "bytes=0-2048"})
        urllib.request.urlopen(req, timeout=15)
        return True
    except urllib.error.HTTPError as e:
        return False if e.code in (404, 410) else None
    except Exception:
        return False


def prompt_template(name):
    """Промпти беремо з prompts.md поруч зі скриптом — один текст для людини і для скрипта."""
    text = (BRAIN / "prompts.md").read_text(encoding="utf-8")
    m = re.search(rf"<!-- {name} -->\s*```text\n(.*?)\n```", text, re.S)
    if not m:
        sys.exit(f"у brain/prompts.md немає блоку <!-- {name} -->")
    return m.group(1)


def research(topic, settings, week, since, seen):
    limit = min(int(settings.get("знахідок на тему", "7")), 10)  # стеля: дайджест читають, а не гортають
    last = sorted((BRAIN / "digests").glob("*.md"))
    last_digest = last[-1].read_text(encoding="utf-8")[:6000] if last else "(це перший дайджест)"
    rss = fetch_rss(topic["rss"], since)
    prompt = prompt_template("research").format(
        topic=topic["name"], question=topic["question"] or topic["name"], keywords=topic["keywords"],
        sources=topic["sources"] or "(не вказано — шукай у відкритих джерелах)",
        lang=settings.get("мова", "українська"), since=since.isoformat(), today=dt.date.today().isoformat(),
        limit=limit, rss=json.dumps(rss, ensure_ascii=False, indent=1) if rss else "(RSS немає)",
        last_digest=last_digest, seen="\n".join(sorted(seen)[-300:]) or "(порожньо)")
    raw = claude(prompt)
    (BRAIN / "sources" / week).mkdir(parents=True, exist_ok=True)
    with open(BRAIN / "sources" / week / f"{topic['slug']}.raw.md", "a", encoding="utf-8") as f:
        f.write(f"\n\n<!-- прогін {dt.datetime.now():%Y-%m-%d %H:%M} -->\n{raw}")
    kept, dropped = [], []
    for f in extract_json(raw):
        url = str(f.get("url", "")).strip()
        date = parse_date(str(f.get("date", "")))
        key = norm_url(url) if url.startswith("http") else ""
        if not key:
            dropped.append(("без URL", f.get("title")))
        elif not date:
            dropped.append(("без дати", url))
        elif date < since or date > dt.date.today():
            dropped.append((f"дата {date} поза вікном", url))
        elif key in seen or key in {norm_url(k["url"]) for k in kept}:
            dropped.append(("вже було", url))
        else:
            alive = url_alive(url)
            if alive is False:
                dropped.append(("не відкривається", url))
                continue
            f["date"], f["checked"] = date.isoformat(), alive is True
            kept.append(f)
        if len(kept) >= limit:
            break
    for why, what in dropped:
        log(f"  відкинуто [{why}]: {what}")
    return kept


def finding_md(f):
    mark = "" if f.get("checked") else " ⚠️ сайт не пустив робота — перевір вручну"
    return (f"- **[{f.get('title', '').strip()}]({f['url']})** · {f['date']} · {f.get('source', '')}{mark}\n"
            f"  - Що нового: {f.get('what', '').strip()}\n"
            f"  - Чому важливо мені: {f.get('why', '').strip()}\n")


def update_topic_page(topic, findings, week, settings):
    page = BRAIN / "topics" / f"{topic['slug']}.md"
    old = page.read_text(encoding="utf-8") if page.exists() else ""
    summary_old = old.split("## Хронологія")[0]
    chronology = old.split("## Хронологія", 1)[1].strip() if "## Хронологія" in old else ""
    if findings:
        summary = claude(prompt_template("topic").format(
            topic=topic["name"], question=topic["question"], week=week, lang=settings.get("мова", "українська"),
            old=summary_old or "(сторінки ще немає)", new="".join(finding_md(f) for f in findings)), tools=False).strip()
        new = "".join(finding_md(f) for f in findings)
        head = f"### {week}\n"
        chronology = head + new + (chronology[len(head):] if chronology.startswith(head) else "\n" + chronology)
    else:
        summary = summary_old.strip() or f"# {topic['name']}\n\nПоки що нічого не знайдено."
    page.write_text(f"{summary}\n\n## Хронологія\n\n{chronology}\n", encoding="utf-8")


def write_index(topics):
    lines = ["# Карта другого мозку", "", f"Оновлено {dt.date.today():%d.%m.%Y}. Генерується скриптом — не правити руками.", "",
             "## Теми", ""]
    for t in topics:
        p = BRAIN / "topics" / f"{t['slug']}.md"
        n = len(re.findall(r"^- \*\*\[", p.read_text(encoding="utf-8"), re.M)) if p.exists() else 0
        lines.append(f"- [{t['name']}](topics/{t['slug']}.md) — знахідок: {n}")
    lines += ["", "## Дайджести", ""]
    for d in sorted((BRAIN / "digests").glob("*.md"), reverse=True):
        lines.append(f"- [{d.stem}](digests/{d.name})")
    own = sorted(p for p in (BRAIN / "sources" / "notes").glob("*") if p.is_file()) if (BRAIN / "sources" / "notes").exists() else []
    if own:
        lines += ["", "## Мої матеріали", ""] + [f"- [{p.name}](sources/notes/{p.name})" for p in own]
    (BRAIN / "INDEX.md").write_text("\n".join(lines) + "\n", encoding="utf-8")


def send(text, env):
    """TG_SEND_CMD — команда userbot'а (СКІЛ 2), текст іде в stdin; інакше Bot API."""
    chunks, cur = [], ""
    for block in text.split("\n\n"):
        if len(cur) + len(block) + 2 > TG_LIMIT:
            chunks.append(cur); cur = ""
        while len(block) > TG_LIMIT:
            chunks.append(block[:TG_LIMIT]); block = block[TG_LIMIT:]
        cur += block + "\n\n"
    chunks.append(cur)
    for c in filter(str.strip, chunks):
        if env.get("TG_SEND_CMD"):
            r = subprocess.run(env["TG_SEND_CMD"], input=c, shell=True, text=True, encoding="utf-8",
                               capture_output=True, cwd=ROOT, timeout=120, creationflags=NO_WINDOW)
            if r.returncode != 0:
                raise RuntimeError(f"TG_SEND_CMD код {r.returncode}: {r.stderr[-300:]}")
        elif env.get("TELEGRAM_BOT_TOKEN") and env.get("TELEGRAM_CHAT_ID"):
            data = urllib.parse.urlencode({"chat_id": env["TELEGRAM_CHAT_ID"], "text": c,
                                           "disable_web_page_preview": "true"}).encode()
            urllib.request.urlopen(f"https://api.telegram.org/bot{env['TELEGRAM_BOT_TOKEN']}/sendMessage",
                                   data=data, timeout=30)
        else:
            raise RuntimeError("доставка = telegram, але в brain/.env немає ні TG_SEND_CMD, ні TELEGRAM_BOT_TOKEN+TELEGRAM_CHAT_ID")


def weekly(no_send):
    settings, topics = parse_topics()
    week = week_id()
    since = dt.date.today() - dt.timedelta(days=int(settings.get("вікно днів", "14")))
    for d in ("sources", "digests", "topics"):
        (BRAIN / d).mkdir(exist_ok=True)
    seen = seen_urls()
    log(f"Тиждень {week}: {len(topics)} тем, вікно з {since}, у пам'яті {len(seen)} URL")
    sections, failed, all_new = [], [], []
    for t in topics:
        log(f"Тема «{t['name']}»")
        try:
            found = research(t, settings, week, since, seen)
        except Exception as e:
            log(f"  ПОМИЛКА: {e}")
            failed.append(t["name"])
            sections.append(f"## {t['name']}\n\n❌ Ресьорч не вдався: {e}\n")
            continue
        log(f"  лишилось {len(found)}")
        update_topic_page(t, found, week, settings)
        seen |= {norm_url(f["url"]) for f in found}
        all_new += [(f, t) for f in found]
        # повторний прогін того ж тижня дописує, а не перетирає знайдене раніше
        kept_file = BRAIN / "sources" / week / f"{t['slug']}.json"
        week_items = json.loads(kept_file.read_text(encoding="utf-8")) if kept_file.exists() else []
        week_items += found
        kept_file.write_text(json.dumps(week_items, ensure_ascii=False, indent=1), encoding="utf-8")
        body = "".join(finding_md(f) for f in week_items) or "Нічого нового за вікно — це теж відповідь.\n"
        sections.append(f"## {t['name']}\n\n{body}")
    digest = BRAIN / "digests" / f"{week}.md"
    digest.write_text(f"# Дайджест {week}\n\nЗгенеровано {dt.datetime.now():%d.%m.%Y %H:%M}. "
                      f"Вікно: {since} — {dt.date.today()}.\n\n" + "\n".join(sections), encoding="utf-8")
    with open(BRAIN / "sources" / "urls.tsv", "a", encoding="utf-8") as f:
        for item, t in all_new:
            f.write(f"{norm_url(item['url'])}\t{week}\t{t['slug']}\n")
    write_index(topics)
    log(f"Дайджест: {digest}")
    if settings.get("експорт у"):
        log(f"Експорт: {export()}")
    if settings.get("доставка", "telegram").lower().startswith("tel") and not no_send:
        msg = [f"🧠 Другий мозок · тиждень {week}"]
        for t in topics:
            items = [f for f, tt in all_new if tt is t][:3]
            msg.append(f"▪️ {t['name']}" + ("".join(f"\n— {f.get('title','').strip()}\n{f['url']}" for f in items) or "\n— нічого нового"))
        msg.append(f"Повний дайджест: brain/digests/{week}.md")
        send("\n\n".join(msg), load_env())
        log("Надіслано в Telegram")
    if failed:
        sys.exit(f"Теми без ресьорчу: {', '.join(failed)} — див. brain/logs/weekly.log")


def md_to_html(md):
    out, in_list = [], 0
    def link(m):
        text, target = m.group(1), m.group(2)
        if target.startswith("http"):
            return f'<a href="{target}">{text}</a>'
        if target.endswith(".md"):  # теми й дайджести — секції цієї ж сторінки
            return f'<a href="#{slug(Path(target).stem)}">{text}</a>'
        return f"{text} (файл у brain/, в експорт не входить)"

    def inline(s):
        s = re.sub(r"\[([^\]]+)\]\(([^)]+)\)", link, html.escape(s))
        return re.sub(r"\*\*(.+?)\*\*", r"<b>\1</b>", s)
    for line in md.splitlines():
        m = re.match(r"^(\s*)- (.*)", line)
        depth = len(m.group(1)) // 2 + 1 if m else 0
        while in_list > depth:
            out.append("</ul>"); in_list -= 1
        while in_list < depth:
            out.append("<ul>"); in_list += 1
        if m:
            out.append(f"<li>{inline(m.group(2))}</li>")
        elif line.startswith("#"):
            lvl = min(len(line) - len(line.lstrip("#")) + 1, 6)
            out.append(f"<h{lvl}>{inline(line.lstrip('#').strip())}</h{lvl}>")
        elif line.strip():
            out.append(f"<p>{inline(line)}</p>")
    out += ["</ul>"] * in_list
    return "\n".join(out)


def export():
    settings, topics = parse_topics()
    parts = [f'<section id="index">{md_to_html((BRAIN / "INDEX.md").read_text(encoding="utf-8"))}</section>']
    for t in topics:
        p = BRAIN / "topics" / f"{t['slug']}.md"
        if p.exists():
            parts.append(f'<section id="{t["slug"]}">{md_to_html(p.read_text(encoding="utf-8"))}<p><a href="#index">↑ до карти</a></p></section>')
    for d in sorted((BRAIN / "digests").glob("*.md"), reverse=True):
        parts.append(f'<section id="{slug(d.stem)}">{md_to_html(d.read_text(encoding="utf-8"))}<p><a href="#index">↑ до карти</a></p></section>')
    css = ("body{font:16px/1.55 system-ui,sans-serif;max-width:860px;margin:0 auto;padding:16px;color:#1d1d1f;background:#fff}"
           "section{border-top:1px solid #ddd;padding-top:8px;margin-top:24px}a{color:#0b57d0}"
           "@media(prefers-color-scheme:dark){body{background:#151515;color:#eee}a{color:#8ab4f8}section{border-color:#333}}")
    out = ROOT / "brain-export"
    out.mkdir(exist_ok=True)
    (out / "brain.html").write_text(f'<!doctype html><html lang="uk"><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">'
                                    f"<title>Другий мозок</title><style>{css}</style><body>{''.join(parts)}</body></html>", encoding="utf-8")
    result = out / "brain.html"
    if settings.get("експорт у"):  # спільна тека Google Drive / OneDrive — синхронізує їхній клієнт
        dest = Path(settings["експорт у"]).expanduser()
        dest.mkdir(parents=True, exist_ok=True)
        result = Path(shutil.copy(result, dest / "brain.html"))
    print(result)
    return result


def check():
    problems = []
    for p in ("TOPICS.md", "prompts.md", "INDEX.md", "sources", "digests", "topics"):
        if not (BRAIN / p).exists():
            problems.append(f"немає brain/{p}")
    if not list((BRAIN / "digests").glob("*.md")):
        problems.append("ще немає жодного дайджесту — запусти weekly")
    settings, topics = parse_topics()
    for t in topics:
        if not (BRAIN / "topics" / f"{t['slug']}.md").exists():
            problems.append(f"немає сторінки теми topics/{t['slug']}.md")
    claude_md = ROOT / "CLAUDE.md"
    if not claude_md.exists() or "Другий мозок" not in claude_md.read_text(encoding="utf-8"):
        problems.append("у CLAUDE.md проєкту немає правила «Другий мозок»")
    gi = ROOT / ".gitignore"
    if (ROOT / ".git").exists():
        ignored = gi.read_text(encoding="utf-8") if gi.exists() else ""
        problems += [f"{p} не в .gitignore" for p in ("brain/.env", ".session") if p not in ignored]
    print("\n".join(problems) or f"OK: {len(topics)} тем, структура на місці")
    sys.exit(1 if problems else 0)


if __name__ == "__main__":
    cmd = sys.argv[1] if len(sys.argv) > 1 else ""
    if cmd == "weekly":
        try:
            weekly("--no-send" in sys.argv)
        except SystemExit as e:
            if e.code:
                log(f"ЗАВЕРШЕНО З ПОМИЛКОЮ: {e.code}")
            raise
        except Exception:
            import traceback
            log("ЗБІЙ:\n" + traceback.format_exc())
            sys.exit(1)
    elif cmd == "export":
        export()
    elif cmd == "check":
        check()
    else:
        sys.exit(__doc__)

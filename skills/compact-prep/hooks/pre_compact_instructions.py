"""PreCompact hook for Claude Code: the same 7 sections for AUTOMATIC compaction.

stdout of a successful PreCompact hook is appended to the compaction instructions,
so the automatic summary keeps the structure too. Manual /compact with its own block
(from /compact-prep) is left alone.

Installed by scripts/install.py (copies it to ~/.claude/hooks/compact_prep_pre_compact.py and registers
PreCompact matcher "auto" in settings.json).
"""
import json
import sys


def main() -> None:
    try:
        sys.stdout.reconfigure(encoding="utf-8")
    except Exception:
        pass
    try:
        p = json.load(sys.stdin)
    except Exception:
        return
    if not isinstance(p, dict) or p.get("trigger") != "auto":
        return
    transcript = p.get("transcript_path", "?")
    print(
        "Збережи ДОСЛІВНО під 7 заголовками (причини зникають першими). Пиши українською.\n"
        "- РІШЕННЯ — що вирішили і ЧОМУ, з відкинутими варіантами і умовою перегляду; хто вирішив (слова користувача — дослівно)\n"
        "- ЧЕРГА — задачі з пріоритетом, кожна в одній актуальній версії; окремо що чекає на користувача\n"
        "- ЗАРАЗ — активна задача або жива помилка + наступний крок однією дією\n"
        "- ШЛЯХИ І ЗНАЧЕННЯ — гілка, точні файли, номери PR, ID, прапорці, URL, константи — символ у символ; "
        f"транскрипт цієї сесії: {transcript} — якщо після стиснення бракує деталі, спершу грепни цей файл\n"
        "- ЛІЧИЛЬНИКИ — цифри самоперевірки + що НЕ доведено («зроблено й перевірено» / «не перевірено» / «лише спробувано»)\n"
        "- ВІДКРИТЕ — що зламалось чи лишилось; граблі з симптомом; фонові процеси, що ще біжать\n"
        "- ІНСТРУМЕНТИ І ДОМОВЛЕНОСТІ — скрипти, сервіси, формати; конкретні правила користувача з причиною; що обіцяно людям\n"
        "Те, що працює, — один рядок. Викинь пошук помилок туди-сюди, мертві гіпотези, вміст файлів, логи. Секрети не пиши."
    )


if __name__ == "__main__":
    main()

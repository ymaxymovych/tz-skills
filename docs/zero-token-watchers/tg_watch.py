"""Read-only Telegram watcher; no model/API-token usage and no interactive login."""
import argparse
import asyncio
import datetime as dt
import json
import os
from pathlib import Path
import sys
from telethon import TelegramClient
from telethon.sessions import StringSession
p = argparse.ArgumentParser(description=__doc__)
p.add_argument('--chats', required=True, help='Comma-separated numeric chat IDs')
p.add_argument('--interval', type=float, default=300)
p.add_argument('--until', help='Next local HH:MM slot(s), comma-separated')
p.add_argument('--state', type=Path, default=Path(os.getenv('LOCALAPPDATA', str(Path.home()))) / 'tgwatch/state.json')
p.add_argument('--me-is-sender-skip', action='store_true', help='Compatibility flag: only signed own messages are skipped (also the default)')
p.add_argument('--env', type=Path, default=Path(os.getenv('TELEGRAM_MCP_ENV', str(Path.home() / 'telegram-mcp/.env'))), help='Path to telegram-mcp .env (TELEGRAM_SESSION_STRING, TELEGRAM_API_ID, TELEGRAM_API_HASH)')
p.add_argument('--dry-run', action='store_true', help='Classify last three messages per chat without changing state')
a = p.parse_args()
if a.interval <= 0:
    p.error('--interval must be positive')
try:
    chats = list(dict.fromkeys(int(x) for x in a.chats.split(',')))
    now = dt.datetime.now()
    slots = []
    for value in (a.until.split(',') if a.until else []):
        hour, minute = value.split(':')
        slot = now.replace(hour=int(hour), minute=int(minute), second=0, microsecond=0)
        slots.append((slot if slot >= now else slot + dt.timedelta(days=1), value))
except ValueError:
    p.error('Use numeric chat IDs and valid HH:MM slots')
sys.stdout.reconfigure(encoding='utf-8')
sys.stderr.reconfigure(encoding='utf-8')
async def main():
    client, failures, me, peers = None, 0, None, {}
    state = json.loads(a.state.read_text(encoding='utf-8')) if a.state.exists() else {}
    if not isinstance(state, dict) or any(type(v) is not int or v < 0 for v in state.values()):
        raise ValueError('State must map chat IDs to nonnegative message IDs')
    try:
        env = {}
        for line in a.env.read_text(encoding='utf-8-sig').splitlines():
            key, sep, value = line.strip().removeprefix('export ').partition('=')
            if sep and not key.startswith('#'):
                env[key.strip()] = value.strip().strip('\"\'')
        client = TelegramClient(StringSession(env['TELEGRAM_SESSION_STRING']), int(env['TELEGRAM_API_ID']), env['TELEGRAM_API_HASH'], request_retries=0, connection_retries=0, flood_sleep_threshold=0)
        while True:
            retry_delay = a.interval
            try:
                async def poll():
                    nonlocal me, peers
                    if not client.is_connected():
                        await client.connect()
                    if me is None:
                        if not await client.is_user_authorized():
                            raise RuntimeError('Telegram session is not authorized')
                        me = await client.get_me()
                    pending, reports = dict(state), []
                    for chat in chats:
                        if chat not in peers:
                            try:
                                peers[chat] = await client.get_input_entity(chat)
                            except ValueError:
                                await client.get_dialogs(limit=100)
                                peers[chat] = await client.get_input_entity(chat)
                        key, messages = str(chat), []
                        if a.dry_run or key not in state:
                            messages = await client.get_messages(peers[chat], limit=3 if a.dry_run else 1)
                        else:
                            offset = 0
                            while True:
                                page = await client.get_messages(peers[chat], min_id=state[key], offset_id=offset, limit=50)
                                messages.extend(page)
                                if len(page) < 50:
                                    break
                                offset = page[-1].id
                        pending[key] = max([pending.get(key, 0)] + [m.id for m in messages])
                        for m in reversed(messages):
                            own = m.out or m.sender_id == me.id
                            report = not (own and 'Відправлено моїм AI-помічником' in (m.raw_text or ''))
                            if a.dry_run or (key in state and report):
                                sender = await m.get_sender()
                                name = ' '.join(filter(None, [getattr(sender, 'first_name', ''), getattr(sender, 'last_name', '')])) or getattr(sender, 'title', '') or str(m.sender_id)
                                label = ('WOULD_REPORT' if report else 'WOULD_SKIP') + ' ' if a.dry_run else ''
                                reports.append(f'{label}chat={chat} date={m.date.astimezone().isoformat()} sender={name}\n{(m.raw_text or "[non-text message]")[:1500]}')
                    return pending, reports
                pending, reports = await asyncio.wait_for(poll(), timeout=45)
                if not a.dry_run and (pending != state or not a.state.exists()):
                    a.state.parent.mkdir(parents=True, exist_ok=True)
                    temp = a.state.with_suffix(a.state.suffix + '.tmp')
                    temp.write_text(json.dumps(pending, indent=2), encoding='utf-8')
                    temp.replace(a.state)
                    state = pending
                failures = 0
                if reports or a.dry_run:
                    print('\n\n'.join(reports), flush=True)
                    return 0
            except Exception as exc:
                failures += 1
                retry_delay = min(60, max(a.interval, getattr(exc, 'seconds', 0)))
                print(f'ERROR poll {failures}/3: {type(exc).__name__}: {exc}', file=sys.stderr, flush=True)
                if failures >= 3:
                    return 3
            now = dt.datetime.now()
            if slots and now >= min(slots)[0] and failures == 0:
                print(f'TICK {min(slots)[1]} status_slot=yes', flush=True)
                return 0
            delay = retry_delay
            if slots and failures == 0:
                delay = min(delay, max(0, (min(slots)[0] - now).total_seconds()))
            await asyncio.sleep(delay)
    finally:
        if client is not None:
            await client.disconnect()

try:
    sys.exit(asyncio.run(main()))
except KeyboardInterrupt:
    sys.exit(130)
except Exception as exc:
    print(f'ERROR: {type(exc).__name__}: {exc}', file=sys.stderr)
    sys.exit(3)

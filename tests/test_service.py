from datetime import datetime, timezone
import json
from pathlib import Path
import sqlite3
import stat
import subprocess
import tempfile
import unittest
from uuid import UUID


from collector_probe import command


class LocalServiceTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name).resolve()
        self.home = self.root / 'codex'
        self.sessions = self.home / 'sessions'
        self.sessions.mkdir(parents=True)
        self.config = self.root / 'app-support' / 'office.json'
        self.command = command(self.home, self.config)

    def request(self, *requests):
        lines = ''.join(json.dumps(request) + '\n' for request in requests)
        result = subprocess.run(self.command, input=lines, capture_output=True, text=True, check=True, timeout=5)
        self.assertEqual(result.stderr, '')
        return [json.loads(line) for line in result.stdout.splitlines()]

    def test_migration_and_settings_round_trip_without_http_service(self):
        legacy = self.root / 'previous.json'
        project = self.root / 'configured-project'
        project.mkdir()
        identifier = str(UUID(int=21))
        legacy_office = {'projects': {str(project): 'Existing alias'},
                         'coordination_section': 'Existing section', 'thread_projects': {identifier: str(project)}}
        migrated_office = {**legacy_office, 'menu_bar_metric': 'token_speed', 'visible_sections': None,
                           'language': 'zh-CN', 'live_quota': False}
        legacy.write_text(json.dumps({**legacy_office, 'always_on_top': True, 'other': 'do not copy'}))
        original = legacy.read_bytes()
        result = subprocess.run([*self.command, '--import-settings', str(legacy)], capture_output=True, timeout=5)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(legacy.read_bytes(), original)
        self.assertEqual(stat.S_IMODE(self.config.stat().st_mode), 0o600)
        now = datetime.now(timezone.utc).isoformat()
        events = [
            {'timestamp': now, 'type': 'session_meta', 'payload': {'id': identifier, 'cwd': str(self.root)}},
            {'timestamp': now, 'type': 'event_msg', 'payload': {'type': 'task_started', 'turn_id': 'turn-a'}},
        ]
        (self.sessions / 'rollout.jsonl').write_text(''.join(json.dumps(row) + '\n' for row in events))
        loaded, snapshot, saved, rejected, after = self.request(
            {'operation': 'loadSettings'}, {'operation': 'snapshot'},
            {'operation': 'saveSettings', 'changes': {'coordination_section': None}},
            {'operation': 'saveSettings', 'changes': {'projects': {'relative/path': 'bad'}}},
            {'operation': 'loadSettings'},
        )
        self.assertEqual(loaded['office'], migrated_office)
        self.assertEqual(snapshot['source_status'], 'ok')
        self.assertEqual(snapshot['coordination']['section'], legacy_office['coordination_section'])
        self.assertEqual(snapshot['threads'][0]['project_id'], snapshot['projects'][0]['id'])
        self.assertEqual(snapshot['threads'][0]['status'], 'running')
        self.assertEqual(saved['office'], {**migrated_office, 'coordination_section': None})
        self.assertIn('error', rejected)
        self.assertEqual(after, saved)
        repeated = subprocess.run([*self.command, '--import-settings', str(legacy)], capture_output=True, timeout=5)
        self.assertNotEqual(repeated.returncode, 0)
        self.assertEqual(self.request({'operation': 'loadSettings'}), [saved])

    def test_menu_bar_selection_is_validated_and_restored_after_restart(self):
        saved, snapshot, rejected = self.request(
            {'operation': 'saveSettings', 'changes': {'menu_bar_metric': 'plan_remaining'}},
            {'operation': 'snapshot'},
            {'operation': 'saveSettings', 'changes': {'menu_bar_metric': 'other'}},
        )
        self.assertEqual(saved['office']['menu_bar_metric'], 'plan_remaining')
        self.assertEqual(snapshot['menu_bar_metric'], 'plan_remaining')
        self.assertIn('error', rejected)
        self.assertEqual(self.request({'operation': 'loadSettings'}), [saved])

    def test_live_quota_is_off_by_default_and_accepts_only_booleans(self):
        initial, enabled, rejected, after = self.request(
            {'operation': 'loadSettings'},
            {'operation': 'saveSettings', 'changes': {'live_quota': True}},
            {'operation': 'saveSettings', 'changes': {'live_quota': 0}},
            {'operation': 'loadSettings'},
        )
        self.assertIs(initial['office']['live_quota'], False)
        self.assertIs(enabled['office']['live_quota'], True)
        self.assertIn('error', rejected)
        self.assertEqual(after, enabled)

    def test_interface_language_persists_without_changing_configured_section(self):
        identifier = str(UUID(int=21))
        now = datetime.now(timezone.utc).isoformat()
        records = [
            {'type': 'session_meta', 'timestamp': now, 'payload': {'id': identifier, 'cwd': str(self.root)}},
            {'type': 'event_msg', 'timestamp': now, 'payload': {'type': 'task_started', 'turn_id': 'turn-a'}},
        ]
        (self.sessions / 'rollout.jsonl').write_text(''.join(json.dumps(record) + '\n' for record in records))
        initial, configured, saved, snapshot, rejected = self.request(
            {'operation': 'loadSettings'},
            {'operation': 'saveSettings', 'changes': {'coordination_section': '跨项目协作'}},
            {'operation': 'saveSettings', 'changes': {'language': 'en'}},
            {'operation': 'snapshot'},
            {'operation': 'saveSettings', 'changes': {'language': 'fr'}},
        )
        self.assertIsNone(initial['office']['coordination_section'])
        self.assertEqual(configured['office']['coordination_section'], '跨项目协作')
        self.assertEqual(saved['office']['language'], 'en')
        self.assertEqual(saved['office']['coordination_section'], '跨项目协作')
        self.assertTrue(snapshot['threads'][0]['title'].startswith('Codex chat · '))
        self.assertIn('error', rejected)
        self.assertEqual(self.request({'operation': 'loadSettings'}), [saved])

    def test_sidebar_filter_persists_ids_across_section_renames(self):
        identifier = str(UUID(int=21))
        db_path = self.home / 'state_5.sqlite'
        with sqlite3.connect(db_path) as connection:
            connection.executescript("""
                CREATE TABLE thread_sections (id TEXT, name TEXT, position INT);
                CREATE TABLE threads (id TEXT, thread_section_id TEXT);
                INSERT INTO thread_sections VALUES ('work', 'Work', 1), ('lab', 'Lab', 2);
            """)
            connection.execute("INSERT INTO threads VALUES (?, 'work')", [identifier])
        now = datetime.now(timezone.utc).isoformat()
        rows = [
            {'type': 'session_meta', 'timestamp': now, 'payload': {'id': identifier, 'cwd': str(self.root)}},
            {'type': 'event_msg', 'timestamp': now, 'payload': {'type': 'task_started', 'turn_id': 'turn-a'}},
        ]
        (self.sessions / 'rollout.jsonl').write_text(''.join(json.dumps(row) + '\n' for row in rows))
        loaded, saved, snapshot, invalid = self.request(
            {'operation': 'loadSettings'},
            {'operation': 'saveSettings', 'changes': {'visible_sections': ['work', None]}},
            {'operation': 'snapshot'},
            {'operation': 'saveSettings', 'changes': {'visible_sections': ['lab', 'lab']}},
        )
        self.assertIsNone(loaded['office']['visible_sections'])
        self.assertEqual(loaded['sidebar']['sections'], [{'id': 'work', 'name': 'Work'}, {'id': 'lab', 'name': 'Lab'}])
        self.assertEqual(saved['office']['visible_sections'], ['work', None])
        self.assertEqual(snapshot['visible_sections'], ['work', None])
        self.assertEqual(snapshot['threads'][0]['section_id'], 'work')
        self.assertIn('error', invalid)
        with sqlite3.connect(db_path) as connection:
            connection.execute("UPDATE thread_sections SET name='Renamed' WHERE id='work'")
            connection.execute("UPDATE threads SET thread_section_id=NULL")
        renamed, moved, hidden, restored = self.request(
            {'operation': 'loadSettings'}, {'operation': 'snapshot'},
            {'operation': 'saveSettings', 'changes': {'visible_sections': []}},
            {'operation': 'saveSettings', 'changes': {'visible_sections': None}},
        )
        self.assertEqual(renamed['office']['visible_sections'], ['work', None])
        self.assertEqual(renamed['sidebar']['sections'][0], {'id': 'work', 'name': 'Renamed'})
        self.assertIsNone(moved['threads'][0]['section_id'])
        self.assertEqual(hidden['office']['visible_sections'], [])
        self.assertIsNone(restored['office']['visible_sections'])

    def test_first_launch_with_no_settings_or_rollouts(self):
        self.sessions.rmdir()
        loaded, snapshot, usage = self.request(
            {'operation': 'loadSettings'}, {'operation': 'snapshot'}, {'operation': 'tokenUsage'},
        )
        self.assertEqual(loaded['office']['projects'], {})
        self.assertFalse(self.config.exists())
        self.assertEqual(snapshot['source_status'], 'unavailable')
        self.assertEqual(usage['live_status'], 'unavailable')
        self.assertIsNone(usage['today_tokens'])
        self.assertIsNone(usage['quota'])

from datetime import datetime, timedelta, timezone
from hashlib import sha256
import json
import os
from pathlib import Path
import sqlite3
import tempfile
import unittest
from uuid import UUID

from collector_probe import CollectorProbe


def project_id(path):
    return sha256(os.fsencode(path.resolve())).hexdigest()[:24]


class CodexActivityTests(unittest.TestCase):
    def setUp(self):
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        self.root = Path(temp.name).resolve()
        self.home = self.root / "codex"
        self.sessions = self.home / "sessions"
        self.sessions.mkdir(parents=True)
        self.projects = self.root / "projects"
        self.a, self.b = (self.projects / name for name in ("project-a", "project-b"))
        for project in (self.a, self.b):
            (project / ".git").mkdir(parents=True)
        self.config = self.root / "projects.json"
        self.probe = CollectorProbe(self.home, self.config)
        self.addCleanup(self.probe.close)
        self.attention = {}
        self.now = datetime.now(timezone.utc).replace(microsecond=0)
        self.owner = str(UUID(int=1))
        self.turn = "turn-owner"

    def record(self, envelope, offset, **payload):
        return {"type": envelope, "timestamp": (self.now + timedelta(seconds=offset)).isoformat(),
                "payload": payload}

    def start(self, owner, project, turn, offset=0, **metadata):
        path = self.sessions / f"rollout-{owner}.jsonl"
        self.write(path, self.record("session_meta", offset, id=owner, cwd=str(project), **metadata),
                   self.record("event_msg", offset + 1, type="task_started", turn_id=turn))
        return path

    def write(self, path, *rows):
        with path.open("a", encoding="utf-8") as handle:
            for row in rows:
                handle.write(json.dumps(row) + "\n")

    def change(self, owner, turn, offset, identifier, targets, status="completed"):
        return self.record("event_msg", offset, type="item_completed", thread_id=owner, turn_id=turn, item={
            "type": "FileChange", "id": identifier, "status": status,
            "changes": {str(target): {"type": "update", "unified_diff": "private patch"} for target in targets},
            "stdout": "private output",
        })

    def rows(self, elapsed=20):
        snapshot = self.scan(elapsed)
        return {row["id"]: row for row in snapshot["threads"]}

    def scan(self, elapsed=0):
        return self.probe.request("snapshot", now=self.now.timestamp() + elapsed, attention=self.attention)

    def sidebar(self, *rows):
        con = sqlite3.connect(self.home / "state_5.sqlite")
        try:
            with con:
                con.executescript(
                    "CREATE TABLE thread_sections (id TEXT, name TEXT);"
                    "CREATE TABLE threads (id TEXT, cwd TEXT, name TEXT, updated_at INTEGER,"
                    "archived INTEGER, thread_section_id TEXT, rollout_path TEXT);"
                )
                con.execute("INSERT INTO thread_sections VALUES ('section-a', '跨项目协作')")
                con.executemany("INSERT INTO threads VALUES (?, ?, ?, ?, ?, ?, ?)", rows)
        finally:
            con.close()

    def dispatch(self, owner, turn, offset, recipient, tool="send_message_to_thread", **overrides):
        item = {
            "type": "McpToolCall", "status": "completed", "tool": tool,
            "server": "codex_app", "pluginId": "codex-app-tools@openai-bundled",
            "arguments": {"threadId": recipient, "prompt": "private dispatch content"},
            "result": {"isError": False, "content": [{"type": "text", "text": json.dumps({"threadId": recipient})}]},
        }
        item.update(overrides)
        return self.record("event_msg", offset, type="item_completed", thread_id=owner, turn_id=turn, item=item)

    def test_successful_cross_project_write_stays_on_source_thread(self):
        path = self.start(self.owner, self.a, self.turn)
        child = str(UUID(int=2))
        self.start(child, self.a, "turn-child", session_id=self.owner, parent_thread_id=self.owner)
        self.write(path,
                   self.record("turn_context", 2, turn_id=self.turn, cwd=str(self.b)),
                   self.change(self.owner, self.turn, 3, "local", [self.a / "a.py"]),
                   self.change(self.owner, self.turn, 4, "failure", [self.b / "failed.py"], "failed"),
                   self.change(child, self.turn, 5, "other-thread", [self.b / "other.py"]),
                   self.record("event_msg", 6, type="item_completed", thread_id=self.owner, turn_id=self.turn,
                               item={"type": "CommandExecution", "status": "completed",
                                     "command": ["echo", str(self.b)], "exit_code": 0}))
        self.assertEqual(self.rows()[self.owner]["cross_edits"], [])
        change = self.change(self.owner, self.turn, 7, "real", [self.b / "changed.py", self.b / "second.py"])
        self.write(path, change, change)
        rows = self.rows()
        owner = rows[self.owner]
        self.assertEqual(owner["project_id"], project_id(self.a))
        self.assertEqual(owner["status"], "running")
        self.assertIsNone(owner["token_total"])
        self.assertEqual(len(owner["cross_edits"]), 1)
        self.assertEqual(owner["cross_edits"][0]["project_id"], project_id(self.b))
        self.assertEqual(set(rows), {self.owner, child})
        self.assertEqual(rows[child]["parent_id"], self.owner)
        self.assertEqual(rows[child]["root_id"], self.owner)
        self.assertNotIn("private", json.dumps(rows))
        self.assertNotIn("changed.py", json.dumps(rows))

    def test_confirmed_wait_keeps_the_root_visible_and_clears_after_reply(self):
        parent = self.start(self.owner, self.a, self.turn)
        child = str(UUID(int=2))
        child_path = self.start(child, self.a, "child-turn", session_id=self.owner, parent_thread_id=self.owner)
        self.attention = {
            child: {"owner": "desktop", "revision": 1, "status": "active", "flags": ["waitingOnApproval"]},
        }
        rows = self.rows()
        self.assertEqual(rows[self.owner]["status"], "waiting")
        self.assertEqual(rows[self.owner]["attention_thread_id"], child)
        self.assertEqual(rows[self.owner]["project_id"], project_id(self.a))
        self.assertEqual(self.rows(1860)[self.owner]["status"], "waiting")
        self.attention = {self.owner: {"owner": "desktop", "revision": 2, "status": "active", "flags": []}}
        rows = self.rows(1860)
        self.assertEqual(rows[self.owner]["status"], "running")
        self.assertIsNone(rows[self.owner]["attention_thread_id"])
        self.write(child_path, self.record("event_msg", 21, type="task_complete", turn_id="child-turn"))
        self.write(parent, self.record("event_msg", 22, type="task_complete", turn_id=self.turn))
        self.attention = {}
        self.assertEqual(self.rows(24)[self.owner]["status"], "completed")
        self.assertEqual(self.scan(24)["polled"], [])

    def test_unreadable_sidebar_keeps_last_known_membership(self):
        path = self.start(self.owner, self.a, self.turn)
        self.sidebar((self.owner, str(self.a), "Chat", int(self.now.timestamp()), 0, "section-a", str(path)))
        self.assertEqual(self.rows()[self.owner]["section_id"], "section-a")
        (self.home / "state_5.sqlite").rename(self.home / "unavailable.sqlite")
        new_chat = str(UUID(int=2))
        self.start(new_chat, self.a, "new-turn")
        rows = self.rows()
        self.assertEqual(rows[self.owner]["section_id"], "section-a")
        self.assertNotIn("section_id", rows[new_chat])

    def test_partial_append_abort_and_new_turn(self):
        path = self.start(self.owner, self.a, self.turn)
        row = self.record("event_msg", 2, type="turn_aborted", turn_id=self.turn)
        encoded = json.dumps(row)
        with path.open("a", encoding="utf-8") as handle:
            handle.write(encoded[:20])
        self.assertEqual(self.rows()[self.owner]["status"], "running")
        with path.open("a", encoding="utf-8") as handle:
            handle.write(encoded[20:] + "\n")
        self.write(path, self.record("event_msg", 3, type="task_complete", turn_id=self.turn))
        self.assertEqual(self.rows()[self.owner]["status"], "interrupted")
        self.write(path, self.record("event_msg", 4, type="task_started", turn_id="new"),
                   self.change(self.owner, self.turn, 5, "late", [self.b / "old.py"]),
                   self.change(self.owner, "new", 6, "new", [self.b / "new.py"]))
        owner = self.rows()[self.owner]
        self.assertEqual(owner["status"], "running")
        self.assertEqual(len(owner["cross_edits"]), 1)
        self.assertIsNone(owner["terminal_at"])
        self.assertEqual(self.rows(1860)[self.owner]["status"], "unknown")

    def test_rewritten_rollout_and_fork_history_do_not_replace_identity(self):
        path = self.start(self.owner, self.a, self.turn, forked_from_id=str(UUID(int=2)))
        self.rows()
        # Rewrite the same inode, including old copied history after the new envelope.
        path.write_text("", encoding="utf-8")
        parent = str(UUID(int=2))
        self.write(path, self.record("session_meta", 8, id=self.owner, cwd=str(self.a), forked_from_id=parent),
                   self.record("session_meta", -100, id=parent, cwd=str(self.b)),
                   self.record("event_msg", -99, type="task_started", turn_id="copied"),
                   self.change(parent, "copied", -90, "copied", [self.b / "old.py"]),
                   self.record("event_msg", 9, type="task_started", turn_id="actual"))
        owner = self.rows()[self.owner]
        self.assertEqual(owner["status"], "running")
        self.assertEqual(owner["project_id"], project_id(self.a))
        self.assertIsNone(owner["parent_id"])
        self.assertEqual(owner["cross_edits"], [])

    def test_spawned_agents_keep_their_main_thread_across_forks_and_nesting(self):
        owner_path = self.start(self.owner, self.a, self.turn)
        child, nested, ordinary = (str(UUID(int=i)) for i in (2, 3, 4))
        self.start(child, self.b, "agent", session_id=self.owner, forked_from_id=self.owner,
                   parent_thread_id=self.owner, thread_source="subagent",
                   source={"subagent": {"thread_spawn": {"parent_thread_id": self.owner}}})
        self.start(nested, self.b, "nested", session_id=child, parent_thread_id=child)
        self.start(ordinary, self.b, "fork", session_id=self.owner, forked_from_id=self.owner,
                   parent_thread_id=self.owner)
        self.write(owner_path, self.record("event_msg", 7, type="task_complete", turn_id=self.turn))
        self.attention = {
            nested: {"owner": "desktop", "revision": 1, "status": "active", "flags": ["waitingOnApproval"]},
        }
        rows = self.rows()
        self.assertEqual(rows[child]["parent_id"], self.owner)
        self.assertEqual(rows[nested]["parent_id"], child)
        self.assertEqual(rows[nested]["root_id"], self.owner)
        self.assertEqual(rows[nested]["project_id"], project_id(self.a))
        self.assertEqual(rows[self.owner]["status"], "waiting")
        self.assertEqual(rows[self.owner]["attention_thread_id"], nested)
        self.assertEqual(rows[ordinary]["root_id"], ordinary)
        self.assertIsNone(rows[ordinary]["parent_id"])

    def test_local_project_override_and_linked_worktree(self):
        linked = self.root / "codex-worktree" / "linked"
        linked.mkdir(parents=True)
        (linked / ".git").write_text(f"gitdir: {self.a}/.git/worktrees/linked\n", encoding="utf-8")
        self.start(self.owner, linked, self.turn)
        self.assertEqual(self.rows()[self.owner]["project_id"], project_id(self.a))
        self.config.write_text(json.dumps({"thread_projects": {self.owner: None}}), encoding="utf-8")
        self.assertIsNone(self.rows()[self.owner]["project_id"])

    def test_sidebar_coordinator_and_successful_dispatch_receipts(self):
        self.probe.request("saveSettings", changes={"coordination_section": "跨项目协作"})
        first, second, unrelated, recipient, archived, rejected = (str(UUID(int=i)) for i in range(10, 16))
        first_path = self.start(first, self.root, "turn-first")
        second_path = self.start(second, self.root, "turn-second")
        unrelated_path = self.start(unrelated, self.a, "turn-unrelated")
        stamp = int(self.now.timestamp())
        self.sidebar(
            (first, str(self.root), "统筹一", stamp, 0, "section-a", str(first_path)),
            (second, str(self.root), "新统筹", stamp, 0, None, str(second_path)),
            (unrelated, str(self.a), "普通聊天", stamp, 0, None, str(unrelated_path)),
            (recipient, str(self.b), "执行聊天", stamp, 0, None, None),
            (archived, str(self.a), "已归档", stamp, 1, None, None),
            (rejected, str(self.a), "未成功", stamp, 0, None, None),
        )
        self.write(first_path,
                   self.dispatch(first, "turn-first", 2, recipient, tool="create_thread"),
                   self.dispatch(first, "turn-first", 3, recipient),
                   self.dispatch(first, "turn-first", 4, archived),
                   self.dispatch(first, "turn-first", 5, rejected, result={"isError": True}),
                   self.dispatch(first, "turn-first", 6, rejected, server="another_server"),
                   self.dispatch(first, "turn-first", 7, rejected, arguments={"threadId": recipient}),
                   self.dispatch(first, "turn-first", 8, recipient, tool="create_thread",
                                 result={"isError": False, "content": [{"type": "text", "text": "{}"}]}))
        self.write(unrelated_path, self.dispatch(unrelated, "turn-unrelated", 3, rejected))
        before = self.scan(19)
        self.assertEqual([row["coordinator_id"] for row in before["coordination"]["groups"]], [first])
        con = sqlite3.connect(self.home / "state_5.sqlite")
        try:
            with con:
                con.execute("UPDATE threads SET thread_section_id='section-a' WHERE id=?", [second])
        finally:
            con.close()
        snapshot = self.scan(20)
        coordination = snapshot["coordination"]
        self.assertEqual(coordination["source_status"], "ok")
        groups = {row["coordinator_id"]: row for row in coordination["groups"]}
        self.assertEqual(set(groups), {first, second})
        self.assertEqual(groups[second]["executors"], [])
        expected_at = (self.now + timedelta(seconds=3)).isoformat()
        self.assertEqual(groups[first]["executors"], [
            {"thread_id": recipient, "received": False, "dispatched_at": expected_at},
        ])
        target = next(row for row in snapshot["threads"] if row["id"] == recipient)
        self.assertEqual((target["project_id"], target["status"]), (project_id(self.b), "idle"))
        self.assertNotIn("private dispatch content", json.dumps(snapshot))

    def test_section_history_is_targeted_and_can_be_disabled(self):
        self.probe.request("saveSettings", changes={"coordination_section": "跨项目协作"})
        recipient = str(UUID(int=20))
        old = -6 * 24 * 3600
        path = self.start(self.owner, self.root, self.turn, offset=old)
        self.write(path, self.dispatch(self.owner, self.turn, old + 2, recipient),
                   self.record("event_msg", old + 3, type="task_complete", turn_id=self.turn))
        old_stamp = int(self.now.timestamp()) + old
        os.utime(path, (old_stamp, old_stamp))
        self.sidebar(
            (self.owner, str(self.root), "旧统筹", old_stamp, 0, "section-a", str(path)),
            (recipient, str(self.b), "历史执行", old_stamp, 0, None, None),
        )
        snapshot = self.scan()
        self.assertEqual(snapshot["coordination"]["groups"][0]["executors"][0]["thread_id"], recipient)
        self.assertEqual(next(row for row in snapshot["threads"] if row["id"] == self.owner)["status"], "completed")
        self.config.write_text(json.dumps({"coordination_section": None}), encoding="utf-8")
        disabled = self.scan()["coordination"]
        self.assertEqual(disabled, {"section": None, "source_status": "disabled", "groups": []})

    def test_usage_and_alias_are_read_from_local_sources(self):
        path = self.start(self.owner, self.a, self.turn)
        self.write(path,
                   self.record("event_msg", 2, type="token_count", info={"total_token_usage": {"total_tokens": 810}}),
                   self.record("event_msg", 3, type="token_count", info={"total_token_usage": {"total_tokens": 900}}),
                   self.record("event_msg", 4, type="token_count", info={"total_token_usage": {"total_tokens": True}}))
        self.probe.request("saveSettings", changes={"projects": {str(self.a): "Project A"}})
        snapshot = self.scan(20)
        self.assertEqual(snapshot["projects"], [{"id": project_id(self.a), "name": "Project A"}])
        self.assertEqual(snapshot["threads"][0]["token_total"], 900)

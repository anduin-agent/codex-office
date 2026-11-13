import base64
from datetime import datetime, timedelta, timezone
import json
import os
from pathlib import Path
import sqlite3
import tempfile
import unittest
from uuid import UUID

from collector_probe import CollectorProbe


class CodexTokenUsageTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.home = Path(temporary.name)
        self.sessions = self.home / "sessions"
        self.archives = self.home / "archived_sessions"
        self.sessions.mkdir()
        self.archives.mkdir()
        self.now = datetime.now(timezone.utc).replace(microsecond=0)
        self.owner, self.child = (str(UUID(int=i)) for i in (1, 2))
        self.probe = CollectorProbe(self.home, self.home / "office.json")
        self.addCleanup(self.probe.close)

    def scan(self, now, budget=1.2):
        return self.probe.request("tokenUsage", now=now.timestamp(), budget=budget)

    def row(self, seconds, envelope, **payload):
        return {"timestamp": (self.now + timedelta(seconds=seconds)).isoformat(),
                "type": envelope, "payload": payload}

    def count(self, seconds, total, last):
        def usage(value):
            return {"total_tokens": value} if value is not None else None
        return self.row(seconds, "event_msg", type="token_count",
                        info={"total_token_usage": usage(total), "last_token_usage": usage(last)})

    def write(self, path, *rows):
        with path.open("a", encoding="utf-8") as handle:
            for row in rows:
                handle.write(json.dumps(row) + "\n")

    def test_increments_expire_and_unfinished_lines_wait_for_completion(self):
        path = self.sessions / "rollout.jsonl"
        self.write(path, self.row(-500, "session_meta", id=self.owner),
                   self.count(-60, 100, 100), self.count(-55, 160, 60),
                   self.count(-40, 160, 60), self.count(-30, None, 30),
                   self.count(-28, 180, 20), self.count(-20, 200, 10),
                   self.count(-10, 15, 15))
        # Cutoff is exclusive. A repeated checkpoint and a lagging one do not add tokens.
        result = self.scan(self.now)
        self.assertEqual(result["recent"], [{"id": self.owner, "tokens": 115}])
        self.assertEqual(result["tokens_per_minute"], 115)
        self.assertEqual(result["history"]["total_tokens"], 215)
        self.assertEqual(len(result["history"]["days"]), 30)
        encoded = json.dumps(self.count(3, 25, 10))
        with path.open("a", encoding="utf-8") as handle:
            handle.write(encoded)
        later = self.now + timedelta(seconds=4)
        self.assertEqual(self.scan(later)["history"]["total_tokens"], 215)
        with path.open("a", encoding="utf-8") as handle:
            handle.write("\n")
        self.assertEqual(self.scan(later)["history"]["total_tokens"], 225)
        quiet = self.scan(self.now + timedelta(minutes=2))
        self.assertEqual(quiet["tokens_per_minute"], 0)
        self.assertEqual(quiet["history"]["total_tokens"], 225)

    def test_distinct_fork_usage_and_copies_are_counted_once(self):
        original = self.sessions / "parent.jsonl"
        self.write(original, self.row(-300, "session_meta", id=self.owner),
                   self.count(-200, 900, 900), self.count(-20, 915, 15))
        (self.archives / "copy.jsonl").write_bytes(original.read_bytes())
        self.write(self.sessions / "fork.jsonl", self.row(-100, "session_meta", id=self.child, forked_from_id=self.owner),
                   self.count(-200, 900, 900), self.count(-10, 940, 40))
        result = self.scan(self.now)
        self.assertEqual(result["history"]["total_tokens"], 955)
        self.assertEqual(result["tokens_per_minute"], 55)
        self.assertEqual([row["id"] for row in result["recent"]], [self.child, self.owner])
        original.rename(self.archives / "parent.jsonl")
        self.assertEqual(self.scan(self.now), result)

    def test_old_logs_can_load_separately_from_live_usage(self):
        path = self.archives / "old.jsonl"
        self.write(path, self.row(-3 * 86400, "session_meta", id=self.owner),
                   self.count(-2 * 86400, None, 40), self.count(-2 * 86400 + 3, 55, 15))
        old = (self.now - timedelta(days=2)).timestamp()
        os.utime(path, (old, old))
        initial = self.scan(self.now, budget=0)
        self.assertEqual((initial["live_status"], initial["history_status"]), ("ok", "loading"))
        self.assertEqual(initial["tokens_per_minute"], 0)
        self.assertEqual(initial["today_tokens"], 0)
        self.assertIsNone(initial["history"])
        result = self.scan(self.now)
        history = result["history"]
        day = (self.now - timedelta(days=2)).astimezone().date().isoformat()
        self.assertEqual((history["first_day"], history["active_days"], history["total_tokens"]), (day, 1, 55))
        self.assertIn({"day": day, "tokens": 55}, history["days"])

    def test_daily_ranking_and_price_coverage_follow_counted_usage(self):
        self.now = datetime(2026, 11, 13, 12).astimezone()
        model = "office-test-model"
        prices = {model: {"input": 2.0, "cached_input": 0.1, "output": 10.0}}

        def count(seconds, cumulative, total, input_tokens, cached, output, reasoning, included):
            return self.row(seconds, "event_msg", type="token_count", info={
                "total_token_usage": {"total_tokens": cumulative},
                "last_token_usage": {"total_tokens": total, "input_tokens": input_tokens,
                                     "cached_input_tokens": cached, "output_tokens": output,
                                     "reasoning_output_tokens": reasoning, "cache_write_input_tokens": 0},
                "last_usage_includes_reasoning": included,
            })

        parent = self.sessions / "parent.jsonl"
        self.write(parent, self.row(-90000, "session_meta", id=self.owner, model_provider="openai"),
                   self.row(-86402, "turn_context", model=model),
                   count(-86401, 100, 100, 80, 20, 20, 5, True),
                   count(-50, 230, 130, 100, 30, 20, 10, False),
                   count(-40, 430, 100, 80, 20, 20, 5, True),
                   self.row(-30, "turn_context", model="unpriced-model"),
                   count(-20, 450, 20, 10, 0, 10, 0, True))
        (self.archives / "copy.jsonl").write_bytes(parent.read_bytes())
        self.write(self.sessions / "child.jsonl",
                   self.row(-60, "session_meta", id=self.child, model_provider="other-provider"),
                   self.row(-25, "turn_context", model=model),
                   count(-10, 500, 500, 400, 100, 100, 20, True))
        self.write(self.home / "session_index.jsonl", {"id": self.owner, "thread_name": "Parent chat"},
                   {"id": self.child, "thread_name": "Other provider chat"})

        result = self.probe.request("tokenUsage", now=self.now.timestamp(), prices=prices)
        self.assertEqual(result["history"]["total_tokens"], 950)
        self.assertEqual(result["history"]["total_priced_tokens"], 230)
        self.assertAlmostEqual(result["history"]["total_estimated_usd"], 0.000765)
        self.assertEqual(result["history"]["prices_updated_at"], "2026-11-13")
        yesterday, today = result["history"]["days"][-2:]
        self.assertEqual((yesterday["tokens"], yesterday["priced_tokens"]), (100, 100))
        self.assertAlmostEqual(yesterday["estimated_usd"], 0.000322)
        self.assertEqual((today["tokens"], today["priced_tokens"]), (850, 130))
        self.assertAlmostEqual(today["estimated_usd"], 0.000443)
        self.assertEqual(result["today_priced_tokens"], 130)
        self.assertAlmostEqual(result["today_estimated_usd"], 0.000443)
        self.assertEqual(result["live_priced_tokens"], 130)
        self.assertAlmostEqual(result["live_estimated_usd"], 0.000443)
        self.assertEqual((today["priced_input_tokens"], today["priced_output_tokens"],
                          today["priced_cached_input_tokens"]), (100, 30, 30))
        self.assertAlmostEqual(today["estimated_input_usd"], 0.000143)
        self.assertAlmostEqual(today["estimated_output_usd"], 0.000300)
        self.assertAlmostEqual(today["estimated_cached_input_usd"], 0.000003)
        self.assertEqual(result["recent"][1]["priced_tokens"], 130)
        self.assertAlmostEqual(result["recent"][1]["estimated_usd"], 0.000443)
        self.assertEqual((today["input_tokens"], today["output_tokens"], today["breakdown_tokens"]),
                         (510, 140, 650))
        self.assertEqual((today["cached_input_tokens"], today["cache_reported_input_tokens"]), (130, 510))
        self.assertNotIn("sessions", today)
        ranked = self.probe.request("usageDay", day=today["day"])
        self.assertEqual((ranked["day"], ranked["total_sessions"]), (today["day"], 2))
        other, parent = ranked["sessions"]
        self.assertEqual(other, {"id": self.child, "title": "Other provider chat", "tokens": 500})
        self.assertEqual((parent["id"], parent["title"], parent["tokens"], parent["priced_tokens"]),
                         (self.owner, "Parent chat", 350, 130))
        self.assertAlmostEqual(parent["estimated_usd"], 0.000443)
        old = self.probe.request("usageDay", day=yesterday["day"])["sessions"][0]
        self.assertEqual((old["id"], old["tokens"], old["priced_tokens"]), (self.owner, 100, 100))
        self.assertAlmostEqual(old["estimated_usd"], 0.000322)
        self.assertEqual(self.probe.request("usageDay", day="2020-01-01")["sessions"], [])

        prices[model]["output"] = 20.0
        repriced = self.probe.request("tokenUsage", now=self.now.timestamp(), prices=prices)
        self.assertAlmostEqual(repriced["history"]["days"][-1]["estimated_usd"], 0.000743)
        unpriced = self.scan(self.now)
        self.assertNotIn("today_estimated_usd", unpriced)
        self.assertNotIn("estimated_usd", unpriced["history"]["days"][-1])
        self.assertEqual(unpriced["history"]["days"][-1]["breakdown_tokens"], 650)

    def test_all_local_costs_include_older_archives_and_follow_grouped_filters(self):
        self.now = datetime(2026, 11, 13, 12).astimezone()
        model = "office-test-model"
        prices = {model: {"input": 2.0, "cached_input": 0.1, "output": 10.0}}
        old = -45 * 86400

        def count(seconds, cumulative, incoming, cached, output):
            return self.row(seconds, "event_msg", type="token_count", info={
                "total_token_usage": {"total_tokens": cumulative},
                "last_token_usage": {"total_tokens": incoming + output, "input_tokens": incoming,
                                     "cached_input_tokens": cached, "output_tokens": output},
            })

        self.write(self.archives / "parent.jsonl",
                   self.row(old - 2, "session_meta", id=self.owner, model=model),
                   count(old, 110, 100, 20, 10))
        self.write(self.sessions / "child.jsonl",
                   self.row(-90, "session_meta", id=self.child, model=model, parent_thread_id=self.owner),
                   count(-60, 55, 50, 10, 5), count(-30, 110, 50, 10, 5))
        result = self.probe.request("tokenUsage", now=self.now.timestamp(), prices=prices)
        history = result["history"]
        self.assertEqual((history["total_tokens"], history["total_priced_tokens"]), (220, 220))
        self.assertAlmostEqual(history["total_estimated_usd"], 0.000524)
        self.assertEqual(sum(day["tokens"] for day in history["days"]), 110)
        self.assertEqual((result["tokens_per_minute"], result["live_priced_tokens"]), (55, 55))
        self.assertAlmostEqual(result["live_estimated_usd"], 0.000131)
        today = history["days"][-1]["day"]
        daily = self.probe.request("usageDay", day=today)["sessions"][0]
        self.assertEqual((daily["id"], daily["tokens"], daily["priced_tokens"]), (self.owner, 110, 110))
        self.assertAlmostEqual(daily["estimated_usd"], 0.000262)
        self.assertAlmostEqual(daily["children"][1]["estimated_usd"], 0.000262)
        self.assertNotIn("estimated_usd", daily["children"][0])
        detail = self.probe.request("usageDetails", query={"model": "model:" + model})
        self.assertEqual((detail["total_tokens"], detail["priced_tokens"]), (220, 220))
        self.assertAlmostEqual(detail["estimated_usd"], 0.000524)
        self.assertAlmostEqual(detail["sessions"][0]["model_totals"][0]["estimated_usd"], 0.000524)
        filtered = self.probe.request("usageDetails", query={"from": today, "to": today, "model": "model:" + model})
        self.assertAlmostEqual(filtered["estimated_usd"], 0.000262)

    def test_daily_breakdown_separates_missing_cache_and_unpriced_models(self):
        self.now = datetime(2026, 11, 13, 12).astimezone()
        model = "office-test-model"
        prices = {model: {"input": 2.0, "cached_input": 0.1, "output": 10.0}}
        path = self.sessions / "rollout.jsonl"

        def count(seconds, cumulative, input_tokens, output_tokens, **detail):
            total = input_tokens + output_tokens
            return self.row(seconds, "event_msg", type="token_count", info={
                "total_token_usage": {"total_tokens": cumulative},
                "last_token_usage": {"total_tokens": total, "input_tokens": input_tokens,
                                     "output_tokens": output_tokens, **detail},
            })

        self.write(path, self.row(-86430, "session_meta", id=self.owner),
                   count(-86420, 100, 80, 20),  # Complete split with absent cache data.
                   count(-60, 150, 40, 10, cached_input_tokens=12),  # Explicit hits without a model.
                   self.row(-55, "turn_context", model=model),
                   count(-50, 250, 80, 20, cached_input_tokens=0),
                   count(-30, 350, 90, 10),  # Known model, missing cache data.
                   count(-20, 400, 25, 25, cached_input_tokens=5, cache_write_input_tokens=20))
        result = self.probe.request("tokenUsage", now=self.now.timestamp(), prices=prices)
        yesterday, today = result["history"]["days"][-2:]
        self.assertEqual((yesterday["input_tokens"], yesterday["output_tokens"]), (80, 20))
        self.assertNotIn("cached_input_tokens", yesterday)
        self.assertNotIn("cache_reported_input_tokens", yesterday)
        self.assertEqual((today["input_tokens"], today["output_tokens"], today["breakdown_tokens"]),
                         (235, 65, 300))
        self.assertEqual((today["cached_input_tokens"], today["cache_reported_input_tokens"]), (17, 145))
        self.assertEqual(result["today_priced_tokens"], 100)
        self.assertAlmostEqual(result["today_estimated_usd"], 0.00036)

        old_path = self.archives / "unscanned.jsonl"
        self.write(old_path, self.row(-2 * 86400, "session_meta", id=self.child))
        old = (self.now - timedelta(days=2)).timestamp()
        os.utime(old_path, (old, old))
        loading = self.probe.request("tokenUsage", now=self.now.timestamp(), prices=prices, budget=0)
        self.assertEqual((loading["today_status"], loading["history_status"]), ("ok", "loading"))
        self.assertIsNone(loading["history"])
        self.assertEqual(loading["today_priced_tokens"], 100)
        self.assertAlmostEqual(loading["today_estimated_usd"], 0.00036)

    def test_usage_rankings_group_explicit_ancestry_without_counting_tokens_twice(self):
        self.now = datetime(2026, 11, 13, 12).astimezone()
        today = self.now.date().isoformat()
        nested, guardian, unlinked, missing, fork, other = (str(UUID(int=i)) for i in range(3, 9))
        missing_parent = str(UUID(int=90))
        root = self.sessions / "parent.jsonl"
        self.write(root, self.row(-86490, "session_meta", id=self.owner, cwd=str(self.home / "project")),
                   self.count(-86480, 30, 30))
        child = self.sessions / "child.jsonl"
        self.write(child, self.row(-90, "session_meta", id=self.child, source={"subagent": {"thread_spawn": {
            "parent_thread_id": self.owner}}}, forked_from_id=self.owner, model="child-model"),
                   self.count(-86480, 30, 30), self.count(-89, 70, 40))
        (self.archives / "child-copy.jsonl").write_bytes(child.read_bytes())
        self.write(self.sessions / "nested.jsonl",
                   self.row(-80, "session_meta", id=nested, model="child-model"),
                   self.count(-79, 35, 35))
        self.write(self.sessions / "guardian.jsonl",
                   self.row(-70, "session_meta", id=guardian, thread_source="guardian_review", parent_thread_id=nested,
                            model="review-model"),
                   self.count(-69, 25, 25))
        self.write(self.sessions / "unlinked.jsonl",
                   self.row(-60, "session_meta", id=unlinked, thread_source="guardian_review", model="review-model"),
                   self.count(-59, 30, 30))
        self.write(self.sessions / "missing.jsonl",
                   self.row(-50, "session_meta", id=missing, source={"subagent": {"other": "guardian"}},
                            parent_thread_id=missing_parent, model="review-model"),
                   self.count(-49, 28, 28))
        self.write(self.sessions / "fork.jsonl",
                   self.row(-40, "session_meta", id=fork, forked_from_id=self.owner, parent_thread_id=self.owner),
                   self.count(-39, 55, 55))
        self.write(self.sessions / "other.jsonl",
                   self.row(-30, "session_meta", id=other), self.count(-29, 15, 15))
        self.write(self.home / "session_index.jsonl", {"id": self.owner, "thread_name": "Main chat"})
        with sqlite3.connect(self.home / "state_5.sqlite") as db:
            db.execute("CREATE TABLE thread_spawn_edges (parent_thread_id TEXT, child_thread_id TEXT)")
            db.execute("INSERT INTO thread_spawn_edges VALUES (?,?)", (self.child, nested))

        snapshot = self.scan(self.now)
        daily = self.probe.request("usageDay", day=today)
        self.assertEqual(daily["total_sessions"], 4)
        self.assertEqual([(row["id"], row["tokens"]) for row in daily["sessions"]],
                         [(self.owner, 100), ("unassigned-guardian", 58), (fork, 55), (other, 15)])
        group, unassigned = daily["sessions"][:2]
        self.assertEqual(group["title"], "Main chat")
        self.assertEqual([(row["id"], row["kind"], row["tokens"]) for row in group["children"]],
                         [(self.owner, "self", 0), (self.child, "subagent", 40), (nested, "subagent", 35),
                          (guardian, "guardian_review", 25)])
        self.assertEqual((unassigned["kind"], unassigned["title"]), ("unassigned_guardian", "未归属的自动审批"))
        self.assertEqual([row["id"] for row in unassigned["children"]], [unlinked, missing])
        self.assertEqual(sum(row["tokens"] for row in daily["sessions"]), snapshot["history"]["days"][-1]["tokens"])

        def details(**query):
            return self.probe.request("usageDetails", query={"from": today, "to": today, **query}, language="en")

        all_usage = details()
        self.assertEqual(all_usage["total_tokens"], 228)
        self.assertEqual(all_usage["total_sessions"], 4)
        project = next(row["id"] for row in all_usage["projects"] if row["title"] == "project")
        scoped = details(project=project, model="model:child-model")
        self.assertEqual((scoped["total_tokens"], scoped["total_sessions"]), (75, 1))
        group = scoped["sessions"][0]
        self.assertEqual(group["id"], self.owner)
        self.assertEqual(group["model_totals"], [{"title": "child-model", "tokens": 75}])
        self.assertEqual([row["tokens"] for row in group["children"]], [0, 40, 35])
        self.assertEqual(details(offset=1)["sessions"][0]["id"], "unassigned-guardian")

    def test_detailed_usage_filters_and_attributes_counted_sessions(self):
        self.now = datetime(2026, 11, 13, 12).astimezone()
        today = self.now.date().isoformat()
        yesterday = (self.now.date() - timedelta(days=1)).isoformat()
        project = self.home / "sample"
        project.mkdir()
        (project / ".git" / "worktrees" / "checkout").mkdir(parents=True)
        checkout = self.home / "checkout"
        checkout.mkdir()
        (checkout / ".git").write_text("gitdir: ../sample/.git/worktrees/checkout\n")
        third, fourth = (str(UUID(int=i)) for i in (3, 4))

        path = self.sessions / "parent.jsonl"
        self.write(path, self.row(-86460, "session_meta", id=self.owner, cwd=str(checkout)),
                   self.row(-86450, "turn_context", model="gpt-example"),
                   self.count(-86440, 100, 100),
                   self.row(-300, "turn_context", model="other-model"),
                   self.count(-290, 300, 200),
                   self.count(-280, 400, 10))  # This checkpoint jumps by more than the last request.
        (self.archives / "duplicate.jsonl").write_bytes(path.read_bytes())
        self.write(self.sessions / "second.jsonl",
                   self.row(-100, "session_meta", id=self.child, cwd=str(project), model_provider="custom"),
                   self.row(-99, "turn_context", model="gpt-example"),
                   self.count(-98, 50, 50))
        self.write(self.sessions / "third.jsonl",
                   self.row(-80, "session_meta", id=third), self.count(-79, 20, 20))
        self.write(self.sessions / "fourth.jsonl",
                   self.row(-70, "session_meta", id=fourth),
                   self.row(-69, "turn_context", model="gpt-example", cwd=str(self.home / "plain-folder")),
                   self.count(-68, 10, 10))
        self.write(self.home / "session_index.jsonl", {"id": self.owner, "thread_name": "First chat"})
        self.probe.request("saveSettings", changes={"projects": {str(project): "Shared project"}})

        def details(**query):
            return self.probe.request("usageDetails", query=query, language="en")

        self.assertEqual(details()["status"], "loading")
        snapshot = self.scan(self.now)
        all_usage = details()
        self.assertEqual((all_usage["status"], all_usage["total_sessions"], all_usage["total_tokens"]), ("ok", 4, 480))
        self.assertEqual(all_usage["total_tokens"], snapshot["history"]["total_tokens"])
        projects = {item["title"]: item["id"] for item in all_usage["projects"]}
        self.assertEqual(set(projects), {"Shared project", "Unassigned project", "plain-folder"})
        self.assertEqual([row["id"] for row in all_usage["sessions"]], [self.owner, self.child, third, fourth])
        self.assertEqual(all_usage["sessions"][0], {
            "id": self.owner, "title": "First chat", "project": "Shared project", "tokens": 400,
            "models": ["other-model", "Unknown model", "gpt-example"],
            "model_totals": [{"title": "other-model", "tokens": 200},
                             {"title": "Unknown model", "tokens": 100},
                             {"title": "gpt-example", "tokens": 100}],
        })
        model = {item["title"]: item["id"] for item in all_usage["models"]}
        filtered = details(**{"from": today, "to": today,
                              "project": projects["Shared project"], "model": model["gpt-example"]})
        self.assertEqual((filtered["total_sessions"], filtered["total_tokens"]), (1, 50))
        self.assertEqual(filtered["sessions"][0]["id"], self.child)
        old = details(**{"from": yesterday, "to": yesterday})
        self.assertEqual((old["total_sessions"], old["total_tokens"]), (1, 100))
        self.assertEqual(details(project=projects["Unassigned project"], model=model["Unknown model"])["total_tokens"], 20)
        self.assertEqual(details(offset=1)["sessions"][0]["id"], self.child)
        self.assertEqual(details(offset=400)["sessions"], [])
        self.assertEqual(details(**{"from": "2026-02-30"})["status"], "invalid")
        self.assertEqual(details(**{"from": today, "to": yesterday})["status"], "invalid")

    def test_quota_cycles_count_local_usage_and_match_the_percentage_timestamp(self):
        short_start = -3600
        week_start = -6 * 86400
        account = "fixture-account"

        def window(minutes, percent, starts):
            return {"used_percent": percent, "window_minutes": minutes,
                    "resets_at": int(self.now.timestamp()) + starts + minutes * 60}

        path = self.sessions / "cycle.jsonl"
        self.write(path, self.row(week_start - 10, "session_meta", id=self.owner, creator_account_id=account),
                   self.count(week_start - 1, 10, 10), self.count(week_start, 30, 20),
                   self.count(short_start - 1, 60, 30), self.count(short_start, 100, 40),
                   self.count(-120, 160, 60),
                   self.row(-90, "event_msg", type="token_count", info=None, rate_limits={
                       "limit_id": "codex", "primary": window(300, 20, short_start),
                       "secondary": window(10_080, 25, week_start),
                   }),
                   self.count(-45, 210, 50), self.count(20, 310, 100))
        (self.archives / "duplicate.jsonl").write_bytes(path.read_bytes())
        self.write(self.sessions / "other-account.jsonl",
                   self.row(-180, "session_meta", id=self.child, creator_account_id="other-account"),
                   self.count(-100, 900, 900))
        self.write(self.sessions / "provider.jsonl",
                   self.row(-180, "session_meta", id=str(UUID(int=3)), model_provider="custom"),
                   self.count(-100, 800, 800))
        short, weekly = self.scan(self.now)["quota_windows"]
        self.assertEqual([short["cycle_tokens"], weekly["cycle_tokens"]], [150, 200])
        self.assertEqual([short["cycle_estimated_tokens"], weekly["cycle_estimated_tokens"]], [500, 600])
        self.assertEqual(short["cycle_status"], "ok")
        self.assertEqual(datetime.fromisoformat(short["cycle_started_at"].replace("Z", "+00:00")),
                         self.now + timedelta(seconds=short_start))

        self.write(self.sessions / "legacy.jsonl",
                   self.row(-150, "session_meta", id=str(UUID(int=4))), self.count(-100, 25, 25))
        short, weekly = self.scan(self.now)["quota_windows"]
        self.assertEqual([short["cycle_tokens"], weekly["cycle_tokens"]], [175, 225])
        self.assertEqual(short["cycle_status"], "partial")
        self.assertNotIn("cycle_estimated_tokens", short)
        self.assertNotIn("cycle_estimated_tokens", weekly)

    def test_quota_previous_cycle_freezes_at_reset_and_compares_only_aligned_estimates(self):
        for minutes in (300, 10_080):
            with self.subTest(minutes=minutes):
                start = -300
                prior_start = start - minutes * 60
                reset = start + minutes * 60
                account = f"account-{minutes}"

                def quota(seconds, used, ends, plan="plus"):
                    return self.row(seconds, "event_msg", type="token_count", info=None, rate_limits={
                        "limit_id": "codex", "plan_type": plan, "primary": {
                            "used_percent": used, "window_minutes": minutes,
                            "resets_at": int(self.now.timestamp()) + ends,
                        },
                    })

                prior = self.archives / "prior.jsonl"
                self.write(prior, self.row(prior_start - 5, "session_meta", id=self.owner, creator_account_id=account),
                           self.count(prior_start - 1, 100, 100), self.count(start - 130, 600, 500),
                           quota(start - 120, 50, start))
                # The final observation can come from a different session for the same account.
                last = self.archives / "last.jsonl"
                self.write(last, self.row(start - 61, "session_meta", id=str(UUID(int=4)), creator_account_id=account),
                           self.count(start - 60, 550, 550), quota(start - 50, 100, start), quota(start, 100, start))
                current = self.sessions / "current.jsonl"
                self.write(current, self.row(start, "session_meta", id=self.child, creator_account_id=account))
                other = self.sessions / "other.jsonl"
                self.write(other, self.row(start - 90, "session_meta", id=str(UUID(int=3)), creator_account_id="different"),
                           self.count(start - 30, 4000, 4000), quota(start - 20, 80, start))

                ended = self.scan(self.now + timedelta(seconds=start))
                self.assertIsNone(ended["quota"])
                self.assertEqual(ended["quota_windows"], [])
                self.assertEqual(ended["quota_closed_windows"][0]["window_minutes"], minutes)
                previous = ended["quota_closed_windows"][0]["previous_cycle"]
                cases = [
                    (self.count(start, 360, 360), -90, 600, "lower"),
                    (self.count(-80, 620, 260), -70, 1033, "similar"),
                    (self.count(-60, 1000, 380), -50, 1667, "higher"),
                ]
                for event, seconds, estimate, comparison in cases:
                    self.write(current, event, quota(seconds, 60, reset))
                    seconds += 5
                    cycle = self.scan(self.now + timedelta(seconds=seconds))["quota"]
                    self.assertEqual(cycle["cycle_estimated_tokens"], estimate)
                    self.assertEqual(cycle["cycle_comparison"]["status"], comparison)
                    self.assertEqual(cycle["cycle_comparison"]["tolerance_percent"], 15)
                    self.assertAlmostEqual(cycle["cycle_comparison"]["change_percent"], (estimate / 1000 - 1) * 100)
                    closed = cycle["previous_cycle"]
                    self.assertEqual(closed, previous)
                    self.assertEqual(closed["cycle_tokens"], 1050)
                    self.assertEqual(closed["used_percent"], 100)
                    self.assertEqual(datetime.fromisoformat(closed["sampled_at"].replace("Z", "+00:00")),
                                     self.now + timedelta(seconds=start - 50))
                    self.assertEqual(closed["basis_used_percent"], 50)
                    self.assertEqual(closed["basis_tokens"], 500)
                    self.assertEqual(closed["cycle_estimated_tokens"], 1000)
                    self.assertEqual(datetime.fromisoformat(closed["resets_at"].replace("Z", "+00:00")),
                                     self.now + timedelta(seconds=start))
                self.write(current, quota(-40, 60, reset, plan="pro"))
                changed_plan = self.scan(self.now)["quota"]
                self.assertEqual(changed_plan["previous_cycle"], previous)
                self.assertNotIn("cycle_comparison", changed_plan)
                self.write(current, quota(1, 3, reset, plan="plus"))
                early_cycle = self.scan(self.now + timedelta(seconds=2))["quota"]
                self.assertEqual(early_cycle["previous_cycle"], previous)
                self.assertNotIn("cycle_estimated_tokens", early_cycle)
                self.assertNotIn("cycle_comparison", early_cycle)
                for path in (prior, last, current, other):
                    path.unlink()

    def test_quota_uses_newest_codex_window_until_its_reset(self):
        def quota(seconds, limit_id, primary, secondary=None):
            def window(data):
                if data is None:
                    return None
                minutes, used, remaining_seconds = data
                return {"used_percent": used, "window_minutes": minutes,
                        "resets_at": int((self.now + timedelta(seconds=remaining_seconds)).timestamp())}
            return self.row(seconds, "event_msg", type="token_count", info=None,
                            rate_limits={"limit_id": limit_id, "primary": window(primary),
                                         "secondary": window(secondary)})
        path = self.sessions / "rollout.jsonl"
        self.write(path, self.row(-600, "session_meta", id=self.owner),
                   quota(-30, "codex", (10_080, 20, 3600)),
                   quota(-20, "codex", (300, 10, 30), (10_080, 100, 45)),
                   quota(-10, "different-model", (10_080, 30, 120)))
        result = self.scan(self.now)
        self.assertEqual(result["quota"]["remaining_percent"], 0)
        self.assertEqual(result["quota"]["window_minutes"], 10_080)
        self.assertEqual([(window["window_minutes"], window["remaining_percent"])
                          for window in result["quota_windows"]], [(300, 90), (10_080, 0)])
        self.assertEqual(result["tokens_per_minute"], 0)
        later = self.scan(self.now + timedelta(seconds=35))
        self.assertEqual(later["quota_windows"], [result["quota"]])
        expired = self.scan(self.now + timedelta(seconds=60))
        self.assertIsNone(expired["quota"])
        self.assertEqual(expired["quota_windows"], [])

        self.write(path, quota(5, "codex", (300, 25, 300)))
        short_only = self.scan(self.now + timedelta(seconds=10))
        self.assertEqual(short_only["quota"]["window_minutes"], 300)
        self.assertEqual(short_only["quota_windows"], [short_only["quota"]])

    def test_plus_quota_preserves_remaining_percent_without_a_reset_time(self):
        path = self.sessions / "plus.jsonl"
        weekly = {"used_percent": 55, "window_minutes": 10_080,
                  "resets_at": int((self.now + timedelta(days=2)).timestamp())}
        self.write(path, self.row(-600, "session_meta", id=self.owner, creator_account_id="plus-fixture"),
                   self.row(-30, "event_msg", type="token_count", info=None, rate_limits={
                       "limit_id": "codex", "plan_type": "plus", "primary": {
                           "used_percent": 25, "window_minutes": 300, "resets_at": None,
                       }, "secondary": weekly,
                   }))
        result = self.scan(self.now)
        self.assertEqual(result["quota_plan"], "plus")
        short, long = result["quota_windows"]
        self.assertEqual(short, {"window_minutes": 300, "remaining_percent": 75, "resets_at": None})
        self.assertEqual(long, result["quota"])
        self.assertEqual(long["window_minutes"], 10_080)

        self.write(path, self.row(-10, "event_msg", type="token_count", info=None, rate_limits={
            "limit_id": "codex", "plan_type": "plus", "primary": weekly,
        }))
        weekly_only = self.scan(self.now)
        self.assertEqual(weekly_only["quota_plan"], "plus")
        self.assertEqual(weekly_only["quota_windows"], [weekly_only["quota"]])
        self.assertEqual(weekly_only["quota"]["window_minutes"], 10_080)

    def test_compressed_archives_and_damaged_frame(self):
        # The frame contains one session_meta and one 120-token event.
        frame = base64.b64decode(
            "KLUv/QRYzQQAogkeHGBH3AawPq/ZqHRSbEu1BAbBo22VitkJE4eBUU7Ce69ZHUfzEh3U8xqKk3Sodu0G2jqad0ucQGpL4"
            "NpglrptwSIFEN77GfKoL9YX1BfKHYpCjuaql6XmFvPyUb+I0kfzTM0cZGoSek4AcYaTA4ESHfUIU83LVn8JCwCdImtO9II"
            "O7LFrIiOWHxAJiQsY8cA1lMSuDEQBEipgvw=="
        )
        archive = self.archives / "rollout.jsonl.zst"
        archive.write_bytes(frame)
        now = datetime(2025, 1, 15, 12, tzinfo=timezone.utc)
        old = (now - timedelta(minutes=5)).timestamp()
        os.utime(archive, (old, old))
        self.assertEqual(self.scan(now)["history"]["total_tokens"], 120)
        archive.write_bytes(frame[:len(frame) // 2])
        os.utime(archive, (old, old))
        result = self.scan(now)
        self.assertEqual((result["live_status"], result["history_status"]), ("ok", "partial"))


if __name__ == "__main__":
    unittest.main()

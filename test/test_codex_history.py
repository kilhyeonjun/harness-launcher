#!/usr/bin/env python3
"""Filesystem contract for the native Codex history archive boundary."""

import hashlib
import importlib.util
import json
import os
from pathlib import Path
import shutil
import sqlite3
import stat
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

ROOT = Path(__file__).resolve().parents[1]
HISTORY = ROOT / "bin" / "codex-history.py"
SPEC = importlib.util.spec_from_file_location("codex_history", HISTORY)
history_module = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(history_module)
ISOLATION_ID = "11111111-2222-4333-8444-555555555555"
RUNTIME_REVISION = "a" * 40
NATIVE_THREAD_ID = "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee"
PARENT_THREAD_ID = "ffffffff-1111-4222-8333-444444444444"


def digest_tree(root, excluded=()):
    entries = []
    for path in sorted(root.rglob("*")):
        relative = path.relative_to(root).as_posix()
        if path.is_file() and not path.is_symlink() and relative not in excluded:
            entries.append((relative, hashlib.sha256(path.read_bytes()).hexdigest()))
    return hashlib.sha256(json.dumps(entries, separators=(",", ":")).encode()).hexdigest()


class CodexHistoryTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.base = Path(self.temp.name)
        self.source_root = self.base / "source-root"
        self.source_root.mkdir()
        self.home = self.source_root / ".harness" / "codex"
        self.catalog = self.base / "profile-local-catalog"
        self.receipt = self.base / "receipt.json"
        self._make_home()

    def _make_home(self):
        if self.home.exists():
            shutil.rmtree(self.home)
        current = self.home / "sessions/2026/10/10"
        archived = self.home / "archived_sessions/2026/10/09"
        current.mkdir(parents=True)
        archived.mkdir(parents=True)
        (self.home / "history.jsonl").write_text(
            json.dumps({"session_id": NATIVE_THREAD_ID, "input": "fixture-only-secret"}) + "\n")
        (self.home / "session_index.jsonl").write_text(
            json.dumps({"id": NATIVE_THREAD_ID, "path": "sessions/2026/10/10/rollout-2026-10-10T01-02-03-" + NATIVE_THREAD_ID + ".jsonl"})
            + "\n" + json.dumps({"id": PARENT_THREAD_ID, "path": "archived_sessions/2026/10/09/rollout-2026-10-09T01-02-03-" + PARENT_THREAD_ID + ".jsonl"}) + "\n")
        (current / ("rollout-2026-10-10T01-02-03-" + NATIVE_THREAD_ID + ".jsonl")).write_text(
            json.dumps({"timestamp": "2026-10-10T01:02:03Z", "type": "session_meta", "payload": {
                "id": NATIVE_THREAD_ID, "history_base": {"thread_id": PARENT_THREAD_ID}, "cwd": "/fixture"}}) + "\n")
        (current / ("rollout-2026-10-10T01-02-03-" + NATIVE_THREAD_ID + "_0001.jsonl")).write_text('{"type":"response_item","id":"segment"}\n')
        (archived / ("rollout-2026-10-09T01-02-03-" + PARENT_THREAD_ID + ".jsonl")).write_text('{"type":"response_item","id":"parent"}\n')
        for name in ("logs_2", "goals_1", "memories_1", "queue_1", "shell_snapshots", "generated_images", "attachments"):
            if name in {"shell_snapshots", "generated_images", "attachments"}:
                (self.home / name).mkdir()
                (self.home / name / "native-data").write_text(name + "\n")
            else:
                self._make_auxiliary_db(name + ".sqlite")
        self._make_state_db()
        self._make_history_db()
        auth_target = self.base / "fixture-auth.json"
        auth_target.write_text('{"token":"fixture-authority"}\n')
        (self.home / "auth.json").symlink_to(auth_target)
        for name, content in (("config.toml", 'model = "fixture"\n'),
                              ("hooks.json", '{"trust":"fixture"}\n'), (".codex-home-prepare.lock", "lock\n")):
            (self.home / name).write_text(content)
        (self.home / "skills").mkdir()
        (self.home / "skills/SKILL.md").write_text("generated\n")
        (self.home / "plugins/cache").mkdir(parents=True)
        (self.home / "plugins/cache/state").write_text("cache\n")

    def _make_auxiliary_db(self, name):
        con = sqlite3.connect(self.home / name)
        self.addCleanup(con.close)
        con.execute("CREATE TABLE retained (value TEXT)")
        con.execute("INSERT INTO retained VALUES (?)", (name,))
        con.commit()

    def _make_state_db(self):
        con = sqlite3.connect(self.home / "state_5.sqlite")
        self.addCleanup(con.close)
        con.execute("CREATE TABLE threads (id TEXT PRIMARY KEY, rollout_path TEXT)")
        con.execute("CREATE TABLE rollout_migration_skipped_rollouts (id TEXT PRIMARY KEY, rollout_path TEXT)")
        con.execute("INSERT INTO threads VALUES (?, ?)", (NATIVE_THREAD_ID, str(self.home / "sessions/2026/10/10" / ("rollout-2026-10-10T01-02-03-" + NATIVE_THREAD_ID + ".jsonl"))))
        con.execute("INSERT INTO rollout_migration_skipped_rollouts VALUES (?, ?)",
                    (PARENT_THREAD_ID, str(self.home / "archived_sessions/2026/10/09" / ("rollout-2026-10-09T01-02-03-" + PARENT_THREAD_ID + ".jsonl"))))
        con.commit()

    def _make_history_db(self):
        path = self.home / "thread_history_1.sqlite"
        con = sqlite3.connect(path)
        con.execute("PRAGMA journal_mode=WAL")
        con.execute("CREATE TABLE history (id TEXT PRIMARY KEY, value TEXT)")
        con.execute("INSERT INTO history VALUES ('thread-1', 'durable')")
        con.commit()
        self.wal_reader = sqlite3.connect(path)
        self.addCleanup(self.wal_reader.close)
        self.assertTrue((self.home / "thread_history_1.sqlite-wal").exists())
        con.close()

    def run_history(self, *args, expected=0):
        self.assertTrue(HISTORY.is_file(), "codex history helper is missing")
        proc = subprocess.run([sys.executable, str(HISTORY), *args], capture_output=True, text=True, timeout=20)
        self.assertEqual(proc.returncode, expected, proc.stderr)
        return proc

    def snapshot(self, *extra, expected=0):
        return self.run_history(
            "snapshot", "--source", str(self.home), "--catalog", str(self.catalog), "--receipt", str(self.receipt),
            "--source-root", str(self.source_root), "--isolation-id", ISOLATION_ID,
            "--runtime-revision", RUNTIME_REVISION, *extra, expected=expected)

    def test_snapshot_restore_preserves_native_history_without_authority(self):
        source_before = digest_tree(self.home)
        proc = self.snapshot()
        receipt = json.loads(proc.stdout)
        self.assertRegex(receipt["source_sha256"], r"^[0-9a-f]{64}$")
        self.assertEqual(receipt["source_home"], str(self.home))
        self.assertEqual(receipt["source_root"], str(self.source_root))
        self.assertEqual(receipt["isolation_id"], ISOLATION_ID)
        self.assertEqual(receipt["runtime_revision"], RUNTIME_REVISION)
        self.assertNotIn("fixture-only-secret", proc.stdout)
        self.assertNotIn("fixture-authority", proc.stdout)
        self.assertEqual(digest_tree(self.home), source_before)
        self.assertEqual(stat.S_IMODE(self.catalog.stat().st_mode), 0o700)
        self.assertEqual(stat.S_IMODE(self.receipt.stat().st_mode), 0o600)

        restored = self.base / "restored-home"
        restored.mkdir()
        (restored / "config.toml").write_text("generated destination\n")
        (restored / "hooks.json").write_text("generated destination\n")
        (restored / "skills").mkdir()
        (restored / "skills/SKILL.md").write_text("generated destination\n")
        restore_receipt = self.base / "restore-receipt.json"
        self.run_history("restore", "--catalog", str(self.catalog), "--snapshot", receipt["snapshot_id"],
                         "--destination", str(restored), "--receipt", str(restore_receipt))
        omitted = {"state_5.sqlite", "thread_history_1.sqlite", "thread_history_1.sqlite-wal", "thread_history_1.sqlite-shm",
                   "auth.json", "config.toml", "hooks.json", "skills/SKILL.md", "plugins/cache/state", ".codex-home-prepare.lock",
                   "logs_2.sqlite", "goals_1.sqlite", "memories_1.sqlite", "queue_1.sqlite"}
        self.assertEqual(digest_tree(restored, omitted), digest_tree(self.home, omitted))
        self.assertTrue((restored / "sessions/2026/10/10" / ("rollout-2026-10-10T01-02-03-" + NATIVE_THREAD_ID + "_0001.jsonl")).is_file())
        self.assertTrue((restored / "archived_sessions/2026/10/09" / ("rollout-2026-10-09T01-02-03-" + PARENT_THREAD_ID + ".jsonl")).is_file())
        self.assertEqual((restored / "config.toml").read_text(), "generated destination\n")
        self.assertEqual((restored / "hooks.json").read_text(), "generated destination\n")
        self.assertEqual((restored / "skills/SKILL.md").read_text(), "generated destination\n")
        for excluded in ("auth.json", "plugins", ".codex-home-prepare.lock"):
            self.assertFalse((restored / excluded).exists(), excluded)
        self.assertEqual(stat.S_IMODE(restored.stat().st_mode), 0o700)
        for path in restored.rglob("*"):
            if path.is_file() and path.relative_to(restored).parts[0] not in {"config.toml", "hooks.json", "skills"}:
                self.assertEqual(stat.S_IMODE(path.stat().st_mode), 0o600, path)

        state = sqlite3.connect(restored / "state_5.sqlite")
        self.addCleanup(state.close)
        paths = [row[0] for row in state.execute(
            "SELECT rollout_path FROM threads UNION ALL SELECT rollout_path FROM rollout_migration_skipped_rollouts")]
        self.assertEqual(len(paths), 2)
        self.assertTrue(all(path.startswith(str(restored)) and str(self.home) not in path for path in paths))
        history = sqlite3.connect(restored / "thread_history_1.sqlite")
        self.addCleanup(history.close)
        self.assertEqual(history.execute("SELECT value FROM history WHERE id = 'thread-1'").fetchone(), ("durable",))
        for name in ("logs_2.sqlite", "goals_1.sqlite", "memories_1.sqlite", "queue_1.sqlite"):
            self.assertEqual(sqlite3.connect(restored / name).execute("SELECT value FROM retained").fetchone(), (name,))

    def test_unknown_top_level_entry_is_gc_hold_not_a_usable_snapshot(self):
        (self.home / "future-native-artifact.bin").write_bytes(b"unknown must stay at source")
        self.snapshot(expected=2)
        self.assertFalse(self.catalog.exists())
        self.assertFalse(self.receipt.exists())
        self.assertTrue((self.home / "future-native-artifact.bin").is_file())

    def test_missing_provenance_malformed_and_symlink_refuse_without_outputs(self):
        self.run_history("snapshot", "--source", str(self.home), "--catalog", str(self.catalog), "--receipt", str(self.receipt),
                         "--source-root", str(self.source_root), "--isolation-id", ISOLATION_ID, expected=2)
        self.assertFalse(self.catalog.exists())
        self.assertFalse(self.receipt.exists())
        (self.home / "session_index.jsonl").write_text("{not-json}\n")
        self.snapshot(expected=2)
        self.assertFalse(self.catalog.exists())
        self._make_home()
        target = self.base / "outside"
        target.write_text("never follow")
        (self.home / "sessions/link.jsonl").symlink_to(target)
        self.snapshot(expected=2)
        self.assertFalse(self.catalog.exists())
        self.assertFalse(self.receipt.exists())

    def test_actual_active_wal_writer_refuses_without_partial_outputs(self):
        writer = sqlite3.connect(self.home / "thread_history_1.sqlite", timeout=0)
        self.addCleanup(writer.close)
        writer.execute("BEGIN IMMEDIATE")
        writer.execute("INSERT INTO history VALUES ('active', 'must-not-copy')")
        self.snapshot(expected=3)
        self.assertEqual(writer.execute("SELECT value FROM history WHERE id = 'active'").fetchone(), ("must-not-copy",))
        self.assertFalse(self.catalog.exists())
        self.assertFalse(self.receipt.exists())

    def test_read_only_source_holds_without_writing_or_archiving(self):
        database = self.home / "thread_history_1.sqlite"
        sidecars = [database, Path(str(database) + "-wal"), Path(str(database) + "-shm")]
        for path in sidecars:
            if path.exists():
                path.chmod(0o400)
        try:
            self.snapshot(expected=3)
            self.assertFalse(self.catalog.exists())
            self.assertFalse(self.receipt.exists())
        finally:
            for path in sidecars:
                if path.exists():
                    path.chmod(0o600)

    def test_catalog_reports_metadata_only_for_the_selected_source(self):
        state = self.base / "state"
        proc = self.run_history("catalog", "--source-root", str(self.source_root), "--state-home", str(state))
        result = json.loads(proc.stdout)
        entry = next(item for item in result["entries"] if item["native_id"] == NATIVE_THREAD_ID)
        self.assertEqual(set(entry), {"native_id", "home", "source_root", "isolation_id", "origin_runtime", "snapshot_id", "updated_at", "status", "reason", "source_local"})
        self.assertEqual(entry["source_root"], str(self.source_root))
        self.assertEqual(entry["isolation_id"], "canonical")
        self.assertEqual(entry["origin_runtime"], "legacy-unknown")
        self.assertTrue(entry["source_local"])
        self.assertNotIn("fixture-only-secret", proc.stdout)
        self.assertNotIn("fixture-authority", proc.stdout)

    def test_non_native_legacy_root_without_inode_does_not_hide_native_catalog(self):
        state=self.base/'old-state';identifier=ISOLATION_ID
        root=state/'worktrees'/identifier;root.mkdir(parents=True)
        record=state/'sessions'/identifier;record.mkdir(parents=True)
        (record/'source-root').write_text(str(self.source_root))
        (record/'session-root').write_text(str(root))
        result=json.loads(self.run_history('catalog','--source-root',str(self.source_root),'--state-home',str(state)).stdout)
        self.assertIn(NATIVE_THREAD_ID,[row['native_id'] for row in result['entries']])

    def test_pool_without_native_needs_no_binary_but_native_original_is_held(self):
        state=self.base/'no-native-binary-state'
        result=json.loads(self.run_history('protect-pool','--source-root',str(self.source_root),'--state-home',str(state)).stdout)
        self.assertTrue(result['safe_to_gc'])
        root=state/'worktrees'/ISOLATION_ID;record=state/'sessions'/ISOLATION_ID
        home=root/'.harness/codex';shutil.copytree(self.home,home,symlinks=True);record.mkdir(parents=True)
        for name,value in (('source-root',str(self.source_root)),('session-root',str(root)),
                           ('root-inode',history_module.root_inode(root)),('runtime.lock',''),
                           ('lease-v1','1\n'),('journal','state=CLOSED\nidentity=\nheartbeat=2026-10-10T00:00:00Z\n')):
            (record/name).write_text(value)
        before=digest_tree(home)
        self.run_history('protect-pool','--source-root',str(self.source_root),'--state-home',str(state),expected=2)
        self.assertEqual(digest_tree(home),before)
        self.assertFalse((state/'native-history/snapshots').exists())

    def test_retained_unpublished_staging_does_not_hide_complete_archives(self):
        state=self.base/'staging-state'
        first=json.loads(self.run_history('prepare','--source-root',str(self.source_root),
                        '--state-home',str(state),'--native-id',NATIVE_THREAD_ID).stdout)
        directory=state/'native-history/snapshots'
        shutil.copytree(directory/first['snapshot_id'],directory/'.snapshot-crash-owned')
        result=json.loads(self.run_history('catalog','--source-root',str(self.source_root),'--state-home',str(state)).stdout)
        row=next(row for row in result['entries'] if row['native_id']==NATIVE_THREAD_ID)
        self.assertEqual(row['snapshot_id'],first['snapshot_id'])
        self.assertTrue((directory/'.snapshot-crash-owned/manifest.json').is_file())

    def test_importing_older_archive_does_not_supersede_newer_native_history(self):
        current=self.base/'import-current';legacy=self.base/'import-legacy';store=legacy/'native-history'
        rollout=next(path for path in (self.home/'sessions').rglob('*.jsonl') if 'session_meta' in path.read_text())
        def capture(label):
            return json.loads(self.run_history('snapshot','--source',str(self.home),'--catalog',str(store),
                    '--receipt',str(self.base/(label+'.json')),'--source-root',str(self.source_root),
                    '--isolation-id','canonical','--runtime-revision','legacy-unknown').stdout)['snapshot_id']
        os.utime(rollout,ns=(1000000000,1000000000));older=capture('older')
        rollout.write_text(rollout.read_text()+'{"type":"response_item","id":"newer-history"}\n')
        os.utime(rollout,ns=(2000000000,2000000000));newer=capture('newer')
        shutil.move(self.home,self.base/'retained-original')
        history_module.import_snapshot(store,current/'native-history',older,self.source_root)
        imported=current/'native-history/snapshots'/older
        original=store/'snapshots'/older
        self.assertEqual(digest_tree(imported),digest_tree(original))
        for path in original.rglob('*'):
            if path.is_file():
                self.assertEqual((imported/path.relative_to(original)).stat().st_mtime_ns,path.stat().st_mtime_ns)
        listed=json.loads(self.run_history('catalog','--source-root',str(self.source_root),'--state-home',str(current),
                         '--legacy-state-home',str(legacy)).stdout)
        selected=next(row for row in listed['entries'] if row['native_id']==NATIVE_THREAD_ID)
        self.assertEqual(selected['snapshot_id'],newer,'copy time must not promote older original data')

    def test_snapshot_capture_time_selects_newer_database_with_same_raw_timestamps(self):
        state=self.base/'database-newer';store=state/'native-history'
        def capture(label):
            return json.loads(self.run_history('snapshot','--source',str(self.home),'--catalog',str(store),
                    '--receipt',str(self.base/(label+'.json')),'--source-root',str(self.source_root),
                    '--isolation-id','canonical','--runtime-revision','legacy-unknown').stdout)['snapshot_id']
        older=capture('db-older')
        db=sqlite3.connect(self.home/'thread_history_1.sqlite')
        db.execute("INSERT INTO history VALUES ('additional','newer original database')");db.commit();db.close()
        newer=capture('db-newer');self.assertNotEqual(older,newer)
        shutil.move(self.home,self.base/'retained-db-original')
        listed=json.loads(self.run_history('catalog','--source-root',str(self.source_root),'--state-home',str(state)).stdout)
        selected=next(row for row in listed['entries'] if row['native_id']==NATIVE_THREAD_ID)
        self.assertEqual(selected['snapshot_id'],newer)

    def test_catalog_updated_time_includes_headerless_native_segments(self):
        paths=list((self.home/'sessions').rglob('*.jsonl'))
        for path in paths:os.utime(path,ns=(1000000000,1000000000))
        segment=next(path for path in paths if '_0001' in path.name)
        os.utime(segment,ns=(3000000000,3000000000))
        listed=json.loads(self.run_history('catalog','--source-root',str(self.source_root),'--state-home',str(self.base/'segments-time-state')).stdout)
        selected=next(row for row in listed['entries'] if row['native_id']==NATIVE_THREAD_ID)
        self.assertEqual(int(selected['updated_at']),3000000000)

    def test_prepare_canonical_selected_history_creates_a_snapshot(self):
        state = self.base / "prepare-state"
        proc = self.run_history("prepare", "--source-root", str(self.source_root), "--state-home", str(state), "--native-id", NATIVE_THREAD_ID)
        row = json.loads(proc.stdout)
        self.assertEqual(row["native_id"], NATIVE_THREAD_ID)
        self.assertEqual(row["isolation_id"], "canonical")
        self.assertRegex(row["snapshot_id"], r"^[0-9a-f]{64}$")

    def test_catalog_retains_canonical_prepare_snapshot_and_rejects_stale_receipt(self):
        state = self.base / "prepare-catalog-state"
        first = json.loads(self.run_history(
            "prepare", "--source-root", str(self.source_root), "--state-home", str(state), "--native-id", NATIVE_THREAD_ID
        ).stdout)
        listed = json.loads(self.run_history(
            "catalog", "--source-root", str(self.source_root), "--state-home", str(state)
        ).stdout)
        selected = next(row for row in listed["entries"] if row["native_id"] == NATIVE_THREAD_ID)
        self.assertEqual(selected["snapshot_id"], first["snapshot_id"])
    def test_changed_canonical_source_does_not_reuse_prepare_receipt(self):
        state = self.base / "prepare-change-state"
        first = json.loads(self.run_history(
            "prepare", "--source-root", str(self.source_root), "--state-home", str(state), "--native-id", NATIVE_THREAD_ID
        ).stdout)
        rollout = self.home / "sessions/2026/10/10" / ("rollout-2026-10-10T01-02-03-" + NATIVE_THREAD_ID + ".jsonl")
        rollout.write_text(rollout.read_text() + '{"type":"response_item","id":"new"}\n')
        second = json.loads(self.run_history(
            "prepare", "--source-root", str(self.source_root), "--state-home", str(state), "--native-id", NATIVE_THREAD_ID
        ).stdout)
        self.assertNotEqual(second["snapshot_id"], first["snapshot_id"], "changed source must not reuse an old prepare receipt")

    def test_tampered_snapshot_manifest_is_rejected_before_restore(self):
        snapshot = json.loads(self.snapshot().stdout)["snapshot_id"]
        manifest = self.catalog / "snapshots" / snapshot / "manifest.json"
        value = json.loads(manifest.read_text())
        value["source_root"] = "/tampered"
        manifest.write_text(json.dumps(value))
        self.run_history("restore", "--catalog", str(self.catalog), "--snapshot", snapshot,
                         "--destination", str(self.base / "tampered-restore"), "--receipt", str(self.base / "tampered-receipt"), expected=2)

    def test_catalog_and_prepare_accept_native_uuid_v7(self):
        native_v7 = "01a12390-1234-7311-8123-123456789abc"
        rollout = self.home / "sessions/2026/10/10" / ("rollout-2026-10-10T01-02-03-" + NATIVE_THREAD_ID + ".jsonl")
        row = json.loads(rollout.read_text().splitlines()[0]); row["payload"]["id"] = native_v7
        rollout.write_text(json.dumps(row) + "\n")
        listed = json.loads(self.run_history("catalog", "--source-root", str(self.source_root), "--state-home", str(self.base / "v7-state")).stdout)
        self.assertIn(native_v7, [entry["native_id"] for entry in listed["entries"]])
        prepared = json.loads(self.run_history("prepare", "--source-root", str(self.source_root), "--state-home", str(self.base / "v7-state"), "--native-id", native_v7).stdout)
        self.assertEqual(prepared["native_id"], native_v7)

    def test_nested_native_directory_symlink_refuses_snapshot(self):
        outside = self.base / "outside-native"; outside.mkdir()
        (self.home / "sessions/2026/10/10/linked-directory").symlink_to(outside, target_is_directory=True)
        self.snapshot(expected=2)
        self.assertFalse(self.catalog.exists())
        self.assertFalse(self.receipt.exists())

    def test_orphan_sqlite_wal_is_not_silently_excluded_from_archive(self):
        (self.home/'state_99.sqlite-wal').write_bytes(b'owned orphan native sentinel')
        self.snapshot(expected=2)
        self.assertFalse(self.receipt.exists())

    def test_foreign_harness_ancestor_symlink_refuses_snapshot_and_catalog(self):
        foreign = self.base / "foreign-source"; foreign.mkdir()
        foreign_harness = foreign / ".harness"; shutil.copytree(self.source_root / ".harness", foreign_harness, symlinks=True)
        shutil.rmtree(self.source_root / ".harness")
        (self.source_root / ".harness").symlink_to(foreign_harness, target_is_directory=True)
        self.snapshot(expected=2)
        self.assertFalse(self.catalog.exists())
        self.assertFalse(self.receipt.exists())
        self.run_history("catalog", "--source-root", str(self.source_root), "--state-home", str(self.base / "symlink-state"), expected=2)

    def test_bound_isolated_foreign_harness_ancestor_symlink_refuses_snapshot(self):
        state = self.base / "isolated-state"; identifier = "33333333-2222-4333-8444-555555555556"
        root = state / "worktrees" / identifier; record = state / "sessions" / identifier
        foreign = self.base / "isolated-foreign"; shutil.copytree(self.source_root / ".harness", foreign / ".harness", symlinks=True)
        root.mkdir(parents=True); (root / ".harness").symlink_to(foreign / ".harness", target_is_directory=True)
        record.mkdir(parents=True)
        for name, value in (("source-root", str(self.source_root)), ("session-root", str(root)),
                            ("root-inode", history_module.root_inode(root)),
                            ("journal", "state=CLOSED\nidentity=\nheartbeat=2026-10-10T00:00:00Z\n"),
                            ("lease-v1", "1\n"), ("runtime.lock", "")):
            (record / name).write_text(value)
        self.run_history("snapshot", "--source", str(root / ".harness/codex"), "--catalog", str(state / "native-history"),
                         "--receipt", str(record / "receipt.json"), "--source-root", str(self.source_root),
                         "--isolation-id", identifier, "--runtime-revision", RUNTIME_REVISION, expected=2)

    def test_legacy_state_catalog_and_prepare_preserve_selected_archive(self):
        legacy = self.base / "legacy-state"; identifier = "11111111-2222-4333-8444-555555555556"
        legacy_native = "22222222-2222-4333-8444-555555555556"
        root = legacy / "worktrees" / identifier; record = legacy / "sessions" / identifier
        legacy_home = root / ".harness/codex"; shutil.copytree(self.home, legacy_home, symlinks=True)
        rollout = next(path for path in (legacy_home / "sessions").rglob("*.jsonl") if "session_meta" in path.read_text())
        first, *rest = rollout.read_text().splitlines(); meta = json.loads(first); meta["payload"]["id"] = legacy_native
        rollout.write_text("\n".join([json.dumps(meta), *rest]) + "\n")
        record.mkdir(parents=True)
        for name, value in (("source-root", str(self.source_root)), ("session-root", str(root)),
                            ("root-inode", history_module.root_inode(root)),
                            ("journal", "state=CLOSED\nidentity=\nheartbeat=2026-10-10T00:00:00Z\n"),
                            ("lease-v1", "1\n"), ("runtime.lock", "")):
            (record / name).write_text(value)
        current = self.base / "current-state"
        listed = json.loads(self.run_history("catalog", "--source-root", str(self.source_root), "--state-home", str(current),
                                             "--legacy-state-home", str(legacy)).stdout)
        entry = next(row for row in listed["entries"] if row["native_id"] == legacy_native and row["home"] == str(legacy_home))
        self.assertEqual(entry["isolation_id"], identifier)
        prepared = self.run_history("prepare", "--source-root", str(self.source_root), "--state-home", str(current),
                                    "--legacy-state-home", str(legacy), "--native-id", legacy_native)
        result = json.loads(prepared.stdout)
        self.assertRegex(result["snapshot_id"], r"^[0-9a-f]{64}$")
        self.assertTrue((current / "native-history/snapshots" / result["snapshot_id"] / "data").is_dir())

    def test_protect_pool_masks_then_restores_on_verifier_failure(self):
        state = self.base / "pool-state"; identifier = ISOLATION_ID
        record = state / "sessions" / identifier; root = state / "worktrees" / identifier
        (root / ".harness/codex").mkdir(parents=True); record.mkdir(parents=True)
        for name, value in (("source-root", str(self.source_root)), ("session-root", str(root)),
                            ("root-inode", history_module.root_inode(root)), ("journal", "state=CLOSED\nidentity=\nheartbeat=2026-10-10T00:00:00Z\n"),
                            ("lease-v1", "1\n"), ("runtime.lock", "")):
            (record / name).write_text(value)
        seen = []
        def fake_snapshot(args):
            Path(args.receipt).write_text(json.dumps({"snapshot_id": "a" * 64}))
            print(json.dumps({"snapshot_id": "a" * 64}))
        def fake_verify(args):
            seen.append((Path(args.source).exists(), root.exists()))
            raise history_module.Refusal("fixture verifier failure")
        args = type("Args", (), {"state_home": str(state), "source_root": str(self.source_root), "codex_bin": "/bin/true"})()
        with mock.patch.object(history_module, "snapshot", fake_snapshot), mock.patch.object(history_module, "verify", fake_verify):
            with self.assertRaises(history_module.Refusal):
                history_module.protect_pool(args)
        self.assertEqual(seen, [(True, False)])
        self.assertTrue((root / ".harness/codex").is_dir())

    def test_repeated_restore_keeps_origin_while_execution_runtime_changes(self):
        state=self.base/'repeat-state';store=state/'native-history'
        first=json.loads(self.run_history('prepare','--source-root',str(self.source_root),
                         '--state-home',str(state),'--native-id',NATIVE_THREAD_ID).stdout)
        revision='b'*40;runtime=state.parent/revision;runtime.mkdir()
        (runtime/'native-placeholder').write_text('fixture runtime bytes')
        manifest={'revision':revision,'version':'0.51.0','files':{'native-placeholder':{
                  'sha256':hashlib.sha256((runtime/'native-placeholder').read_bytes()).hexdigest()}}}
        (runtime/'manifest.json').write_text(json.dumps(manifest))
        bindings=state.parent/'bindings';bindings.mkdir()
        previous=first
        for identifier in ('11111111-2222-4333-8444-555555555557','11111111-2222-4333-8444-555555555558'):
            root=state/'worktrees'/identifier;record=state/'sessions'/identifier
            (root/'.harness/codex').mkdir(parents=True);record.mkdir(parents=True)
            for name,value in (('source-root',str(self.source_root)),('session-root',str(root)),
                               ('root-inode',history_module.root_inode(root)),('runtime.lock',''),
                               ('lease-v1','1\n'),('journal','state=CLOSED\nidentity=\nheartbeat=2026-10-10T00:00:00Z\n')):
                (record/name).write_text(value)
            binding={'source_root':str(self.source_root),'runtime':{'revision':revision,'version':'0.51.0',
                     'path':str(runtime),'manifest_sha256':hashlib.sha256((runtime/'manifest.json').read_bytes()).hexdigest()}}
            file=bindings/(identifier+'.json');file.write_text(json.dumps(binding));file.chmod(0o600)
            self.run_history('restore','--catalog',str(store),'--snapshot',previous['snapshot_id'],
                             '--destination',str(root/'.harness/codex'),'--receipt',str(record/'native-history-restore.json'),
                             '--native-id',NATIVE_THREAD_ID,'--origin-runtime',previous['origin_runtime'])
            prepared=json.loads(self.run_history('prepare','--source-root',str(self.source_root),
                                '--state-home',str(state),'--native-id',NATIVE_THREAD_ID).stdout)
            self.assertEqual(prepared['origin_runtime'],'legacy-unknown')
            saved=json.loads((store/'snapshots'/prepared['snapshot_id']/'manifest.json').read_text())
            self.assertEqual(saved['runtime_revision'],revision)
            self.assertEqual(saved['origin_runtime'],'legacy-unknown')
            listed=json.loads(self.run_history('catalog','--source-root',str(self.source_root),'--state-home',str(state)).stdout)
            row=next(row for row in listed['entries'] if row['native_id']==NATIVE_THREAD_ID)
            self.assertEqual(row['snapshot_id'],prepared['snapshot_id'])
            self.assertEqual(row['origin_runtime'],prepared['origin_runtime'])
            previous=prepared

    def test_protect_pool_calls_verifier_then_restores_terminal_root(self):
        state = self.base / "pool-success"; identifier = ISOLATION_ID
        record = state / "sessions" / identifier; root = state / "worktrees" / identifier
        (root / ".harness/codex").mkdir(parents=True); record.mkdir(parents=True)
        for name, value in (("source-root", str(self.source_root)), ("session-root", str(root)),
                            ("root-inode", history_module.root_inode(root)), ("journal", "state=CLOSED\nidentity=\nheartbeat=2026-10-10T00:00:00Z\n"),
                            ("lease-v1", "1\n"), ("runtime.lock", "")):
            (record / name).write_text(value)
        called = []
        def fake_snapshot(args):
            Path(args.receipt).write_text(json.dumps({"snapshot_id": "b" * 64})); print(json.dumps({"snapshot_id": "b" * 64}))
        def fake_verify(args):
            called.append((Path(args.source).exists(), root.exists()))
        args = type("Args", (), {"state_home": str(state), "source_root": str(self.source_root), "codex_bin": "/bin/true"})()
        with mock.patch.object(history_module, "snapshot", fake_snapshot), mock.patch.object(history_module, "verify", fake_verify):
            history_module.protect_pool(args)
        self.assertEqual(called, [(True, False)])
        self.assertTrue((root / ".harness/codex").is_dir())
        self.assertEqual((record / "journal").read_text(), "state=CLOSED\nidentity=\nheartbeat=2026-10-10T00:00:00Z\n")

    def test_catalog_warns_for_missing_or_mismatched_legacy_native_inode_without_hiding_canonical(self):
        state = self.base / "legacy-inode-warnings"
        for identifier, inode in (("11111111-2222-4333-8444-555555555556", None),
                                  ("11111111-2222-4333-8444-555555555557", "0 0\n")):
            root = state / "worktrees" / identifier
            record = state / "sessions" / identifier
            shutil.copytree(self.home, root / ".harness/codex", symlinks=True)
            record.mkdir(parents=True)
            (record / "source-root").write_text(str(self.source_root))
            (record / "session-root").write_text(str(root))
            if inode is not None:
                (record / "root-inode").write_text(inode)
        result = json.loads(self.run_history("catalog", "--source-root", str(self.source_root), "--state-home", str(state)).stdout)
        self.assertIn(NATIVE_THREAD_ID, [row["native_id"] for row in result["entries"]])
        self.assertEqual({(warning["reason"], warning["isolation_id"], warning["pool"]) for warning in result["warnings"]}, {
            ("root_inode_missing", "11111111-2222-4333-8444-555555555556", "current"),
            ("root_inode_mismatch", "11111111-2222-4333-8444-555555555557", "current"),
        })

    def test_prepare_refuses_unverified_inode_without_snapshot_or_native_mutation(self):
        state = self.base / "unverified-prepare"
        identifier = "11111111-2222-4333-8444-555555555556"
        native = "22222222-2222-4333-8444-555555555556"
        root, record = state / "worktrees" / identifier, state / "sessions" / identifier
        shutil.copytree(self.home, root / ".harness/codex", symlinks=True)
        rollout = next(path for path in (root / ".harness/codex/sessions").rglob("*.jsonl") if "session_meta" in path.read_text())
        value = json.loads(rollout.read_text().splitlines()[0]); value["payload"]["id"] = native
        rollout.write_text(json.dumps(value) + "\n")
        record.mkdir(parents=True)
        (record / "source-root").write_text(str(self.source_root))
        (record / "session-root").write_text(str(root))
        before = digest_tree(root / ".harness/codex")
        self.run_history("prepare", "--source-root", str(self.source_root), "--state-home", str(state), "--native-id", native, expected=2)
        self.assertEqual(digest_tree(root / ".harness/codex"), before)
        self.assertFalse((state / "native-history/snapshots").exists())

    def test_filename_collision_marks_native_uuid_ambiguous_and_prepare_holds(self):
        state = self.base / "filename-collision"
        identifier = "11111111-2222-4333-8444-555555555556"
        root, record = state / "worktrees" / identifier, state / "sessions" / identifier
        shutil.copytree(self.home, root / ".harness/codex", symlinks=True)
        record.mkdir(parents=True)
        (record / "source-root").write_text(str(self.source_root))
        (record / "session-root").write_text(str(root))
        listed = json.loads(self.run_history("catalog", "--source-root", str(self.source_root), "--state-home", str(state)).stdout)
        row = next(item for item in listed["entries"] if item["native_id"] == NATIVE_THREAD_ID)
        self.assertEqual((row["status"], row["reason"]), ("ambiguous", "unverified_native_owner"))
        self.run_history("prepare", "--source-root", str(self.source_root), "--state-home", str(state), "--native-id", NATIVE_THREAD_ID, expected=2)
        self.assertFalse((state / "native-history/snapshots").exists())

    def test_quarantined_rollout_links_fail_catalog_and_prepare_without_body_read(self):
        for kind in ("symlink", "hardlink"):
            state = self.base / ("quarantined-" + kind)
            identifier = "11111111-2222-4333-8444-555555555556"
            root, record = state / "worktrees" / identifier, state / "sessions" / identifier
            home = root / ".harness/codex"
            shutil.copytree(self.home, home, symlinks=True)
            record.mkdir(parents=True)
            (record / "source-root").write_text(str(self.source_root))
            (record / "session-root").write_text(str(root))
            outside = self.base / ("quarantined-" + kind + ".jsonl")
            outside.write_text('{"fixture-only-secret":"must not be read"}\n')
            target = home / "sessions/2026/10/10/quarantined.jsonl"
            if kind == "symlink":
                target.symlink_to(outside)
            else:
                os.link(outside, target)
            proc = self.run_history("catalog", "--source-root", str(self.source_root), "--state-home", str(state), expected=2)
            self.assertNotIn("fixture-only-secret", proc.stdout + proc.stderr)
            self.run_history("prepare", "--source-root", str(self.source_root), "--state-home", str(state), "--native-id", NATIVE_THREAD_ID, expected=2)

    def test_quarantined_malformed_body_is_not_read_and_keeps_canonical_stable(self):
        state = self.base / "quarantined-body"
        identifier = "11111111-2222-4333-8444-555555555556"
        quarantined = "22222222-2222-4333-8444-555555555556"
        root, record = state / "worktrees" / identifier, state / "sessions" / identifier
        home = root / ".harness/codex"
        (home / "sessions/2026/10/10").mkdir(parents=True)
        body = home / "sessions/2026/10/10" / ("rollout-quarantined-" + quarantined + ".jsonl")
        body.write_text("{ malformed native body\n")
        record.mkdir(parents=True)
        (record / "source-root").write_text(str(self.source_root))
        (record / "session-root").write_text(str(root))
        original_open = Path.open
        def guarded_open(path, *args, **kwargs):
            if path == body:
                raise AssertionError("catalog read quarantined native body")
            return original_open(path, *args, **kwargs)
        args = type("Args", (), {"source_root": str(self.source_root), "state_home": str(state), "legacy_state_home": None})()
        with mock.patch.object(Path, "open", guarded_open):
            listed = history_module.catalog_value(args)
        row = next(item for item in listed["entries"] if item["native_id"] == NATIVE_THREAD_ID)
        self.assertEqual((row["status"], row["reason"]), ("canonical", None))
        self.assertIn("root_inode_missing", [warning["reason"] for warning in listed["warnings"]])

    def test_inode_change_after_catalog_makes_prepare_hold(self):
        state = self.base / "inode-changed-after-catalog"
        identifier = "11111111-2222-4333-8444-555555555556"
        native = "22222222-2222-4333-8444-555555555556"
        root, record = state / "worktrees" / identifier, state / "sessions" / identifier
        shutil.copytree(self.home, root / ".harness/codex", symlinks=True)
        rollout = next(path for path in (root / ".harness/codex/sessions").rglob("*.jsonl") if "session_meta" in path.read_text())
        value = json.loads(rollout.read_text().splitlines()[0]); value["payload"]["id"] = native
        rollout.write_text(json.dumps(value) + "\n")
        record.mkdir(parents=True)
        for name, value in (("source-root", str(self.source_root)), ("session-root", str(root)),
                            ("root-inode", history_module.root_inode(root)), ("runtime.lock", ""),
                            ("lease-v1", "1\n"), ("journal", "state=CLOSED\nidentity=\nheartbeat=2026-10-10T00:00:00Z\n")):
            (record / name).write_text(value)
        self.run_history("catalog", "--source-root", str(self.source_root), "--state-home", str(state))
        (record / "root-inode").write_text("0 0\n")
        self.run_history("prepare", "--source-root", str(self.source_root), "--state-home", str(state), "--native-id", native, expected=2)
        self.assertFalse((state / "native-history/snapshots").exists())


    def test_unreadable_quarantined_directory_cannot_hide_a_uuid_collision(self):
        state=self.base/'unreadable-quarantine'
        identifier='11111111-2222-4333-8444-555555555556'
        root=state/'worktrees'/identifier;record=state/'sessions'/identifier
        directory=root/'.harness/codex/sessions';directory.mkdir(parents=True)
        (directory/('rollout-'+NATIVE_THREAD_ID+'.jsonl')).write_text('never parse this body')
        record.mkdir(parents=True)
        (record/'source-root').write_text(str(self.source_root));(record/'session-root').write_text(str(root))
        before={p.name:p.read_bytes() for p in record.iterdir()}
        for denied in (directory,directory.parent,directory.parent.parent,state,root.parent,record,state/'sessions'):
            with self.subTest(denied=str(denied.relative_to(state))):
                denied.chmod(0)
                try:
                    self.run_history('catalog','--source-root',str(self.source_root),'--state-home',str(state),expected=2)
                    self.run_history('prepare','--source-root',str(self.source_root),'--state-home',str(state),'--native-id',NATIVE_THREAD_ID,expected=2)
                finally:denied.chmod(0o700)
        self.assertEqual(before,{p.name:p.read_bytes() for p in record.iterdir()})
        self.assertFalse((state/'native-history/snapshots').exists())

    def test_unreadable_nested_native_data_is_never_omitted_from_snapshot(self):
        denied=self.home/'attachments/private-directory';denied.mkdir()
        (denied/'retained-native-data').write_text('owned native data must remain')
        denied.chmod(0)
        try:self.snapshot(expected=2)
        finally:denied.chmod(0o700)
        self.assertFalse(self.receipt.exists())

    def test_unreadable_canonical_rollout_directory_cannot_hide_a_valid_owner(self):
        denied=self.home/'sessions';denied.chmod(0)
        try:
            self.run_history('catalog','--source-root',str(self.source_root),'--state-home',str(self.base/'unreadable-canonical'),expected=2)
        finally:denied.chmod(0o700)


if __name__ == "__main__":
    unittest.main()

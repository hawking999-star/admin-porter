import importlib
import os
import sys
import threading
import time
import unittest
from unittest.mock import Mock, patch

WORKER_DIR = os.path.dirname(os.path.dirname(__file__))
sys.path.insert(0, WORKER_DIR)


def load_worker_module():
    environment = {
        "SUPABASE_URL": "https://example.supabase.co",
        "SUPABASE_SERVICE_ROLE_KEY": "test-service-role",
        "R2_ACCOUNT_ID": "test-account",
        "R2_ACCESS_KEY_ID": "test-access",
        "R2_SECRET_ACCESS_KEY": "test-secret",
        "R2_BUCKET": "test-bucket",
        "TRACK_CONCURRENCY": "2",
        "TRACK_MAX_ATTEMPTS": "2",
    }
    with (
        patch.dict(os.environ, environment, clear=False),
        patch("supabase.create_client", return_value=Mock()),
        patch("boto3.client", return_value=Mock()),
    ):
        sys.modules.pop("main", None)
        return importlib.import_module("main")


class AsyncTrackProcessingTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.worker = load_worker_module()

    def test_track_configuration_is_centralized_and_bounded(self):
        self.assertEqual(self.worker.TRACK_CONCURRENCY, 2)
        self.assertEqual(self.worker.TRACK_MAX_ATTEMPTS, 2)

    def test_transient_track_failure_stops_after_two_claims(self):
        entry = {
            "id": "abcdefghijk",
            "title": "Faixa teste",
            "duration": 180,
            "request_position": 1,
        }
        with (
            patch.object(
                self.worker,
                "claim_request_item",
                side_effect=[
                    {"id": "item-1", "attempts": 1},
                    {"id": "item-1", "attempts": 2},
                ],
            ) as claim,
            patch.object(self.worker, "set_request_item_status"),
            patch.object(
                self.worker.supabase,
                "table",
                side_effect=RuntimeError("temporary transport failure"),
            ),
        ):
            result = self.worker.process_playlist_entry(
                job_id="job-1",
                playlist_id="playlist-1",
                playlist_request_id="request-1",
                entry=entry,
                source_url="https://www.youtube.com/watch?v=abcdefghijk",
                deadline=self.worker.time.monotonic() + 30,
            )

        self.assertEqual(claim.call_count, 2)
        self.assertEqual(result["status"], "failed")
        self.assertEqual(result["code"], "IMPORTER_ERROR")

    def test_playlist_uses_configured_small_track_pool(self):
        active = 0
        maximum_active = 0
        lock = threading.Lock()

        def fake_process(**_kwargs):
            nonlocal active, maximum_active
            with lock:
                active += 1
                maximum_active = max(maximum_active, active)
            time.sleep(0.05)
            with lock:
                active -= 1
            return {"status": "completed", "reused": False, "abort": False}

        entries = [
            {
                "id": f"video00000{i}",
                "title": f"Faixa {i}",
                "duration": 180,
                "request_position": i,
            }
            for i in range(1, 5)
        ]
        with (
            patch.object(self.worker, "list_source_entries", return_value=(entries, [])),
            patch.object(self.worker, "sync_request_items"),
            patch.object(self.worker, "update_job"),
            patch.object(self.worker, "process_playlist_entry", side_effect=fake_process),
        ):
            self.worker.process_job(
                {
                    "id": "job-1",
                    "playlist_id": "playlist-1",
                    "playlist_request_id": "request-1",
                    "source_url": "https://www.youtube.com/watch?v=abcdefghijk",
                    "attempts": 2,
                    "mode": "playlist",
                }
            )

        self.assertEqual(maximum_active, self.worker.TRACK_CONCURRENCY)
        self.assertLessEqual(maximum_active, 2)


if __name__ == "__main__":
    unittest.main()

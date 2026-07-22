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
        "POT_PROVIDER_BASE_URL": "",
        "YOUTUBE_COOKIES": "",
        "YOUTUBE_COOKIES_FILE": "",
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

    def test_global_youtube_block_defers_track_without_consuming_attempt(self):
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
                return_value={"id": "item-1", "attempts": 1},
            ),
            patch.object(self.worker, "set_request_item_status") as set_status,
            patch.object(self.worker, "open_youtube_circuit") as open_circuit,
            patch.object(
                self.worker.supabase,
                "table",
                side_effect=RuntimeError("YOUTUBE_COOKIES_INVALID"),
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

        self.assertEqual(result["status"], "deferred")
        self.assertTrue(result["abort"])
        open_circuit.assert_called_once_with("YOUTUBE_COOKIES_INVALID")
        self.assertEqual(set_status.call_args.args[2], "resolved")
        self.assertEqual(set_status.call_args.kwargs["attempts"], 0)

    def test_global_youtube_block_requeues_job_for_automatic_resume(self):
        with (
            patch.object(self.worker, "update_job") as update_job,
            patch.object(self.worker, "open_youtube_circuit") as open_circuit,
        ):
            self.worker.fail_job(
                {
                    "id": "job-1",
                    "playlist_id": "playlist-1",
                    "attempts": 3,
                    "started_at": "2026-07-22T12:00:00+00:00",
                },
                RuntimeError("YOUTUBE_COOKIES_INVALID"),
            )

        open_circuit.assert_called_once_with("YOUTUBE_COOKIES_INVALID")
        fields = update_job.call_args.kwargs
        self.assertEqual(fields["status"], "queued")
        self.assertEqual(fields["attempts"], 1)
        self.assertIsNone(fields["locked_at"])
        self.assertEqual(fields["error_code"], "YOUTUBE_COOKIES_INVALID")


if __name__ == "__main__":
    unittest.main()

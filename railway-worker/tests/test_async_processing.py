import importlib
import os
import sys
import tempfile
import threading
import time
import unittest
from unittest.mock import Mock, patch

WORKER_DIR = os.path.dirname(os.path.dirname(__file__))
sys.path.insert(0, WORKER_DIR)


def load_worker_module(**overrides):
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
    environment.update(overrides)
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

    def setUp(self):
        self.worker.reset_youtube_format_failures()

    def test_track_configuration_is_centralized_and_bounded(self):
        self.assertEqual(self.worker.TRACK_CONCURRENCY, 2)
        self.assertEqual(self.worker.TRACK_MAX_ATTEMPTS, 2)

    def test_spotify_failure_resumes_from_validated_request_snapshot(self):
        snapshot = [
            {
                "id": "abcdefghijk",
                "request_position": 1,
                "title": "Faixa teste",
            }
        ]
        with (
            patch.object(
                self.worker,
                "list_source_entries",
                side_effect=RuntimeError("SPOTIFY_METADATA_ERROR"),
            ),
            patch.object(
                self.worker,
                "list_request_snapshot_entries",
                return_value=snapshot,
            ) as list_snapshot,
        ):
            entries, skipped = self.worker.list_source_entries_resumable(
                "https://open.spotify.com/playlist/0AS2QQdymdLg7BHeCs0ech",
                "request-1",
                "job-new",
            )

        self.assertEqual(entries, snapshot)
        self.assertEqual(skipped, [])
        list_snapshot.assert_called_once_with("request-1", "job-new")

    def test_request_snapshot_prefers_the_most_complete_previous_job(self):
        query = Mock()
        query.select.return_value = query
        query.eq.return_value = query
        query.execute.return_value = Mock(
            data=[
                {
                    "download_job_id": "job-new",
                    "position": 1,
                    "youtube_video_id": "zzzzzzzzzzz",
                },
                {
                    "download_job_id": "job-recent",
                    "position": 1,
                    "youtube_video_id": "yyyyyyyyyyy",
                    "updated_at": "2026-07-26T09:00:00+00:00",
                },
                {
                    "download_job_id": "job-complete",
                    "position": 1,
                    "youtube_video_id": "abcdefghijk",
                    "youtube_url": "https://www.youtube.com/watch?v=abcdefghijk",
                    "title": "Faixa um",
                    "artists": ["Artista"],
                    "duration_ms": 180000,
                    "updated_at": "2026-07-24T09:00:00+00:00",
                },
                {
                    "download_job_id": "job-complete",
                    "position": 2,
                    "youtube_video_id": "lmnopqrstuv",
                    "title": "Faixa dois",
                    "artists": ["Artista"],
                    "duration_ms": 190000,
                    "updated_at": "2026-07-24T09:00:00+00:00",
                },
            ]
        )

        with patch.object(self.worker.supabase, "table", return_value=query):
            entries = self.worker.list_request_snapshot_entries(
                "request-1",
                "job-new",
            )

        self.assertEqual(
            [entry["id"] for entry in entries],
            ["abcdefghijk", "lmnopqrstuv"],
        )
        self.assertTrue(
            all(entry["match_method"] == "playlist_request_snapshot" for entry in entries)
        )

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

    def test_duplicate_snapshot_item_does_not_repeat_track_id(self):
        entry = {"_request_item_id": "item-1", "request_position": 1}
        with patch.object(self.worker.supabase, "table") as table:
            self.worker.set_request_item_status(
                "request-1",
                entry,
                "duplicate",
                track_id="track-1",
                error_message="Faixa já vinculada a esta playlist.",
            )

        payload = table.return_value.update.call_args.args[0]
        self.assertEqual(payload["item_status"], "duplicate")
        self.assertNotIn("track_id", payload)

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

    def test_old_railway_client_order_gains_independent_fallbacks(self):
        worker = load_worker_module(
            POT_PROVIDER_BASE_URL="http://pot-provider.internal:4416",
            YT_PLAYER_CLIENTS="mweb,web_safari,default",
        )
        self.assertEqual(
            worker.YT_PLAYER_CLIENTS[:4],
            ["mweb", "default", "android_vr", "web_safari"],
        )

        with patch.object(worker, "YOUTUBE_COOKIEFILE", "cookies.txt"):
            strategies = worker.youtube_download_strategies()

        public = strategies[:4]
        self.assertEqual(
            [strategy.client for strategy in public],
            ["mweb", "default", "android_vr", "web_safari"],
        )
        self.assertEqual(
            [strategy.use_pot_provider for strategy in public],
            [True, False, False, True],
        )
        self.assertTrue(all(not strategy.use_cookie for strategy in public))
        self.assertTrue(any(strategy.use_cookie for strategy in strategies[4:]))
        self.assertTrue(
            all(
                strategy.client != "android_vr"
                for strategy in strategies
                if strategy.use_cookie
            )
        )

    def test_download_falls_back_from_tokenized_mweb_to_clean_default(self):
        video_id = "abcdefghijk"
        commands: list[list[str]] = []
        strategies = [
            self.worker.YoutubeDownloadStrategy("mweb", use_pot_provider=True),
            self.worker.YoutubeDownloadStrategy("default"),
        ]

        with tempfile.TemporaryDirectory() as workdir:
            def fake_run(command, **_kwargs):
                commands.append(command)
                if len(commands) == 1:
                    raise RuntimeError(
                        "Requested format is not available via "
                        "http://pot-provider.internal:4416"
                    )
                with open(os.path.join(workdir, f"{video_id}.mp3"), "wb") as output:
                    output.write(b"mp3")

            with (
                patch.object(
                    self.worker,
                    "POT_PROVIDER_BASE_URL",
                    "http://pot-provider.internal:4416",
                ),
                patch.object(
                    self.worker,
                    "youtube_download_strategies",
                    return_value=strategies,
                ),
                patch.object(
                    self.worker,
                    "run_ytdlp_command",
                    side_effect=fake_run,
                ),
                patch.object(self.worker, "log") as worker_log,
            ):
                result = self.worker.download_one(
                    {"id": video_id},
                    workdir,
                    deadline=self.worker.time.monotonic() + 30,
                )

        self.assertTrue(result.endswith(f"{video_id}.mp3"))
        self.assertIn("youtube:player_client=mweb", commands[0])
        self.assertTrue(
            any("youtubepot-bgutilhttp:base_url=" in arg for arg in commands[0])
        )
        self.assertFalse(
            any("youtubepot-bgutilhttp:base_url=" in arg for arg in commands[1])
        )
        self.assertFalse(any("youtube:player_client=" in arg for arg in commands[1]))
        self.assertNotIn(
            "http://pot-provider.internal:4416",
            "\n".join(str(call) for call in worker_log.call_args_list),
        )

    def test_download_reaches_android_vr_without_provider_or_cookie(self):
        video_id = "abcdefghijk"
        commands: list[list[str]] = []
        strategies = [
            self.worker.YoutubeDownloadStrategy("mweb", use_pot_provider=True),
            self.worker.YoutubeDownloadStrategy("default"),
            self.worker.YoutubeDownloadStrategy("android_vr"),
            self.worker.YoutubeDownloadStrategy(
                "web_safari",
                use_pot_provider=True,
            ),
        ]

        with tempfile.TemporaryDirectory() as workdir:
            def fake_run(command, **_kwargs):
                commands.append(command)
                if len(commands) < 3:
                    raise RuntimeError("Requested format is not available")
                with open(os.path.join(workdir, f"{video_id}.mp3"), "wb") as output:
                    output.write(b"mp3")

            with (
                patch.object(
                    self.worker,
                    "POT_PROVIDER_BASE_URL",
                    "http://pot-provider.internal:4416",
                ),
                patch.object(self.worker, "YOUTUBE_COOKIEFILE", "cookies.txt"),
                patch.object(
                    self.worker,
                    "youtube_download_strategies",
                    return_value=strategies,
                ),
                patch.object(
                    self.worker,
                    "run_ytdlp_command",
                    side_effect=fake_run,
                ),
            ):
                self.worker.download_one(
                    {"id": video_id},
                    workdir,
                    deadline=self.worker.time.monotonic() + 30,
                )

        android_command = commands[2]
        self.assertIn("youtube:player_client=android_vr", android_command)
        self.assertFalse(
            any("youtubepot-bgutilhttp:base_url=" in arg for arg in android_command)
        )
        self.assertNotIn("--cookies", android_command)
        self.assertEqual(len(commands), 3)

    def test_independent_format_failures_remain_a_track_error(self):
        video_id = "abcdefghijk"
        strategies = [
            self.worker.YoutubeDownloadStrategy("mweb", use_pot_provider=True),
            self.worker.YoutubeDownloadStrategy("default"),
            self.worker.YoutubeDownloadStrategy("android_vr"),
            self.worker.YoutubeDownloadStrategy("web_safari", use_pot_provider=True),
        ]

        with (
            tempfile.TemporaryDirectory() as workdir,
            patch.object(
                self.worker,
                "youtube_download_strategies",
                return_value=strategies,
            ),
            patch.object(
                self.worker,
                "run_ytdlp_command",
                side_effect=RuntimeError("Requested format is not available"),
            ),
        ):
            with self.assertRaisesRegex(RuntimeError, "YOUTUBE_FORMAT_UNAVAILABLE"):
                self.worker.download_one(
                    {"id": video_id},
                    workdir,
                    deadline=self.worker.time.monotonic() + 30,
                )

        self.assertEqual(
            self.worker._YOUTUBE_FORMAT_FAILURE_IDS,
            {video_id},
        )

    def test_global_degradation_from_an_alternative_is_not_swallowed(self):
        entry = {
            "id": "abcdefghijk",
            "title": "Faixa teste",
            "artist": "Artista teste",
            "duration": 180,
        }
        with (
            tempfile.TemporaryDirectory() as workdir,
            patch.object(
                self.worker,
                "download_one",
                side_effect=[
                    RuntimeError("YOUTUBE_FORMAT_UNAVAILABLE"),
                    RuntimeError("YOUTUBE_EXTRACTION_DEGRADED"),
                ],
            ),
            patch.object(
                self.worker,
                "find_alternatives",
                return_value=[
                    {
                        "id": "lmnopqrstuv",
                        "title": "Faixa teste alternativa",
                        "duration": 180,
                    }
                ],
            ),
        ):
            with self.assertRaisesRegex(RuntimeError, "YOUTUBE_EXTRACTION_DEGRADED"):
                self.worker.download_with_fallback(
                    entry,
                    workdir,
                    deadline=self.worker.time.monotonic() + 30,
                )

    def test_one_format_failure_remains_track_scoped(self):
        self.assertFalse(self.worker.record_youtube_format_failure("video-one"))
        code, _message = self.worker.classify_error(
            RuntimeError("YOUTUBE_FORMAT_UNAVAILABLE: sem formato")
        )
        self.assertEqual(code, "YOUTUBE_FORMAT_UNAVAILABLE")

    def test_three_distinct_format_failures_promote_global_degradation(self):
        self.assertFalse(self.worker.record_youtube_format_failure("video-one"))
        self.assertFalse(self.worker.record_youtube_format_failure("video-two"))
        self.assertTrue(self.worker.record_youtube_format_failure("video-three"))
        code, _message = self.worker.classify_error(
            RuntimeError("YOUTUBE_EXTRACTION_DEGRADED")
        )
        self.assertEqual(code, "YOUTUBE_EXTRACTION_DEGRADED")

    def test_success_resets_format_failure_streak(self):
        self.assertFalse(self.worker.record_youtube_format_failure("video-one"))
        self.assertFalse(self.worker.record_youtube_format_failure("video-two"))
        self.worker.close_youtube_circuit()
        self.assertFalse(self.worker.record_youtube_format_failure("video-three"))

    def test_global_extraction_degradation_defers_without_consuming_attempt(self):
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
                side_effect=RuntimeError("YOUTUBE_EXTRACTION_DEGRADED"),
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
        open_circuit.assert_called_once_with("YOUTUBE_EXTRACTION_DEGRADED")
        self.assertEqual(set_status.call_args.args[2], "resolved")
        self.assertEqual(set_status.call_args.kwargs["attempts"], 0)


if __name__ == "__main__":
    unittest.main()

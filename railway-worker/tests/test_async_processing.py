import importlib
import os
import sys
import tempfile
import threading
import time
import unittest
from unittest.mock import MagicMock, Mock, patch

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
        self.assertEqual(self.worker.TRACK_CONCURRENCY, 1)
        self.assertEqual(self.worker.TRACK_MAX_ATTEMPTS, 2)
        self.assertEqual(self.worker.MAX_CONCURRENT_JOBS, 10)
        self.assertEqual(self.worker.LOCAL_CONCURRENT_JOBS, 5)

    def test_single_track_reuses_existing_audio_without_unbound_video_id(self):
        tracks_query = MagicMock()
        tracks_query.select.return_value = tracks_query
        tracks_query.eq.return_value = tracks_query
        tracks_query.limit.return_value = tracks_query
        tracks_query.execute.return_value = Mock(data=[{"id": "track-existing"}])

        playlist_tracks_query = MagicMock()
        playlist_tracks_query.select.return_value = playlist_tracks_query
        playlist_tracks_query.eq.return_value = playlist_tracks_query
        playlist_tracks_query.order.return_value = playlist_tracks_query
        playlist_tracks_query.limit.return_value = playlist_tracks_query
        playlist_tracks_query.upsert.return_value = playlist_tracks_query
        playlist_tracks_query.execute.side_effect = [
            Mock(data=[{"position": 5}]),
            Mock(data=[]),
        ]

        def table_for_existing_audio(name):
            if name == "tracks":
                return tracks_query
            if name == "playlist_tracks":
                return playlist_tracks_query
            raise AssertionError(f"unexpected table: {name}")

        with (
            patch.object(
                self.worker,
                "_extract_single_video",
                return_value={
                    "id": "e_TAAedy0Y4",
                    "title": "Faixa existente",
                    "artist": "Artista",
                    "duration": 180,
                },
            ),
            patch.object(
                self.worker.supabase,
                "table",
                side_effect=table_for_existing_audio,
            ),
            patch.object(self.worker, "download_with_fallback") as download,
            patch.object(self.worker, "_remove_skipped_from_playlist"),
            patch.object(self.worker, "update_job") as update_job,
            patch.object(
                self.worker,
                "set_request_item_status_by_youtube_id",
            ) as set_item_status,
            patch.object(
                self.worker,
                "reconcile_playlist_job_after_manual_item",
            ) as reconcile_job,
        ):
            self.worker.process_single_track_job(
                {
                    "id": "job-1",
                    "playlist_id": "playlist-1",
                    "playlist_request_id": "request-1",
                    "replace_youtube_id": "e_TAAedy0Y4",
                },
                "https://www.youtube.com/watch?v=e_TAAedy0Y4",
            )

        download.assert_not_called()
        update_job.assert_called_once()
        self.assertEqual(update_job.call_args.kwargs["status"], "done")
        set_item_status.assert_called_once_with(
            "request-1",
            "e_TAAedy0Y4",
            "completed",
            track_id="track-existing",
            error_message=None,
        )
        reconcile_job.assert_called_once_with("request-1")

    def test_single_track_status_updates_only_processing_duplicate_item(self):
        select_query = MagicMock()
        select_query.select.return_value = select_query
        select_query.eq.return_value = select_query
        select_query.order.return_value = select_query
        select_query.execute.return_value = Mock(
            data=[
                {
                    "id": "item-processing",
                    "item_status": "processing",
                    "track_id": None,
                },
                {
                    "id": "item-historical",
                    "item_status": "failed",
                    "track_id": "track-existing",
                },
            ]
        )
        update_query = MagicMock()
        update_query.update.return_value = update_query
        update_query.eq.return_value = update_query
        update_query.execute.return_value = Mock(data=[])

        with patch.object(
            self.worker.supabase,
            "table",
            side_effect=[select_query, update_query],
        ):
            self.worker.set_request_item_status_by_youtube_id(
                "request-1",
                "e_TAAedy0Y4",
                "completed",
                track_id="track-existing",
                error_message=None,
            )

        payload = update_query.update.call_args.args[0]
        self.assertEqual(payload["item_status"], "duplicate")
        self.assertEqual(
            payload["error_message"],
            "Faixa já vinculada a esta playlist.",
        )
        self.assertNotIn("track_id", payload)
        update_query.eq.assert_called_once_with("id", "item-processing")

    def test_manual_retry_reconciles_fully_resolved_playlist_job(self):
        jobs_query = MagicMock()
        jobs_query.select.return_value = jobs_query
        jobs_query.eq.return_value = jobs_query
        jobs_query.order.return_value = jobs_query
        jobs_query.execute.return_value = Mock(
            data=[
                {
                    "id": "single-job",
                    "mode": "single_track",
                    "status": "done",
                },
                {
                    "id": "playlist-job",
                    "mode": None,
                    "status": "partial",
                },
            ]
        )
        items_query = MagicMock()
        items_query.select.return_value = items_query
        items_query.eq.return_value = items_query
        items_query.execute.return_value = Mock(
            data=[
                {"item_status": "duplicate"},
                {"item_status": "completed"},
            ]
        )

        with (
            patch.object(
                self.worker.supabase,
                "table",
                side_effect=[jobs_query, items_query],
            ),
            patch.object(self.worker, "update_job") as update_job,
        ):
            self.worker.reconcile_playlist_job_after_manual_item("request-1")

        update_job.assert_called_once()
        self.assertEqual(update_job.call_args.args[0], "playlist-job")
        self.assertEqual(update_job.call_args.kwargs["status"], "done")
        self.assertEqual(update_job.call_args.kwargs["total"], 2)
        self.assertEqual(update_job.call_args.kwargs["completed"], 2)
        self.assertEqual(update_job.call_args.kwargs["failed"], 0)
        self.assertIsNone(update_job.call_args.kwargs["error_code"])

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

    def test_request_snapshot_requires_matching_hash_and_total_from_same_request(self):
        snapshot_rows = [
            {
                "download_job_id": "job-complete",
                "position": 1,
                "source_track_id": "0000000000000000000001",
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
                "source_track_id": "0000000000000000000002",
                "youtube_video_id": None,
                "title": "Faixa dois",
                "artists": ["Artista"],
                "duration_ms": 190000,
                "updated_at": "2026-07-24T09:00:00+00:00",
            },
        ]
        digest = self.worker.spotify_snapshot_digest(snapshot_rows)

        request_query = Mock()
        request_query.select.return_value = request_query
        request_query.eq.return_value = request_query
        request_query.limit.return_value = request_query
        request_query.execute.return_value = Mock(
            data=[
                {
                    "source_metadata": {
                        "spotify_snapshot": {
                            "track_count": 2,
                            "ordered_track_ids_sha256": digest,
                        }
                    }
                }
            ]
        )

        tracks_query = Mock()
        tracks_query.select.return_value = tracks_query
        tracks_query.eq.return_value = tracks_query
        tracks_query.execute.return_value = Mock(
            data=[
                {
                    "download_job_id": "job-new",
                    "position": 1,
                    "youtube_video_id": "zzzzzzzzzzz",
                },
                *snapshot_rows,
            ]
        )

        with patch.object(
            self.worker.supabase,
            "table",
            side_effect=[request_query, tracks_query],
        ):
            entries = self.worker.list_request_snapshot_entries(
                "request-1",
                "job-new",
            )

        self.assertEqual([entry["id"] for entry in entries], ["abcdefghijk", None])
        self.assertEqual(entries[1]["spotify_match_status"], "resolving")
        self.assertTrue(
            all(entry["match_method"] == "playlist_request_snapshot" for entry in entries)
        )

    def test_new_request_never_uses_snapshot_from_another_request(self):
        request_query = Mock()
        request_query.select.return_value = request_query
        request_query.eq.return_value = request_query
        request_query.limit.return_value = request_query
        request_query.execute.return_value = Mock(data=[{"source_metadata": {}}])

        with patch.object(
            self.worker.supabase,
            "table",
            return_value=request_query,
        ) as table:
            entries = self.worker.list_request_snapshot_entries(
                "request-new",
                "job-new",
            )

        self.assertEqual(entries, [])
        table.assert_called_once_with("playlist_requests")

    def test_fresh_spotify_items_are_all_persisted_as_resolving(self):
        query = Mock()
        query.select.return_value = query
        query.eq.return_value = query
        query.execute.return_value = Mock(data=[])
        query.upsert.return_value = query
        entries = [
            {
                "id": None,
                "request_position": position,
                "spotify_id": f"{position:022d}",
                "spotify_url": f"https://open.spotify.com/track/{position:022d}",
                "title": f"Faixa {position}",
                "artists": ["Artista"],
                "artist": "Artista",
                "duration": 180,
                "spotify_match_status": "resolving",
            }
            for position in range(1, 12)
        ]

        with (
            patch.object(self.worker.supabase, "table", return_value=query),
            patch.object(
                self.worker,
                "previous_request_items_for_retry",
                return_value=[],
            ),
        ):
            self.worker.sync_request_items("request-1", "job-1", entries, [])

        payload = query.upsert.call_args.args[0]
        self.assertEqual(len(payload), 11)
        self.assertTrue(all(item["item_status"] == "resolving" for item in payload))
        self.assertEqual(
            [item["source_track_id"] for item in payload],
            [f"{position:022d}" for position in range(1, 12)],
        )

    def test_reimport_preserves_previous_terminal_states_and_track_identity(self):
        query = Mock()
        query.select.return_value = query
        query.eq.return_value = query
        query.execute.return_value = Mock(data=[])
        query.delete.return_value = query
        query.is_.return_value = query
        query.upsert.return_value = query
        previous_items = [
            {
                "position": 1,
                "item_status": "completed",
                "error_message": None,
                "last_error_code": None,
                "track_id": "track-existing",
                "youtube_url": "https://www.youtube.com/watch?v=abcdefghijk",
                "youtube_video_id": "abcdefghijk",
                "match_confidence": 99.0,
                "metadata": {"accepted_in_job": "job-old"},
            },
            {
                "position": 2,
                "item_status": "failed",
                "error_message": "Falha temporária",
                "last_error_code": "YOUTUBE_FORMAT_UNAVAILABLE",
                "track_id": None,
                "youtube_url": "https://www.youtube.com/watch?v=lmnopqrstuv",
                "youtube_video_id": "lmnopqrstuv",
                "match_confidence": 98.0,
                "metadata": {},
            },
        ]
        entries = [
            {
                "id": "newvideo001",
                "request_position": 1,
                "title": "Faixa concluída",
                "artists": ["Artista"],
                "duration": 180,
                "spotify_match_status": "matched",
            },
            {
                "id": "newvideo002",
                "request_position": 2,
                "title": "Faixa com falha",
                "artists": ["Artista"],
                "duration": 181,
                "spotify_match_status": "matched",
            },
        ]

        with (
            patch.object(self.worker.supabase, "table", return_value=query),
            patch.object(
                self.worker,
                "previous_request_items_for_retry",
                return_value=previous_items,
            ) as previous,
        ):
            self.worker.sync_request_items("request-1", "job-new", entries, [])

        previous.assert_called_once_with("request-1", "job-new")
        payload = query.upsert.call_args.args[0]
        self.assertEqual(payload[0]["item_status"], "completed")
        self.assertEqual(payload[0]["track_id"], "track-existing")
        self.assertEqual(payload[0]["youtube_video_id"], "abcdefghijk")
        self.assertEqual(
            payload[0]["metadata"]["accepted_in_job"],
            "job-old",
        )
        self.assertEqual(payload[0]["download_job_id"], "job-new")
        self.assertEqual(payload[1]["item_status"], "failed")
        self.assertEqual(payload[1]["youtube_video_id"], "newvideo002")
        self.assertEqual(
            payload[1]["last_error_code"],
            "YOUTUBE_FORMAT_UNAVAILABLE",
        )

    def test_retry_history_prefers_decisive_state_over_reopened_review(self):
        jobs_query = MagicMock()
        jobs_query.select.return_value = jobs_query
        jobs_query.eq.return_value = jobs_query
        jobs_query.neq.return_value = jobs_query
        jobs_query.order.return_value = jobs_query
        jobs_query.limit.return_value = jobs_query
        jobs_query.execute.return_value = Mock(
            data=[
                {"id": "job-newer", "mode": "playlist"},
                {"id": "job-older", "mode": "playlist"},
                {"id": "job-single", "mode": "single_track"},
            ]
        )
        items_query = MagicMock()
        items_query.select.return_value = items_query
        items_query.eq.return_value = items_query
        items_query.in_.return_value = items_query
        items_query.execute.return_value = Mock(
            data=[
                {
                    "download_job_id": "job-newer",
                    "position": 1,
                    "item_status": "review_recommended",
                },
                {
                    "download_job_id": "job-older",
                    "position": 1,
                    "item_status": "completed",
                },
                {
                    "download_job_id": "job-newer",
                    "position": 2,
                    "item_status": "review_recommended",
                },
                {
                    "download_job_id": "job-older",
                    "position": 2,
                    "item_status": "failed",
                },
                {
                    "download_job_id": "job-newer",
                    "position": 3,
                    "item_status": "duplicate",
                },
                {
                    "download_job_id": "job-older",
                    "position": 3,
                    "item_status": "completed",
                },
            ]
        )

        with patch.object(
            self.worker.supabase,
            "table",
            side_effect=[jobs_query, items_query],
        ):
            items = self.worker.previous_request_items_for_retry(
                "request-1",
                "job-current",
            )

        self.assertEqual(
            [item["item_status"] for item in items],
            ["completed", "review_recommended", "duplicate"],
        )
        items_query.in_.assert_called_once_with(
            "download_job_id",
            ["job-newer", "job-older"],
        )

    def test_resume_preserves_resolved_youtube_match_and_diagnostics(self):
        query = Mock()
        query.select.return_value = query
        query.eq.return_value = query
        query.delete.return_value = query
        query.is_.return_value = query
        query.upsert.return_value = query
        query.execute.side_effect = [
            Mock(
                data=[
                    {
                        "position": 1,
                        "item_status": "resolved",
                        "error_message": "instabilidade anterior",
                        "youtube_url": "https://www.youtube.com/watch?v=abcdefghijk",
                        "youtube_video_id": "abcdefghijk",
                        "match_confidence": 98.7,
                        "metadata": {
                            "last_error_details": {"exception_type": "ConnectError"}
                        },
                    }
                ]
            ),
            Mock(data=[]),
            Mock(data=[]),
        ]
        entry = {
            "id": None,
            "request_position": 1,
            "spotify_id": "spotify-track-1",
            "spotify_url": "https://open.spotify.com/track/spotify-track-1",
            "title": "Faixa teste",
            "artists": ["Artista"],
            "duration": 180,
            "spotify_match_status": "resolving",
        }

        with patch.object(self.worker.supabase, "table", return_value=query):
            self.worker.sync_request_items("request-1", "job-1", [entry], [])

        payload = query.upsert.call_args.args[0][0]
        self.assertEqual(payload["youtube_video_id"], "abcdefghijk")
        self.assertEqual(
            payload["youtube_url"],
            "https://www.youtube.com/watch?v=abcdefghijk",
        )
        self.assertEqual(payload["match_confidence"], 98.7)
        self.assertEqual(
            payload["metadata"]["last_error_details"]["exception_type"],
            "ConnectError",
        )

    def test_spotify_youtube_search_ranks_exact_audio_above_live_version(self):
        ydl = MagicMock()
        ydl.__enter__.return_value = ydl
        ydl.extract_info.return_value = {
            "entries": [
                {
                    "id": "livevideo01",
                    "title": "Artista Teste - Faixa Teste (Live)",
                    "uploader": "Artista Teste",
                    "duration": 240,
                },
                {
                    "id": "exactvideo1",
                    "title": "Artista Teste - Faixa Teste (Official Audio)",
                    "uploader": "Artista Teste",
                    "duration": 201,
                },
            ]
        }
        with patch.object(self.worker, "YoutubeDL", return_value=ydl):
            resolved = self.worker.resolve_spotify_youtube_entry(
                {
                    "title": "Faixa Teste",
                    "artists": ["Artista Teste"],
                    "artist": "Artista Teste",
                    "duration": 201.5,
                },
                deadline=self.worker.time.monotonic() + 30,
            )

        self.assertEqual(resolved["id"], "exactvideo1")
        self.assertEqual(resolved["spotify_match_status"], "resolved")
        self.assertEqual(
            resolved["_match_metadata"]["youtube_channel"],
            "Artista Teste",
        )

    def test_spotify_youtube_search_recommends_live_candidate_for_review(self):
        ydl = MagicMock()
        ydl.__enter__.return_value = ydl
        ydl.extract_info.return_value = {
            "entries": [
                {
                    "id": "livevideo01",
                    "title": "Artista Teste - Faixa Teste (Live)",
                    "uploader": "Artista Teste",
                    "duration": 240,
                }
            ]
        }
        with patch.object(self.worker, "YoutubeDL", return_value=ydl):
            resolved = self.worker.resolve_spotify_youtube_entry(
                {
                    "title": "Faixa Teste",
                    "artists": ["Artista Teste"],
                    "artist": "Artista Teste",
                    "duration": 201.5,
                },
                deadline=self.worker.time.monotonic() + 30,
            )

        self.assertEqual(resolved["spotify_match_status"], "review_recommended")
        self.assertIn("live", resolved["spotify_review_reason"])

    def test_spotify_youtube_search_without_candidate_has_stable_failure(self):
        ydl = MagicMock()
        ydl.__enter__.return_value = ydl
        ydl.extract_info.return_value = {"entries": []}
        with patch.object(self.worker, "YoutubeDL", return_value=ydl):
            with self.assertRaisesRegex(RuntimeError, "SPOTIFY_MATCH_NOT_FOUND"):
                self.worker.resolve_spotify_youtube_entry(
                    {
                        "title": "Faixa sem candidato",
                        "artists": ["Artista"],
                        "duration": 180,
                    },
                    deadline=self.worker.time.monotonic() + 30,
                )

    def test_existing_spotify_track_is_reused_without_duplicate_download(self):
        existing_track = Mock()
        existing_track.select.return_value = existing_track
        existing_track.eq.return_value = existing_track
        existing_track.limit.return_value = existing_track
        existing_track.execute.return_value = Mock(data=[{"id": "track-existing"}])

        existing_link = Mock()
        existing_link.select.return_value = existing_link
        existing_link.eq.return_value = existing_link
        existing_link.limit.return_value = existing_link
        existing_link.execute.return_value = Mock(data=[{"track_id": "track-existing"}])

        resolved = {
            "id": "exactvideo1",
            "source": "spotify",
            "spotify_id": "0000000000000000000001",
            "spotify_url": "https://open.spotify.com/track/0000000000000000000001",
            "request_position": 1,
            "title": "Faixa existente",
            "artists": ["Artista"],
            "artist": "Artista",
            "duration": 180,
            "spotify_match_status": "resolved",
            "match_method": "yt_dlp_search",
        }
        with (
            patch.object(
                self.worker,
                "claim_request_item",
                return_value={"id": "item-1", "attempts": 1},
            ),
            patch.object(
                self.worker,
                "resolve_spotify_youtube_entry",
                return_value=resolved,
            ),
            patch.object(self.worker, "persist_request_item_match"),
            patch.object(self.worker, "set_request_item_status") as set_status,
            patch.object(self.worker, "download_with_fallback") as download,
            patch.object(
                self.worker.supabase,
                "table",
                side_effect=[existing_track, existing_link],
            ),
        ):
            result = self.worker.process_playlist_entry(
                job_id="job-1",
                playlist_id="playlist-1",
                playlist_request_id="request-1",
                entry={
                    **resolved,
                    "id": None,
                    "spotify_match_status": "resolving",
                },
                source_url="https://open.spotify.com/playlist/0AS2QQdymdLg7BHeCs0ech",
                deadline=self.worker.time.monotonic() + 30,
            )

        self.assertEqual(result["status"], "duplicate")
        self.assertTrue(result["reused"])
        download.assert_not_called()
        self.assertEqual(set_status.call_args.args[2], "duplicate")

    def test_storage_key_reuse_only_accepts_available_track(self):
        query = Mock()
        query.select.return_value = query
        query.eq.return_value = query
        query.limit.return_value = query
        query.execute.return_value = Mock(data=[])

        with patch.object(self.worker.supabase, "table", return_value=query):
            result = self.worker.existing_available_track_by_storage_key(
                "tracks/AoIkvrgiPQg.mp3"
            )

        self.assertIsNone(result)
        self.assertIn(
            ("status", "available"),
            [call.args for call in query.eq.call_args_list],
        )

    def test_bound_single_track_uses_atomic_replacement(self):
        tracks_query = MagicMock()
        tracks_query.select.return_value = tracks_query
        tracks_query.eq.return_value = tracks_query
        tracks_query.limit.return_value = tracks_query
        tracks_query.execute.return_value = Mock(data=[{"id": "track-existing"}])

        with (
            patch.object(
                self.worker,
                "_extract_single_video",
                return_value={
                    "id": "e_TAAedy0Y4",
                    "title": "Faixa existente",
                    "artist": "Artista",
                    "duration": 180,
                },
            ),
            patch.object(self.worker.supabase, "table", return_value=tracks_query),
            patch.object(self.worker, "replace_playlist_request_track") as replace_track,
            patch.object(self.worker, "_remove_skipped_from_playlist"),
            patch.object(self.worker, "update_job"),
            patch.object(self.worker, "set_request_item_status_by_youtube_id") as legacy_status,
            patch.object(self.worker, "reconcile_playlist_job_after_manual_item"),
        ):
            self.worker.process_single_track_job(
                {
                    "id": "job-atomic",
                    "playlist_id": "playlist-1",
                    "playlist_request_id": "request-1",
                    "playlist_request_item_id": "item-1",
                    "replace_youtube_id": "oldVideo001",
                },
                "https://www.youtube.com/watch?v=e_TAAedy0Y4",
            )

        replace_track.assert_called_once_with(
            "job-atomic",
            "track-existing",
            "e_TAAedy0Y4",
        )
        legacy_status.assert_not_called()

    def test_transient_track_failure_defers_without_consuming_attempt(self):
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
                return_value={"id": "item-1", "attempts": 1, "metadata": {}},
            ) as claim,
            patch.object(self.worker, "set_request_item_status") as set_status,
            patch.object(self.worker, "open_youtube_circuit") as open_circuit,
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

        self.assertEqual(claim.call_count, 1)
        self.assertEqual(result["status"], "deferred")
        self.assertEqual(result["code"], "IMPORTER_TRANSIENT")
        self.assertTrue(result["abort"])
        self.assertEqual(set_status.call_args.args[2], "resolved")
        self.assertEqual(set_status.call_args.kwargs["attempts"], 0)
        self.assertEqual(
            set_status.call_args.kwargs["youtube_video_id"],
            "abcdefghijk",
        )
        self.assertIn(
            "temporary transport failure",
            set_status.call_args.kwargs["metadata"]["last_error_details"][
                "technical_summary"
            ],
        )
        open_circuit.assert_not_called()

    def test_unknown_track_failure_still_uses_bounded_local_retry(self):
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
                    {"id": "item-1", "attempts": 1, "metadata": {}},
                    {"id": "item-1", "attempts": 2, "metadata": {}},
                ],
            ) as claim,
            patch.object(self.worker, "set_request_item_status") as set_status,
            patch.object(
                self.worker.supabase,
                "table",
                side_effect=RuntimeError("unexpected parser bug"),
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
        self.assertEqual(
            set_status.call_args.kwargs["metadata"]["last_error_details"][
                "exception_type"
            ],
            "RuntimeError",
        )

    def test_cached_terminal_item_restores_saved_technical_error(self):
        entry = {
            "id": "abcdefghijk",
            "title": "Faixa teste",
            "duration": 180,
            "request_position": 1,
        }
        saved_details = {
            "exception_type": "RemoteProtocolError",
            "technical_summary": "server disconnected",
        }
        with (
            patch.object(self.worker, "claim_request_item", return_value=None),
            patch.object(
                self.worker,
                "current_request_item",
                return_value={
                    "item_status": "failed",
                    "attempts": 2,
                    "last_error_code": "IMPORTER_ERROR",
                    "error_message": "O serviço de importação está indisponível.",
                    "youtube_video_id": "abcdefghijk",
                    "metadata": {"last_error_details": saved_details},
                },
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

        self.assertEqual(result["status"], "failed")
        self.assertEqual(result["technical"], saved_details)
        self.assertEqual(result["skipped"]["youtube_id"], "abcdefghijk")

    def test_resumed_job_rebuilds_review_and_completed_counts_from_items(self):
        entries = [
            {
                "id": "abcdefghijk",
                "title": "Faixa concluída",
                "duration": 180,
                "request_position": 1,
                "spotify_match_status": "matched",
            },
            {
                "id": None,
                "title": "Faixa para revisão",
                "duration": 180,
                "request_position": 2,
                "spotify_match_status": "resolving",
            },
        ]
        with (
            patch.object(
                self.worker,
                "list_source_entries_resumable",
                return_value=(entries, []),
            ),
            patch.object(self.worker, "sync_request_items"),
            patch.object(self.worker, "persist_spotify_snapshot"),
            patch.object(
                self.worker,
                "current_job_request_item_statuses",
                return_value={1: "completed", 2: "review_recommended"},
            ),
            patch.object(self.worker, "update_job") as update_job,
            patch.object(
                self.worker,
                "principal_playlist_remaining_slots",
                return_value=None,
            ),
            patch.object(self.worker, "process_playlist_entry") as process_entry,
        ):
            self.worker.process_job(
                {
                    "id": "job-resume",
                    "playlist_id": "playlist-1",
                    "playlist_request_id": "request-1",
                    "source_url": "https://open.spotify.com/playlist/2UFg68VUkweILTWPUg5sYW",
                    "attempts": 2,
                    "mode": "playlist",
                }
            )

        process_entry.assert_not_called()
        final = update_job.call_args.kwargs
        self.assertEqual(final["status"], "partial")
        self.assertEqual(final["completed"], 1)
        self.assertEqual(final["failed"], 0)
        self.assertEqual(final["error_code"], "REVIEW_RECOMMENDED")
        self.assertEqual(
            final["error_details"]["summary"]["review_pending"],
            1,
        )

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
            patch.object(self.worker, "update_job") as update_job,
            patch.object(
                self.worker,
                "principal_playlist_remaining_slots",
                return_value=None,
            ),
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
        final_fields = update_job.call_args.kwargs
        self.assertEqual(final_fields["status"], "done")
        self.assertEqual(final_fields["failed"], 0)
        self.assertIsNone(final_fields["error_code"])
        self.assertIsNone(final_fields["error_message"])

    def test_principal_playlist_stops_downloading_when_last_slot_is_filled(self):
        entries = [
            {
                "id": f"video00000{i}",
                "title": f"Faixa {i}",
                "duration": 180,
                "request_position": i,
            }
            for i in range(1, 5)
        ]

        def limit_skips(_job_id, outside_limit):
            return [
                self.worker.playlist_limit_skip(entry)
                for entry in outside_limit
            ]

        with (
            patch.object(self.worker, "list_source_entries", return_value=(entries, [])),
            patch.object(self.worker, "sync_request_items"),
            patch.object(self.worker, "update_job") as update_job,
            patch.object(
                self.worker,
                "principal_playlist_remaining_slots",
                side_effect=[1, 0],
            ),
            patch.object(
                self.worker,
                "process_playlist_entry",
                return_value={
                    "status": "completed",
                    "reused": False,
                    "abort": False,
                },
            ) as process_entry,
            patch.object(
                self.worker,
                "mark_entries_outside_principal_limit",
                side_effect=limit_skips,
            ) as mark_limit,
        ):
            self.worker.process_job(
                {
                    "id": "job-limit",
                    "playlist_id": "playlist-principal",
                    "playlist_request_id": "request-limit",
                    "source_url": "https://www.youtube.com/watch?v=abcdefghijk",
                    "attempts": 1,
                    "mode": "playlist",
                }
            )

        process_entry.assert_called_once()
        outside_limit = mark_limit.call_args.args[1]
        self.assertEqual(
            [entry["request_position"] for entry in outside_limit],
            [2, 3, 4],
        )
        final_fields = update_job.call_args.kwargs
        self.assertEqual(final_fields["status"], "done")
        self.assertEqual(final_fields["completed"], 1)
        self.assertEqual(final_fields["failed"], 3)
        self.assertEqual(final_fields["error_code"], "PLAYLIST_LIMIT_REACHED")

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

    def test_global_youtube_block_uses_finite_shared_deferral(self):
        with (
            patch.object(self.worker, "update_job") as update_job,
            patch.object(self.worker, "open_youtube_circuit") as open_circuit,
            patch.object(
                self.worker,
                "defer_youtube_job",
                return_value={
                    "defer_count": 3,
                    "blocked": True,
                    "delay_seconds": 3600,
                },
            ) as defer_job,
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

        defer_job.assert_called_once()
        open_circuit.assert_called_once_with("YOUTUBE_COOKIES_INVALID", 3600)
        update_job.assert_not_called()

    def test_first_global_youtube_block_waits_fifteen_minutes(self):
        with (
            patch.object(
                self.worker,
                "defer_youtube_job",
                return_value={
                    "defer_count": 1,
                    "blocked": False,
                    "delay_seconds": 900,
                },
            ),
            patch.object(self.worker, "open_youtube_circuit") as open_circuit,
        ):
            self.worker.fail_job(
                {"id": "job-1", "playlist_id": "playlist-1", "attempts": 1},
                RuntimeError("YOUTUBE_COOKIES_INVALID"),
            )

        open_circuit.assert_called_once_with("YOUTUBE_COOKIES_INVALID", 900)

    def test_global_slot_is_released_when_download_crashes(self):
        with (
            tempfile.TemporaryDirectory() as workdir,
            patch.object(
                self.worker,
                "acquire_music_operation_slot",
                return_value="lease-1",
            ),
            patch.object(
                self.worker,
                "download_with_fallback",
                side_effect=RuntimeError("download crashed"),
            ),
            patch.object(self.worker, "release_music_operation_slot") as release,
        ):
            with self.assertRaisesRegex(RuntimeError, "download crashed"):
                self.worker.download_with_global_slot(
                    {"id": "abcdefghijk"},
                    workdir,
                    playlist_id="playlist-1",
                    deadline=self.worker.time.monotonic() + 30,
                )

        release.assert_called_once_with("lease-1")

    def test_upload_magic_bytes_reject_spoofed_extension(self):
        with tempfile.TemporaryDirectory() as workdir:
            path = os.path.join(workdir, "spoofed.mp3")
            with open(path, "wb") as upload:
                upload.write(b"not an audio container")
            with self.assertRaisesRegex(ValueError, "MUSIC_UPLOAD_MAGIC_BYTES_INVALID"):
                self.worker.detect_uploaded_audio_container(path)

    def test_upload_magic_bytes_accept_supported_containers(self):
        headers = {
            "mp3": b"ID3\x04\x00\x00\x00\x00\x00\x00",
            "m4a": b"\x00\x00\x00\x18ftypM4A ",
            "ogg": b"OggS\x00\x02\x00\x00\x00\x00\x00\x00",
            "wav": b"RIFF\x00\x00\x00\x00WAVEfmt ",
        }
        for expected, header in headers.items():
            with self.subTest(container=expected), tempfile.TemporaryDirectory() as workdir:
                path = os.path.join(workdir, f"audio.{expected}")
                with open(path, "wb") as upload:
                    upload.write(header)
                self.assertEqual(
                    self.worker.detect_uploaded_audio_container(path),
                    expected,
                )

    def test_upload_transcode_is_mp3_128k_without_source_metadata(self):
        commands = []
        with tempfile.TemporaryDirectory() as workdir:
            source_path = os.path.join(workdir, "source.wav")
            output_path = os.path.join(workdir, "output.mp3")

            def fake_run(command, **_kwargs):
                commands.append(command)
                with open(output_path, "wb") as output:
                    output.write(b"ID3-transcoded")
                return Mock(returncode=0)

            with patch.object(self.worker.subprocess, "run", side_effect=fake_run):
                self.worker.transcode_uploaded_audio(source_path, output_path)

        self.assertEqual(len(commands), 1)
        self.assertIn("128k", commands[0])
        self.assertIn("-map_metadata", commands[0])
        self.assertEqual(commands[0][-1], output_path)

    def test_upload_reuses_hash_links_idempotently_and_cleans_staging(self):
        task = {
            "task_id": "task-upload",
            "session_id": "session-upload",
            "playlist_id": "playlist-upload",
            "staging_object_key": "music-uploads/staging/source.m4a",
            "declared_size_bytes": 12,
            "position": 4,
            "title": "Faixa autorizada",
            "artists": ["Artista"],
        }
        tracks = MagicMock()
        tracks.select.return_value = tracks
        tracks.eq.return_value = tracks
        tracks.limit.return_value = tracks
        tracks.execute.return_value = Mock(
            data=[{"id": "track-existing", "storage_object_key": "tracks/existing.mp3"}]
        )
        def table(_name):
            return tracks

        def download_file(_bucket, _key, path):
            with open(path, "wb") as source:
                source.write(b"\x00\x00\x00\x18ftypM4A ")

        def transcode(_source, output):
            with open(output, "wb") as encoded:
                encoded.write(b"ID3-encoded")

        with (
            patch.object(self.worker, "acquire_music_operation_slot", return_value="lease-upload"),
            patch.object(self.worker, "release_music_operation_slot") as release,
            patch.object(self.worker.s3, "download_file", side_effect=download_file),
            patch.object(self.worker.s3, "delete_object") as delete_object,
            patch.object(self.worker, "uploaded_audio_duration_seconds", return_value=180),
            patch.object(self.worker, "transcode_uploaded_audio", side_effect=transcode),
            patch.object(self.worker, "sha256_of", return_value="a" * 64),
            patch.object(self.worker.supabase, "table", side_effect=table),
            patch.object(self.worker, "attach_music_upload_track") as attach,
            patch.object(self.worker, "finish_music_upload_task", return_value={"terminal": True}) as finish,
        ):
            self.worker.process_music_upload_task(task)

        tracks_upserts = tracks.upsert.call_count
        self.assertEqual(tracks_upserts, 0)
        attach.assert_called_once_with("task-upload", "track-existing")
        finish.assert_called_once_with(
            "task-upload",
            True,
            track_id="track-existing",
            content_sha256="a" * 64,
        )
        delete_object.assert_called_once_with(
            Bucket=self.worker.R2_BUCKET,
            Key="music-uploads/staging/source.m4a",
        )
        release.assert_called_once_with("lease-upload")

    def test_upload_failure_only_cleans_staging_after_terminal_outcome(self):
        task = {
            "task_id": "task-upload",
            "playlist_id": "playlist-upload",
            "staging_object_key": "music-uploads/staging/source.wav",
            "declared_size_bytes": 1024,
        }
        for terminal in (False, True):
            with (
                self.subTest(terminal=terminal),
                patch.object(self.worker, "acquire_music_operation_slot", return_value="lease-upload"),
                patch.object(self.worker, "release_music_operation_slot") as release,
                patch.object(self.worker.s3, "download_file", side_effect=RuntimeError("R2_ERROR")),
                patch.object(self.worker.s3, "delete_object") as delete_object,
                patch.object(
                    self.worker,
                    "finish_music_upload_task",
                    return_value={"terminal": terminal},
                ) as finish,
            ):
                self.worker.process_music_upload_task(task)

            finish.assert_called_once()
            self.assertEqual(delete_object.call_count, 1 if terminal else 0)
            release.assert_called_once_with("lease-upload")

    def test_expired_upload_cleanup_is_confirmed_and_retried_safely(self):
        session = {
            "session_id": "session-expired",
            "staging_object_key": "music-uploads/staging/expired.wav",
        }
        with (
            patch.object(self.worker.s3, "delete_object") as delete_object,
            patch.object(self.worker, "complete_expired_music_upload_cleanup") as complete,
        ):
            self.worker.process_expired_music_upload_cleanup(session)
        delete_object.assert_called_once_with(
            Bucket=self.worker.R2_BUCKET,
            Key="music-uploads/staging/expired.wav",
        )
        complete.assert_called_once_with("session-expired", True)

        with (
            patch.object(self.worker.s3, "delete_object", side_effect=RuntimeError("R2 unavailable")),
            patch.object(self.worker, "complete_expired_music_upload_cleanup") as complete,
        ):
            with self.assertRaisesRegex(RuntimeError, "R2 unavailable"):
                self.worker.process_expired_music_upload_cleanup(session)
        complete.assert_called_once_with("session-expired", False, "R2 unavailable")

    def test_authorized_canary_must_download_before_shared_resume(self):
        def rpc(name, _params):
            call = MagicMock()
            call.execute.return_value = Mock(
                data={"claimed": True, "probe_playlist_id": "playlist-canary"}
                if name == "worker_claim_youtube_probe"
                else {"healthy": True}
            )
            return call

        def download_canary(_entry, workdir, **_kwargs):
            path = os.path.join(workdir, "canary.mp3")
            with open(path, "wb") as output:
                output.write(b"ID3-canary")
            return path

        with (
            patch.object(self.worker, "YOUTUBE_CANARY_URL", "https://www.youtube.com/watch?v=abcdefghijk"),
            patch.object(self.worker.supabase, "rpc", side_effect=rpc) as rpc_mock,
            patch.object(self.worker, "_extract_single_video", return_value={"id": "abcdefghijk"}),
            patch.object(self.worker, "download_one", side_effect=download_canary) as download_one,
            patch.object(self.worker, "acquire_music_operation_slot", return_value="lease-canary") as acquire,
            patch.object(self.worker, "release_music_operation_slot") as release,
            patch.object(self.worker, "close_youtube_circuit") as close_circuit,
        ):
            self.assertTrue(self.worker.maybe_probe_youtube_provider())

        download_one.assert_called_once()
        acquire.assert_called_once()
        self.assertEqual(acquire.call_args.args[:2], ("youtube", "playlist-canary"))
        release.assert_called_once_with("lease-canary")
        self.assertEqual(
            [call.args[0] for call in rpc_mock.call_args_list],
            ["worker_claim_youtube_probe", "worker_record_youtube_probe_result"],
        )
        self.assertTrue(rpc_mock.call_args_list[-1].args[1]["p_success"])
        close_circuit.assert_called_once()

    def test_spotify_transient_failures_wait_one_then_five_minutes(self):
        for attempts, expected_delay in ((1, 60), (2, 300)):
            with (
                self.subTest(attempts=attempts),
                patch.object(self.worker, "update_job") as update_job,
                patch.object(
                    self.worker,
                    "datetime",
                    wraps=self.worker.datetime,
                ),
            ):
                before = self.worker.datetime.now(self.worker.timezone.utc)
                self.worker.fail_job(
                    {
                        "id": "job-spotify",
                        "playlist_id": "playlist-1",
                        "attempts": attempts,
                    },
                    RuntimeError("SPOTIFY_METADATA_ERROR"),
                )
                after = self.worker.datetime.now(self.worker.timezone.utc)

            fields = update_job.call_args.kwargs
            scheduled = self.worker.datetime.fromisoformat(fields["next_attempt_at"])
            self.assertEqual(fields["status"], "queued")
            self.assertGreaterEqual(
                (scheduled - before).total_seconds(),
                expected_delay - 1,
            )
            self.assertLessEqual(
                (scheduled - after).total_seconds(),
                expected_delay + 1,
            )

    def test_importer_transport_failure_uses_delayed_job_retry(self):
        with patch.object(self.worker, "update_job") as update_job:
            self.worker.fail_job(
                {
                    "id": "job-importer",
                    "playlist_id": "playlist-1",
                    "attempts": 1,
                },
                RuntimeError("IMPORTER_TRANSIENT: connection reset"),
            )

        fields = update_job.call_args.kwargs
        self.assertEqual(fields["status"], "queued")
        self.assertNotIn("attempts", fields)
        self.assertEqual(fields["error_code"], "IMPORTER_TRANSIENT")
        self.assertIn("next_attempt_at", fields)

    def test_third_spotify_failure_is_terminal(self):
        with patch.object(self.worker, "update_job") as update_job:
            self.worker.fail_job(
                {
                    "id": "job-spotify",
                    "playlist_id": "playlist-1",
                    "attempts": 3,
                },
                RuntimeError("SPOTIFY_RESOLVER_UNAVAILABLE"),
            )

        fields = update_job.call_args.kwargs
        self.assertEqual(fields["status"], "error")
        self.assertEqual(fields["error_code"], "SPOTIFY_RESOLVER_UNAVAILABLE")

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

    def test_transport_exception_type_is_classified_as_transient(self):
        class RemoteProtocolError(Exception):
            pass

        code, message = self.worker.classify_error(
            RemoteProtocolError("peer vanished without response")
        )
        self.assertEqual(code, "IMPORTER_TRANSIENT")
        self.assertIn("tentará novamente", message)

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

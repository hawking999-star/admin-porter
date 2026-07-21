import json
import os
import sys
import unittest
from unittest.mock import Mock, patch

sys.path.insert(0, os.path.dirname(os.path.dirname(__file__)))

from music_source_resolver import SpotDlSpotifyResolver, classify_spotify_match, resolver_from_environment


class SpotifyResolverTests(unittest.TestCase):
    def test_spotdl_returns_normalized_tracks_without_downloading_audio(self):
        resolver = SpotDlSpotifyResolver(max_tracks=170, timeout_seconds=10)

        def fake_run(command):
            save_path = command[command.index("--save-file") + 1]
            self.assertIn("save", command)
            self.assertIn("--preload", command)
            self.assertNotIn("download", command)
            with open(save_path, "w", encoding="utf-8") as handle:
                json.dump(
                    [
                        {
                            "song_id": "5uRT0Cra9A96TnoWkCyhFA",
                            "url": "https://open.spotify.com/track/5uRT0Cra9A96TnoWkCyhFA?si=test",
                            "name": "Faixa teste",
                            "artists": ["Artista teste"],
                            "album_name": "Album teste",
                            "duration": 201.5,
                            "download_url": "https://www.youtube.com/watch?v=hQf7MeBTR2E",
                        },
                        {
                            "song_id": "3QaPy1KgI7nu9FJEQUgn6h",
                            "name": "Sem correspondencia",
                            "duration": 120,
                        },
                    ],
                    handle,
                )
            return ""

        with patch.object(resolver, "_run", side_effect=fake_run):
            collection = resolver.resolve("https://open.spotify.com/playlist/5uRT0Cra9A96TnoWkCyhFA")

        self.assertEqual(collection.source, "spotify")
        self.assertEqual(len(collection.tracks), 2)
        self.assertEqual(collection.tracks[0].youtubeVideoId, "hQf7MeBTR2E")
        self.assertEqual(
            collection.tracks[0].youtubeUrl,
            "https://www.youtube.com/watch?v=hQf7MeBTR2E",
        )
        self.assertEqual(collection.tracks[0].durationMs, 201500)
        self.assertEqual(collection.tracks[0].matchStatus, "resolved")
        self.assertEqual(collection.tracks[1].matchStatus, "not_found")

    def test_factory_uses_http_only_when_configured(self):
        with patch.dict(os.environ, {"SPOTIFY_RESOLVER_URL": "", "SPOTIFY_RESOLVER_TOKEN": ""}):
            self.assertEqual(
                type(resolver_from_environment(max_tracks=170, timeout_seconds=10)).__name__,
                "SpotDlSpotifyResolver",
            )

    def test_low_confidence_alone_does_not_reject_a_correct_match(self):
        status, reason = classify_spotify_match(
            {"match_confidence": 0.77, "youtube_title": "Faixa Teste", "youtube_duration": 205},
            title="Faixa Teste",
            artists=["Artista Teste"],
            duration_ms=201500,
            video_id="hQf7MeBTR2E",
        )
        self.assertEqual(status, "resolved")
        self.assertIsNone(reason)

    def test_confidence_below_85_never_triggers_review_by_itself(self):
        for confidence in (0, 0.5, 0.77, 77, 84):
            with self.subTest(confidence=confidence):
                status, reason = classify_spotify_match(
                    {
                        "match_confidence": confidence,
                        "youtube_title": "Faixa Teste",
                        "youtube_artist": "Artista Teste",
                        "youtube_duration": 204,
                    },
                    title="Faixa Teste",
                    artists=["Artista Teste"],
                    duration_ms=201500,
                    video_id="hQf7MeBTR2E",
                )
                self.assertEqual(status, "resolved")
                self.assertIsNone(reason)

    def test_version_terms_and_large_duration_difference_recommend_review(self):
        status, reason = classify_spotify_match(
            {"youtube_title": "Faixa Teste (Live)", "youtube_duration": 240},
            title="Faixa Teste",
            artists=["Artista Teste"],
            duration_ms=201500,
            video_id="hQf7MeBTR2E",
        )
        self.assertEqual(status, "review_recommended")
        self.assertIn("versão diferente: live", reason or "")

    def test_small_duration_difference_is_accepted(self):
        status, _ = classify_spotify_match(
            {"youtube_title": "Faixa Teste", "youtube_duration": 207},
            title="Faixa Teste",
            artists=["Artista Teste"],
            duration_ms=201500,
            video_id="hQf7MeBTR2E",
        )
        self.assertEqual(status, "resolved")

    def test_spotdl_unavailable_link_has_stable_internal_code(self):
        resolver = SpotDlSpotifyResolver(max_tracks=170, timeout_seconds=10)
        process = Mock()
        process.communicate.return_value = ("Playlist is unavailable", None)
        process.returncode = 1
        with patch("music_source_resolver.subprocess.Popen", return_value=process):
            with self.assertRaisesRegex(RuntimeError, "^SPOTIFY_LINK_UNAVAILABLE$"):
                resolver._run(["python", "-m", "spotdl", "save", "safe-url"])

    def test_spotdl_generic_failure_does_not_expose_command_arguments(self):
        resolver = SpotDlSpotifyResolver(max_tracks=170, timeout_seconds=10)
        process = Mock()
        process.communicate.return_value = ("resolver internal failure", None)
        process.returncode = 2
        secret_argument = "server-token-value"
        with patch("music_source_resolver.subprocess.Popen", return_value=process):
            with self.assertRaisesRegex(RuntimeError, "SPOTIFY_METADATA_ERROR") as raised:
                resolver._run(["python", "--token", secret_argument])
        self.assertNotIn(secret_argument, str(raised.exception))


if __name__ == "__main__":
    unittest.main()

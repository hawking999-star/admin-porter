import os
import sys
import time
import unittest
from unittest.mock import Mock, patch

sys.path.insert(0, os.path.dirname(os.path.dirname(__file__)))

from music_source_resolver import (
    SpotipyFreeMetadataResolver,
    classify_spotify_match,
    resolver_from_environment,
)


def spotify_track(index: int) -> dict:
    spotify_id = f"{index:022d}"
    return {
        "id": spotify_id,
        "name": f"Faixa {index}",
        "duration_ms": 180_000 + index,
        "artists": [{"name": f"Artista {index}"}],
        "album": {"name": "Álbum teste"},
        "external_urls": {
            "spotify": f"https://open.spotify.com/track/{spotify_id}",
        },
    }


class SpotifyResolverTests(unittest.TestCase):
    def setUp(self):
        self.resolver = SpotipyFreeMetadataResolver(
            max_tracks=170,
            timeout_seconds=10,
        )

    def test_playlist_reads_all_eleven_tracks_as_metadata_only(self):
        client = Mock(spec=["playlist_items"])
        client.playlist_items.return_value = {
            "items": [{"track": spotify_track(index)} for index in range(1, 12)]
        }

        with patch.object(self.resolver, "_client", return_value=client):
            collection = self.resolver.resolve(
                "https://open.spotify.com/playlist/0AS2QQdymdLg7BHeCs0ech"
            )

        self.assertEqual(collection.source, "spotify")
        self.assertEqual(len(collection.tracks), 11)
        self.assertEqual(collection.tracks[0].title, "Faixa 1")
        self.assertEqual(collection.tracks[0].durationMs, 180001)
        self.assertEqual(collection.tracks[0].matchStatus, "resolving")
        self.assertTrue(all(track.youtubeVideoId is None for track in collection.tracks))
        client.playlist_items.assert_called_once()

    def test_album_and_single_track_are_supported(self):
        album_client = Mock(spec=["album_tracks"])
        album_client.album_tracks.return_value = {
            "items": [spotify_track(1), spotify_track(2)]
        }
        with patch.object(self.resolver, "_client", return_value=album_client):
            album = self.resolver.resolve(
                "https://open.spotify.com/album/0000000000000000000001"
            )
        self.assertEqual([track.position for track in album.tracks], [1, 2])

        track_client = Mock(spec=["track"])
        track_client.track.return_value = spotify_track(3)
        with patch.object(self.resolver, "_client", return_value=track_client):
            track = self.resolver.resolve(
                "https://open.spotify.com/track/0000000000000000000003"
            )
        self.assertEqual(len(track.tracks), 1)
        self.assertEqual(track.tracks[0].spotifyTrackId, "0000000000000000000003")

    def test_factory_uses_lightweight_client_when_http_is_not_configured(self):
        with patch.dict(
            os.environ,
            {"SPOTIFY_RESOLVER_URL": "", "SPOTIFY_RESOLVER_TOKEN": ""},
        ):
            resolver = resolver_from_environment(max_tracks=170, timeout_seconds=10)
        self.assertIsInstance(resolver, SpotipyFreeMetadataResolver)

    def test_unavailable_link_has_stable_internal_code(self):
        client = Mock(spec=["playlist_items"])
        client.playlist_items.side_effect = Exception("playlist is unavailable")
        with patch.object(self.resolver, "_client", return_value=client):
            with self.assertRaisesRegex(RuntimeError, "^SPOTIFY_LINK_UNAVAILABLE$"):
                self.resolver.resolve(
                    "https://open.spotify.com/playlist/0AS2QQdymdLg7BHeCs0ech"
                )

    def test_generic_failure_does_not_expose_client_details(self):
        client = Mock(spec=["playlist_items"])
        client.playlist_items.side_effect = Exception("secret internal response")
        with patch.object(self.resolver, "_client", return_value=client):
            with self.assertRaisesRegex(RuntimeError, "SPOTIFY_METADATA_ERROR") as raised:
                self.resolver.resolve(
                    "https://open.spotify.com/playlist/0AS2QQdymdLg7BHeCs0ech"
                )
        self.assertNotIn("secret internal response", str(raised.exception))

    def test_metadata_timeout_has_stable_code(self):
        resolver = SpotipyFreeMetadataResolver(max_tracks=170, timeout_seconds=0.01)
        client = Mock(spec=["playlist_items"])
        client.playlist_items.side_effect = lambda _url: time.sleep(0.05)
        with patch.object(resolver, "_client", return_value=client):
            with self.assertRaisesRegex(TimeoutError, "SPOTIFY_RESOLVE_TIMEOUT"):
                resolver.resolve(
                    "https://open.spotify.com/playlist/0AS2QQdymdLg7BHeCs0ech"
                )

    def test_low_confidence_alone_does_not_reject_a_correct_match(self):
        status, reason = classify_spotify_match(
            {
                "match_confidence": 0.77,
                "youtube_title": "Faixa Teste",
                "youtube_duration": 205,
            },
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


if __name__ == "__main__":
    unittest.main()

import os
import sys
import unittest
from unittest.mock import patch

sys.path.insert(0, os.path.dirname(os.path.dirname(__file__)))

from music_security import (
    parse_supported_music_url,
    redact_sensitive,
    require_youtube_video_url,
    sanitize_string_list,
    sanitize_text,
    validate_server_endpoint,
)


class MusicSecurityTests(unittest.TestCase):
    def test_source_allowlist_normalizes_supported_urls(self):
        spotify = parse_supported_music_url(
            "https://open.spotify.com/playlist/5uRT0Cra9A96TnoWkCyhFA?si=secret"
        )
        youtube = require_youtube_video_url(
            "https://youtu.be/hQf7MeBTR2E?feature=shared"
        )
        self.assertEqual(
            spotify.normalized_url,
            "https://open.spotify.com/playlist/5uRT0Cra9A96TnoWkCyhFA",
        )
        self.assertEqual(
            youtube.normalized_url,
            "https://www.youtube.com/watch?v=hQf7MeBTR2E",
        )

    def test_rejects_arbitrary_hosts_credentials_ports_and_non_video_replacement(self):
        invalid = (
            "http://127.0.0.1/internal",
            "https://example.com/spotify/playlist/id",
            "https://user:pass@open.spotify.com/playlist/5uRT0Cra9A96TnoWkCyhFA",
            "https://open.spotify.com:8443/playlist/5uRT0Cra9A96TnoWkCyhFA",
        )
        for value in invalid:
            with self.subTest(value=value), self.assertRaises(ValueError):
                parse_supported_music_url(value)
        with self.assertRaises(ValueError):
            require_youtube_video_url(
                "https://www.youtube.com/playlist?list=PL1234567890"
            )

    def test_resolver_endpoint_blocks_private_networks_and_redirect_surface(self):
        private_answer = [
            (2, 1, 6, "", ("127.0.0.1", 443)),
        ]
        with patch("music_security.socket.getaddrinfo", return_value=private_answer):
            with self.assertRaises(ValueError):
                validate_server_endpoint("https://resolver.example")
            self.assertEqual(
                validate_server_endpoint("https://resolver.example", allow_private=True),
                "https://resolver.example",
            )
        with self.assertRaises(ValueError):
            validate_server_endpoint("https://resolver.example/path?next=http://127.0.0.1")

    def test_metadata_and_logs_are_sanitized(self):
        self.assertEqual(sanitize_text("Faixa\x00\n teste"), "Faixa teste")
        self.assertEqual(sanitize_string_list([" Artista ", "", "B\x7f"]), ["Artista", "B"])
        secret = "sb_secret_super_sensitive_value"
        redacted = redact_sensitive(f"Authorization: Bearer token123 {secret}", (secret,))
        self.assertNotIn(secret, redacted)
        self.assertNotIn("token123", redacted)
        self.assertIn("[REDACTED]", redacted)


if __name__ == "__main__":
    unittest.main()

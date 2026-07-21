import assert from "node:assert/strict";
import test from "node:test";
import { parseMusicUrl } from "../src/lib/music-url.ts";

test("normaliza links aceitos do Spotify", () => {
  assert.deepEqual(parseMusicUrl("https://open.spotify.com/track/3QaPy1KgI7nu9FJEQUgn6h?si=abc"), {
    source: "spotify",
    resourceType: "track",
    resourceId: "3QaPy1KgI7nu9FJEQUgn6h",
    originalUrl: "https://open.spotify.com/track/3QaPy1KgI7nu9FJEQUgn6h?si=abc",
    normalizedUrl: "https://open.spotify.com/track/3QaPy1KgI7nu9FJEQUgn6h",
  });
  assert.equal(
    parseMusicUrl("https://open.spotify.com/intl-pt/album/4yP0hdKOZPNshxUOjY0cZj?utm_source=x")?.normalizedUrl,
    "https://open.spotify.com/album/4yP0hdKOZPNshxUOjY0cZj",
  );
  assert.equal(
    parseMusicUrl("https://open.spotify.com/playlist/5uRT0Cra9A96TnoWkCyhFA?si=c3cba1b3e0674ea5")
      ?.normalizedUrl,
    "https://open.spotify.com/playlist/5uRT0Cra9A96TnoWkCyhFA",
  );
});

test("normaliza vídeos e playlists do YouTube", () => {
  assert.equal(
    parseMusicUrl("https://youtu.be/hQf7MeBTR2E?si=abc")?.normalizedUrl,
    "https://www.youtube.com/watch?v=hQf7MeBTR2E",
  );
  assert.equal(
    parseMusicUrl("https://music.youtube.com/watch?v=hQf7MeBTR2E&feature=share")?.resourceType,
    "video",
  );
  assert.equal(
    parseMusicUrl("https://www.youtube.com/watch?v=hQf7MeBTR2E&list=PL1234567890&index=2")
      ?.normalizedUrl,
    "https://www.youtube.com/playlist?list=PL1234567890",
  );
});

test("rejeita recursos e domínios não suportados", () => {
  const invalid = [
    "spotify",
    "https://spotify.com/track/3QaPy1KgI7nu9FJEQUgn6h",
    "https://open.spotify.com/episode/3QaPy1KgI7nu9FJEQUgn6h",
    "https://open.spotify.com/show/3QaPy1KgI7nu9FJEQUgn6h",
    "https://open.spotify.com/artist/3QaPy1KgI7nu9FJEQUgn6h",
    "https://open.spotify.com/user/3QaPy1KgI7nu9FJEQUgn6h",
    "https://evil.example/spotify/playlist/5uRT0Cra9A96TnoWkCyhFA",
    "https://m.youtube.com/watch?v=hQf7MeBTR2E",
    "https://www.youtube.com/channel/abc",
    "https://www.youtube.com/playlist?list=RD1234567890",
    "not a url",
  ];

  for (const value of invalid) assert.equal(parseMusicUrl(value), null, value);
});

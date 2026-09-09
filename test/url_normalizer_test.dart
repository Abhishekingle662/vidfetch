import 'package:flutter_test/flutter_test.dart';
import 'package:vidfetch/utils/url_normalizer.dart';

void main() {
  group('Instagram highlight URLs', () {
    test('strips share query from /stories/highlights/ links', () {
      expect(
        normalizeDownloadInput(
          'https://www.instagram.com/stories/highlights/18090946048123978/?igsh=abc',
        ),
        'https://www.instagram.com/stories/highlights/18090946048123978/',
      );
    });

    test('rewrites /s/ highlight share tokens', () {
      expect(
        normalizeDownloadInput(
          'https://www.instagram.com/s/aGlnaGxpZ2h0OjE4MDkwOTQ2MDQ4MTIzOTc4',
        ),
        'https://www.instagram.com/stories/highlights/18090946048123978/',
      );
    });

    test('rewrites /s/ share links that include story_media_id', () {
      expect(
        normalizeDownloadInput(
          'https://www.instagram.com/s/aGlnaGxpZ2h0OjE4MDkwOTQ2MDQ4MTIzOTc4'
          '?story_media_id=3570766765028588805&igsh=xyz',
        ),
        'https://www.instagram.com/stories/highlights/18090946048123978/',
      );
    });

    test('rewrites bare-host /s/ highlight shares', () {
      expect(
        normalizeDownloadInput(
          'instagram.com/s/aGlnaGxpZ2h0OjE4MDkwOTQ2MDQ4MTIzOTc4',
        ),
        'https://www.instagram.com/stories/highlights/18090946048123978/',
      );
    });

    test('classifies highlight and story URLs', () {
      expect(
        isInstagramStoryOrHighlightInput(
          'https://www.instagram.com/stories/highlights/18090946048123978/',
        ),
        isTrue,
      );
      expect(
        isInstagramStoryOrHighlightInput(
          'https://www.instagram.com/s/aGlnaGxpZ2h0OjE4MDkwOTQ2MDQ4MTIzOTc4',
        ),
        isTrue,
      );
      expect(
        isInstagramStoryOrHighlightInput(
          'https://www.instagram.com/stories/someuser/3570766765028588805/',
        ),
        isTrue,
      );
      expect(
        isInstagramProfileInput(
          'https://www.instagram.com/stories/highlights/18090946048123978/',
        ),
        isFalse,
      );
      expect(isInstagramProfileInput('@someuser'), isTrue);
      expect(isInstagramStoryOrHighlightInput('@someuser'), isFalse);
    });

    test('strips igsh from a regular post without leaving ?#', () {
      expect(
        normalizeDownloadInput(
          'https://www.instagram.com/p/aye83DjauH/?igsh=abc#one',
        ),
        'https://www.instagram.com/p/aye83DjauH/',
      );
    });

    test('http and Instagram rules still apply alongside magnets', () {
      expect(
        normalizeDownloadInput('https://www.youtube.com/watch?v=dQw4w9wgGcI'),
        'https://www.youtube.com/watch?v=dQw4w9wgGcI',
      );
      expect(normalizeDownloadInput('@someuser'), 'https://www.instagram.com/someuser/');
      expect(isMagnetUri('https://www.instagram.com/someuser/'), isFalse);
    });

    test('decodeInstagramHighlightShareId rejects non-highlight payloads', () {
      expect(decodeInstagramHighlightShareId('not-valid-base64!!!'), isNull);
      expect(
        decodeInstagramHighlightShareId(
          // "hello" in base64 — not a highlight token
          'aGVsbG8=',
        ),
        isNull,
      );
    });
  });

  group('magnet URIs', () {
    const hex = 'C3E67041ECF73C38B95975A80C26009B170221D8';
    const hexLower = 'c3e67041ecf73c38b95975a80c26009b170221d8';
    const base32 = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ234567';

    test('accepts hex btih', () {
      final magnet = 'magnet:?xt=urn:btih:$hex';
      expect(normalizeDownloadInput(magnet), magnet);
      expect(isMagnetUri(magnet), isTrue);
      expect(looksLikeMagnetInput(magnet), isTrue);
    });

    test('accepts lowercase hex btih', () {
      final magnet = 'magnet:?xt=urn:btih:$hexLower';
      expect(normalizeDownloadInput(magnet), magnet);
    });

    test('accepts base32 btih', () {
      final magnet = 'magnet:?xt=urn:btih:$base32';
      expect(normalizeDownloadInput(magnet), magnet);
      expect(isMagnetUri(magnet), isTrue);
    });

    test('accepts magnet with display name and trackers', () {
      final magnet =
          'magnet:?xt=urn:btih:$hex&dn=Example+Name&tr=udp://tracker.example:80';
      expect(normalizeDownloadInput(magnet), magnet);
      expect(magnetDisplayName(magnet), 'Example Name');
    });

    test('accepts uppercase MAGNET scheme', () {
      final magnet = 'MAGNET:?xt=urn:btih:$hex';
      expect(normalizeDownloadInput(magnet), magnet);
      expect(looksLikeMagnetInput(magnet), isTrue);
    });

    test('rejects magnet without xt', () {
      expect(normalizeDownloadInput('magnet:?dn=only-a-name'), isNull);
      expect(isMagnetUri('magnet:?dn=only-a-name'), isFalse);
      expect(looksLikeMagnetInput('magnet:?dn=only-a-name'), isTrue);
    });

    test('rejects short or empty infohash', () {
      expect(normalizeDownloadInput('magnet:?xt=urn:btih:'), isNull);
      expect(normalizeDownloadInput('magnet:?xt=urn:btih:abcd'), isNull);
      expect(
        normalizeDownloadInput('magnet:?xt=urn:btih:${hex.substring(0, 39)}'),
        isNull,
      );
    });

    test('rejects non-btih magnet payloads', () {
      expect(normalizeDownloadInput('magnet:?xt=urn:ed2k:abc'), isNull);
      expect(
        normalizeDownloadInput(
          'magnet:?xt=urn:btmh:1220${'a' * 64}',
        ),
        isNull,
      );
    });

    test('rejects magnet-looking http URLs', () {
      expect(
        normalizeDownloadInput('http://example.com/magnet:?xt=urn:btih:$hex'),
        'http://example.com/magnet:?xt=urn:btih:$hex',
      );
      expect(
        isMagnetUri('http://example.com/magnet:?xt=urn:btih:$hex'),
        isFalse,
      );
    });
  });
}

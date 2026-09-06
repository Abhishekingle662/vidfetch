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
}

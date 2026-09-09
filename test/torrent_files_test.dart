import 'package:flutter_test/flutter_test.dart';
import 'package:vidfetch/utils/torrent_files.dart';

void main() {
  group('magnetHasTrackers', () {
    const hash = 'C3E67041ECF73C38B95975A80C26009B170221D8';

    test('false when magnet has only xt', () {
      expect(magnetHasTrackers('magnet:?xt=urn:btih:$hash'), isFalse);
    });

    test('true when magnet has tr', () {
      expect(
        magnetHasTrackers(
          'magnet:?xt=urn:btih:$hash&tr=udp://tracker.example:80',
        ),
        isTrue,
      );
    });

    test('true when tracker is listed as tr.1', () {
      expect(
        magnetHasTrackers(
          'magnet:?xt=urn:btih:$hash&tr.1=http://tracker.example/announce',
        ),
        isTrue,
      );
    });
  });

  group('pickPrimaryTorrentFile', () {
    test('returns the only file', () {
      const file = TorrentFileEntry(path: 'a.bin', size: 10);
      expect(pickPrimaryTorrentFile([file]), file);
    });

    test('prefers the largest video', () {
      final picked = pickPrimaryTorrentFile(const [
        TorrentFileEntry(path: 'folder/sample.nfo', size: 200),
        TorrentFileEntry(path: 'folder/clip.mp4', size: 500),
        TorrentFileEntry(path: 'folder/movie.mkv', size: 900),
      ]);
      expect(picked?.path, 'folder/movie.mkv');
    });

    test('falls back to the largest file when there is no video', () {
      final picked = pickPrimaryTorrentFile(const [
        TorrentFileEntry(path: 'a.bin', size: 10),
        TorrentFileEntry(path: 'b.bin', size: 30),
      ]);
      expect(picked?.path, 'b.bin');
    });

    test('detects announce in torrent bytes', () {
      expect(torrentBytesHaveAnnounce('8:announce'.codeUnits), isTrue);
      expect(torrentBytesHaveAnnounce('4:infod6:lengthi1e'.codeUnits), isFalse);
    });

    test('ignores empty and zero-length files', () {
      expect(
        pickPrimaryTorrentFile(const [
          TorrentFileEntry(path: '', size: 10),
          TorrentFileEntry(path: 'a.bin', size: 0),
        ]),
        isNull,
      );
    });
  });
}

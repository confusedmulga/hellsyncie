import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// An in-memory Google Drive v3 server behind an [http.Client], speaking the
/// REST shapes `package:googleapis` really sends: `files.list` with `q` and
/// paging, `alt=media` downloads, multipart create / update, delete.
///
/// It reproduces the Drive behaviour the backend must survive, each drawn from
/// a seeded [Random] so runs replay:
///
///  - names are NOT unique; nothing stops two files sharing one;
///  - [queryLag]: a newly created file stays invisible to `files.list` for
///    [lagRequests] requests (Drive's eventually consistent search);
///  - [failBefore]: a request fails with 500 and changes nothing;
///  - [loseResponse]: a create / update / delete is applied, then the response
///    is lost (503) — the classic source of duplicate creates.
///
/// List requests fail only when [failLists] is set: a failed list fails the
/// whole sync round by design, which the fuzzer would report as a crash.
///
/// Anything outside `appDataFolder`, or any query it does not understand, is a
/// 400 — the fake fails loudly rather than guessing.
class FakeDrive {
  FakeDrive({
    Random? rng,
    this.failBefore = 0,
    this.loseResponse = 0,
    this.queryLag = 0,
    this.lagRequests = 3,
  }) : _rng = rng ?? Random(0);

  final Random _rng;
  double failBefore;
  double loseResponse;
  double queryLag;
  int lagRequests;

  /// Fail the next N list requests with 500.
  int failLists = 0;

  /// How often each fault actually fired, plus duplicate-name creates.
  final Map<String, int> injected = <String, int>{};

  final Map<String, FakeFile> files = <String, FakeFile>{};
  int _requests = 0;
  int _ids = 0;
  int _clock = 0;

  late final http.Client client = MockClient(_handle);

  /// Files named [name], in creation order.
  List<FakeFile> named(String name) =>
      files.values.where((f) => f.name == name).toList();

  /// Plant a file directly (bypassing faults), e.g. a leftover duplicate.
  FakeFile plant(String name, List<int> bytes) {
    final f = FakeFile(_newId(), name, Uint8List.fromList(bytes), ++_clock);
    files[f.id] = f;
    return f;
  }

  bool _dice(double p) => p > 0 && _rng.nextDouble() < p;

  bool _fault(String kind, double p) {
    if (!_dice(p)) return false;
    injected[kind] = (injected[kind] ?? 0) + 1;
    return true;
  }

  String _newId() => 'f${(++_ids).toString().padLeft(6, '0')}';

  Future<http.Response> _handle(http.Request req) async {
    _requests++;
    final path = req.url.path;
    final params = req.url.queryParameters;

    if (req.method == 'GET' && path == '/drive/v3/files') {
      if (failLists > 0) {
        failLists--;
        return _error(500, 'backend error');
      }
      return _list(params);
    }
    if (_fault('failBefore', failBefore)) return _error(500, 'backend error');

    if (req.method == 'GET' && path == '/drive/v3/files/generateIds') {
      if (params['space'] != 'appDataFolder') {
        return _error(400, 'ids outside appDataFolder');
      }
      final n = int.parse(params['count'] ?? '10');
      return _json(<String, Object?>{
        'ids': <String>[for (var i = 0; i < n; i++) _newId()],
      });
    }
    final byId = RegExp(
      r'^/(upload/)?drive/v3/files/([^/]+)$',
    ).firstMatch(path);
    if (req.method == 'GET' && byId != null && byId[1] == null) {
      if (params['alt'] != 'media') return _error(400, 'only alt=media');
      final f = files[byId[2]];
      if (f == null) return _error(404, 'File not found: ${byId[2]}');
      return http.Response.bytes(
        f.bytes,
        200,
        headers: {'content-type': 'application/octet-stream'},
      );
    }
    if (req.method == 'POST' && path == '/upload/drive/v3/files') {
      final (meta, media) = _multipart(req);
      final parents = (meta['parents'] as List?)?.cast<String>();
      if (parents == null || !parents.contains('appDataFolder')) {
        return _error(400, 'create outside appDataFolder');
      }
      final id = meta['id'] as String? ?? _newId();
      if (files.containsKey(id)) {
        injected['idConflict'] = (injected['idConflict'] ?? 0) + 1;
        return _error(409, 'A file already exists with the provided ID.');
      }
      final f = FakeFile(id, meta['name'] as String, media, ++_clock)
        ..visibleAfter = _fault('queryLag', queryLag)
            ? _requests + lagRequests
            : 0;
      if (named(f.name).isNotEmpty) {
        injected['duplicateCreate'] = (injected['duplicateCreate'] ?? 0) + 1;
      }
      files[f.id] = f;
      return _maybeLost(_json(f.toJson()));
    }
    if (req.method == 'PATCH' && byId != null && byId[1] != null) {
      final f = files[byId[2]];
      if (f == null) return _error(404, 'File not found: ${byId[2]}');
      final (meta, media) = _multipart(req);
      if (meta.isNotEmpty) return _error(400, 'fake only updates content');
      f
        ..bytes = media
        ..modified = ++_clock;
      return _maybeLost(_json(f.toJson()));
    }
    if (req.method == 'DELETE' && byId != null && byId[1] == null) {
      if (files.remove(byId[2]) == null) {
        return _error(404, 'File not found: ${byId[2]}');
      }
      return _maybeLost(http.Response('', 204));
    }
    return _error(400, 'fake does not handle ${req.method} $path');
  }

  http.Response _maybeLost(http.Response ok) =>
      _fault('loseResponse', loseResponse) ? _error(503, 'response lost') : ok;

  http.Response _list(Map<String, String> params) {
    if (params['spaces'] != 'appDataFolder') {
      return _error(400, 'list outside appDataFolder');
    }
    final q = params['q'] ?? '';
    final String? name;
    if (q == 'trashed = false') {
      name = null;
    } else {
      final m = RegExp(
        r"^name = '((?:[^'\\]|\\.)*)' and trashed = false$",
      ).firstMatch(q);
      if (m == null) return _error(400, 'fake cannot parse q: $q');
      name = m[1]!.replaceAllMapped(RegExp(r'\\(.)'), (x) => x[1]!);
    }
    final hits =
        files.values
            .where((f) => f.visibleAfter <= _requests)
            .where((f) => name == null || f.name == name)
            .toList()
          ..sort((a, b) => a.id.compareTo(b.id));
    final size = int.parse(params['pageSize'] ?? '100');
    final from = int.parse(params['pageToken'] ?? '0');
    final page = hits.skip(from).take(size).toList();
    final next = from + size < hits.length ? '${from + size}' : null;
    return _json(<String, Object?>{
      'files': <Object?>[for (final f in page) f.toJson()],
      'nextPageToken': ?next,
    });
  }

  /// Parse googleapis' multipart/related body: a JSON part, then the media
  /// part, base64 encoded.
  (Map<String, dynamic>, Uint8List) _multipart(http.Request req) {
    if (req.url.queryParameters['uploadType'] != 'multipart') {
      throw StateError('fake expects multipart uploads');
    }
    final boundary = RegExp(
      r'boundary="?([^";]+)"?',
    ).firstMatch(req.headers['content-type']!)![1]!;
    final parts = req.body
        .split('--$boundary')
        .map((p) => p.trim())
        .where((p) => p.isNotEmpty && p != '--')
        .map((p) => p.substring(p.indexOf('\r\n\r\n') + 4).trim())
        .toList();
    return (
      jsonDecode(parts[0]) as Map<String, dynamic>,
      base64Decode(parts[1]),
    );
  }

  http.Response _json(Object body) => http.Response(
    jsonEncode(body),
    200,
    headers: {'content-type': 'application/json; charset=utf-8'},
  );

  http.Response _error(int code, String message) => http.Response(
    jsonEncode(<String, Object?>{
      'error': <String, Object?>{'code': code, 'message': message},
    }),
    code,
    headers: {'content-type': 'application/json; charset=utf-8'},
  );
}

class FakeFile {
  FakeFile(this.id, this.name, this.bytes, this.modified);

  final String id;
  final String name;
  Uint8List bytes;
  int modified;

  /// Request count after which `files.list` can see this file.
  int visibleAfter = 0;

  Map<String, Object?> toJson() => <String, Object?>{
    'id': id,
    'name': name,
    'size': '${bytes.length}',
    'modifiedTime': DateTime.utc(
      2026,
    ).add(Duration(milliseconds: modified)).toIso8601String(),
  };
}

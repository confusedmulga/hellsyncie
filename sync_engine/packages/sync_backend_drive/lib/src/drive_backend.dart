import 'dart:async';
import 'dart:typed_data';

import 'package:googleapis/drive/v3.dart' as drive;
import 'package:http/http.dart' as http;
import 'package:sync_engine/sync_engine.dart';

/// A [Backend] over Google Drive's `appDataFolder`: hidden, per-app storage in
/// the user's own Drive. Needs only the [scope] `drive.appdata` — no access to
/// the user's visible files.
///
/// The app supplies an authenticated [http.Client] (from `google_sign_in`, or
/// `googleapis_auth`); this class never sees credentials.
///
/// Drive is not a filesystem, and three differences shape this class:
///
///  - Names are not unique, and name queries are eventually consistent. A
///    create whose response is lost, retried while search cannot see it yet,
///    would make two files named `ops_a_3.bin`. So each name is created under
///    a file id reserved up front (`files.generateIds`) and remembered: a
///    retry re-creates under the SAME id, Drive answers 409, and the retry
///    becomes an update. Duplicates can still come from another process (an
///    app restart mid-retry); [upload] then rewrites the newest copy and
///    deletes the others it can see, and [download] reads the newest.
///  - A just-created file can be missing from [list] for a while. That is the
///    "stale listing" / "delayed visibility" the [Backend] contract allows.
///  - Every call is a network request that can fail. Nothing here retries: a
///    failed upload or download is retried by the sync client's next round, a
///    failed [list] fails that round.
///
/// Uploads are single-request (multipart), which Drive applies atomically: a
/// failed request leaves no partial content.
class DriveBackend implements Backend {
  DriveBackend(http.Client client, {this.pageSize = 1000})
    : _files = drive.DriveApi(client).files;

  /// The OAuth scope to request at sign-in.
  static const String scope = drive.DriveApi.driveAppdataScope;

  /// Files per `files.list` page (Drive caps it at 1000).
  final int pageSize;

  final drive.FilesResource _files;

  /// name -> the id its first create used, kept so retries reuse it.
  final Map<String, String> _createdAs = <String, String>{};

  /// Reserved ids not yet used, fetched in batches.
  final List<String> _spareIds = <String>[];
  static const int _idBatch = 100;

  static const String _space = 'appDataFolder';
  static const String _fields =
      'nextPageToken, files(id, name, size, '
      'modifiedTime)';

  @override
  Future<List<RemoteFile>> list() async => <RemoteFile>[
    for (final f in await _query('trashed = false'))
      RemoteFile(f.name!, int.tryParse(f.size ?? '') ?? 0),
  ];

  /// Throws if no file named [name] is visible.
  @override
  Future<Uint8List> download(String name) async {
    final copies = await _byName(name);
    if (copies.isEmpty) throw StateError('download: no such file: $name');
    final media =
        await _files.get(
              copies.first.id!,
              downloadOptions: drive.DownloadOptions.fullMedia,
            )
            as drive.Media;
    final bytes = BytesBuilder(copy: false);
    await media.stream.forEach(bytes.add);
    return bytes.takeBytes();
  }

  @override
  Future<void> upload(String name, Uint8List bytes) async {
    final copies = await _byName(name);
    // One Media per request: its stream can be listened to only once.
    drive.Media media() => drive.Media(
      Stream<List<int>>.value(bytes),
      bytes.length,
      contentType: 'application/octet-stream',
    );
    if (copies.isEmpty) {
      final id = _createdAs[name] ??= await _reserveId();
      try {
        await _files.create(
          drive.File(id: id, name: name, parents: <String>[_space]),
          uploadMedia: media(),
        );
      } on drive.DetailedApiRequestError catch (e) {
        if (e.status != 409) rethrow;
        // An earlier create under this id landed but search cannot see it
        // yet: overwrite it instead of making a second copy.
        await _files.update(drive.File(), id, uploadMedia: media());
      }
      return;
    }
    _createdAs.remove(name); // visible now; the lookup finds it from here on
    await _files.update(drive.File(), copies.first.id!, uploadMedia: media());
    for (final extra in copies.skip(1)) {
      await _deleteId(extra.id!);
    }
  }

  /// Deletes every visible copy of [name]. Idempotent.
  @override
  Future<void> delete(String name) async {
    for (final f in await _byName(name)) {
      await _deleteId(f.id!);
    }
  }

  /// Visible files named [name], newest first.
  Future<List<drive.File>> _byName(String name) async =>
      (await _query("name = '${_escape(name)}' and trashed = false"))
        ..sort(_newestFirst);

  Future<List<drive.File>> _query(String q) async {
    final out = <drive.File>[];
    String? token;
    do {
      final page = await _files.list(
        spaces: _space,
        q: q,
        pageSize: pageSize,
        pageToken: token,
        $fields: _fields,
      );
      out.addAll(page.files ?? const <drive.File>[]);
      token = page.nextPageToken;
    } while (token != null);
    return out;
  }

  Future<String> _reserveId() async {
    if (_spareIds.isEmpty) {
      final generated = await _files.generateIds(
        count: _idBatch,
        space: _space,
        type: 'files',
        $fields: 'ids',
      );
      _spareIds.addAll(generated.ids ?? const <String>[]);
      if (_spareIds.isEmpty) throw StateError('Drive generated no file ids');
    }
    return _spareIds.removeLast();
  }

  Future<void> _deleteId(String id) async {
    try {
      await _files.delete(id);
    } on drive.DetailedApiRequestError catch (e) {
      if (e.status != 404) rethrow; // already gone
    }
  }

  /// Newest modifiedTime first; ties broken by id so every device agrees.
  static int _newestFirst(drive.File a, drive.File b) {
    final ta = a.modifiedTime, tb = b.modifiedTime;
    if (ta != null && tb != null && ta != tb) return tb.compareTo(ta);
    return a.id!.compareTo(b.id!);
  }

  /// Escape for a Drive query string literal.
  static String _escape(String s) =>
      s.replaceAll(r'\', r'\\').replaceAll("'", r"\'");
}

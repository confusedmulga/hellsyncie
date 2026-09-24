import 'dart:io';
import 'dart:typed_data';

import 'package:sync_backend_fs/sync_backend_fs.dart';
import 'package:sync_engine/sync_engine.dart';
import 'package:test/test.dart';

void main() {
  late Directory tmp;
  late Directory root;
  late FsBackend backend;

  Uint8List b(String s) => Uint8List.fromList(s.codeUnits);

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('hsy_fs_');
    root = Directory('${tmp.path}${Platform.pathSeparator}store');
    backend = FsBackend(root);
  });

  tearDown(() async {
    if (await tmp.exists()) await tmp.delete(recursive: true);
  });

  test('list on a missing folder is empty, not an error', () async {
    expect(await backend.list(), isEmpty);
  });

  test('upload then list and download round-trip exact bytes', () async {
    await backend.upload('ops_d0_0.bin', b('hello'));
    final listing = await backend.list();
    expect(listing.map((f) => f.name), <String>['ops_d0_0.bin']);
    expect(listing.single.size, 5);
    expect(await backend.download('ops_d0_0.bin'), b('hello'));
  });

  test('re-upload replaces the file atomically and lists it once', () async {
    await backend.upload('ops_d0_0.bin', b('first'));
    await backend.upload('ops_d0_0.bin', b('second'));
    expect((await backend.list()).map((f) => f.name), <String>['ops_d0_0.bin']);
    expect(await backend.download('ops_d0_0.bin'), b('second'));
  });

  test('uploads leave no temp files behind', () async {
    for (var i = 0; i < 5; i++) {
      await backend.upload('ops_d0_$i.bin', b('x$i'));
    }
    final names = root
        .listSync()
        .map((e) => e.path.split(RegExp(r'[/\\]')).last)
        .toList();
    expect(names.where((n) => n.startsWith('.')), isEmpty);
    expect(names, hasLength(5));
  });

  test('hidden files and subdirectories are not listed', () async {
    await backend.upload('ops_d0_0.bin', b('v'));
    File('${root.path}/.ops_d1_0.bin.999-0.tmp').writeAsBytesSync(b('half'));
    Directory('${root.path}/nested').createSync();
    expect((await backend.list()).map((f) => f.name), <String>['ops_d0_0.bin']);
  });

  test('delete removes the file and is idempotent', () async {
    await backend.upload('ops_d0_0.bin', b('v'));
    await backend.delete('ops_d0_0.bin');
    expect(await backend.list(), isEmpty);
    await backend.delete('ops_d0_0.bin'); // second delete: no-op
    await backend.delete('never_existed.bin'); // missing: no-op
  });

  test('download of a missing file throws', () async {
    await expectLater(
      backend.download('ops_d9_9.bin'),
      throwsA(isA<FileSystemException>()),
    );
  });

  test('rejects names that escape the folder or are not portable', () async {
    const bad = <String>[
      '',
      '.hidden',
      '..',
      '../escape.bin',
      'a/b.bin',
      r'a\b.bin',
      'c:x.bin',
      'star*.bin',
      'trailing.',
      'trailing ',
    ];
    for (final name in bad) {
      await expectLater(() => backend.upload(name, b('v')), throwsArgumentError,
          reason: 'upload "$name"');
      await expectLater(() => backend.download(name), throwsArgumentError,
          reason: 'download "$name"');
      await expectLater(() => backend.delete(name), throwsArgumentError,
          reason: 'delete "$name"');
    }
    expect(await backend.list(), isEmpty);
  });

  test('carries a real op file byte-exactly', () async {
    final op = Op(
      'd3',
      7,
      OperationCodec.encode(MapPut(
        docId: 'note:1',
        field: 'title',
        value: b('Groceries'),
        hlc: const Hlc(1700000000000, 2, 'd3'),
      )),
    );
    final name = OpFileFormat.fileName(op.deviceId, op.seq);
    await backend.upload(name, OpCodec.encode(op));
    final back = OpCodec.decode(await backend.download(name));
    expect(back.key, op.key);
    expect(back.payload, op.payload);
    final decoded = OperationCodec.decode(back.payload) as MapPut;
    expect(decoded.field, 'title');
    expect(String.fromCharCodes(decoded.value), 'Groceries');
  });
}

import 'dart:io';
import 'dart:typed_data';

import 'package:sync_backend_fs/sync_backend_fs.dart';
import 'package:sync_engine/sync_engine.dart';
import 'package:test/test.dart';

Uint8List _b(String s) => Uint8List.fromList(s.codeUnits);

void main() {
  late Directory tmp;

  String path(String name) => '${tmp.path}${Platform.pathSeparator}$name';

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('hsy_store_');
  });

  tearDown(() async {
    if (await tmp.exists()) await tmp.delete(recursive: true);
  });

  test('a fresh store is empty', () async {
    final store = FsLocalStore(Directory(path('fresh')));
    expect(await store.loadDeviceId(), isNull);
    expect(await store.loadOps(), isEmpty);
  });

  test('device id and ops round-trip through disk', () async {
    final dir = Directory(path('s'));
    final op = Op('a', 3, _b('payload'));
    await FsLocalStore(dir).saveDeviceId('a');
    await FsLocalStore(dir).appendOps(<Op>[op, op]); // duplicate append

    final reopened = FsLocalStore(dir);
    expect(await reopened.loadDeviceId(), 'a');
    final ops = await reopened.loadOps();
    expect(ops.map((o) => o.key), <String>['a#3']);
    expect(ops.single.payload, op.payload);
  });

  test('a corrupt op file is skipped on load', () async {
    final dir = Directory(path('s'));
    final store = FsLocalStore(dir);
    await store.appendOps(<Op>[Op('a', 0, _b('ok')), Op('a', 1, _b('bad'))]);
    final bad = File('${dir.path}/ops/${OpFileFormat.fileName('a', 1)}');
    bad.writeAsBytesSync(bad.readAsBytesSync().sublist(0, 10));
    expect((await store.loadOps()).map((o) => o.key), <String>['a#0']);
  });

  test('two installs sync through one folder across restarts', () async {
    final shared = FsBackend(Directory(path('shared')));
    Future<SyncClient> launch(String install) => SyncClient.open(
        backend: shared, store: FsLocalStore(Directory(path(install))));

    var phone = await launch('phone');
    var laptop = await launch('laptop');
    expect(phone.deviceId, isNot(laptop.deviceId));

    await phone.put('note', 'title', _b('Groceries'));
    final milk = await phone.insertIntoList('note', 'items', _b('Milk'));
    await phone.sync();
    await laptop.sync();
    await laptop.insertIntoList('note', 'items', _b('Eggs'), after: milk);

    // Both apps are killed and relaunched from disk.
    final phoneId = phone.deviceId;
    phone = await launch('phone');
    laptop = await launch('laptop');
    expect(phone.deviceId, phoneId);
    expect(laptop.ops, hasLength(3), reason: 'own and pulled ops persisted');

    await laptop.sync();
    await phone.sync();
    await phone.addToSet('note', 'tags', _b('home'));
    await phone.sync();
    await laptop.sync();

    expect(phone.materialize(), laptop.materialize());
    final text = String.fromCharCodes(phone.materialize());
    expect(text, allOf(contains('Groceries'), contains('home')));
    expect(text.indexOf('Milk'), lessThan(text.indexOf('Eggs')));
    expect(phone.pendingUploads + laptop.pendingUploads, 0);
  });
}

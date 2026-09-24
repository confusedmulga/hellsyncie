import 'dart:math';
import 'dart:typed_data';

import 'package:sync_backend_drive/sync_backend_drive.dart';
import 'package:sync_engine/sync_engine.dart';
import 'package:sync_engine/testing.dart';
import 'package:test/test.dart';

import 'fake_drive.dart';

Uint8List _b(String s) => Uint8List.fromList(s.codeUnits);

/// HTTP-level Drive faults, under the contract-level FaultyBackend.
FakeDrive _fuzzDrive(int seed) => FakeDrive(
  rng: Random(seed ^ 0x5eed),
  failBefore: 0.05,
  loseResponse: 0.05,
  queryLag: 0.2,
);

/// The drain must be honest at every layer: switch the fake's faults off too.
FuzzConfig _config(FakeDrive drive) => FuzzConfig(
  onDrain: () => drive
    ..failBefore = 0
    ..loseResponse = 0
    ..queryLag = 0,
);

void main() {
  late FakeDrive fake;
  late DriveBackend backend;

  setUp(() {
    fake = FakeDrive();
    backend = DriveBackend(fake.client);
  });

  group('contract', () {
    test('an empty appDataFolder lists nothing', () async {
      expect(await backend.list(), isEmpty);
    });

    test('upload then list and download round-trip exact bytes', () async {
      await backend.upload('ops_d0_0.bin', _b('hello'));
      final listing = await backend.list();
      expect(listing.map((f) => f.name), <String>['ops_d0_0.bin']);
      expect(listing.single.size, 5);
      expect(await backend.download('ops_d0_0.bin'), _b('hello'));
    });

    test('re-upload replaces content in place, never adds a copy', () async {
      await backend.upload('ops_d0_0.bin', _b('first'));
      await backend.upload('ops_d0_0.bin', _b('second'));
      expect(fake.named('ops_d0_0.bin'), hasLength(1));
      expect(await backend.download('ops_d0_0.bin'), _b('second'));
    });

    test('delete removes every copy and is idempotent', () async {
      fake
        ..plant('ops_d0_0.bin', _b('a'))
        ..plant('ops_d0_0.bin', _b('b'));
      await backend.delete('ops_d0_0.bin');
      expect(await backend.list(), isEmpty);
      await backend.delete('ops_d0_0.bin');
      await backend.delete('never_existed.bin');
    });

    test('download of a missing file throws', () async {
      await expectLater(backend.download('ops_d9_9.bin'), throwsStateError);
    });

    test('carries a real op file byte-exactly', () async {
      final op = Op(
        'd3',
        7,
        OperationCodec.encode(
          MapPut(
            docId: 'note:1',
            field: 'title',
            value: _b('Groceries'),
            hlc: const Hlc(1700000000000, 2, 'd3'),
          ),
        ),
      );
      final name = OpFileFormat.fileName(op.deviceId, op.seq);
      final bytes = OpCodec.encode(op);
      await backend.upload(name, bytes);
      expect(await backend.download(name), bytes);
    });

    test('quotes and backslashes in names are escaped in queries', () async {
      for (final name in <String>["it's.bin", r'back\slash.bin']) {
        await backend.upload(name, _b(name));
        expect(await backend.download(name), _b(name), reason: name);
      }
    });
  });

  test('list follows every page', () async {
    final paged = DriveBackend(fake.client, pageSize: 2);
    for (var i = 0; i < 5; i++) {
      fake.plant('ops_d0_$i.bin', _b('$i'));
    }
    expect((await paged.list()).map((f) => f.name).toSet(), hasLength(5));
  });

  group('duplicate names', () {
    test('download reads the newest copy', () async {
      fake
        ..plant('ops_a_0.bin', _b('old-partial'))
        ..plant('ops_a_0.bin', _b('new-full'));
      expect(await backend.download('ops_a_0.bin'), _b('new-full'));
    });

    test('upload rewrites the newest copy and deletes the rest', () async {
      fake
        ..plant('ops_a_0.bin', _b('x'))
        ..plant('ops_a_0.bin', _b('y'));
      await backend.upload('ops_a_0.bin', _b('z'));
      expect(fake.named('ops_a_0.bin').map((f) => f.bytes), [_b('z')]);
    });

    test('a create retried after a lost response, while search lags, '
        'overwrites instead of duplicating', () async {
      fake
        ..loseResponse = 1
        ..queryLag = 1;
      await expectLater(
        backend.upload('ops_a_0.bin', _b('partial')),
        throwsA(isA<Exception>()),
      );
      fake
        ..loseResponse = 0
        ..queryLag = 0;
      await backend.upload('ops_a_0.bin', _b('full')); // cannot see the first
      expect(fake.injected['idConflict'], 1);
      expect(fake.named('ops_a_0.bin').map((f) => f.bytes), [_b('full')]);
    });

    test('a duplicate from another process (a restart mid-retry) is folded '
        'away by the next upload', () async {
      fake
        ..loseResponse = 1
        ..queryLag = 1;
      await expectLater(
        backend.upload('ops_a_0.bin', _b('v')),
        throwsA(isA<Exception>()),
      );
      fake
        ..loseResponse = 0
        ..queryLag = 0;
      final restarted = DriveBackend(fake.client); // reserved id forgotten
      await restarted.upload('ops_a_0.bin', _b('v'));
      expect(fake.named('ops_a_0.bin'), hasLength(2));

      for (final f in fake.files.values) {
        f.visibleAfter = 0;
      }
      await restarted.upload('ops_a_0.bin', _b('v'));
      expect(fake.named('ops_a_0.bin'), hasLength(1));
    });
  });

  group('SyncClient over Drive', () {
    test('a failed list fails the round; the next round recovers', () async {
      final a = await SyncClient.open(
        backend: backend,
        store: MemoryStore(),
        deviceId: 'a',
      );
      final b = await SyncClient.open(
        backend: backend,
        store: MemoryStore(),
        deviceId: 'b',
      );
      await a.put('d', 'f', _b('value'));
      await a.sync();

      fake.failLists = 1;
      await expectLater(b.sync(), throwsA(isA<Exception>()));
      final result = await b.sync();
      expect(result.received, 1);
      expect(b.materialize(), a.materialize());
    });

    // Seeds that once failed over Drive. PERMANENT, like regression_seeds.
    //  4: HTTP faults stayed on through the drain, so a round in which every
    //     download of one op failed looked quiescent. Fixed by FuzzConfig
    //     .onDrain; the convergence assertion was not touched.
    for (final seed in const <int>[4]) {
      test('pinned seed $seed converges', () async {
        final drive = _fuzzDrive(seed);
        final result = await runFuzz(
          seed,
          backend: DriveBackend(drive.client),
          config: _config(drive),
        );
        expect(result.converged, isTrue, reason: result.failureReason);
      });
    }

    test(
      '200 random seeds converge over DriveBackend under fault injection',
      () async {
        final meta = Random();
        final failing = <String>[];
        final fired = <String, int>{};
        for (var i = 0; i < 200; i++) {
          final seed = meta.nextInt(0x7fffffff);
          final drive = _fuzzDrive(seed);
          final result = await runFuzz(
            seed,
            backend: DriveBackend(drive.client),
            config: _config(drive),
          );
          if (!result.converged) failing.add('$seed (${result.failureReason})');
          drive.injected.forEach((k, v) => fired[k] = (fired[k] ?? 0) + v);
        }
        // Guard against a vacuous pass: every Drive fault really happened,
        // including creates retried under a reserved id (409 -> update).
        for (final kind in <String>[
          'failBefore',
          'loseResponse',
          'queryLag',
          'idConflict',
        ]) {
          expect(fired[kind] ?? 0, greaterThan(0), reason: '$kind never fired');
        }
        expect(
          failing,
          isEmpty,
          reason:
              'Non-converging seeds over DriveBackend. Pin each in '
              'sync_engine/test/regression_seeds.dart and fix the cause, '
              'never the assertion: $failing',
        );
      },
      timeout: const Timeout(Duration(minutes: 5)),
    );
  });
}

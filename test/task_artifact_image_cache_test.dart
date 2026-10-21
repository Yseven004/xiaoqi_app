import 'dart:async';
import 'dart:convert';
import 'dart:io' as io;
import 'dart:typed_data';

import 'package:file/file.dart' as fs;
import 'package:file/local.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:path/path.dart' as p;
import 'package:xiaoqi_app/config/release.dart';
import 'package:xiaoqi_app/features/capabilities/data/capability_cloud_sync.dart';
import 'package:xiaoqi_app/services/task_artifact_image_cache.dart';

class _TestFileSystem implements FileSystem {
  _TestFileSystem(this.directory);
  final String directory;

  @override
  Future<fs.File> createFile(String name) async =>
      const LocalFileSystem().file(p.join(directory, name));
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late io.Directory directory;
  late CacheManager disk;
  late TaskArtifactImageCache cache;
  final managers = <CacheManager>[];
  var downloads = 0;

  CacheManager newDisk() {
    final manager = CacheManager(
      Config(
        'image_cache_test',
        repo: JsonCacheInfoRepository(
          path: p.join(directory.path, 'metadata.json'),
        ),
        fileSystem: _TestFileSystem(directory.path),
      ),
    );
    managers.add(manager);
    return manager;
  }

  Future<Uint8List> load({
    TaskArtifactImageCache? from,
    String scope = 'service:account-a',
    String taskId = 'task-a',
    String id = 'image-a',
    Future<Uint8List> Function()? download,
  }) => (from ?? cache).load(
    scope: scope,
    taskId: taskId,
    artifactId: id,
    download:
        download ??
        () async {
          downloads++;
          return Uint8List.fromList([1, 2, 3]);
        },
  );

  setUp(() async {
    directory = await io.Directory.systemTemp.createTemp(
      'xiaoqi-artifact-cache-test-',
    );
    disk = newDisk();
    cache = TaskArtifactImageCache(diskCache: disk);
    downloads = 0;
    FlutterSecureStorage.setMockInitialValues({
      'xiaoqi.capabilities.device_token.v1': 'account-a-token',
    });
  });

  tearDown(() async {
    for (final manager in managers) {
      await manager.dispose();
    }
    managers.clear();
    expect(
      p.basename(directory.path),
      startsWith('xiaoqi-artifact-cache-test-'),
    );
    await directory.delete(recursive: true);
  });

  test('reopening reuses the same bytes and decoded-image cache key', () async {
    final original = await load();
    expect(identical(await load(), original), isTrue);
    expect(downloads, 1);
  });

  test(
    'cold cache restores from disk after manager recreation, offline',
    () async {
      final original = await load();
      await disk.dispose();
      managers.remove(disk);
      disk = newDisk();
      cache = TaskArtifactImageCache(diskCache: disk);
      final restored = await load(
        download: () => throw StateError('network must not be used'),
      );
      expect(restored, original);
      expect(downloads, 1);
    },
  );

  test(
    'simultaneous preview and original requests share one download',
    () async {
      final ready = Completer<void>();
      final result = Completer<Uint8List>();
      final first = load(
        download: () {
          downloads++;
          ready.complete();
          return result.future;
        },
      );
      final second = load();
      await ready.future;
      result.complete(Uint8List.fromList([7]));
      final both = await Future.wait([first, second]);
      expect(identical(both.first, both.last), isTrue);
      expect(downloads, 1);
    },
  );

  test('account, service, task and artifact identities are isolated', () async {
    await load();
    await load(scope: 'service:account-b');
    await load(scope: 'other-service:account-a');
    await load(taskId: 'task-b');
    await load(id: 'image-b');
    expect(downloads, 5);
    final metadata = await io.File(
      p.join(directory.path, 'metadata.json'),
    ).readAsString();
    expect(metadata, isNot(contains('account-a')));
    expect(metadata, isNot(contains('task-a')));
  });

  test('a failed download can be retried', () async {
    await expectLater(
      load(download: () async => throw StateError('network failed')),
      throwsStateError,
    );
    expect(await load(), [1, 2, 3]);
    expect(downloads, 1);
  });

  test('empty downloads are rejected and do not poison the cache', () async {
    await expectLater(
      load(download: () async => Uint8List(0)),
      throwsFormatException,
    );
    expect(await load(), [1, 2, 3]);
    expect(downloads, 1);
  });

  test('memory eviction falls back to disk without another download', () async {
    cache = TaskArtifactImageCache(diskCache: disk, maxMemoryBytes: 3);
    final first = await load();
    await load(id: 'image-b');
    expect(await load(), first);
    expect(downloads, 2);
  });

  test('a disk file removed by the OS is downloaded again', () async {
    await load();
    await for (final entity in directory.list()) {
      if (entity.path.endsWith('.image')) await entity.delete();
    }
    cache = TaskArtifactImageCache(diskCache: disk);
    expect(await load(), [1, 2, 3]);
    expect(downloads, 2);
  });

  test('disk write failures still return the downloaded image', () async {
    final blocked = io.File(p.join(directory.path, 'not-a-directory'));
    await blocked.writeAsString('occupied');
    final unavailable = CacheManager(
      Config(
        'unavailable_cache_test',
        repo: JsonCacheInfoRepository(
          path: p.join(directory.path, 'unavailable.json'),
        ),
        fileSystem: _TestFileSystem(blocked.path),
      ),
    );
    managers.add(unavailable);
    final cache = TaskArtifactImageCache(diskCache: unavailable);
    expect(await load(from: cache), [1, 2, 3]);
    expect(await load(from: cache), [1, 2, 3]);
    expect(downloads, 1);
  });

  http.Response health() => http.Response(
    jsonEncode({
      'release_id': releaseId,
      'api_contract_version': apiContractVersion,
    }),
    200,
  );

  test(
    'cached cloud images bypass health and download while offline',
    () async {
      var requests = 0;
      final online = CapabilityCloudSync.forTesting(
        MockClient((request) async {
          requests++;
          return request.url.path == '/health'
              ? health()
              : http.Response.bytes([4, 5, 6], 200);
        }),
        imageCache: cache,
      );
      await online.downloadTaskArtifact('task', 'image', cacheImage: true);
      expect(requests, 2);
      final offline = CapabilityCloudSync.forTesting(
        MockClient((_) => throw StateError('offline')),
        imageCache: TaskArtifactImageCache(diskCache: disk),
      );
      expect(
        await offline.downloadTaskArtifact('task', 'image', cacheImage: true),
        [4, 5, 6],
      );
      FlutterSecureStorage.setMockInitialValues({});
      await expectLater(
        offline.downloadTaskArtifact('task', 'image', cacheImage: true),
        throwsStateError,
      );
    },
  );

  test('parallel cloud images share one release verification', () async {
    var checks = 0;
    var images = 0;
    final cloud = CapabilityCloudSync.forTesting(
      MockClient((request) async {
        if (request.url.path == '/health') {
          checks++;
          await Future<void>.delayed(const Duration(milliseconds: 10));
          return health();
        }
        images++;
        return http.Response.bytes([1], 200);
      }),
      imageCache: cache,
    );
    await Future.wait([
      cloud.downloadTaskArtifact('task', 'one', cacheImage: true),
      cloud.downloadTaskArtifact('task', 'two', cacheImage: true),
      cloud.downloadTaskArtifact('task', 'one', cacheImage: true),
    ]);
    expect(checks, 1);
    expect(images, 2);
  });

  test(
    'changing the cloud account cannot reuse another account image',
    () async {
      final accounts = <String?>[];
      final cloud = CapabilityCloudSync.forTesting(
        MockClient((request) async {
          if (request.url.path == '/health') return health();
          accounts.add(request.headers['Authorization']);
          return http.Response.bytes([accounts.length], 200);
        }),
        imageCache: cache,
      );
      expect(
        await cloud.downloadTaskArtifact('task', 'image', cacheImage: true),
        [1],
      );
      FlutterSecureStorage.setMockInitialValues({
        'xiaoqi.capabilities.device_token.v1': 'account-b-token',
      });
      expect(
        await cloud.downloadTaskArtifact('task', 'image', cacheImage: true),
        [2],
      );
      expect(accounts, ['Bearer account-a-token', 'Bearer account-b-token']);
    },
  );

  test('a release mismatch prevents downloading uncached images', () async {
    var images = 0;
    final cloud = CapabilityCloudSync.forTesting(
      MockClient((request) async {
        if (request.url.path == '/health') {
          return http.Response(
            jsonEncode({
              'release_id': 'wrong',
              'api_contract_version': 'wrong',
            }),
            200,
          );
        }
        images++;
        return http.Response.bytes([1], 200);
      }),
      imageCache: cache,
    );
    await expectLater(
      cloud.downloadTaskArtifact('task', 'image', cacheImage: true),
      throwsStateError,
    );
    expect(images, 0);
  });
}

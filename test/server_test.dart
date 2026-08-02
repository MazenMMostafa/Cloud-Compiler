import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

import 'package:newbegin_compiler_server/compiler.dart';
import 'package:newbegin_compiler_server/server.dart';

const _realHex = ':100000000C9434000C943E000C943E000C943E00F7\n'
    ':100010000C943E000C943E000C943E000C943E00F7\n'
    ':00000001FF\n';

class _FakeCompileService implements CompileService {
  _FakeCompileService({this.result});

  CompileResult? result;
  int compileCount = 0;

  @override
  Future<CompileResult> compile({
    required String source,
    required String boardId,
  }) async {
    compileCount++;
    return result!;
  }
}

class _TestServer {
  _TestServer(this.server, this.http, this.subscription);

  final CompilerServer server;
  final HttpServer http;
  final StreamSubscription<HttpRequest> subscription;

  int get port => http.port;

  Future<void> close() async {
    await subscription.cancel();
    await http.close(force: true);
  }

  Future<HttpClientResponse> request(
    String method,
    String path, {
    Object? jsonBody,
    Map<String, String>? headers,
    List<int>? rawBody,
  }) async {
    final client = HttpClient();
    try {
      final req = await client.openUrl(method, Uri.parse('http://127.0.0.1:$port$path'));
      headers?.forEach((k, v) => req.headers.set(k, v));
      req.headers.contentType = ContentType.json;
      final body = rawBody ?? utf8.encode(jsonEncode(jsonBody));
      req.contentLength = body.length;
      req.add(body);
      return await req.close();
    } finally {
      client.close();
    }
  }
}

Future<_TestServer> _startServer({
  String? apiKey,
  CompileService? compiler,
  int maxBody = kMaxRequestBodyBytes,
}) async {
  final server = CompilerServer(
    compiler: compiler ?? _FakeCompileService(),
    apiKey: apiKey,
    maxRequestBodyBytes: maxBody,
  );
  final http = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  final subscription = http.listen((req) => server.handle(req));
  return _TestServer(server, http, subscription);
}

Future<Map<String, dynamic>> _readJson(HttpClientResponse res) async {
  final body = await res.transform(utf8.decoder).join();
  return jsonDecode(body) as Map<String, dynamic>;
}

void main() {
  group('GET /health', () {
    test('returns success without starting a compilation', () async {
      final fake = _FakeCompileService();
      final ts = await _startServer(compiler: fake);
      try {
        final res = await ts.request('GET', '/health');
        expect(res.statusCode, 200);
        final body = await _readJson(res);
        expect(body['success'], isTrue);
        expect(body['service'], 'newbegin-arduino-compiler');
        expect(body['board'], 'arduino:avr:uno');
        expect(fake.compileCount, 0);
      } finally {
        await ts.close();
      }
    });

    test('health is not protected by the API key', () async {
      final ts = await _startServer(apiKey: 'test-secret');
      try {
        final res = await ts.request('GET', '/health');
        expect(res.statusCode, 200);
      } finally {
        await ts.close();
      }
    });
  });

  group('POST /compile request validation', () {
    test('missing source code is rejected', () async {
      final ts = await _startServer();
      try {
        final res = await ts.request('POST', '/compile', jsonBody: {'board': 'arduino_uno'});
        expect(res.statusCode, 400);
        final body = await _readJson(res);
        expect(body['error'], contains('source'));
      } finally {
        await ts.close();
      }
    });

    test('empty source code is rejected', () async {
      final ts = await _startServer();
      try {
        final res = await ts.request('POST', '/compile', jsonBody: {'source': '', 'board': 'arduino_uno'});
        expect(res.statusCode, 400);
      } finally {
        await ts.close();
      }
    });

    test('invalid JSON is rejected', () async {
      final ts = await _startServer();
      try {
        final res = await ts.request('POST', '/compile', rawBody: utf8.encode('{not json'));
        expect(res.statusCode, 400);
        final body = await _readJson(res);
        expect(body['error'], 'Invalid JSON');
      } finally {
        await ts.close();
      }
    });

    test('non-object JSON is rejected', () async {
      final ts = await _startServer();
      try {
        final res = await ts.request('POST', '/compile', rawBody: utf8.encode('[1,2,3]'));
        expect(res.statusCode, 400);
      } finally {
        await ts.close();
      }
    });

    test('oversized requests are rejected', () async {
      final ts = await _startServer(maxBody: 100);
      try {
        final big = 'void setup(){}' * 30; // > 100 bytes
        final res = await ts.request('POST', '/compile', jsonBody: {'source': big, 'board': 'arduino_uno'});
        expect(res.statusCode, 413);
      } finally {
        await ts.close();
      }
    });
  });

  group('API key protection', () {
    test('invalid or missing API key is rejected', () async {
      final fake = _FakeCompileService();
      final ts = await _startServer(apiKey: 'test-secret', compiler: fake);
      try {
        final noKey = await ts.request('POST', '/compile', jsonBody: {'source': 'void setup(){}', 'board': 'arduino_uno'});
        expect(noKey.statusCode, 401);
        final wrongKey = await ts.request('POST', '/compile',
            jsonBody: {'source': 'void setup(){}', 'board': 'arduino_uno'},
            headers: {'X-API-Key': 'wrong'});
        expect(wrongKey.statusCode, 401);
        expect(fake.compileCount, 0);
      } finally {
        await ts.close();
      }
    });

    test('correct API key is accepted', () async {
      final fake = _FakeCompileService(
        result: CompileResult(success: true, firmwareBytes: utf8.encode(_realHex), firmwareSize: _realHex.length),
      );
      final ts = await _startServer(apiKey: 'test-secret', compiler: fake);
      try {
        final res = await ts.request('POST', '/compile',
            jsonBody: {'source': 'void setup(){}', 'board': 'arduino_uno'},
            headers: {'X-API-Key': 'test-secret'});
        expect(res.statusCode, 200);
        expect(fake.compileCount, 1);
      } finally {
        await ts.close();
      }
    });
  });

  group('POST /compile responses', () {
    test('successful mocked compilation returns the real HEX', () async {
      final fake = _FakeCompileService(
        result: CompileResult(
          success: true,
          firmwareBytes: utf8.encode(_realHex),
          firmwareSize: _realHex.length,
          compilerVersion: '7.3.0',
          fqbn: 'arduino:avr:uno',
        ),
      );
      final ts = await _startServer(compiler: fake);
      try {
        final res = await ts.request('POST', '/compile', jsonBody: {
          'source': 'void setup() { pinMode(13, OUTPUT); } void loop() {}',
          'board': 'arduino_uno',
          'format': 'hex',
        });
        expect(res.statusCode, 200);
        final body = await _readJson(res);
        expect(body['success'], isTrue);
        expect(body['firmware'], base64Encode(utf8.encode(_realHex)));
        expect(body['firmwareSize'], _realHex.length);
        expect(body['errors'], isEmpty);
        expect(base64Decode(body['firmware'] as String), utf8.encode(_realHex));
      } finally {
        await ts.close();
      }
    });

    test('compiler failure returns an error rather than fake HEX', () async {
      final fake = _FakeCompileService(
        result: CompileResult(
          success: false,
          errors: [
            CompileError(
              code: 'COMPILE-ERROR',
              severity: 'error',
              description: "'digitalWrite' was not declared",
              file: 'NewBeginSketch.ino',
              line: 3,
            ),
          ],
        ),
      );
      final ts = await _startServer(compiler: fake);
      try {
        final res = await ts.request('POST', '/compile', jsonBody: {
          'source': 'void setup() { digitalWrite(13); }',
          'board': 'arduino_uno',
        });
        expect(res.statusCode, 200);
        final body = await _readJson(res);
        expect(body['success'], isFalse);
        expect(body['firmware'], isNull);
        expect(body['errors'], isNotEmpty);
        expect((body['errors'] as List).first['code'], 'COMPILE-ERROR');
      } finally {
        await ts.close();
      }
    });

    test('unsupported board is rejected by the compiler layer', () async {
      final tempRoot = await Directory.systemTemp.createTemp('newbegin_test_');
      final compiler = ArduinoCliCompiler(
        cliPath: 'fake-arduino-cli',
        processRunner: (exe, args, {workingDirectory, timeout}) async =>
            ProcessResult(1, 0, '', ''),
        tempDirProvider: () => tempRoot.createTemp('newbegin_compile_'),
      );
      final ts = await _startServer(compiler: compiler);
      try {
        final res = await ts.request('POST', '/compile', jsonBody: {
          'source': 'void setup() {}',
          'board': 'esp32_devkit_v1',
        });
        expect(res.statusCode, 200);
        final body = await _readJson(res);
        expect(body['success'], isFalse);
        expect(body['firmware'], isNull);
        expect((body['errors'] as List).isNotEmpty, isTrue);
        expect(tempRoot.listSync(), isEmpty);
      } finally {
        await ts.close();
        await tempRoot.delete(recursive: true);
      }
    });

    test('unsupported format is rejected', () async {
      final ts = await _startServer();
      try {
        final res = await ts.request('POST', '/compile', jsonBody: {
          'source': 'void setup() {}',
          'board': 'arduino_uno',
          'format': 'bin',
        });
        expect(res.statusCode, 400);
      } finally {
        await ts.close();
      }
    });
  });
}

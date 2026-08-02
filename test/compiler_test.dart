import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

import 'package:newbegin_compiler_server/compiler.dart';

const _realHex = ':100000000C9434000C943E000C943E000C943E00F7\n'
    ':100010000C943E000C943E000C943E000C943E00F7\n'
    ':00000001FF\n';

/// Fake toolchain process that records invocations and, when [writeHex] is
/// set, writes a real HEX file into the build directory passed via
/// `--build-path`.
class _FakeRunner {
  _FakeRunner({
    required this.exitCode,
    required this.writeHex,
    this.stderr = '',
    this.delay,
  });

  final int exitCode;
  final bool writeHex;
  final String stderr;
  final Duration? delay;

  final List<List<String>> calls = [];
  final List<String> buildDirs = [];

  Future<ProcessResult> call(
    String executable,
    List<String> arguments, {
    String? workingDirectory,
    Duration? timeout,
  }) async {
    calls.add(List.of(arguments));
    if (delay != null) await Future<void>.delayed(delay!);

    final i = arguments.indexOf('--build-path');
    if (i >= 0 && i + 1 < arguments.length) {
      final buildDir = arguments[i + 1];
      buildDirs.add(buildDir);
      if (writeHex) {
        final hexFile = File('$buildDir/NewBeginSketch.ino.hex');
        await hexFile.create(recursive: true);
        await hexFile.writeAsString(_realHex);
      }
    }
    return ProcessResult(1, exitCode, '', stderr);
  }
}

ArduinoCliCompiler _compiler(
  _FakeRunner runner,
  Directory tempRoot,
) {
  return ArduinoCliCompiler(
    cliPath: 'fake-arduino-cli',
    timeout: const Duration(seconds: 10),
    processRunner: runner.call,
    tempDirProvider: () => tempRoot.createTemp('newbegin_compile_'),
  );
}

void main() {
  late Directory tempRoot;

  setUp(() async {
    tempRoot = await Directory.systemTemp.createTemp('newbegin_test_root_');
  });

  tearDown(() async {
    if (await tempRoot.exists()) {
      await tempRoot.delete(recursive: true);
    }
  });

  group('ArduinoCliCompiler', () {
    test('successful compilation returns the real HEX from the build directory',
        () async {
      final runner = _FakeRunner(exitCode: 0, writeHex: true);
      final compiler = _compiler(runner, tempRoot);

      final result = await compiler.compile(
        source: 'void setup() { pinMode(13, OUTPUT); }',
        boardId: 'arduino_uno',
      );

      expect(result.success, isTrue);
      expect(result.firmwareBytes, isNotNull);
      expect(utf8.decode(result.firmwareBytes!), _realHex);
      expect(result.firmwareSize, _realHex.length);
      expect(result.errors, isEmpty);

      // Compile invoked with an argument array, never a shell string.
      expect(runner.calls.first, contains('compile'));
      expect(runner.calls.first, contains('arduino:avr:uno'));
    });

    test('compiler failure returns an error and no HEX', () async {
      final runner = _FakeRunner(
        exitCode: 1,
        writeHex: false,
        stderr: 'NewBeginSketch.ino:3:1: error: \'digitalWrite\' was not declared',
      );
      final compiler = _compiler(runner, tempRoot);

      final result = await compiler.compile(
        source: 'void setup() { digitalWrite(13); }',
        boardId: 'arduino_uno',
      );

      expect(result.success, isFalse);
      expect(result.firmwareBytes, isNull);
      expect(result.errors, isNotEmpty);
      expect(result.errors.first.code, 'COMPILE-ERROR');
    });

    test('exit 0 but no HEX file still fails without fabricated firmware',
        () async {
      final runner = _FakeRunner(exitCode: 0, writeHex: false);
      final compiler = _compiler(runner, tempRoot);

      final result = await compiler.compile(
        source: 'void setup() {}',
        boardId: 'arduino_uno',
      );

      expect(result.success, isFalse);
      expect(result.firmwareBytes, isNull);
      expect(result.errors, isNotEmpty);
    });

    test('temporary directories are cleaned up after success', () async {
      final runner = _FakeRunner(exitCode: 0, writeHex: true);
      final compiler = _compiler(runner, tempRoot);

      await compiler.compile(source: 'void setup() {}', boardId: 'arduino_uno');

      expect(tempRoot.listSync(), isEmpty);
    });

    test('temporary directories are cleaned up after failure', () async {
      final runner = _FakeRunner(exitCode: 1, writeHex: false);
      final compiler = _compiler(runner, tempRoot);

      await compiler.compile(source: 'broken {', boardId: 'arduino_uno');

      expect(tempRoot.listSync(), isEmpty);
    });

    test('temporary directories are cleaned up when the process times out',
        () async {
      final runner = _FakeRunner(
        exitCode: 1,
        writeHex: false,
        delay: const Duration(milliseconds: 300),
      );
      final compiler = ArduinoCliCompiler(
        cliPath: 'fake-arduino-cli',
        timeout: const Duration(milliseconds: 50),
        processRunner: runner.call,
        tempDirProvider: () => tempRoot.createTemp('newbegin_compile_'),
      );

      final result = await compiler.compile(
        source: 'void setup() {}',
        boardId: 'arduino_uno',
      );

      expect(result.success, isFalse);
      expect(result.errors.first.code, 'SERVER-003');
      expect(tempRoot.listSync(), isEmpty);
    });

    test('two concurrent requests use different temporary directories', () async {
      final runner = _FakeRunner(
        exitCode: 0,
        writeHex: true,
        delay: const Duration(milliseconds: 50),
      );
      final compiler = _compiler(runner, tempRoot);

      final futures = [
        compiler.compile(source: 'void setup() { pinMode(13, OUTPUT); }', boardId: 'arduino_uno'),
        compiler.compile(source: 'void setup() { pinMode(12, OUTPUT); }', boardId: 'arduino_uno'),
      ];
      final results = await Future.wait(futures);

      expect(results.every((r) => r.success), isTrue);
      expect(runner.buildDirs.length, 2);
      expect(runner.buildDirs[0], isNot(runner.buildDirs[1]));
      expect(tempRoot.listSync(), isEmpty);
    });

    test('unsupported boards are rejected with a clear error', () async {
      final runner = _FakeRunner(exitCode: 0, writeHex: true);
      final compiler = _compiler(runner, tempRoot);

      final result = await compiler.compile(
        source: 'void setup() {}',
        boardId: 'esp32_devkit_v1',
      );

      expect(result.success, isFalse);
      expect(result.errors.first.code, 'SERVER-001');
      expect(runner.calls, isEmpty);
      expect(tempRoot.listSync(), isEmpty);
    });
  });
}

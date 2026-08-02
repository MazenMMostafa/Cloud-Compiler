import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// Maximum number of bytes of compiler stdout/stderr retained per request.
///
/// Guards against a runaway toolchain flooding memory. Truncation is safe:
/// the HEX firmware is read directly from the build directory, never from the
/// text output.
const int kMaxCompilerOutputBytes = 512 * 1024;

/// Result of a single compilation request.
class CompileResult {
  CompileResult({
    required this.success,
    this.firmwareBytes,
    this.firmwareSize = 0,
    this.compilerVersion,
    this.output = '',
    this.fqbn = '',
    this.errors = const [],
    this.warnings = const [],
  });

  final bool success;
  final List<int>? firmwareBytes;
  final int firmwareSize;
  final String? compilerVersion;
  final String output;
  final String fqbn;
  final List<CompileError> errors;
  final List<CompileError> warnings;
}

/// A single compile error or warning parsed from compiler output.
class CompileError {
  CompileError({
    required this.code,
    required this.severity,
    required this.description,
    this.file,
    this.line,
  });

  final String code;
  final String severity;
  final String description;
  final String? file;
  final int? line;
}

/// Strategy used to run the underlying toolchain process.
///
/// Injectable so tests can substitute a fake process without invoking
/// arduino-cli. The real implementation streams stdout/stderr with a hard cap
/// and kills the process if it exceeds [timeout].
typedef ProcessRunner = Future<ProcessResult> Function(
  String executable,
  List<String> arguments, {
  String? workingDirectory,
  Duration? timeout,
});

/// Creates the unique temporary directory used by a single compile request.
typedef TempDirProvider = Future<Directory> Function();

/// Service that compiles Arduino source code for a board.
abstract class CompileService {
  Future<CompileResult> compile({
    required String source,
    required String boardId,
  });
}

/// Wraps arduino-cli to compile Arduino sketches.
///
/// Container-safe by design:
///   * Only the Arduino Uno board (`arduino:avr:uno`) is accepted.
///   * Every request gets its own unique temporary directory that is always
///     deleted afterwards (even on failure).
///   * Commands are executed with an argument array (never a shell string) and
///     never accept arguments supplied by the client.
///   * A timeout kills the toolchain process.
///   * Toolchain output is capped.
///   * The AVR core is expected to be pre-installed (see Dockerfile.vercel);
///     nothing is downloaded at request time.
class ArduinoCliCompiler implements CompileService {
  ArduinoCliCompiler({
    required this.cliPath,
    this.timeout = const Duration(seconds: 120),
    ProcessRunner? processRunner,
    TempDirProvider? tempDirProvider,
  })  : _processRunner = processRunner ?? _defaultProcessRunner,
        _tempDirProvider = tempDirProvider ?? _defaultTempDirProvider;

  final String cliPath;
  final Duration timeout;

  final ProcessRunner _processRunner;
  final TempDirProvider _tempDirProvider;

  /// Request board id → Arduino FQBN. Only Arduino Uno is enabled initially.
  static const _boardMap = <String, String>{
    'arduino_uno': 'arduino:avr:uno',
  };

  static const _formatMap = <String, String>{
    'arduino_uno': 'hex',
  };

  String get supportedBoards => _boardMap.keys.join(', ');

  static Future<ProcessResult> _defaultProcessRunner(
    String executable,
    List<String> arguments, {
    String? workingDirectory,
    Duration? timeout,
  }) async {
    final process = await Process.start(
      executable,
      arguments,
      workingDirectory: workingDirectory,
    );

    final stdoutBytes = <int>[];
    final stderrBytes = <int>[];
    final stdoutSub = process.stdout.listen((chunk) => _appendCapped(stdoutBytes, chunk));
    final stderrSub = process.stderr.listen((chunk) => _appendCapped(stderrBytes, chunk));

    final int exitCode;
    try {
      if (timeout != null) {
        exitCode = await process.exitCode.timeout(timeout, onTimeout: () {
          // Kill the process on timeout so it cannot keep running after the
          // request has been abandoned.
          process.kill(ProcessSignal.sigkill);
          throw TimeoutException('Process exceeded ${timeout.inSeconds}s');
        });
      } else {
        exitCode = await process.exitCode;
      }
    } finally {
      await stdoutSub.cancel();
      await stderrSub.cancel();
    }

    return ProcessResult(
      process.pid,
      exitCode,
      utf8.decode(stdoutBytes, allowMalformed: true),
      utf8.decode(stderrBytes, allowMalformed: true),
    );
  }

  static void _appendCapped(List<int> buffer, List<int> chunk) {
    if (buffer.length >= kMaxCompilerOutputBytes) return;
    final remaining = kMaxCompilerOutputBytes - buffer.length;
    if (chunk.length > remaining) {
      buffer.addAll(chunk.sublist(0, remaining));
    } else {
      buffer.addAll(chunk);
    }
  }

  static Future<Directory> _defaultTempDirProvider() async {
    return Directory.systemTemp.createTemp('newbegin_compile_');
  }

  /// Check whether arduino-cli is installed and reachable.
  Future<bool> isAvailable() async {
    try {
      final result = await _processRunner(
        cliPath,
        ['version'],
        timeout: const Duration(seconds: 15),
      );
      return result.exitCode == 0;
    } catch (_) {
      return false;
    }
  }

  /// Get arduino-cli version string.
  Future<String?> getVersion() async {
    try {
      final result = await _processRunner(
        cliPath,
        ['version', '--format', 'json'],
        timeout: const Duration(seconds: 15),
      );
      if (result.exitCode == 0 && result.stdout.toString().isNotEmpty) {
        final data = jsonDecode(result.stdout.toString());
        return data['VersionString'] ??
            data['version'] ??
            data['Version'] ??
            result.stdout.toString().trim();
      }
    } catch (_) {}
    return null;
  }

  /// Compile [source] for [boardId].
  ///
  /// Creates a unique temporary sketch directory, writes the .ino file, runs
  /// `arduino-cli compile` with an argument array, reads the generated HEX from
  /// the build directory, and always cleans up the temporary directory.
  @override
  Future<CompileResult> compile({
    required String source,
    required String boardId,
  }) async {
    final fqbn = _boardMap[boardId];
    if (fqbn == null) {
      return CompileResult(
        success: false,
        fqbn: '',
        errors: [
          CompileError(
            code: 'SERVER-001',
            severity: 'error',
            description:
                'Unsupported board: $boardId. Only Arduino Uno (${_boardMap.keys.join(', ')}) is supported initially.',
          ),
        ],
      );
    }

    final ext = _formatMap[boardId] ?? 'hex';
    final tempDir = await _tempDirProvider();
    final sketchDir = Directory('${tempDir.path}/NewBeginSketch');
    final buildDir = Directory('${tempDir.path}/build');

    try {
      await sketchDir.create(recursive: true);
      await buildDir.create(recursive: true);

      final sketchFile = File('${sketchDir.path}/NewBeginSketch.ino');
      await sketchFile.writeAsString(source);

      final procResult = await _runTool(
        [
          'compile',
          '--fqbn', fqbn,
          '--build-path', buildDir.path,
          sketchDir.path,
        ],
        workingDirectory: tempDir.path,
      );

      final output = procResult.stdout.toString();
      final errOutput = procResult.stderr.toString();
      final combinedOutput = [
        if (output.isNotEmpty) output,
        if (errOutput.isNotEmpty) errOutput,
      ].join('\n').trim();

      final errors = _parseErrors(combinedOutput);
      final warnings = _parseWarnings(combinedOutput);

      if (procResult.exitCode == 0) {
        final filename = 'NewBeginSketch.ino.$ext';
        final firmwareFile = File('${buildDir.path}/$filename');
        if (await firmwareFile.exists()) {
          final firmwareBytes = await firmwareFile.readAsBytes();
          return CompileResult(
            success: true,
            firmwareBytes: firmwareBytes,
            firmwareSize: firmwareBytes.length,
            compilerVersion: await getVersion(),
            output: combinedOutput,
            fqbn: fqbn,
            warnings: warnings,
          );
        }
      }

      if (errors.isEmpty) {
        errors.add(CompileError(
          code: 'SERVER-002',
          severity: 'error',
          description: 'Compilation failed (exit code ${procResult.exitCode})',
        ));
      }

      return CompileResult(
        success: false,
        output: combinedOutput,
        fqbn: fqbn,
        errors: errors,
        warnings: warnings,
      );
    } on TimeoutException {
      return CompileResult(
        success: false,
        fqbn: fqbn,
        errors: [
          CompileError(
            code: 'SERVER-003',
            severity: 'error',
            description: 'Compilation timed out after ${timeout.inSeconds}s',
          ),
        ],
      );
    } catch (e) {
      return CompileResult(
        success: false,
        fqbn: fqbn,
        errors: [
          CompileError(
            code: 'SERVER-999',
            severity: 'error',
            description: 'Server error: $e',
          ),
        ],
      );
    } finally {
      await _cleanup(tempDir);
    }
  }

  Future<ProcessResult> _runTool(
    List<String> arguments, {
    required String workingDirectory,
  }) {
    return _processRunner(
      cliPath,
      arguments,
      workingDirectory: workingDirectory,
      timeout: timeout,
    ).timeout(timeout, onTimeout: () {
      throw TimeoutException('Process exceeded ${timeout.inSeconds}s');
    });
  }

  /// Parse GCC-style errors: `file:line:col: error: message`
  List<CompileError> _parseErrors(String output) {
    final errors = <CompileError>[];
    final regex = RegExp(r'(.+?):(\d+):(\d+): error: (.+)');
    for (final m in regex.allMatches(output)) {
      errors.add(CompileError(
        code: 'COMPILE-ERROR',
        severity: 'error',
        description: m.group(4)!,
        file: m.group(1),
        line: int.tryParse(m.group(2)!),
      ));
    }
    return errors;
  }

  /// Parse GCC-style warnings: `file:line:col: warning: message`
  List<CompileError> _parseWarnings(String output) {
    final warnings = <CompileError>[];
    final regex = RegExp(r'(.+?):(\d+):(\d+): warning: (.+)');
    for (final m in regex.allMatches(output)) {
      warnings.add(CompileError(
        code: 'COMPILE-WARNING',
        severity: 'warning',
        description: m.group(4)!,
        file: m.group(1),
        line: int.tryParse(m.group(2)!),
      ));
    }
    return warnings;
  }

  Future<void> _cleanup(Directory dir) async {
    try {
      if (await dir.exists()) {
        await dir.delete(recursive: true);
      }
    } catch (_) {}
  }
}

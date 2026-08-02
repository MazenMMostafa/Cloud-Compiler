import 'dart:io';

import 'package:newbegin_compiler_server/compiler.dart';
import 'package:newbegin_compiler_server/server.dart';

/// Resolves the arduino-cli path:
/// 1. `ARDUINO_CLI_PATH` environment variable
/// 2. bundled `tools/arduino-cli` relative to CWD (local dev / setup scripts)
/// 3. `arduino-cli` on the system PATH
String _findDefaultCli() {
  final env = Platform.environment['ARDUINO_CLI_PATH'];
  if (env != null && env.isNotEmpty) return env;

  final name = Platform.isWindows ? 'arduino-cli.exe' : 'arduino-cli';
  final bundled = 'tools${Platform.pathSeparator}$name';
  if (File(bundled).existsSync()) return File(bundled).absolute.path;
  return name; // fallback to system PATH
}

Future<void> main() async {
  final port = int.tryParse(Platform.environment['PORT'] ?? '') ?? 8080;
  final host = Platform.environment['HOST'] ?? '0.0.0.0';
  final apiKey = Platform.environment['COMPILER_API_KEY'];
  final cliPath = _findDefaultCli();

  final diagEnvCount = Platform.environment.length;
  final diagKeyState = apiKey == null
      ? 'absent'
      : (apiKey.isEmpty ? 'present-but-empty' : 'present-nonempty');
  final diagMarker = Platform.environment.containsKey('CC_DIAG');
  final diagPlain = Platform.environment.containsKey('CC_PLAIN');
  final diagPortValue = Platform.environment['PORT'];

  stdout.writeln('NewBegin Compiler Server');
  stdout.writeln('  arduino-cli: $cliPath');
  stdout.writeln('  Host:        $host');
  stdout.writeln('  Port:        $port');
  stdout.writeln('  API key:     ${apiKey != null && apiKey.isNotEmpty ? 'enabled' : 'disabled'}');
  stdout.writeln('  DIAG envCount=$diagEnvCount key=$diagKeyState sensitiveMarker=$diagMarker plainMarker=$diagPlain portEnv=$diagPortValue');
  stdout.writeln('');

  final compiler = ArduinoCliCompiler(cliPath: cliPath);

  if (!await compiler.isAvailable()) {
    stderr.writeln('ERROR: arduino-cli not found at "$cliPath"');
    stderr.writeln('Set ARDUINO_CLI_PATH or run the container image which bundles it.');
    exit(1);
  }

  final version = await compiler.getVersion();
  stdout.writeln('arduino-cli version: $version');
  stdout.writeln('Supported boards: ${compiler.supportedBoards}');
  stdout.writeln('');

  final server = CompilerServer(
    compiler: compiler,
    apiKey: (apiKey != null && apiKey.isNotEmpty) ? apiKey : null,
    compilerVersion: version,
  );

  final httpServer = await HttpServer.bind(host, port);
  stdout.writeln('Server listening on http://$host:$port');
  stdout.writeln('Health: http://$host:$port/health');
  stdout.writeln('');

  await for (final request in httpServer) {
    // Fire-and-forget so requests are handled concurrently.
    server.handle(request);
  }
}

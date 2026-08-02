import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'compiler.dart';

/// Maximum accepted /compile request body size in bytes.
const int kMaxRequestBodyBytes = 512 * 1024;

/// Header used to authenticate /compile requests when `COMPILER_API_KEY` is set.
const String kApiKeyHeader = 'X-API-Key';

/// Error thrown when a request body exceeds [kMaxRequestBodyBytes].
class RequestTooLargeException implements Exception {}

/// Routes HTTP requests to the compile service.
///
/// Endpoints:
///   GET  /health  → liveness + identity (never starts a compilation)
///   POST /compile → compile source code for the Arduino Uno
///
/// Response shapes intentionally match the contract consumed by the Flutter
/// app:
///   success: `{"success": true, "firmware": "<base64 hex>", "firmwareSize": N,
///             "compilerVersion": "...", "output": "...", "fqbn": "...",
///             "errors": [], "warnings": []}`
///   failure: `{"success": false, "firmware": null, "errors": [...], ...}`
class CompilerServer {
  CompilerServer({
    required this.compiler,
    this.apiKey,
    this.maxRequestBodyBytes = kMaxRequestBodyBytes,
    this.serviceName = 'newbegin-arduino-compiler',
    this.boardId = 'arduino:avr:uno',
    this.compilerVersion,
  });

  final CompileService compiler;

  /// Optional `COMPILER_API_KEY`. When set, `/compile` requires it in the
  /// `X-API-Key` header. `/health` is never protected.
  final String? apiKey;

  final int maxRequestBodyBytes;

  /// Human-readable service name returned by `/health`.
  final String serviceName;

  /// Fixed board identifier supported by this deployment.
  final String boardId;

  /// Compiler version string captured at startup, returned by `/health`.
  final String? compilerVersion;

  /// Handles a single HTTP request.
  Future<void> handle(HttpRequest request) async {
    _addCorsHeaders(request.response);

    if (request.method == 'OPTIONS') {
      await request.response.close();
      return;
    }

    final path = request.uri.path;

    try {
      if (request.method == 'GET' && path == '/health') {
        await _handleHealth(request);
        return;
      }

      if (request.method == 'POST' && path == '/compile') {
        await _handleCompile(request);
        return;
      }

      _respond(request, 404, {'error': 'Not found', 'path': path});
    } catch (_) {
      _respond(request, 500, {'error': 'Internal server error'});
    }
  }

  Future<void> _handleHealth(HttpRequest request) async {
    _respond(request, 200, {
      'success': true,
      'service': serviceName,
      'board': boardId,
      if (compilerVersion != null) 'compilerVersion': compilerVersion,
    });
  }

  Future<void> _handleCompile(HttpRequest request) async {
    if (apiKey != null && !_isAuthorized(request)) {
      _respond(request, 401, {'error': 'Unauthorized'});
      return;
    }

    final String body;
    try {
      body = await _readBody(request);
    } on RequestTooLargeException {
      _respond(request, 413, {
        'error': 'Request body too large (limit ${maxRequestBodyBytes} bytes)',
      });
      return;
    } catch (_) {
      _respond(request, 400, {'error': 'Invalid request body'});
      return;
    }

    Map<String, dynamic> data;
    try {
      final decoded = jsonDecode(body);
      if (decoded is! Map<String, dynamic>) {
        throw const FormatException('expected a JSON object');
      }
      data = decoded;
    } catch (_) {
      _respond(request, 400, {'error': 'Invalid JSON'});
      return;
    }

    final source = data['source'];
    if (source is! String || source.isEmpty) {
      _respond(request, 400, {'error': 'Missing required field: source'});
      return;
    }

    final board = data['board'];
    if (board is! String || board.isEmpty) {
      _respond(request, 400, {'error': 'Missing required field: board'});
      return;
    }

    final format = data['format'];
    if (format != null && (format is! String || format != 'hex')) {
      _respond(request, 400, {'error': 'Unsupported format. Only "hex" is supported.'});
      return;
    }

    final result = await compiler.compile(source: source, boardId: board);

    final response = <String, dynamic>{
      'success': result.success,
      'firmware': result.firmwareBytes != null
          ? base64Encode(result.firmwareBytes!)
          : null,
      'firmwareSize': result.firmwareSize,
      'compilerVersion': result.compilerVersion,
      'output': result.output,
      'fqbn': result.fqbn,
      'errors': result.errors
          .map((e) => {
                'code': e.code,
                'severity': e.severity,
                'description': e.description,
                if (e.file != null) 'file': e.file,
                if (e.line != null) 'line': e.line,
              })
          .toList(),
      'warnings': result.warnings
          .map((w) => {
                'code': w.code,
                'severity': w.severity,
                'description': w.description,
                if (w.file != null) 'file': w.file,
                if (w.line != null) 'line': w.line,
              })
          .toList(),
    };

    _respond(request, 200, response);
  }

  Future<String> _readBody(HttpRequest request) async {
    final bytes = <int>[];
    var overLimit = false;
    await for (final chunk in request) {
      if (overLimit) continue; // drain + discard the rest of the request
      bytes.addAll(chunk);
      if (bytes.length > maxRequestBodyBytes) {
        overLimit = true;
        bytes.clear();
      }
    }
    if (overLimit) throw RequestTooLargeException();
    return utf8.decode(bytes, allowMalformed: true);
  }

  bool _isAuthorized(HttpRequest request) {
    final provided = request.headers.value(kApiKeyHeader);
    final expected = apiKey;
    if (provided == null || expected == null) return false;
    return _constantTimeEquals(provided, expected);
  }

  /// Constant-time string comparison to avoid leaking the key length/prefix
  /// through timing side channels.
  static bool _constantTimeEquals(String a, String b) {
    final aBytes = utf8.encode(a);
    final bBytes = utf8.encode(b);
    if (aBytes.length != bBytes.length) return false;
    var diff = 0;
    for (var i = 0; i < aBytes.length; i++) {
      diff |= aBytes[i] ^ bBytes[i];
    }
    return diff == 0;
  }

  void _addCorsHeaders(HttpResponse response) {
    response.headers.add('Access-Control-Allow-Origin', '*');
    response.headers.add('Access-Control-Allow-Methods', 'GET, POST, OPTIONS');
    response.headers.add('Access-Control-Allow-Headers', 'Content-Type, X-API-Key');
    response.headers.contentType = ContentType.json;
  }

  void _respond(HttpRequest request, int status, Map<String, dynamic> body) {
    request.response.statusCode = status;
    request.response.write(jsonEncode(body));
    request.response.close();
  }
}

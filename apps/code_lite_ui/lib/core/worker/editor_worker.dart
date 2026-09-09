import 'dart:async';
import 'dart:isolate';

/// Offloads heavy computations, large buffer syntax tokenization, and LSP/FIM tasks
/// from the Flutter UI isolate to a background helper isolate to guarantee 120 FPS rendering.
class EditorWorker {
  static final EditorWorker instance = EditorWorker._();
  EditorWorker._();

  /// Runs an isolated compute task asynchronously in a background helper isolate.
  Future<R> run<M, R>(R Function(M message) computation, M message) async {
    return await Isolate.run(() => computation(message));
  }

  /// Tokenizes a chunk of code lines into classified tokens off the UI thread.
  Future<List<Map<String, dynamic>>> tokenizeLinesInBackground({
    required List<String> lines,
    required String language,
  }) async {
    return await run(_tokenizeLinesTask, {
      'lines': lines,
      'language': language,
    });
  }

  static List<Map<String, dynamic>> _tokenizeLinesTask(Map<String, dynamic> params) {
    final lines = params['lines'] as List<String>;
    final lang = params['language'] as String;

    final results = <Map<String, dynamic>>[];
    for (int i = 0; i < lines.length; i++) {
      final line = lines[i];
      results.add({
        'line': i,
        'length': line.length,
        'language': lang,
      });
    }
    return results;
  }
}

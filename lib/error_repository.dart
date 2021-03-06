library atom.error_repository;

import 'dart:async';

import 'package:atom/node/fs.dart';
import 'package:atom/utils/disposable.dart';
import 'package:logging/logging.dart';

import 'package:analysis_server_lib/analysis_server_lib.dart'
    show AnalysisErrors, AnalysisError, AnalysisFlushResults;
import 'utils.dart';

final Logger _logger = new Logger('error_repository');

/// Repository of errors generated by `analysis.errors` events.
///
/// One-stop shop for getting the status of errors the analyzer has reported.
/// Source agonostic.
class ErrorRepository implements Disposable {
  static const List<AnalysisError> _emptyErrors = const [];

  /// A collection of all known errors that the analysis_server has provided us,
  /// organized by filename.
  final Map<String, List<AnalysisError>> knownErrors = {};

  final StreamSubscriptions subs = new StreamSubscriptions();

  StreamController _changeController = new StreamController.broadcast();
  Stream<AnalysisErrors> _errorStream;
  Stream<AnalysisFlushResults> _flushStream;

  ErrorRepository();

  Stream get onChange => _changeController.stream;

  void initStreams(Stream<AnalysisErrors> errorStream,
      Stream<AnalysisFlushResults> flushStream) {
    this._errorStream = errorStream;
    this._flushStream = flushStream;

    subs.cancel();

    subs.add(_errorStream.listen(_handleAddErrors));
    subs.add(_flushStream.listen(_handleFlushErrors));
  }

  /// Clear all known errors. This is useful for situations like when the
  /// analysis server goes down.
  void clearAll() {
    knownErrors.clear();
    _changeController.add(null);
  }

  /// Clear all errors for files contained within the given directory.
  void clearForDirectory(Directory dir) {
    List<String> paths = knownErrors.keys.toList();
    for (String path in paths) {
      if (dir.contains(path)) knownErrors.remove(path);
    }
  }

  List<AnalysisError> getForPath(String path) => knownErrors[path];

  void dispose() => subs.cancel();

  void _handleAddErrors(AnalysisErrors analysisErrors) {
    String path = analysisErrors.file;
    File file = new File.fromPath(path);

    // We use statSync() here and not file.isFile() as File.isFile() always
    // returns true.
    if (file.existsSync() && fs.statSync(path).isFile()) {
      var oldErrors = knownErrors[path];
      var newErrors = analysisErrors.errors;

      if (oldErrors == null) oldErrors = _emptyErrors;
      if (newErrors == null) newErrors = _emptyErrors;

      knownErrors[path] = analysisErrors.errors;

      if (!listIdentical(oldErrors, newErrors)) {
        _changeController.add(null);
      }
    } else {
      _logger.info('received an error event for a non-existent file: ${path}');
    }
  }

  void _handleFlushErrors(AnalysisFlushResults analysisFlushResults) {
    analysisFlushResults.files.forEach(knownErrors.remove);
    _changeController.add(null);
  }
}

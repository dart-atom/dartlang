library atom.chrome_debugger;

import 'dart:async';
import 'dart:html' show HttpRequest;

import 'package:atom/atom.dart';
import 'package:atom/node/fs.dart' as fs;
import 'package:atom/node/process.dart';
import 'package:atom/utils/disposable.dart';
import 'package:logging/logging.dart';
import 'package:source_maps/source_maps.dart';
import 'package:source_maps/src/utils.dart';
import 'package:source_span/source_span.dart';

import '../launch/launch.dart';
import '../state.dart';
import 'breakpoints.dart';
import 'chrome.dart';
import 'debugger.dart';
import 'model.dart';

final Logger _logger = new Logger('atom.chrome');

const _verbose = false;

// TODO figure out how to set breakpoints them without needing a restart
// calling pause/resume ?
// TODO on restart, should we remove all breakpoints and reset them?
// TODO put up message when pausing (running -> waiting to pause)
// TODO restore expanded/focus state of variables panel
// TODO (same for outline panel)
// TODO tooltips observation of variables
// TODO investigate why debug launch gets closed properly when restarting
//   but not serve launch

class ChromeDebugger {
  /// Establish a connection to a service protocol server at the given port.
  static Future<DebugConnection> connect(Launch launch, LaunchConfiguration configuration,
    String debugHost, String root, String htmlFile) {
    var cdp = new ChromeDebuggingProtocol();
    int maxTries = 6;
    return Future.doWhile(() {
      if (maxTries-- == 0) {
        atom.notifications.addWarning("Coudn't connect to debugger at '$debugHost'.");
        return false;
      }
      return cdp.connect(host: debugHost).then((client) {
        return Future.wait([
            client.debugger.enable(),
            client.page.enable(),
            client.runtime.enable()
          ]).then((_) {
          String fullPath =
              '${configuration.projectPath}/${configuration.shortResourceName}';
          UriResolver uriResolver = new UriResolver(root,
              translator: new WebUriTranslator(fs.fs.dirname(fullPath),
                  prefix: '${Uri.parse(root)}/'),
              selfRefName: launch.project?.getSelfRefName());

          ChromeConnection connection = new ChromeConnection(launch, client, uriResolver);
          return client.page.navigate('$root/$htmlFile').then((s) {
            launch.addDebugConnection(connection);
            launch.pipeStdio('Launched ($s)\n');
            return false;
          });
        });
      }).catchError((e) {
        launch.pipeStdio('Launched failed, retrying\n');
        return new Future.delayed(new Duration(seconds: 1)).then((_) => true);
      });
    });
  }
}

class ChromeConnection extends DebugConnection {
  final Completer completer;

  ChromeDebugIsolate _isolate;

  StreamController<DebugIsolate> _isolatePaused = new StreamController.broadcast();
  StreamController<DebugIsolate> _isolateResumed = new StreamController.broadcast();

  StreamSubscriptions subs = new StreamSubscriptions();

  ChromeDebugConnection chrome;
  UriResolver uriResolver;

  Map<String, ScriptParsed> scripts = {};
  Map<String, Future<Mapping>> loadinMaps = {};
  Map<String, Mapping> maps = {};
  Map<String, Mapping> reversedMaps = {};

  bool isPaused = false;

  ChromeConnection(Launch launch, this.chrome, this.uriResolver)
      : completer = new Completer(),
        super(launch) {
    launch.manager.onLaunchTerminated.listen((launch) {
      if (launch == this.launch) completer.complete();
    });

    chrome.debugger.scriptParsed((script) {
      if (script.url == null || script.url.isEmpty) return;
      launch.pipeStdio('Script Parsed: ${script.url}\n');
      scripts[script.scriptId] = script;
      // TODO: should we use script.sourceMapURL (which isn't a full url, but just
      // the filename with .map tagged onto it)
      if (script.sourceMapURL != null && script.sourceMapURL.isNotEmpty) {
        // start load source map
        loadinMaps.putIfAbsent(script.scriptId, () {
          launch.pipeStdio('  fetching ${script.url}.map\n');
          return HttpRequest.getString('${script.url}.map')
            .then((text) => parse(text))
            .then((map) {
              launch.pipeStdio('    parsing ${script.url}.map\n');
              maps[script.scriptId] = map;
              // create reverse map into separate  for each .dart targets.
              createReverseMaps(script.url, map);
              return installBreakpoints().then((_) => map);
            })
            .catchError((e) {
              launch.pipeStdio(
                  '    error fetching or parsing ${script.url}.map\n'
                  '      $e\n');
            });
        });
      }
    });
    chrome.debugger.scriptFailedToParse((script) {
      if (script.url == null || script.url.isEmpty) return;
      launch.pipeStdio('Script Parsed Failed: ${script.url}\n');
    });
    chrome.debugger.breakpointResolved((bkpt) {
      launch.pipeStdio('Bkpt Resolved: $bkpt\n');
      // TODO add to breakpoints lists
    });

    chrome.debugger.paused((paused) {
      launch.pipeStdio('Pausing.');
      isPaused = true;
      _isolate = new ChromeDebugIsolate(this, this.chrome, paused);
      _isolatePaused.add(_isolate);
    });

    subs.add(breakpointManager.onAdd.listen(addBreakpoint));
    subs.add(breakpointManager.onRemove.listen(removeBreakpoint));
  }

  void createReverseMaps(String sourceUrl, Mapping map) {
    if (map is SingleMapping) {
      // Create reverse maps
      // TODO: rewrite for efficiency, creating forward and reverse mappings
      // as we read original map.
      Map<String, List<Entry>> entries = {};
      for (var line in map.lines) {
        if (line.entries == null) continue;
        for (var entry in line.entries) {
          if (entry.sourceUrlId == null || entry.sourceUrlId < 0) continue;
          String destinationUrl = map.urls[entry.sourceUrlId];
          Entry e = new Entry(
              new RevSourceLocation(entry.column, line.line, sourceUrl),
              new RevSourceLocation(entry.sourceColumn, entry.sourceLine, destinationUrl),
              entry.sourceNameId != null && entry.sourceNameId >= 0
                  ? map.names[entry.sourceNameId] : null);
          entries.putIfAbsent(destinationUrl, () => []).add(e);
        }
      }
      entries.forEach((k, v) {
        if (!k.startsWith('http')) {
          Uri src = Uri.parse(sourceUrl);
          List<String> pathSegments = new List.from(src.pathSegments);
          pathSegments..removeLast()..add(k);
          k = src.replace(pathSegments: pathSegments).toString();
        }
        launch.pipeStdio('      Adding reverse map for $k -> $sourceUrl\n');
        reversedMaps[k] = new SingleMapping.fromEntries(v, k);
      });
    }
  }

  Map<AtomBreakpoint, List<Breakpoint>> breakpoints = {};

  Future addBreakpoint(AtomBreakpoint atomBreakpoint) {
    return uriResolver.resolvePathToUris(atomBreakpoint.path).then((List<String> uris) {
      launch.pipeStdio('Set breakpoint for: $atomBreakpoint\n  $uris\n');
      return Future.forEach(uris, (String uri) {
        Mapping m = reversedMaps[uri];
        launch.pipeStdio('Set breakpoint for: $uri\n');
        if (m == null) return new Future.value();

        SourceMapSpan span = SingleMappingProxy.spanFor(m, atomBreakpoint.line - 1, atomBreakpoint.column ?? 0);
        if (span == null) return new Future.value();

        return setBreakpointByUrl(span.sourceUrl.toString(), span.start.line, span.start.column)
            .then((Breakpoint chromeBreakpoint) {
              launch.pipeStdio('  Set breakpoint: $chromeBreakpoint\n');
              if (chromeBreakpoint == null) return;
              breakpoints.putIfAbsent(atomBreakpoint, () => []).add(chromeBreakpoint);
            }).catchError((e) {
              launch.pipeStdio('  Fail to set breakpoint: $atomBreakpoint\n');
            });
      });
    }).catchError((e) {
      launch.pipeStdio(
          '  Error resolving uri: ${atomBreakpoint.path}\n'
          '    ${e}\n');
    });
  }

  Future removeBreakpoint(AtomBreakpoint atomBreakpoint) {
    List<Breakpoint> bkpts = breakpoints.remove(atomBreakpoint);
    if (bkpts != null) {
      return Future.forEach(bkpts, (Breakpoint breakpoint) {
        return chrome.debugger.removeBreakpoint(breakpoint.breakpointId)
            .catchError((e) {
          launch.pipeStdio('Error removing breakpoint:\n  $e\n');
        });
      });
    }
    return new Future.value();
  }

  Future installBreakpoints() {
    return Future.forEach(breakpointManager.breakpoints, (AtomBreakpoint atomBreakpoint) {
      if (breakpoints[atomBreakpoint] != null || !atomBreakpoint.fileExists()) {
        return null;
      }
      return addBreakpoint(atomBreakpoint);
    });
  }

  Future setBreakpointByUrl(String url, int line, int column) {
    return chrome.debugger.setBreakpointByUrl(line, url: url, columnNumber: column)
        .then((bk) {
      launch.pipeStdio('Breakpoint added: $bk\n');
      return bk;
    }).catchError((e) {
      launch.pipeStdio('Breakpoint not added: $url($line,$column)\n  $e\n');
    });
  }

  void dispose() {
    subs.cancel();
    if (isAlive) terminate();
    chrome.close();
    uriResolver.dispose();
  }

  bool get isAlive => launch.isRunning;

  Stream<DebugIsolate> get onPaused => _isolatePaused.stream;
  Stream<DebugIsolate> get onResumed => _isolateResumed.stream;

  Future get onTerminated => completer.future;

  Future resume() {
    return chrome.debugger.resume().then((_) {
      isPaused = false;
      _isolateResumed.add(_isolate);
    });
  }

  stepIn() {
    if (isPaused) {
      isPaused = false;
      chrome.debugger.stepInto();
    }
  }
  stepOut() {
    if (isPaused) {
      isPaused = false;
      chrome.debugger.stepOut();
    }
  }
  stepOver() {
    if (isPaused) {
      isPaused = false;
      chrome.debugger.stepOver();
    }
  }

  autoStepOver() => stepOver();

  // TODO: do we need this?
  stepOverAsyncSuspension() {}

  Future terminate() => launch.kill();
}

class RevSourceLocation extends SourceLocation {
  RevSourceLocation(int column, int line, sourceUrl)
      : super(column, sourceUrl: sourceUrl, line: line);

  int compareTo(SourceLocation other) {
    int to = line - other.line;
    if (to == 0) to = column - other.column;
    return to;
  }
}

class SingleMappingProxy {
  /// Proxies SingleMapping and returns first span of a line if we
  /// don't know the column.
  ///
  /// Makes sense for reverse maps, because Atom doesn't have a column
  /// for the breakpoint.
  static SourceMapSpan spanFor(SingleMapping proxy, int line, int column,
      {Map<String, SourceFile> files, String uri}) {
    var entry = _findColumn(line, column, _findLine(proxy.lines, line));
    if (entry == null || entry.sourceUrlId == null) return null;
    return proxy.spanFor(line, entry.column, files: files, uri: uri);
  }

  static TargetEntry _findColumn(int line, int column, TargetLineEntry lineEntry) {
    if (lineEntry == null || lineEntry.entries.length == 0) return null;
    if (lineEntry.line != line) return lineEntry.entries.last;
    var entries = lineEntry.entries;
    int index = binarySearch(entries, (e) => e.column > column);
    return (index <= 0) ? entries.first : entries[index - 1];
  }

  static TargetLineEntry _findLine(List<TargetLineEntry> lines, int line) {
    int index = binarySearch(lines, (e) => e.line > line);
    return (index <= 0) ? null : lines[index - 1];
  }
}

class ChromeDebugIsolate extends DebugIsolate {
  final ChromeConnection connection;
  final ChromeDebugConnection chrome;
  final Paused paused;

  ChromeDebugIsolate(this.connection, this.chrome, this.paused) : super();

  // TODO: Web workers?
  String get name => 'main';

  /// Return a more human readable name for the Isolate.
  String get displayName => name;

  String get detail => paused.reason;

  bool get suspended => connection.isPaused;

  bool get hasFrames => frames != null && frames.isNotEmpty;

  List<DebugFrame> get frames =>
      paused.callFrames.map((frame) =>
          new ChromeDebugFrame(connection, frame)).toList();

  pause() => chrome.debugger.pause();

  Future resume() => connection.resume();
  stepIn() => connection.stepIn();
  stepOver() => connection.stepOver();
  stepOut() => connection.stepOut();
  stepOverAsyncSuspension() => connection.stepOverAsyncSuspension();
  autoStepOver() => connection.autoStepOver();
}

class ChromeDebugFrame extends DebugFrame {
  final ChromeConnection connection;
  final CallFrame frame;

  List<DebugVariable> _locals;

  String get title =>
      frame.functionName != null && frame.functionName.isNotEmpty
          ? frame.functionName : 'anonymous';

  bool get isSystem => false;
  bool get isExceptionFrame => false;

  List<DebugVariable> get locals => _locals;

  DebugLocation get location =>
      new ChromeDebugLocation(connection, frame.location);

  ChromeDebugFrame(this.connection, this.frame) : super();

  Future<List<DebugVariable>> resolveLocals() {
    if (!connection.isPaused) return new Future.value([]);
    _logger.info('Getting frame locals: ${frame.self}');
    return connection.chrome.runtime.getProperties(frame.self.objectId,
        ownProperties: true,
        accessorPropertiesOnly: false,
        generatePreview: true).then((properties) {
      _locals = [];
      properties.result.where((p) => p.isUseable).forEach((property) {
        _locals.add(new ChromeDebugVariable(connection, property));
      });
      // TODO make scopes more identifiable
      for (var property in frame.scopeChain) {
        _locals.add(new ChromeScope(connection, property));
      }
      // TODO add exceptionDetails
      properties.internalProperties.where((p) => p.isUseable).forEach((property) {
        _locals.add(new ChromeDebugVariable(connection, property));
      });
      return _locals;
    });
  }


  Future<String> eval(String expression) {
    // TODO (enable expression tab)
    return new Future.value();
  }
}

class ChromeScope extends DebugVariable {
  final ChromeConnection connection;
  final Scope scope;
  ChromeScopeValue _value;

  String get name => scope.name ?? scope.type;
  DebugValue get value => _value ??= new ChromeScopeValue(connection, scope.object);

  ChromeScope(this.connection, this.scope);
}

class ChromeScopeValue extends DebugValue {
  final ChromeConnection connection;
  final RemoteObject value;

  List<DebugVariable> _variables;

  String get className => value == null
      ? 'Null' : (value?.className ?? '${value.type}.${value.subtype}');

  String get valueAsString => value == null
      ? 'null' : value.description ?? value.unserializableValue;

  bool get isPrimitive =>  false;
  bool get isString => false;
  bool get isPlainInstance => false;
  bool get isList => false;
  bool get isMap => true;

  bool get valueIsTruncated => false;

  int get itemsLength => _variables?.length;

  ChromeScopeValue(this.connection, this.value);

  Future<List<DebugVariable>> getChildren() {
    if (!connection.isPaused) return new Future.value([]);
    _logger.info('Getting scope: ${value}');
    return connection.chrome.runtime.getProperties(value.objectId,
        ownProperties: true,
        accessorPropertiesOnly: false,
        generatePreview: true).then((properties) {
      _variables = [];
      properties.result.where((p) => p.isUseable).forEach((property) {
        _variables.add(new ChromeDebugVariable(connection, property));
      });
      properties.internalProperties.where((p) => p.isUseable).forEach((property) {
        _variables.add(new ChromeDebugVariable(connection, property));
      });
      // TODO add exceptionDetails
      return _variables;
    });
  }

  Future<DebugValue> invokeToString() => new Future.value(this);
}

class ChromeDebugVariable extends DebugVariable {
  final ChromeConnection connection;
  final PropertyDescriptor property;
  ChromeDebugValue _value;

  String get name => property.name;
  DebugValue get value => _value ??= new ChromeDebugValue(connection, property.value);

  ChromeDebugVariable(this.connection, this.property);
}

class ChromeDebugValue extends DebugValue {
  final ChromeConnection connection;
  final RemoteObject value;

  List<DebugVariable> _variables;

  String get className => value == null
      ? 'Null' : (value?.className ?? "${value.type}.${value.subtype}");

  String get valueAsString {
    return value == null ? 'null'
        : value.description ?? value.unserializableValue;
  }

  // TODO
  bool get isString => false;
  bool get isPlainInstance => false;

  bool get isPrimitive => !isList && !isMap;
  bool get isList => value?.subtype == 'array' && value?.objectId != null;
  bool get isMap => !isList && value.type == 'object' && value?.objectId != null;

  bool get valueIsTruncated => false;

  // TODO fix debugger_ui.dart to update the tree with [itemsLength] after
  // get children.  Consider renaming to hint and as a string.
  int get itemsLength => null;

  // Warning: value can be null.
  ChromeDebugValue(this.connection, this.value);

  Future<List<DebugVariable>> getChildren() {
    if (!connection.isPaused) return new Future.value([]);
    _logger.info('Getting children: ${value}');
    return connection.chrome.runtime.getProperties(value.objectId,
        ownProperties: true,
        accessorPropertiesOnly: false,
        generatePreview: true).then((properties) {
      _variables = [];
      properties.result.where((p) => p.isUseable).forEach((property) {
        _variables.add(new ChromeDebugVariable(connection, property));
      });
      return _variables;
    });
  }

  // TODO needed for longer details, needs valueAsString + valueIsTruncated
  Future<DebugValue> invokeToString() => new Future.value(this);
}

class ChromeDebugLocation extends DebugLocation {
  final ChromeConnection connection;
  final Location location;

  SourceMapSpan _span;
  String _resolvedPath;

  /// A file path.
  String get path => _resolvedPath ?? displayPath;

  /// 1-based line number.
  int get line => _span == null ? 0 : _span.start.line + 1;

  /// 1-based column number.
  int get column => _span == null ? 0 : _span.start.column + 1;

  /// A display file path.
  String get displayPath => _span == null
      ? connection.scripts[location.scriptId]?.url
      : _span.start.sourceUrl.toString();

  bool resolved = false;

  ChromeDebugLocation(this.connection, this.location) {
    _span = connection.maps[location.scriptId]?.spanFor(location.lineNumber, location.columnNumber);
    if (_span != null) _resolvePath();
  }

  Future<DebugLocation> resolve() {
    // TOOD catch error and don't try again
    if (_span == null && connection.loadinMaps[location.scriptId] != null) {
      return connection.loadinMaps[location.scriptId].then((map) {
        _span = map.spanFor(location.lineNumber, location.columnNumber);
        return _resolvePath().then((_) => this);
      });
    }
    return new Future.value(this);
  }

  Future _resolvePath() {
    if (_span?.start?.sourceUrl != null) {
      return connection.uriResolver.resolveUriToPath(_span.start.sourceUrl.toString())
          .then((path) {
        _resolvedPath = path;
        resolved = true;
      }).catchError((e) {
        _logger.warning('Failed to resolve: ${_span.start.sourceUrl}');
      });
    }
    return new Future.value(this);
  }
}

class WebUriTranslator implements UriTranslator {
  static const _packagesPrefix = 'packages/';
  static const _packagePrefix = 'package:';

  final String root;
  final String prefix;

  String _rootPrefix;

  WebUriTranslator(this.root, {this.prefix: 'http://localhost:8081/'}) {
    _rootPrefix = new Uri.directory(root, windows: isWindows).toString();
  }

  String targetToClient(String str) {
    String result = _targetToClient(str);
    _logger.finer('targetToClient ${str} ==> ${result}');
    return result;
  }

  String _targetToClient(String str) {
    if (str.startsWith(prefix)) {
      str = str.substring(prefix.length);

      if (str.startsWith(_packagesPrefix)) {
        // Convert packages/ prefix to package: one.
        return _packagePrefix + str.substring(_packagesPrefix.length);
      } else {
        // Return files relative to the starting project.
        return '${_rootPrefix}${str}';
      }
    } else {
      return '${_rootPrefix}${str}';
    }
  }

  String clientToTarget(String str) {
    String result = _clientToTarget(str);
    _logger.finer('clientToTarget ${str} ==> ${result}');
    return result;
  }

  String _clientToTarget(String str) {
    if (str.startsWith(_packagePrefix)) {
      // Convert package: prefix to packages/ one.
      return prefix + _packagesPrefix + str.substring(_packagePrefix.length);
    } else if (str.startsWith(_rootPrefix)) {
      // Convert file:///foo/bar/lib/main.dart to http://.../lib/main.dart.
      return prefix + str.substring(_rootPrefix.length);
    } else {
      return str;
    }
  }
}
library atom.changelog;

import 'dart:async';
import 'dart:html' show HttpRequest;

import 'package:logging/logging.dart';
import 'package:pub_semver/pub_semver.dart';

import '../atom.dart';
import '../atom_utils.dart';
import '../utils.dart';

final Logger _logger = new Logger('changelog');

checkChangelog() => getPackageVersion().then(_checkChangelog);

class ChangelogManager implements Disposable {
  Disposables disposables = new Disposables();

  File _changeLogFile;

  ChangelogManager() {
    disposables.add(atom.commands.add('atom-workspace', 'dartlang:release-notes', (_) {
      _handleReleaseNotes();
    }));
    disposables.add(atom.commands.add('atom-workspace', 'dartlang:getting-started', (_) {
      _handleGettingStarted();
    }));
  }

  void _handleReleaseNotes() {
    Future<File> f;

    if (_changeLogFile != null) {
      f = new Future.value(_changeLogFile);
    } else {
      f = HttpRequest
          .getString('atom://dartlang/CHANGELOG.md')
          .then((contents) {
        Directory dir = new Directory.fromPath(tmpdir());
        _changeLogFile = dir.getFile('CHANGELOG.md');
        _changeLogFile.writeSync(contents);
        return _changeLogFile;
      });
    }

    f.then((File file) {
      atom.workspace.open(file.path, options: {'split': 'right'});
    });
  }

  void _handleGettingStarted() {
    shell.openExternal(
        'https://github.com/dart-atom/dartlang/blob/master/doc/getting_started.md');
  }

  void dispose() => disposables.dispose();
}

void _checkChangelog(String currentVersion) {
  String lastVersion = atom.config.getValue('_dartlang._version');
  atom.config.setValue('_dartlang._version', currentVersion);

  if (lastVersion != currentVersion) {
    _logger.info("upgraded from ${lastVersion} to ${currentVersion}");

    HttpRequest.getString('atom://dartlang/CHANGELOG.md').then((str) {
      String changes;
      if (lastVersion != null) {
        changes = _extractVersion(str, lastVersion, inclusive: false);
      } else {
        changes = _extractVersion(str, currentVersion, inclusive: true);
      }
      if (changes != null && changes.isNotEmpty) {
        atom.notifications.addSuccess(
            'Upgraded to dartlang plugin version ${currentVersion}.',
            description: changes,
            dismissable: true);
      }
    });
  }
}

String _extractVersion(String changelog, String last, {bool inclusive: true}) {
  Version lastVersion = new Version.parse(last);
  List<String> changes = changelog.split('\n');
  Iterable itor = changes.skipWhile((line) => !line.startsWith('##'));
  changes = itor.takeWhile((line) {
    if (line.startsWith('## ')) {
      try {
        line = line.substring(3);
        Version ver = new Version.parse(line);
        if (inclusive) return ver >= lastVersion;
        return ver > lastVersion;
      } catch (_) {
        return true;
      }
    }
    return true;
  }).toList();
  return changes.join('\n').trim();
}

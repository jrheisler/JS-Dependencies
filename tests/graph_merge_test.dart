import '../lib/nurox_view.dart';

void main() {
  final graph = Graph();
  graph.addGraph({
    'nodes': [
      {
        'id': 'C:/repo/src/a.js',
        'type': 'file',
        'state': 'used',
        'absPath': 'C:/repo/src/a.js',
      }
    ],
    'edges': const [],
    'securityFindings': {
      'C:/repo/src/a.js': [
        {
          'id': 'rule.eval',
          'message': 'Use of eval()',
          'severity': 'high',
          'line': 12,
        }
      ]
    }
  });

  graph.addGraph({
    'nodes': [
      {
        'id': r'C:\\repo\\src\\a.js',
        'type': 'file',
        'state': 'used',
        'absPath': r'C:\\repo\\src\\a.js',
      }
    ],
    'edges': const [],
    'securityFindings': {
      r'C:\\repo\\src\\a.js': [
        {
          'id': 'rule.exec',
          'message': 'child_process exec',
          'severity': 'high',
          'line': 30,
        }
      ]
    }
  });

  graph.addGraph({
    'exports': {
      r'C:\\repo\\src\\a.js': {
        'exports': [
          {'name': 'alpha', 'kind': 'function'}
        ]
      }
    }
  });

  graph.addGraph({
    'exports': {
      'C:/repo/src/a.js': {
        'reexports': [
          {'name': 'beta', 'from': 'pkg.module'}
        ]
      }
    }
  });

  graph.addGraph({
    'entrypoints': ['C:/repo/src/a.js'],
    'entries': [
      {'id': 'C:/repo/src/b.js'},
      'C:/repo/src/c.js'
    ]
  });

  final merged = graph.toJson();
  final security = merged['securityFindings'] as Map<String, dynamic>?;
  assert(security != null && security!.isNotEmpty, 'security findings should be preserved');

  final key = 'C:/repo/src/a.js';
  final findings = security![key] as List<dynamic>?;
  assert(findings != null && findings!.length == 2, 'both findings should merge on canonical path');

  final ids = findings!.map((item) => (item as Map<String, dynamic>)['id']).toSet();
  assert(ids.contains('rule.eval') && ids.contains('rule.exec'));

  final exports = merged['exports'] as Map<String, dynamic>?;
  assert(exports != null && exports!.containsKey(key), 'exports should merge on canonical path');
  final exportGroups = exports![key] as Map<String, dynamic>;
  final named = exportGroups['exports'] as List<dynamic>?;
  final reexports = exportGroups['reexports'] as List<dynamic>?;
  assert(named != null && named.length == 1 && (named.first as Map)['name'] == 'alpha');
  assert(reexports != null && reexports.length == 1 && (reexports.first as Map)['name'] == 'beta');

  final entrypoints = merged['entrypoints'] as List<dynamic>?;
  assert(entrypoints != null && entrypoints!.length == 3, 'entrypoints should merge from multiple keys');
  final entrySet = entrypoints!.toSet();
  assert(entrySet.contains('C:/repo/src/a.js'));
  assert(entrySet.contains('C:/repo/src/b.js'));
  assert(entrySet.contains('C:/repo/src/c.js'));
}

const assert = require('assert');
const fs = require('fs');
const path = require('path');
const vm = require('vm');

function loadGraphPreprocessing(){
  const filePath = path.join(__dirname, '..', 'public', 'js', 'graph-preprocessing.js');
  const source = fs.readFileSync(filePath, 'utf8');
  const sandbox = { console };
  sandbox.self = sandbox;
  sandbox.window = sandbox;
  sandbox.globalThis = sandbox;
  sandbox.setTimeout = function(){};
  sandbox.clearTimeout = function(){};
  vm.runInNewContext(source, sandbox, { filename: 'graph-preprocessing.js' });
  return sandbox.GraphPreprocessing || sandbox.self.GraphPreprocessing || sandbox.window.GraphPreprocessing;
}

const GraphPreprocessing = loadGraphPreprocessing();
const { preprocessGraph, helpers } = GraphPreprocessing;

function test(name, fn){
  try {
    fn();
    console.log(`✔ ${name}`);
  } catch (error){
    console.error(`✘ ${name}`);
    console.error(error);
    throw error;
  }
}

test('merges node and referenced security findings without overwriting', () => {
  const rawGraph = {
    nodes: [
      {
        id: 'src/fileA.js',
        securityFindings: [
          { id: 'existing', message: 'local finding', severity: 'low', severityNormalized: 'low', line: 12 }
        ]
      }
    ],
    securityFindings: {
      'src/fileA.js': [
        { id: 'existing', message: 'local finding', severity: 'low', severityNormalized: 'low', line: 12 },
        { id: 'global', message: 'global finding', severity: 'high', severityNormalized: 'high', code: 'SEC001' }
      ]
    }
  };

  const result = preprocessGraph({ rawGraph });
  const node = result.graph.nodes.find(n => n.id === 'src/fileA.js');
  assert(node, 'expected node in result');
  assert(Array.isArray(node.securityFindings), 'security findings should be array');
  assert.strictEqual(node.securityFindings.length, 2, 'security findings should merge without duplication');
  const messages = new Set(node.securityFindings.map(item => item.message));
  assert(messages.has('global finding'), 'should include global finding');
  assert(messages.has('local finding'), 'should include local finding');
});

test('resolves canonical IDs so security findings survive normalization', () => {
  const rawGraph = {
    nodes: [
      {
        id: 'module-a',
        meta: {
          realPath: 'C:/app/src/index.js'
        }
      }
    ],
    securityFindings: {
      'c:\\\\app\\\\src\\\\index.js': [
        { id: 'canonical', message: 'canonical finding', severity: 'medium', severityNormalized: 'med' }
      ]
    }
  };

  const result = preprocessGraph({ rawGraph });
  const node = result.graph.nodes.find(n => n.id === 'module-a');
  assert(node, 'expected node in result');
  assert(Array.isArray(node.securityFindings), 'security findings should exist');
  assert.strictEqual(node.securityFindings.length, 1, 'should attach canonical finding');
  assert.strictEqual(node.securityFindings[0].message, 'canonical finding');
});

test('collectNodeSecurityFindings handles nested sources', () => {
  const node = {
    security: {
      findings: [
        { id: 'dup', message: 'duplicate finding', severity: 'critical', severityNormalized: 'critical' },
        { id: 'dup', message: 'duplicate finding', severity: 'critical', severityNormalized: 'critical' }
      ]
    },
    meta: {
      security: {
        findings: [
          { id: 'meta', message: 'meta finding', severity: 'info' }
        ]
      }
    }
  };

  const collected = helpers.collectNodeSecurityFindings(node);
  assert(Array.isArray(collected), 'collected findings should be an array');
  const merged = helpers.mergeSecurityFindingLists(collected);
  assert.strictEqual(merged.length, 2, 'duplicates should collapse after merge');
  const ids = new Set(merged.map(item => item.id));
  assert(ids.has('dup'), 'should include duplicate id after merge');
  assert(ids.has('meta'), 'should include meta id after merge');
});

test('ingests security findings from array entries and direct records', () => {
  const rawGraph = {
    nodes: [
      { id: 'src/alpha.js' },
      { id: 'src/beta.js' }
    ],
    securityFindings: [
      {
        path: 'src/alpha.js',
        findings: [
          { id: 'rule.alpha', message: 'alpha issue', severity: 'high', line: 10 }
        ]
      },
      {
        source: 'src/beta.js',
        id: 'rule.beta',
        message: 'beta issue',
        severity: 'low',
        line: 42
      }
    ]
  };

  const result = preprocessGraph({ rawGraph });
  const alpha = result.graph.nodes.find(n => n.id === 'src/alpha.js');
  const beta = result.graph.nodes.find(n => n.id === 'src/beta.js');

  assert(alpha && beta, 'expected both nodes present');
  assert.strictEqual(alpha.securityFindings.length, 1, 'alpha finding should attach');
  assert.strictEqual(alpha.securityFindings[0].id, 'rule.alpha');
  assert.strictEqual(beta.securityFindings.length, 1, 'beta finding should attach');
  assert.strictEqual(beta.securityFindings[0].id, 'rule.beta');

  assert.strictEqual(result.summary.security.totalFindings, 2, 'summary should count total findings');
  assert.strictEqual(result.summary.security.affectedNodes, 2, 'summary should count affected nodes');
});

test('exports survive repeated preprocessing on same payload', () => {
  const rawGraph = {
    nodes: [
      { id: 'src/foo.js' }
    ],
    exports: {
      'src/foo.js': {
        named: ['alpha'],
        functions: ['beta']
      }
    }
  };

  const first = preprocessGraph({ rawGraph });
  const firstNode = first.graph.nodes.find(n => n.id === 'src/foo.js');
  assert(firstNode, 'expected node in first result');
  assert(firstNode.exports, 'expected exports on first pass');
  assert(Array.isArray(firstNode.exports.named), 'named exports should be array');
  assert(Array.isArray(firstNode.exports.functions), 'function exports should be array');
  assert.strictEqual(firstNode.exports.named.length, 1, 'expected one named export');
  assert.strictEqual(firstNode.exports.functions.length, 1, 'expected one function export');
  assert.strictEqual(firstNode.exports.named[0], 'alpha');
  assert.strictEqual(firstNode.exports.functions[0], 'beta');

  const second = preprocessGraph({ rawGraph });
  const secondNode = second.graph.nodes.find(n => n.id === 'src/foo.js');
  assert(secondNode, 'expected node in second result');
  assert(secondNode.exports, 'expected exports on second pass');
  assert(Array.isArray(secondNode.exports.named), 'named exports should persist as array');
  assert(Array.isArray(secondNode.exports.functions), 'function exports should persist as array');
  assert.strictEqual(secondNode.exports.named.length, 1, 'expected one named export after second pass');
  assert.strictEqual(secondNode.exports.functions.length, 1, 'expected one function export after second pass');
  assert.strictEqual(secondNode.exports.named[0], 'alpha');
  assert.strictEqual(secondNode.exports.functions[0], 'beta');
});

test('normalizeEntrypoints understands entries field', () => {
  const rawGraph = {
    nodes: [
      { id: 'lib/main.dart' },
      { id: 'lib/cli.dart' }
    ],
    entries: ['lib/main.dart', { id: 'lib/cli.dart' }]
  };

  const result = preprocessGraph({ rawGraph });
  assert(Array.isArray(result.entrypoints), 'entrypoints should be an array');
  assert.strictEqual(result.entrypoints.length, 2, 'should capture both entrypoints');
  assert(result.entrypoints.includes('lib/main.dart'));
  assert(result.entrypoints.includes('lib/cli.dart'));
});

console.log('All GraphPreprocessing tests passed.');

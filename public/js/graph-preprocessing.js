(function(global){
  'use strict';

  const nodeId = (ref) => (ref && typeof ref === 'object') ? ref.id : ref;

  function computeDegrees(graph){
    const idMap = new Map(graph.nodes.map(node => [node.id, node]));
    graph.nodes.forEach(node => {
      node.inDeg = 0;
      node.outDeg = 0;
    });
    graph.edges.forEach(edge => {
      const src = nodeId(edge.source);
      const tgt = nodeId(edge.target);
      if(idMap.has(src)) idMap.get(src).outDeg += 1;
      if(idMap.has(tgt)) idMap.get(tgt).inDeg += 1;
    });
  }

  function inferUsageStates(graph){
    const fileNodes = graph.nodes.filter(node => (node.type || 'file') === 'file');
    const hasFileUsage = fileNodes.some(node => node.state && node.state !== 'unused');
    if(hasFileUsage || fileNodes.length === 0) return;

    const idMap = new Map(graph.nodes.map(node => [node.id, node]));
    const adjacency = new Map();
    graph.edges.forEach(edge => {
      const src = nodeId(edge.source);
      const tgt = nodeId(edge.target);
      if(!idMap.has(src) || !idMap.has(tgt)) return;
      if(!adjacency.has(src)) adjacency.set(src, new Set());
      adjacency.get(src).add(tgt);
    });

    const seeds = new Set();
    fileNodes.forEach(node => { if(node.hasSideEffects) seeds.add(node.id); });
    graph.edges.forEach(edge => {
      if(edge.kind === 'side_effect'){
        const tgt = nodeId(edge.target);
        if(idMap.has(tgt)) seeds.add(tgt);
      }
    });

    if(seeds.size === 0){
      fileNodes.forEach(node => {
        const inDeg = node.inDeg || 0;
        const outDeg = node.outDeg || 0;
        if(inDeg === 0 && outDeg > 0) seeds.add(node.id);
      });
    }

    const used = new Set();
    const queue = Array.from(seeds);
    while(queue.length){
      const id = queue.shift();
      if(used.has(id)) continue;
      used.add(id);
      const next = adjacency.get(id);
      if(!next) continue;
      next.forEach(nid => {
        if(!idMap.has(nid)) return;
        const neighbor = idMap.get(nid);
        if((neighbor.type || 'file') === 'file' && !used.has(nid)) queue.push(nid);
      });
    }

    graph.nodes.forEach(node => {
      if((node.type || 'file') !== 'file') return;
      if(used.has(node.id)){
        const fanOut = adjacency.get(node.id);
        const hasFanOut = fanOut && fanOut.size > 0;
        if(node.hasSideEffects && (node.inDeg || 0) === 0 && !hasFanOut){
          node.state = 'side_effect_only';
        } else {
          node.state = 'used';
        }
      } else if(node.hasSideEffects){
        node.state = 'side_effect_only';
      } else {
        node.state = 'unused';
      }
    });
  }

  function edgeTypeString(edge){
    return String(edge?.type || edge?.kind || edge?.mode || '').toLowerCase();
  }

  function isDeferredEdge(edge){
    if(!edge) return false;
    if(edge.deferred === true || edge.lazy === true || edge.loading === 'deferred') return true;
    const t = edgeTypeString(edge);
    return t.includes('defer') || t.includes('lazy');
  }

  function isDynamicEdge(edge){
    if(!edge) return false;
    if(edge.dynamic === true || edge.reflection === true) return true;
    if(edge.certainty === 'heuristic' || edge.mode === 'runtime_dynamic') return true;
    const t = edgeTypeString(edge);
    return t.includes('dynamic') || t.includes('require.ensure') || t.includes('eval');
  }

  function edgePhase(edge){
    if(!edge) return 'runtime';
    const phaseSource = edge.phase || edge.stage || edge.scope || edge.context || edgeTypeString(edge);
    const phase = String(phaseSource).toLowerCase();
    if(phase.includes('test') || edge.test === true) return 'test';
    if(phase.includes('spec')) return 'test';
    if(phase.includes('build') || phase.includes('codegen') || phase.includes('tool') || edge.build === true) return 'build';
    return 'runtime';
  }

  function isEdgeActiveInProfile(edge, profile){
    if(!profile) return true;
    if(Array.isArray(edge?.profiles)){
      if(edge.profiles.length === 0) return true;
      return edge.profiles.includes(profile.name);
    }
    if(typeof edge?.profile === 'string'){
      return edge.profile === profile.name;
    }
    if(edge?.when && typeof edge.when === 'string'){
      return edge.when.split(',').map(s => s.trim()).filter(Boolean).includes(profile.name);
    }
    if(edge?.flags && profile.flags){
      for(const [flag, expected] of Object.entries(edge.flags)){
        const actual = profile.flags?.[flag];
        if(expected === true && !actual) return false;
        if(expected === false && actual) return false;
        if(typeof expected === 'string' && actual !== expected) return false;
      }
    }
    return true;
  }

  function hasDynamicEvidence(node){
    if(!node) return false;
    if(node.dynamic === true || node.runtimeLoaded === true || node.dynamicOnly === true) return true;
    if(typeof node.coverageHits === 'number' && node.coverageHits > 0) return true;
    if(typeof node.runtimeHits === 'number' && node.runtimeHits > 0) return true;
    if(Array.isArray(node.coverage) && node.coverage.some(value => (value || 0) > 0)) return true;
    if(Array.isArray(node.events) && node.events.some(ev => String(ev?.type || '').toLowerCase().includes('load'))) return true;
    if(Array.isArray(node.tags) && node.tags.some(tag => String(tag).toLowerCase().includes('dynamic'))) return true;
    return false;
  }

  function normalizeEntrypoints(raw, graph){
    const sources = [raw?.entrypoints, raw?.entryPoints, raw?.entry_points, raw?.entrances];
    const collected = [];
    sources.forEach(item => {
      if(item == null) return;
      if(Array.isArray(item)){
        item.forEach(x => collected.push(x));
      } else if(item && typeof item === 'object' && Array.isArray(item.list)){
        item.list.forEach(x => collected.push(x));
      } else {
        collected.push(item);
      }
    });
    const ids = collected
      .map(x => (typeof x === 'string' ? x : x?.id))
      .filter(Boolean);
    if(ids.length){
      return Array.from(new Set(ids));
    }
    const fromNodes = graph.nodes
      .filter(node => node.entrypoint || node.isEntrypoint || node.isEntryPoint || node.isRoot)
      .map(node => node.id);
    if(fromNodes.length){
      return Array.from(new Set(fromNodes));
    }
    const degRoots = graph.nodes
      .filter(node => {
        if((node.type || 'file') !== 'file') return false;
        if((node.inDeg || 0) !== 0) return false;
        const totalDeg = (node.inDeg || 0) + (node.outDeg || 0);
        return totalDeg > 0;
      })
      .map(node => node.id);
    if(degRoots.length){
      return Array.from(new Set(degRoots));
    }
    return graph.nodes.slice(0, 1).map(node => node.id).filter(Boolean);
  }

  function normalizeProfiles(raw){
    const list = [];
    const maybeProfiles = raw?.profiles || raw?.profile || raw?.targets || [];
    if(Array.isArray(maybeProfiles)){
      maybeProfiles.forEach((p, idx) => {
        if(typeof p === 'string'){
          list.push({ name: p, flags: {} });
        } else if(p && typeof p === 'object'){
          list.push({ name: p.name || `profile-${idx+1}`, flags: p.flags || p.gates || {} });
        }
      });
    } else if(maybeProfiles && typeof maybeProfiles === 'object'){
      Object.entries(maybeProfiles).forEach(([name, cfg]) => {
        if(cfg && typeof cfg === 'object'){
          list.push({ name, flags: cfg.flags || cfg });
        }
      });
    } else if(typeof maybeProfiles === 'string'){
      list.push({ name: maybeProfiles, flags: {} });
    }
    if(list.length === 0){
      return [{ name: 'default', flags: {} }];
    }
    return list;
  }

  function compileRule(rule){
    if(!rule) return null;
    if(rule instanceof RegExp) return rule;
    if(typeof rule === 'string'){
      try { return new RegExp(rule); } catch { return null; }
    }
    if(typeof rule === 'object'){
      if(typeof rule.regex === 'string'){
        try { return new RegExp(rule.regex, rule.flags || ''); } catch { return null; }
      }
      if(typeof rule.pattern === 'string'){
        const glob = rule.glob === true;
        const base = glob
          ? `^${rule.pattern.replace(/[.+^${}()|\[\]\\]/g,'\\$&').replace(/\*/g,'.*')}$`
          : rule.pattern;
        try { return new RegExp(base, rule.flags || ''); } catch { return null; }
      }
    }
    return null;
  }

  function compileKeepRules(keepRuleConfig = [], localKeepRules = []){
    const compiled = [];
    [...keepRuleConfig, ...localKeepRules].forEach(rule => {
      const re = compileRule(rule);
      if(re) compiled.push(re);
    });
    return compiled;
  }

  const STATUS_ORDER = [
    'reachable_current',
    'deferred_only',
    'dynamic_only',
    'test_only',
    'build_time_only',
    'reachable_other_profile',
    'disconnected_all_profiles'
  ];

  function matchesKeepRuleFromList(list, id){
    if(!id) return false;
    return list.some(re => {
      try { return re.test(id); } catch { return false; }
    });
  }

  function computeProfileReachability(graph, entrypoints, profile){
    const activeEdges = graph.edges.filter(edge => isEdgeActiveInProfile(edge, profile));
    const adjacency = new Map();
    activeEdges.forEach(edge => {
      const src = nodeId(edge.source);
      const tgt = nodeId(edge.target);
      if(!src || !tgt) return;
      if(!adjacency.has(src)) adjacency.set(src, []);
      adjacency.get(src).push(edge);
    });
    const starts = entrypoints.length ? entrypoints : graph.nodes.slice(0,1).map(node => node.id).filter(Boolean);
    const uniqueStarts = Array.from(new Set(starts));
    const traverse = (filterFn) => {
      const seen = new Set();
      const stack = uniqueStarts.slice();
      while(stack.length){
        const id = stack.pop();
        if(!id || seen.has(id)) continue;
        seen.add(id);
        const edges = adjacency.get(id);
        if(!edges) continue;
        edges.forEach(edge => {
          if(filterFn && !filterFn(edge)) return;
          const tgt = nodeId(edge.target);
          if(tgt && !seen.has(tgt)) stack.push(tgt);
        });
      }
      return seen;
    };

    const reachableAll = traverse(()=>true);
    const reachableNoDeferred = traverse(edge => !isDeferredEdge(edge));
    const reachableNoDynamic = traverse(edge => !isDynamicEdge(edge));
    const reachableRuntime = traverse(edge => edgePhase(edge) === 'runtime');
    const reachableTest = traverse(edge => edgePhase(edge) !== 'build');
    const reachableBuild = traverse(edge => edgePhase(edge) !== 'test');

    return { profile, adjacency, reachableAll, reachableNoDeferred, reachableNoDynamic, reachableRuntime, reachableTest, reachableBuild };
  }

  function determineNodeStatuses(node, res, reachByNode, compiledKeepRules){
    const statuses = new Set();
    const id = node.id;
    const reachableHere = res.reachableAll.has(id);
    const reachableElsewhere = (reachByNode.get(id) || new Set()).size > (reachableHere ? 1 : 0);
    const reachableAny = reachByNode.has(id);

    if(!reachableAny){
      return ['disconnected_all_profiles'];
    }

    if(reachableHere){
      statuses.add('reachable_current');
      if(!res.reachableNoDeferred.has(id)) statuses.add('deferred_only');
      if(!res.reachableNoDynamic.has(id)) statuses.add('dynamic_only');
      if(!res.reachableRuntime.has(id)){
        if(res.reachableTest.has(id)) statuses.add('test_only');
        if(res.reachableBuild.has(id)) statuses.add('build_time_only');
      }
    } else {
      if(reachableElsewhere) statuses.add('reachable_other_profile');
      if(matchesKeepRuleFromList(compiledKeepRules, id) || hasDynamicEvidence(node)) statuses.add('dynamic_only');
      const phaseTags = String(node.phase || node.scope || '').toLowerCase();
      if(phaseTags.includes('test') || node.test === true || node.isTest === true) statuses.add('test_only');
      if(phaseTags.includes('build') || node.build === true) statuses.add('build_time_only');
      if(!reachableElsewhere) statuses.add('disconnected_all_profiles');
    }

    return Array.from(statuses);
  }

  function classifyGraph(graph, profiles, entrypoints, options){
    const compiledKeepRules = options?.compiledKeepRules || [];
    const profileResults = profiles.map(profile => computeProfileReachability(graph, entrypoints, profile));
    const reachByNode = new Map();
    profileResults.forEach(res => {
      res.reachableAll.forEach(id => {
        if(!reachByNode.has(id)) reachByNode.set(id, new Set());
        reachByNode.get(id).add(res.profile.name);
      });
    });

    graph.nodes.forEach(node => {
      node.statusByProfile = node.statusByProfile || {};
      node.primaryByProfile = node.primaryByProfile || {};
      node.reachableProfiles = Array.from(reachByNode.get(node.id) || []);
      profileResults.forEach(res => {
        const statuses = determineNodeStatuses(node, res, reachByNode, compiledKeepRules);
        node.statusByProfile[res.profile.name] = statuses;
        const primary = statuses.includes('disconnected_all_profiles')
          ? 'disconnected_all_profiles'
          : STATUS_ORDER.find(st => statuses.includes(st)) || statuses[0] || 'disconnected_all_profiles';
        node.primaryByProfile[res.profile.name] = primary;
      });
    });

    return profileResults;
  }

  function toSerializableRegexList(list){
    return list.map(re => ({ source: re.source, flags: re.flags }));
  }

  const EXPORT_ID_KEYS = ['id', 'node', 'file', 'path', 'module'];
  const EXPORT_GROUP_KEYS = ['groups', 'exports', 'symbols', 'values', 'items', 'members', 'entries', 'data', 'list'];
  const EXPORT_SKIP_KEYS = new Set([...EXPORT_ID_KEYS, ...EXPORT_GROUP_KEYS, 'meta', 'summary', 'stats', 'count', 'type', 'kind', 'category', 'description']);
  const createExportVisitTracker = ()=> typeof WeakSet !== 'undefined' ? new WeakSet() : null;

  const SECURITY_SEVERITY_ALIASES = new Map([
    ['crit', 'critical'],
    ['critical', 'critical'],
    ['severe', 'high'],
    ['high', 'high'],
    ['warn', 'med'],
    ['warning', 'med'],
    ['medium', 'med'],
    ['med', 'med'],
    ['moderate', 'med'],
    ['medium-high', 'med'],
    ['medium_low', 'med'],
    ['low', 'low'],
    ['info', 'info'],
    ['informational', 'info'],
    ['note', 'info'],
    ['unknown', 'unknown']
  ]);

  function normalizeSecuritySeverity(value){
    if(value == null) return 'unknown';
    const raw = String(value).trim().toLowerCase();
    if(!raw) return 'unknown';
    if(SECURITY_SEVERITY_ALIASES.has(raw)) return SECURITY_SEVERITY_ALIASES.get(raw);
    if(raw.startsWith('crit')) return 'critical';
    if(raw.startsWith('hi')) return 'high';
    if(raw.startsWith('med')) return 'med';
    if(raw.startsWith('mod')) return 'med';
    if(raw.startsWith('low')) return 'low';
    if(raw.startsWith('info')) return 'info';
    return raw;
  }

  function normalizeSecurityFinding(raw){
    if(!raw || typeof raw !== 'object') return null;
    const id = raw.id != null ? String(raw.id) : null;
    const message = raw.message != null ? String(raw.message) : '';
    const severity = raw.severity != null ? String(raw.severity) : '';
    const severityNormalized = normalizeSecuritySeverity(raw.severityNormalized != null ? raw.severityNormalized : severity);
    const line = Number.isFinite(raw.line) ? Number(raw.line) : null;
    const code = raw.code != null ? String(raw.code) : null;
    return {
      id,
      message,
      severity,
      severityNormalized,
      line,
      code
    };
  }

  function cloneSecurityFinding(finding){
    if(!finding || typeof finding !== 'object') return null;
    const clone = {
      message: finding.message != null ? String(finding.message) : ''
    };
    if(finding.id != null) clone.id = String(finding.id);
    if(finding.severity != null) clone.severity = String(finding.severity);
    if(finding.severityNormalized != null) clone.severityNormalized = String(finding.severityNormalized);
    if(Number.isFinite(finding.line)) clone.line = Number(finding.line);
    if(finding.code != null) clone.code = String(finding.code);
    return clone;
  }

  function securityFindingKey(finding){
    if(!finding || typeof finding !== 'object') return '';
    const parts = [
      finding.severityNormalized || finding.severity || '',
      finding.id || '',
      Number.isFinite(finding.line) ? finding.line : '',
      finding.message || '',
      finding.code || ''
    ];
    return parts.join('|');
  }

  const SECURITY_LOCATION_KEYS = [
    'source',
    'sources',
    'path',
    'paths',
    'file',
    'files',
    'absPath',
    'realPath',
    'canonicalPath',
    'resolvedPath',
    'module',
    'modules',
    'node',
    'nodes',
    'uri',
    'url',
    'target',
    'targets'
  ];

  const SECURITY_FINDING_COLLECTION_KEYS = [
    'findings',
    'securityFindings',
    'items',
    'values',
    'entries',
    'list',
    'results'
  ];

  function registerSecurityFindingsForKey(rawKey, rawValue, target){
    if(typeof rawKey !== 'string') return false;
    const trimmedKey = rawKey.trim();
    if(!trimmedKey) return false;
    const normalizedList = [];
    const visited = typeof WeakSet !== 'undefined' ? new WeakSet() : null;
    collectSecurityFindingInputs(rawValue, normalizedList, visited);
    if(!normalizedList.length) return false;
    const keys = [];
    const canonical = canonicalExportId(trimmedKey);
    if(canonical) keys.push(canonical);
    if(!canonical || canonical !== trimmedKey) keys.push(trimmedKey);
    keys.forEach(key => {
      if(!key) return;
      if(!target.has(key)) target.set(key, []);
      const bucket = target.get(key);
      const seen = new Set(bucket.map(securityFindingKey));
      normalizedList.forEach(item => {
        const entryKey = securityFindingKey(item);
        if(seen.has(entryKey)) return;
        bucket.push(cloneSecurityFinding(item));
        seen.add(entryKey);
      });
    });
    return true;
  }

  function extractSecurityRecords(container){
    if(!container || typeof container !== 'object') return [];
    const locations = [];
    SECURITY_LOCATION_KEYS.forEach(key => {
      const value = container[key];
      if(typeof value === 'string'){
        const trimmed = value.trim();
        if(trimmed && /[\\/.:]/.test(trimmed)) locations.push(trimmed);
      } else if(Array.isArray(value)){
        value.forEach(entry => {
          if(typeof entry !== 'string') return;
          const trimmed = entry.trim();
          if(trimmed && /[\\/.:]/.test(trimmed)) locations.push(trimmed);
        });
      }
    });
    if(!locations.length) return [];
    let findingsSource = null;
    for(const key of SECURITY_FINDING_COLLECTION_KEYS){
      const candidate = container[key];
      if(Array.isArray(candidate)){
        findingsSource = candidate;
        break;
      }
    }
    if(!findingsSource && container.finding != null){
      findingsSource = container.finding;
    }
    if(!findingsSource){
      if(container.message != null || container.id != null || container.severity != null || container.code != null){
        findingsSource = container;
      }
    }
    if(!findingsSource) return [];
    return locations.map(location => ({ key: location, findings: findingsSource }));
  }

  function ingestSecurityFindings(container, target){
    if(!container) return;
    if(container instanceof Map){
      container.forEach((value, key) => registerSecurityFindingsForKey(String(key), value, target));
      return;
    }
    if(Array.isArray(container)){
      container.forEach(entry => {
        if(!entry) return;
        if(typeof entry === 'object'){
          const records = extractSecurityRecords(entry);
          if(records.length){
            records.forEach(record => registerSecurityFindingsForKey(record.key, record.findings, target));
            return;
          }
        }
        ingestSecurityFindings(entry, target);
      });
      return;
    }
    if(typeof container !== 'object') return;
    const directRecords = extractSecurityRecords(container);
    if(directRecords.length){
      directRecords.forEach(record => registerSecurityFindingsForKey(record.key, record.findings, target));
      return;
    }
    const entries = Object.entries(container);
    entries.forEach(([rawKey, rawValue]) => {
      if(!registerSecurityFindingsForKey(rawKey, rawValue, target)){
        ingestSecurityFindings(rawValue, target);
      }
    });
  }

  function collectSecurityFindingInputs(source, target, visited){
    if(source == null) return;
    if(Array.isArray(source)){
      source.forEach(item => collectSecurityFindingInputs(item, target, visited));
      return;
    }
    if(typeof source !== 'object') return;
    if(visited){
      if(visited.has(source)) return;
      visited.add(source);
    }
    if(Array.isArray(source.findings)){
      collectSecurityFindingInputs(source.findings, target, visited);
    }
    if(Array.isArray(source.securityFindings)){
      collectSecurityFindingInputs(source.securityFindings, target, visited);
    }
    if(source.finding != null){
      collectSecurityFindingInputs(source.finding, target, visited);
    }
    const normalized = normalizeSecurityFinding(source);
    if(normalized && (normalized.message || normalized.id)){
      target.push(normalized);
    }
  }

  function collectNodeSecurityFindings(node){
    if(!node || typeof node !== 'object') return [];
    const collected = [];
    const visited = typeof WeakSet !== 'undefined' ? new WeakSet() : null;
    const add = (value) => collectSecurityFindingInputs(value, collected, visited);
    add(node.securityFindings);
    add(node.security);
    if(node.meta && typeof node.meta === 'object'){
      add(node.meta.securityFindings);
      add(node.meta.security);
    }
    return collected;
  }

  function summarizeSecurityFindings(nodes){
    const summary = {
      totalFindings: 0,
      affectedNodes: 0,
      bySeverity: {}
    };
    if(!Array.isArray(nodes)) return summary;
    nodes.forEach(node => {
      const findings = collectNodeSecurityFindings(node);
      if(!findings.length) return;
      summary.affectedNodes += 1;
      summary.totalFindings += findings.length;
      findings.forEach(finding => {
        const severity = finding && finding.severityNormalized != null
          ? finding.severityNormalized
          : finding && finding.severity != null
            ? finding.severity
            : 'unknown';
        const bucket = normalizeSecuritySeverity(severity);
        summary.bySeverity[bucket] = (summary.bySeverity[bucket] || 0) + 1;
      });
    });
    return summary;
  }

  function mergeSecurityFindingLists(...lists){
    if(!lists || lists.length === 0) return [];
    const merged = [];
    const seen = new Set();
    lists.forEach(list => {
      if(!list) return;
      const array = Array.isArray(list) ? list : [list];
      array.forEach(item => {
        const normalized = normalizeSecurityFinding(item);
        if(!normalized || (!normalized.message && !normalized.id)) return;
        const key = securityFindingKey(normalized);
        if(seen.has(key)) return;
        merged.push(cloneSecurityFinding(normalized));
        seen.add(key);
      });
    });
    return merged;
  }

  function canonicalExportId(id){
    if(typeof id !== 'string') return null;
    let value = id.trim();
    if(!value) return null;
    if(value.startsWith('\\\\?\\')) value = value.substring(4);
    const hadUncPrefix = value.startsWith('\\') || value.startsWith('\\/') || value.startsWith('//');
    let normalized = value.replace(/\\/g, '/');
    if(hadUncPrefix && !normalized.startsWith('//')){
      normalized = '//' + normalized.replace(/^\/+/, '');
    }
    if(normalized.startsWith('//')){
      const body = normalized.slice(2).replace(/\/{2,}/g, '/');
      normalized = '//' + body;
    } else {
      normalized = normalized.replace(/\/{2,}/g, '/');
    }
    const drive = normalized.match(/^([a-zA-Z]):\//);
    if(drive){
      normalized = drive[1].toUpperCase() + normalized.substring(1);
    }
    return normalized;
  }

  function cloneExportEntry(entry){
    if(entry == null) return null;
    if(Array.isArray(entry)){
      return entry.map(cloneExportEntry).filter(value => value != null);
    }
    if(typeof entry === 'object'){
      const clone = {};
      Object.entries(entry).forEach(([key, value]) => {
        const cloned = cloneExportEntry(value);
        if(cloned !== null && cloned !== undefined){
          clone[key] = cloned;
        }
      });
      return clone;
    }
    return entry;
  }

  function listFromExportGroup(raw){
    if(Array.isArray(raw)) return raw;
    if(raw && typeof raw === 'object'){
      if(Array.isArray(raw.list)) return raw.list;
      if(Array.isArray(raw.values)) return raw.values;
      if(Array.isArray(raw.items)) return raw.items;
      if(Array.isArray(raw.entries)) return raw.entries;
      if(Array.isArray(raw.members)) return raw.members;
      if(Array.isArray(raw.data)) return raw.data;
      return Object.values(raw);
    }
    if(raw == null) return [];
    return [raw];
  }

  function normalizeExportGroups(groups){
    if(groups == null) return null;

    const buildGroupFromValues = (raw, defaultKind = 'symbols') => {
      const arr = listFromExportGroup(raw)
        .map(cloneExportEntry)
        .filter(value => {
          if(value == null) return false;
          if(typeof value === 'string') return value.trim() !== '';
          return true;
        });
      return arr.length ? { [defaultKind]: arr } : null;
    };

    if(Array.isArray(groups) || typeof groups !== 'object'){
      return buildGroupFromValues(groups);
    }

    const normalized = {};
    Object.entries(groups).forEach(([kind, rawList]) => {
      const grouped = buildGroupFromValues(rawList, kind);
      if(grouped){
        normalized[kind] = grouped[kind];
      }
    });
    return Object.keys(normalized).length ? normalized : null;
  }

  function mergeExportGroupMaps(base, addition){
    if(!addition) return base || null;
    const target = base ? { ...base } : {};
    Object.entries(addition).forEach(([kind, values]) => {
      if(!Array.isArray(values) || !values.length) return;
      if(!target[kind]) target[kind] = [];
      values.forEach(value => {
        const cloned = cloneExportEntry(value);
        if(cloned !== null && cloned !== undefined){
          target[kind].push(cloned);
        }
      });
    });
    return Object.keys(target).length ? target : null;
  }

  function recordExports(exportsById, id, groups){
    if(id == null) return;
    const normalized = normalizeExportGroups(groups);
    if(!normalized) return;

    const store = (key)=>{
      if(!key) return;
      const existing = exportsById.get(key);
      exportsById.set(key, mergeExportGroupMaps(existing, normalized));
    };

    const canonical = canonicalExportId(id);
    if(canonical) store(canonical);

    if(typeof id === 'string'){
      const trimmed = id.trim();
      if(trimmed && trimmed !== canonical){
        store(trimmed);
      }
    }
  }

  function ingestExports(exportsById, container, visited){
    if(container == null) return;
    if(visited && typeof container === 'object'){
      if(visited.has(container)) return;
      visited.add(container);
    }
    if(Array.isArray(container)){
      container.forEach(entry => {
        if(entry == null) return;
        if(Array.isArray(entry)){
          if(entry.length >= 2 && typeof entry[0] === 'string'){
            recordExports(exportsById, entry[0], entry[1]);
          } else {
            ingestExports(exportsById, entry, visited);
          }
          return;
        }
        if(typeof entry !== 'object') return;
        const id = EXPORT_ID_KEYS.map(key => entry[key]).find(value => typeof value === 'string' && value.trim());
        if(id){
          for(const key of EXPORT_GROUP_KEYS){
            if(entry[key] && typeof entry[key] === 'object'){
              recordExports(exportsById, id, entry[key]);
              return;
            }
          }
          const fallback = {};
          Object.entries(entry).forEach(([key, value]) => {
            if(EXPORT_SKIP_KEYS.has(key)) return;
            if(Array.isArray(value) && value.length){
              fallback[key] = value;
            }
          });
          recordExports(exportsById, id, fallback);
          return;
        }
        ingestExports(exportsById, entry, visited);
      });
      return;
    }
    if(typeof container !== 'object') return;
    const directId = EXPORT_ID_KEYS.map(key => container[key]).find(value => typeof value === 'string' && value.trim());
    if(directId){
      for(const key of EXPORT_GROUP_KEYS){
        if(container[key] && typeof container[key] === 'object'){
          recordExports(exportsById, directId, container[key]);
          return;
        }
      }
      recordExports(exportsById, directId, container);
      return;
    }
    Object.entries(container).forEach(([key, value]) => {
      if(value == null) return;
      if(typeof key === 'string' && key.trim() && !EXPORT_SKIP_KEYS.has(key)){
        if((typeof value === 'object' || Array.isArray(value)) && (key.includes('/') || key.includes('\\') || key.includes('.'))){
          recordExports(exportsById, key, value);
          return;
        }
      }
      ingestExports(exportsById, value, visited);
    });
  }

  function preprocessGraph(payload){
    const rawGraph = payload?.rawGraph || {};
    const keepRuleConfig = Array.isArray(payload?.keepRuleConfig) ? payload.keepRuleConfig : [];
    const localKeepRules = Array.isArray(payload?.localKeepRules) ? payload.localKeepRules : [];

    const normalizedEdges = Array.isArray(rawGraph.edges || rawGraph.links)
      ? (rawGraph.edges || rawGraph.links).map(edge => ({ ...edge, source: edge.source, target: edge.target }))
      : [];
    const graph = {
      nodes: Array.isArray(rawGraph.nodes) ? rawGraph.nodes.map(node => ({ ...node })) : [],
      edges: normalizedEdges
    };

    const exportsById = new Map();
    const exportSources = [rawGraph.exports, rawGraph.exportedSymbols];
    if(rawGraph.symbols && typeof rawGraph.symbols === 'object'){
      exportSources.push(rawGraph.symbols.exports, rawGraph.symbols);
    }
    const visitedExportContainers = createExportVisitTracker();
    exportSources.forEach(source => ingestExports(exportsById, source, visitedExportContainers));

    const securityById = new Map();
    const securitySources = [rawGraph.securityFindings];
    if(rawGraph.security && typeof rawGraph.security === 'object'){
      securitySources.push(rawGraph.security.findings, rawGraph.security);
    }
    securitySources.forEach(source => ingestSecurityFindings(source, securityById));

    const NODE_EXPORT_ID_KEYS = [
      'id',
      'absPath',
      'path',
      'file',
      'module',
      'source',
      'resolvedPath',
      'realPath',
      'canonicalPath',
      'uri'
    ];
    const collectCandidateIds = (from, target)=>{
      if(!from) return;
      if(typeof from === 'string'){ target.add(from); return; }
      if(Array.isArray(from)){ from.forEach(value => collectCandidateIds(value, target)); }
      if(typeof from === 'object'){
        NODE_EXPORT_ID_KEYS.forEach(key => {
          if(Object.prototype.hasOwnProperty.call(from, key)){
            collectCandidateIds(from[key], target);
          }
        });
      }
    };

    graph.nodes.forEach(node => {
      if(!node || (typeof node !== 'object')) return;
      const direct = normalizeExportGroups(node.exports);
      let collected = null;
      const candidates = new Set();
      NODE_EXPORT_ID_KEYS.forEach(key => collectCandidateIds(node[key], candidates));
      if(node.meta && typeof node.meta === 'object'){
        NODE_EXPORT_ID_KEYS.forEach(key => collectCandidateIds(node.meta[key], candidates));
      }
      if(candidates.size === 0 && typeof node.id === 'string'){
        candidates.add(node.id);
      }

      const candidateList = Array.from(candidates).filter(value => typeof value === 'string');

      for(const candidate of candidateList){
        if(typeof candidate !== 'string') continue;
        const canonical = canonicalExportId(candidate);
        if(canonical && exportsById.has(canonical)){
          collected = exportsById.get(canonical);
          break;
        }
      }

      if(!collected){
        for(const candidate of candidateList){
          if(typeof candidate !== 'string') continue;
          const trimmed = candidate.trim();
          if(!trimmed) continue;
          if(exportsById.has(trimmed)){
            collected = exportsById.get(trimmed);
            break;
          }
        }
      }

      const merged = mergeExportGroupMaps(direct, collected);
      if(merged){
        node.exports = merged;
      } else if(node.exports){
        delete node.exports;
      }

      const directSecurity = collectNodeSecurityFindings(node);
      let referencedSecurity = null;
      if(securityById.size){
        for(const candidate of candidateList){
          const canonical = canonicalExportId(candidate);
          if(canonical && securityById.has(canonical)){
            referencedSecurity = securityById.get(canonical);
            break;
          }
        }
        if(!referencedSecurity){
          for(const candidate of candidateList){
            const trimmed = typeof candidate === 'string' ? candidate.trim() : '';
            if(!trimmed) continue;
            if(securityById.has(trimmed)){
              referencedSecurity = securityById.get(trimmed);
              break;
            }
          }
        }
      }

      const mergedSecurity = mergeSecurityFindingLists(directSecurity, referencedSecurity);
      if(mergedSecurity.length){
        node.securityFindings = mergedSecurity;
      } else if(node.securityFindings){
        delete node.securityFindings;
      }
    });

    computeDegrees(graph);
    inferUsageStates(graph);
    const entrypoints = normalizeEntrypoints(rawGraph, graph);
    const profiles = normalizeProfiles(rawGraph);
    const compiledKeepRules = compileKeepRules(keepRuleConfig, localKeepRules);
    const profileResults = classifyGraph(graph, profiles, entrypoints, { compiledKeepRules });
    const securitySummary = summarizeSecurityFindings(graph.nodes);

    return {
      graph,
      entrypoints,
      profiles,
      compiledKeepRules: toSerializableRegexList(compiledKeepRules),
      profileResults: profileResults.map(res => ({
        profile: res.profile,
        reachableAll: Array.from(res.reachableAll),
        reachableNoDeferred: Array.from(res.reachableNoDeferred),
        reachableNoDynamic: Array.from(res.reachableNoDynamic),
        reachableRuntime: Array.from(res.reachableRuntime),
        reachableTest: Array.from(res.reachableTest),
        reachableBuild: Array.from(res.reachableBuild)
      })),
      summary: {
        security: securitySummary
      }
    };
  }

  global.GraphPreprocessing = {
    computeDegrees,
    inferUsageStates,
    computeProfileReachability,
    classifyGraph,
    preprocessGraph,
    STATUS_ORDER,
    helpers: {
      nodeId,
      isDeferredEdge,
      isDynamicEdge,
      edgePhase,
      isEdgeActiveInProfile,
      hasDynamicEvidence,
      normalizeEntrypoints,
      normalizeProfiles,
      compileKeepRules,
      normalizeSecuritySeverity,
      collectNodeSecurityFindings,
      summarizeSecurityFindings,
      mergeSecurityFindingLists
    }
  };
})(typeof self !== 'undefined' ? self : this);

In jsDependency.dart, layer a  rich **static security lint** on top of the same pass, without external packages or web calls.

Below are **security signals you can reliably derive just from source text** (JS/TS/JSX/TSX), plus **exact patterns and a drop-in patch** to emit findings into your JSON.

---

# What you can detect (fast + file-local)

## 1) Dangerous code execution & sandbox escapes

* **`eval`, `Function`, `setTimeout/Interval` with string**, `vm.*` (Node)
  Risks: code injection.
* **`child_process`**: `exec`, `execSync`, `spawn` with `{shell:true}`
  Risks: command injection / privilege escalation.
* **Dynamic `require`/`import()` with non-literal** (template or variable).
  Risks: loading arbitrary code + bypass of bundler analysis.

**Regex sketches**

* `\beval\s*\(`, `new\s+Function\s*\(`
* `set(?:Timeout|Interval)\s*\(\s*['"]`
* `require\(\s*[^'"][^)]+\)` / `import\(\s*[^'"][^)]+\)`
* `from\s+` followed by template literal: `from\s*` + `` ` ``

## 2) File-system / network surface (Node & browser)

* **Node built-ins**: `fs`, `net`, `tls`, `http`, `https`, `dgram`, `cluster`, `os`, `process.env`
  Risks: data exfil, SSRF, weak file perms.
* **`fs` with user-controlled paths** (heuristic): any `fs.*(` containing `..` or string concat with variables.
  Risks: path traversal.
* **HTTP over cleartext**: URLs starting with `http://` (not localhost).
  Risks: MITM.

**Regex**

* `\b(require|import)\s*\(\s*['"](?:fs|net|tls|http|https|dgram|cluster|os)\b`
* `\bfs\.(?:readFile|writeFile|readdir|createWriteStream|createReadStream)\s*\(`
* `http://(?!localhost|127\.0\.0\.1)`

## 3) XSS sinks (frontend & SSR)

* Direct **DOM sinks**: `innerHTML=`, `outerHTML=`, `document.write`, `insertAdjacentHTML`, `Range.createContextualFragment`, `dangerouslySetInnerHTML` (React).
* Assigning to `srcdoc`, `on*=` attributes in string templates.
* **Template injection**: `` element.innerHTML = `${var}` `` where var isn’t obviously constant (heuristic: `${` usage).

**Regex**

* `\.\s*innerHTML\s*=` / `document\.write\s*\(` / `insertAdjacentHTML\s*\(`
* `dangerouslySetInnerHTML\s*:`
* `\bsrcdoc\s*=`
* `` `[^`]*\$\{[^}]+\}[^`]*` `` (flag as “template interpolation”—contextual risk)

## 4) postMessage misuse

* **`window.postMessage(data, '*')`** or missing strict origin in same line/scope.
  Risks: data exfil.

**Regex**

* `postMessage\s*\([^,]+,\s*['"]\*['"]\)`

## 5) Token & secret handling

* **Hard-coded tokens/keys**:
  common names: `API_KEY`, `SECRET`, `TOKEN`, `PASSWORD`, `PRIVATE_KEY`, `AUTH`, `BEARER` w/ long base64/hex.
* **Math.random()** used for IDs/tokens/nonces.
* **Local/session storage** of sensitive names: `setItem('token'|'auth'|...)`.

**Regex**

* `(?:API[_-]?KEY|SECRET|TOKEN|PASSWORD|PRIVATE[_-]?KEY)\s*[:=]\s*['"][A-Za-z0-9_\-\.=+/]{12,}['"]`
* `\bMath\.random\s*\(`
* `localStorage\.setItem\s*\(\s*['"](token|auth|jwt|session)['"]` (same for `sessionStorage`)

## 6) Crypto misuse

* Weak digests: **MD5/SHA-1**; insecure random: **`crypto.randomBytes(…)` vs `Math.random()`**; deprecated **`createCipher`**.
* **JWT** with none/HS256 secrets inline; **verify** without `aud/iss` checks (heuristic: `jwt.verify(` with only two args).

**Regex**

* `crypto\.createHash\(['"](?:md5|sha1)['"]\)`
* `crypto\.createCipher\(` / `createDecipher\(`
* `jwt\.verify\s*\([^,]+,\s*[^,)\s]+(?:\)|,)` (2-arg verify)

## 7) CORS / CSRF hints (server code)

* **`res.set('Access-Control-Allow-Origin','*')`** or CORS middleware with wildcard.
* **CSRF**: use of cookie sessions without `SameSite`/`HttpOnly` (heuristic in string).

**Regex**

* `Access-Control-Allow-Origin['"]?\s*[:=]\s*['"]\*['"]`
* `cookie\s*:\s*['"][^'"]*(?i)(Secure|HttpOnly|SameSite)[^'"]*['"]` (negate to flag missing—but you can just flag cookie literals for manual review)

## 8) Framework-specific quick wins

* **React**: `dangerouslySetInnerHTML` (already above).
* **Next.js**: `getServerSideProps` referencing `req.query` concatenated into `fetch` URL without validation (heuristic “query in URL”).
* **Express**: `app.use(cors())` with no options; `app.get('*')` catch-alls that return secrets.

## 9) Supply chain / dependency hygiene (package.json only; no CVE lookup)

* **Loose ranges**: `^`, `~`, `*`, `x`, `latest`, Git URLs—flag as “pinned-version recommended for prod”.
* **Scripts** with risk: pre/post-install calling curl/bash, `node-gyp`, arbitrary `sh`.

**Heuristics**

* `dependencies` / `devDependencies` value not matching `^\d+\.\d+\.\d+(-.*)?$` → flag.
* `scripts` value containing `curl|wget|bash|powershell|Invoke-Expression`.

## 10) Info leaks / debug

* `console.log` that includes `password|secret|token`.
* `.env` patterns: `import.meta.env.*` (Vite) using non-public keys (best practice: only `VITE_*` should appear in client code).

**Regex**

* `console\.(log|dir)\([^)]*(password|secret|token)[^)]*\)`
* `import\.meta\.env\.(?!VITE_)`

---

# How to wire it into your current pass

You already sanitize and split into lines in `_extractFacts`. Reuse that loop to emit **per-line findings**. Minimal surface:

```dart
class SecurityFinding {
  final String ruleId;
  final String severity; // info|low|med|high
  final String message;
  final int line;
  final String snippet;

  SecurityFinding(this.ruleId, this.severity, this.message, this.line, this.snippet);

  Map<String, dynamic> toJson() => {
    'ruleId': ruleId,
    'severity': severity,
    'message': message,
    'line': line,
    'snippet': snippet.trim(),
  };
}
```

Add to `_FileFacts`:

```dart
final List<SecurityFinding> findings;
_FileFacts(this.path, this.imports, this.hasSideEffectImport, this.exports, [this.findings = const []]);
```

### 1) Define your rules (regex + severity + message)

```dart
class _SecRule {
  final String id, message, severity;
  final RegExp re;
  const _SecRule(this.id, this.message, this.severity, this.re);
}

final _secRules = <_SecRule>[
  _SecRule('exec.eval', 'Use of eval()', 'high', RegExp(r'\beval\s*\(')),
  _SecRule('exec.Function', 'Use of new Function()', 'high', RegExp(r'\bnew\s+Function\s*\(')),
  _SecRule('timer.string', 'String-based setTimeout/Interval', 'med', RegExp(r'set(?:Timeout|Interval)\s*\(\s*["\']')),
  _SecRule('child.exec', 'child_process exec/execSync', 'high', RegExp(r'\b(child_process\.)?exec(Sync)?\s*\(')),
  _SecRule('child.shell', 'spawn with shell:true', 'high', RegExp(r'spawn\s*\([^)]*shell\s*:\s*true')),
  _SecRule('dyn.require', 'Dynamic require/import arg', 'med', RegExp(r'(require|import)\s*\(\s*(?!["\'])([^)]+)\)')),
  _SecRule('fs.pathTraversal', 'fs call with potentially unsafe path', 'med', RegExp(r'\bfs\.(read|write|readdir|create(Read|Write)Stream)\s*\(')),
  _SecRule('net.http', 'Cleartext HTTP URL', 'med', RegExp(r'http://(?!localhost|127\.0\.0\.1)')),
  _SecRule('dom.innerHTML', 'Assignment to innerHTML', 'high', RegExp(r'\.\s*innerHTML\s*=')),
  _SecRule('dom.dangerouslySetInnerHTML', 'dangerouslySetInnerHTML usage', 'high', RegExp(r'dangerouslySetInnerHTML\s*:')),
  _SecRule('postMessage.star', 'postMessage with "*" target origin', 'med', RegExp(r'\bpostMessage\s*\([^,]+,\s*["\']\*["\']\)')),
  _SecRule('secrets.inline', 'Possible hard-coded secret', 'high', RegExp(r'(API[_-]?KEY|SECRET|TOKEN|PASSWORD|PRIVATE[_-]?KEY)\s*[:=]\s*["\'][A-Za-z0-9_\-\.=+/]{12,}["\']')),
  _SecRule('secrets.storage', 'Token written to storage', 'med', RegExp(r'(localStorage|sessionStorage)\.setItem\s*\(\s*["\'](token|auth|jwt|session)["\']')),
  _SecRule('rand.weak', 'Math.random used for security-sensitive values', 'low', RegExp(r'\bMath\.random\s*\(')),
  _SecRule('crypto.weakHash', 'Weak hash (MD5/SHA1)', 'high', RegExp(r'crypto\.createHash\(["\'](md5|sha1)["\']\)')),
  _SecRule('cors.wildcard', 'CORS wildcard origin', 'med', RegExp(r'Access-Control-Allow-Origin["\']?\s*[:=]\s*["\']\*["\']')),
  _SecRule('console.secrets', 'Console logs may leak secrets', 'low', RegExp(r'console\.(log|dir)\([^)]*(password|secret|token)[^)]*\)')),
  _SecRule('env.exposed', 'Non-VITE env var used in client', 'med', RegExp(r'import\.meta\.env\.(?!VITE_)')),
];
```

### 2) Scan lines inside `_extractFacts`

Right after you build `lines`:

```dart
final findings = <SecurityFinding>[];

for (var i = 0; i < lines.length; i++) {
  final raw = lines[i];
  final lineNo = i + 1;
  for (final rule in _secRules) {
    final m = rule.re.firstMatch(raw);
    if (m != null) {
      findings.add(SecurityFinding(rule.id, rule.severity, rule.message, lineNo, raw.trim()));
    }
  }

  // Extra heuristic: fs + '..'
  if (raw.contains('fs.') && raw.contains('..')) {
    findings.add(SecurityFinding('fs.dotdot', 'Possible path traversal ("..")', 'med', lineNo, raw.trim()));
  }
}
```

Finally, return `_FileFacts(filePath, imports, sideEffectOnly, exports, findings);`

### 3) Emit in the output JSON

In `main` when you build `out`, add a `security` section:

```dart
final security = <String, List<Map<String, dynamic>>>{};
factsByPath.forEach((path, facts) {
  if (facts.findings.isEmpty) return;
  security[_normalize(path)] = facts.findings.map((f) => f.toJson()).toList();
});
if (security.isNotEmpty) out['securityFindings'] = security;
```

### 4) (Optional) package.json hygiene

Reuse your `_readPackageJson` result:

```dart
Map<String, dynamic> pkgHygiene = {};
void _scanDeps(Map<String, dynamic>? pkg) {
  if (pkg == null) return;
  Map<String, dynamic> risks = {};
  for (final field in ['dependencies','devDependencies','optionalDependencies']) {
    final deps = pkg[field];
    if (deps is Map) {
      final items = <String, String>{};
      deps.forEach((k,v) {
        if (v is String) {
          final loose = RegExp(r'[\^\~\*x]|latest|github\.com|git\+');
          if (loose.hasMatch(v)) items[k] = v;
        }
      });
      if (items.isNotEmpty) risks[field] = items;
    }
  }
  if (risks.isNotEmpty) pkgHygiene['looseVersions'] = risks;
  // Risky scripts
  final scripts = pkg['scripts'];
  if (scripts is Map) {
    final bad = <String,String>{};
    scripts.forEach((k,v){
      if (v is String && RegExp(r'(curl|wget|bash|powershell|Invoke-Expression)').hasMatch(v)) {
        bad[k] = v;
      }
    });
    if (bad.isNotEmpty) pkgHygiene['riskyScripts'] = bad;
  }
}
_scanDeps(pkg);
if (pkgHygiene.isNotEmpty) out['packageRisks'] = pkgHygiene;
```

---

# What this gives you in practice

* A **per-file, per-line** list of findings with rule IDs and severities you can render in your graph UI (e.g., color nodes red/orange/blue; show badges per rule).
* **Zero dependency** enrichment: runs in the same pass as your import/export scan.
* **Actionable triage**: start with HIGH (code execution, innerHTML, child_process, secrets), then MED (postMessage '*', HTTP, fs traversal), then LOW (console secrets, Math.random).

---

# Nice stretch goals (still static, still quick)

1. **Sources → sinks (tiny taint mode)**
   Track identifiers that originate from obvious sources (`req.query`, `req.params`, `req.body`, `window.location`, `location.hash`, `document.cookie`, `event.data`) and if the same identifier (even same name) appears on a sink line (e.g., `innerHTML`, `exec`, URL concat in `fetch`), raise severity.
   Implementation: keep a per-file `Set<String> taintedNames` you fill when a line matches `const (\w+) = req\.query\.\w+` etc.; in sink checks, if the line also contains one of those names, escalate (`severity=high`).

2. **Bundle surface**
   Count usage of sensitive Node built-ins per file → render degree-weighted risk.

3. **SSR vs client**
   If your project is mixed, a simple rule: any file under `pages/api` (Next.js) or server folders → enable server-only checks; files importing `react` or `.tsx` → enable client checks (XSS sinks).

---

# Quick test cases you can drop in

```js
// HIGH: eval + innerHTML + secret + postMessage(*)
const API_KEY = "sk_live_1234567890abcdef"; // secret
setTimeout("doBad()", 100);
element.innerHTML = userInput;
window.postMessage({data}, "*");
eval(code);

// MED: dynamic require + fs traversal + http
const m = require(moduleName);
fs.readFile("../etc/passwd", 'utf8', cb);
fetch("http://example.com");

// LOW: Math.random + console leak
const token = Math.random().toString(36);
console.log("user token", token);
```

You should see 7–8 findings, with severities as defined.

---


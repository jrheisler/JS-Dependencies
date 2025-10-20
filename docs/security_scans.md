# JavaScript security scans

The `jsDependency.dart` crawler includes a lightweight static security scan when it
parses JavaScript and TypeScript sources. The scanner performs a regular
expression sweep over each file (after stripping comments and string contents)
plus a small number of bespoke heuristics. Each match is emitted as a
`SecurityFinding` and exported under the `securityFindings` section of
`jsDependencies.json`.

## Rule reference

The scanner exposes two groups of built-in rules:

* **Pattern rules** – straightforward regular-expression checks that operate on
  the sanitized source text.
* **Heuristic rules** – context-aware inspections that look for combinations of
  patterns (for example, user input flowing into a sink) before reporting a
  finding.

### Pattern rules

| ID | Severity | Description | Pattern / trigger |
| --- | --- | --- | --- |
| `eval.call` | high | Use of `eval()` which can execute arbitrary code. | `\beval\s*\(` |
| `function.constructor` | high | Construction of dynamic functions via `new Function()`. | `new\s+Function\s*\(` |
| `timeout.string` | high | Passing a string to `setTimeout`/`setInterval`, which executes it as code. | `set(?:Timeout|Interval)\s*\(\s*["']` |
| `vm.module` | high | Calls into Node's `vm` module that can escape sandboxes. | `\bvm\.[A-Za-z_]\w*\s*\(` |
| `child_process.exec` | high | Running `child_process` exec/spawn helpers which launch shell commands. | `(?:\brequire\s*\(\s*["']child_process["']\s*\)|\bchild_process)\s*\.\s*(?:exec|execSync|spawn|spawnSync)\s*\(` |
| `child_process.shell` | high | Enabling shell execution for process spawns. | `shell\s*:\s*true` |
| `child_process.spawnShell` | high | Shelling out via `spawn`/`execFile` with `shell: true`. | `{ ... shell: true ... }` inside spawn/execFile calls |
| `dynamic.require` | high | `require()` with a non-literal argument (dynamic module loading). | `require\s*\(\s*[^\'"\s][^\)]*\)` |
| `dynamic.import` | high | `import()` with a non-literal argument. | `import\s*\(\s*[^\'"\s][^\)]*\)` |
| `import.template` | high | Module specifier expressed as a template literal. | `from` followed by a backtick-delimited template literal |
| `node.builtin` | med | Sensitive Node built-ins imported (`fs`, `net`, `tls`, `http`, `https`, `dgram`, `cluster`, `os`). | `(?:require|import)\s*\(\s*["'](?:fs|net|tls|http|https|dgram|cluster|os)` |
| `process.env` | med | Access to `process.env`, potentially leaking secrets. | `process\.env` |
| `fs.access` | med | Reading or writing via Node's `fs` module. | `fs\.(?:readFile|readFileSync|writeFile|writeFileSync|readdir|readdirSync|createWriteStream|createReadStream)\s*\(` |
| `http.cleartext` | med | Cleartext HTTP requests to non-localhost targets. | `http://` (excluding localhost/loopback) |
| `dom.innerHTML` | high | Assignments to `innerHTML`. | `\.\s*innerHTML\s*=` |
| `dom.outerHTML` | high | Assignments to `outerHTML`. | `\.\s*outerHTML\s*=` |
| `document.write` | high | Calls to `document.write()`. | `document\.write\s*\(` |
| `dom.insertAdjacentHTML` | high | Calls to `insertAdjacentHTML()`. | `insertAdjacentHTML\s*\(` |
| `dom.javascriptHref` | high | Assigning `javascript:` URLs to links. | `.href = 'javascript:...'` |
| `dom.javascriptLocation` | high | Navigating to `javascript:` URLs. | `location = 'javascript:...'` |
| `dom.range` | high | Calls to `Range.createContextualFragment()`. | `createContextualFragment\s*\(` |
| `react.dangerousHTML` | high | Usage of React's `dangerouslySetInnerHTML`. | `dangerouslySetInnerHTML\s*:` |
| `iframe.srcdoc` | high | Assigning to the `srcdoc` attribute. | `\bsrcdoc\s*=` |
| `template.interpolation` | low | Template literal interpolation that may need sanitization. | <code>`...${...}`</code> |
| `postmessage.wildcard` | med | `window.postMessage` calls targeting the wildcard origin. | `postMessage\s*\([^,]+,\s*["']\*["']\)` |
| `secret.literal` | high | Potential hard-coded secrets (API keys, tokens, passwords). | `(?:API[_-]?KEY|SECRET|TOKEN|PASSWORD|PRIVATE[_-]?KEY)\s*[:=]\s*["'][A-Za-z0-9_\-\.=+/]{12,}["']` |
| `math.random` | low | Usage of `Math.random()` where cryptographic randomness may be required. | `Math\.random\s*\(` |
| `storage.token` | med | Writing tokens into Web Storage/IndexedDB helpers. | Storage identifier followed by `setItem`/`put`/`add` targeting token-like keys |
| `crypto.weakHash` | med | Hashing with MD5/SHA1. | `crypto\.createHash\(\s*["'](?:md5|sha1)["']` |
| `crypto.createCipher` | med | Deprecated `crypto.createCipher`/`createDecipher` usage. | `crypto\.create(?:Cipher|Decipher)\s*\(` |
| `jwt.verify` | med | `jwt.verify` invoked without explicit options. | `jwt.verify(...)` with only token + secret arguments |
| `cors.wildcard` | med | Wildcard `Access-Control-Allow-Origin` headers. | `Access-Control-Allow-Origin\s*[:=]\s*["']\*["']` |
| `cors.middleware` | med | Express `app.use(cors())` without configuration. | `app\.use\s*\(\s*cors\s*\(\s*\)` |
| `cookie.literal` | low | Cookie strings defined inline; security flags should be reviewed. | `document\.cookie\s*=\s*["'][^"']*["']` or `cookie\s*:\s*["'][^"']*["']` |
| `console.secret` | low | Logging values that look like secrets. | `console\.(?:log|dir)\s*\([^)]*(password|secret|token|api[_-]?key|auth|credential|ssn|social|credit|card|email)[^)]*\)` |
| `import.meta.env` | low | Direct reads from `import.meta.env`. | `import\.meta\.env\.[A-Za-z_]\w*` |
| `ssrf.metadataHost` | high | Requests to metadata or private-network IP ranges. | URLs that target cloud metadata or RFC1918 ranges |
| `injection.mongoOperator` | high | Usage of MongoDB `$where`/`$regex` operators which may execute user input. | `$where:` or `$regex:` |
| `regex.dynamic` | med | `RegExp` constructed from dynamic (non-literal) input. | `new RegExp(variable)` / `RegExp(variable)` |
| `regex.catastrophic` | high | Regex literal with nested quantifiers that can trigger ReDoS. | Patterns such as `/(a+)+/` |
| `cors.credentialsWildcard` | high | Wildcard CORS origin combined with credential support. | `Access-Control-Allow-Origin` wildcard plus `Access-Control-Allow-Credentials: true` |
| `tls.disabledEnv` | high | TLS verification disabled via environment variable. | `NODE_TLS_REJECT_UNAUTHORIZED=0` |
| `tls.agentInsecure` | high | TLS verification disabled on `https.Agent`. | `https.Agent({ rejectUnauthorized: false })` |
| `template.tripleStache` | med | Unescaped Handlebars/Mustache triple-stache rendering. | `{{{...}}}` |
| `template.escapeDisabled` | med | Template rendering with escaping disabled. | `escape: false` |
| `prototype.proto` | high | Direct assignment to `__proto__` or `constructor.prototype`. | `__proto__ =` or `constructor.prototype =` |
| `crypto.aesEcb` | high | AES ECB mode selected. | `aes-128-ecb`, `AES_ECB`, etc. |

### Heuristic rules

| ID | Severity | Description | Trigger |
| --- | --- | --- | --- |
| `ssrf.dynamicFetch` | high | `fetch()` invoked with potential user-controlled input. | `fetch(...)` where the URL expression references request/body/query/context data. |
| `ssrf.dynamicAxios` | high | `axios` requests built from user input. | `axios...(...)` with arguments containing request/body/query/context fields. |
| `ssrf.dynamicRequest` | high | `http.request(...)`/`https.request(...)` using user-controlled hosts. | Host/URL arguments derived from request/body/query data. |
| `injection.sqlTemplate` | high | SQL queries composed with template literal interpolation. | ``client.query(`...${expr}...`)`` |
| `injection.sqlConcat` | high | SQL queries built via string concatenation of tainted data. | `.query('...' + req.body.foo)` |
| `prototype.mergeUserInput` | high | Lodash `_.merge` merges user data into an object. | `_.merge(target, req.body, ...)` |
| `prototype.assignUserInput` | high | `Object.assign` merges user data into a plain object. | `Object.assign({}, req.body, ...)` |
| `path.join.userInput` | high | `path.join` combines user-controlled segments or contains `..`. | `path.join(req.body.path, ...)` or `path.join(..., '..')`. |
| `zipSlip.entryPath` | high | Archive extraction uses entry paths containing `..`. | Extraction helpers or `entry.path` values with traversal segments. |
| `child_process.userArgs` | high | `child_process` spawn/execFile arguments built from user input. | Spawn/execFile calls that concatenate or template-interpolate request data. |
| `storage.token.assignment` | med | Token-like data assigned directly to storage globals. | `localStorage.token = req.body.token`. |
| `fs.dotdot` | med | File-system access combined with `..` (path traversal). | Lines containing both `fs.` operations and `..`. |
| `cookie.sameSiteNoneInsecure` | high | `SameSite=None` cookies without the `Secure` flag. | Cookie strings or options specifying `SameSite=None` while omitting `Secure`. |
| `cookie.session.noHttpOnly` | med | Session cookies missing `HttpOnly`. | Cookie definitions for `sid`/`session` lacking the `HttpOnly` flag or option. |
| `open_redirect.clientLocation` | high | Client-side navigation built from user input. | Assignments to `window.location`/`location.href` that reference request data. |
| `open_redirect.serverRedirect` | high | Server redirects fed by user data. | `res.redirect(...)` calls whose argument contains request data. |
| `upload.trustsClientMime` | med | Upload flow trusts client-supplied MIME type or filename. | Access to `req.file.mimetype` / `req.file.originalname`. |
| `upload.publicWrite` | high | Upload writes user files straight to public directories. | `fs.writeFile`/`fs.createWriteStream` into `/public` or `/uploads` with user-controlled data. |
| `csrf.credentialsMissingToken` | high | Credentialed cross-origin requests lacking CSRF tokens. | Credentialed `fetch`, Axios, or XHR POST/PUT/PATCH/DELETE calls missing CSRF header/cookie markers. |
| `jwt.verify.missingOptions` | high | `jwt.verify` missing a populated options object. | Options argument absent, `{}`, `null`, or `undefined`. |
| `jwt.verify.algorithms.missing` | high | JWT verification without an algorithm allowlist. | Options object missing `algorithms`. |
| `jwt.verify.algorithms.none` | high | JWT verification allows the `none` algorithm. | `algorithms: [...]` containing `none`. |
| `jwt.verify.missingAud` | med | JWT verification lacks audience validation. | Options missing `audience`/`aud`. |
| `jwt.verify.missingIss` | med | JWT verification lacks issuer validation. | Options missing `issuer`/`iss`. |
| `jwt.verify.missingExp` | med | JWT verification ignores expiration. | Options missing expiry enforcement or setting `ignoreExpiration: true`. |
| `jwt.verify.missingNbf` | med | JWT verification ignores not-before. | Options missing `nbf`/`notBefore` or setting `ignoreNotBefore: true`. |
| `headers.securityBaseline` | med | Security headers set without CSP/X-Frame-Options/Referrer-Policy. | Response header blocks missing that trio while setting other security headers (unless Helmet is detected). |
| `yaml.load.unsafe` | high | `js-yaml` `load()` without a safe schema. | `yaml.load(...)` lacking `schema: DEFAULT_SAFE_SCHEMA`/`FAILSAFE_SCHEMA`. |
| `xml.externalEntities` | high | XML parser enables external entity expansion. | Options such as `{ resolveEntities: true }`. |
| `crypto.staticIv` | high | Static IV/nonce literals passed to crypto APIs. | `crypto.createCipheriv(..., 'iv')` or `crypto.subtle.encrypt({ iv: ... })` with constant values. |

### Notes

* Sanitization removes comments and quoted strings before evaluating the regular
  expressions, helping reduce false positives from commented code or string
  literals. Some heuristic rules (such as `fs.dotdot`) run on the raw line to
  catch directory traversal attempts.
* Findings include the rule identifier, severity, message, source line, and a
  snippet of the triggering code so downstream tooling can present actionable
  context.
* The scanner is heuristic-driven and may produce false positives/negatives; it
  is intended for surfacing potential risks rather than enforcing strict policy.

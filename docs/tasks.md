# Pending tasks

## Security scanner enhancements for `lib/jsDependency.dart`

### Strong additions (defense-in-depth)

- [ ] Harden JWT verification checks
  - Extend the existing `jwt.verify` rule to flag `algorithms` arrays that include `"none"` or omit the option entirely.
  - Add heuristics to require explicit `aud`, `iss`, `exp`, and `nbf` validations when calling `jsonwebtoken.verify` / `jwt.verify`, emitting a separate finding when these options are missing or falsey.
  - Update `docs/security_scans.md` to document the new findings and their trigger patterns.

- [ ] Expand cookie flag coverage
  - Add a rule that warns when `SameSite=None` is set without `Secure` in cookie literals, Express `res.cookie`, or Set-Cookie header builders.
  - Detect session-oriented cookies (names like `session`, `sid`, `connect.sid`) that lack `HttpOnly`, emitting a medium/high severity finding.
  - Cover both server-side (`res.cookie`, header objects) and client-side (`document.cookie`) configuration blocks.

- [ ] CSRF heuristic for credentialed fetches
  - Scan for `fetch`/`axios`/`XMLHttpRequest` calls with `credentials: 'include'` (or `withCredentials: true`) combined with state-changing HTTP verbs (POST/PUT/PATCH/DELETE) and ensure a CSRF token header/body parameter is present.
  - Emit a finding when such requests lack common CSRF markers (headers like `X-CSRF-Token`, `X-XSRF-TOKEN`, body keys `csrfToken`, etc.).
  - Consider multi-line object literals; ensure sanitization pipeline preserves enough structure to evaluate options.

- [ ] Open redirect sinks
  - Flag assignments to `location.href`, `window.location`, or `res.redirect()` where the argument includes user-controlled identifiers (`req.query`, `req.body`, etc.).
  - Reuse the existing `userInputPattern` heuristics for taint detection and extend it if necessary for URL parameters.
  - Emit separate findings for client-side navigation vs. Express `res.redirect` usage so the messages are actionable.

- [ ] HTTP response header hygiene
  - During server configuration scans (Express `app.use`, `res.set`, header literals), detect absence of `Content-Security-Policy`, `X-Frame-Options` / `frame-ancestors`, and `Referrer-Policy` when other security headers (e.g., `helmet`) are not applied.
  - Add heuristics to recognize Express/Node response builders and produce low/medium severity findings when these headers are missing in initialization files.
  - Document assumptions to limit false positives (e.g., only flag when other headers are being set explicitly in the same scope).

- [ ] Unsafe YAML/XML loaders
  - Create rules to flag `js-yaml`'s `load()` (without schema) and encourage `load` with `FAILSAFE_SCHEMA`/`DEFAULT_SAFE_SCHEMA` or `safeLoad` when available.
  - Detect XML parsers (`xml2js`, `xmldom`, `fast-xml-parser`, etc.) configured with external entity resolution enabled or defaulting to unsafe behavior.
  - Note any libraries requiring manual option inspection so implementers can extend the pattern list.

- [ ] Weak crypto modes and IV misuse
  - Add detection for AES ECB mode strings (`aes-128-ecb`, `AES_ECB`) and warn about insecure mode selection.
  - Flag constant IV/nonce arguments passed to `crypto.createCipheriv`, `createDecipheriv`, or browser `crypto.subtle` calls (e.g., string literals, zero IVs).
  - Track repeated IV definitions across files when feasible; otherwise, warn on obvious static literals.

- [ ] Insecure file upload flows
  - Detect code paths that trust client-provided MIME types or file extensions when saving uploads (e.g., `req.file.mimetype` checks that only look at extension).
  - Flag writes placing uploads into executable directories (`/public`, `/uploads` served statically) without renaming/randomization.
  - Leverage existing `pathInputPattern` to highlight uses of `fs.writeFile`, `fs.createWriteStream`, or `multer` destinations that combine user input.

- [ ] Enhance sensitive logging detection
  - Broaden the `console.secret` rule to include PII patterns (email regexes, SSN-like digit groups) and secret-bearing key names beyond `password|secret|token`.
  - Ensure sanitization preserves enough of the literal to match while minimizing false positives (e.g., allow hyphenated keys like `apiKey`, `auth_token`).
  - Update associated unit tests under `lib/jsDependency_test.dart` to cover the expanded detection cases.

- [ ] Supply-chain red flags
  - Parse `package.json` scripts to surface `postinstall`, `preinstall`, and `install` scripts and flag non-trivial commands (e.g., network access, shell exec).
  - Integrate dependency metadata (lockfile parsing or optional SBOM input) to annotate packages with deprecated or known vulnerable status (consider hooking into `npm audit` JSON when available).
  - Emit findings grouped under a new category so downstream tooling can highlight supply-chain risks separately from code-level issues.

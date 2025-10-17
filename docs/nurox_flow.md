# Nurox dependency viewer flow

This document explains how the desktop viewer executable (`NuroxView.exe`) coordinates the HTML frontend (`nuros_nexus.html` and its legacy shim `nexus.html`) and the language-specific crawlers that produce dependency graphs.

## 1. Desktop controller (`NuroxView.exe`)

`NuroxView.exe` is the compiled form of `lib/nurox_view.dart`. When launched it binds an HTTP server on a random available port, loads any bundled sample graph into memory, generates a bearer token, and opens the default browser to the local viewer URL with the token appended.【F:lib/nurox_view.dart†L185-L205】【F:lib/nurox_view.dart†L81-L146】

Key responsibilities:

* **Serving the viewer UI.** Requests to `/`, `/nuros_nexus.html`, or `/nexus.html` return the viewer HTML with the token injected into a `<meta name="nurox-token">` tag so the browser can authenticate subsequent API calls.【F:lib/nurox_view.dart†L210-L227】【F:lib/nurox_view.dart†L516-L525】
* **Static assets.** Any other non-API GET request is treated as a static asset lookup, resolved against the working directory, the script directory, and packaged `public/` folders.【F:lib/nurox_view.dart†L257-L267】【F:lib/nurox_view.dart†L385-L465】
* **Graph storage.** The controller keeps an in-memory `Graph` that merges nodes and edges from crawlers, deduplicating nodes and edges while preserving the richest metadata.【F:lib/nurox_view.dart†L23-L75】
* **API surface.**
  * `GET /api/languages` reports which crawler executables are currently discoverable on disk, scanning for each language’s known filenames.【F:lib/nurox_view.dart†L269-L281】【F:lib/nurox_view.dart†L148-L173】
  * `POST /api/crawl` accepts a target root plus one or more language identifiers, runs the matching crawler executables from that root, loads their default `*Dependencies.json` outputs, and merges them into the active graph.【F:lib/nurox_view.dart†L283-L341】
  * `GET /api/graph` returns the merged dependency graph for the frontend to render.【F:lib/nurox_view.dart†L344-L348】

Authentication is enforced on every `/api/*` route: the viewer must send the bearer token that was injected into the HTML or provided via the `?token=` query parameter.【F:lib/nurox_view.dart†L250-L362】

## 2. Primary frontend (`nuros_nexus.html`)

`public/nuros_nexus.html` is the main visualization. A bootstrap script adds a `<base>` tag so that assets work regardless of whether the file is opened directly or served from the embedded web server.【F:public/nuros_nexus.html†L6-L24】 The page hosts the D3-based graph canvas, sidebar controls, and a modal help system.【F:public/nuros_nexus.html†L25-L339】

When loaded inside the desktop viewer, the page reads the injected token or URL parameter and stores it as an Authorization header for API calls.【F:public/nuros_nexus.html†L780-L806】 In this “viewer mode” it enables the Local Crawl panel, which lets users:

1. Fetch the list of available crawlers via `GET /api/languages`, presenting each language with availability state and executable path metadata.【F:public/nuros_nexus.html†L1044-L1105】
2. Start a crawl by posting `{ root, languages, clear }` to `/api/crawl`, showing progress updates and reporting merged node/edge counts when the controller responds.【F:public/nuros_nexus.html†L1160-L1207】
3. Reload the current merged graph from `/api/graph`, which the page immediately feeds into its processing pipeline for layout and filtering.【F:public/nuros_nexus.html†L1608-L1667】

Outside of viewer mode, the UI still functions for static JSON files (drag-and-drop, manual load) but the crawl controls stay disabled, guiding users to launch the desktop app.【F:public/nuros_nexus.html†L1044-L1054】

## 3. Legacy shim (`nexus.html`)

`public/nexus.html` is retained for backward compatibility: it immediately redirects to `nuros_nexus.html` while displaying a short message. This allows older shortcuts or bookmarks to keep working with the renamed viewer.【F:public/nexus.html†L1-L22】

## 4. Language crawlers

The controller knows about eight language identifiers, each mapped to a set of executable names and a default output file. It probes the working directory, the script or packaged `public/` folders, and the system PATH until it finds a match.【F:lib/nurox_view.dart†L148-L173】【F:lib/nurox_view.dart†L530-L579】 The expected JSON filenames are `jsDependencies.json`, `pyDependencies.json`, `goDependencies.json`, `rustDependencies.json`, `javaDependencies.json`, `kotlinDependencies.json`, `csharpDependencies.json`, and `dartDependencies.json` respectively.【F:lib/nurox_view.dart†L163-L173】

Each crawler is implemented as a standalone Dart CLI in `lib/` and can be compiled to a native executable. They all follow the same broad pattern: recursively scan source files for the target language, infer imports/modules, compute reachability from entry points, and write the dependency graph in the schema that the viewer understands.【F:README.md†L6-L18】 The top-of-file documentation summarises what each crawler inspects:

* **JavaScript / TypeScript (`lib/jsDependency.dart`):** Extracts ES module imports, resolves them to local files or external package nodes, estimates LOC, and labels nodes as used, unused, or side-effect-only based on reachability analysis.【F:lib/jsDependency.dart†L1-L120】
* **Python (`lib/pyDependency.dart`):** Scans `.py` files, evaluates `import`/`from` statements, interprets `__main__` guards and packaging metadata as entry points, resolves modules to files or `pip:` externals, and marks usage state from reachability.【F:lib/pyDependency.dart†L1-L200】
* **Go (`lib/goDependency.dart`):** Walks `.go` files, reads `go.mod`, resolves imports within the module or to `std:`/`go:` externals, and treats `package main` files with `func main()` as entry points.【F:lib/goDependency.dart†L1-L40】
* **Rust (`lib/rustDependency.dart`):** Parses `mod`, `use`, and `extern crate` directives, consults `Cargo.toml` for bins and dependencies, and resolves module paths to files or `crate:` externals.【F:lib/rustDependency.dart†L1-L32】
* **Java (`lib/javaDependency.dart`):** Collects packages, imports, and classes with `public static void main`, resolving imports to internal classes or Maven-style external identifiers.【F:lib/javaDependency.dart†L1-L20】
* **Kotlin (`lib/kotlinDependency.dart`):** Reads package declarations and imports, infers declarations and `fun main` entry points, and expands wildcard imports to internal files when possible.【F:lib/kotlinDependency.dart†L1-L20】
* **C# (`lib/csharpDependency.dart`):** Analyses namespaces, `using` directives, and `Main` methods to connect files and identify external references such as `dotnet:` or `nuget:` packages.【F:lib/csharpDependency.dart†L1-L19】
* **Dart (`lib/dartDependency.dart`):** Tracks `import`, `export`, and `part` directives, resolves `package:` URIs relative to the current project or as `pub:` externals, and detects `main()` entry points in common locations.【F:lib/dartDependency.dart†L1-L20】

During a crawl the controller runs each selected language sequentially, reading the emitted JSON from the project root. Missing outputs or non-zero exit codes are logged but do not stop the overall process; any successful outputs are merged into the shared graph and exposed back to the frontend.【F:lib/nurox_view.dart†L309-L341】


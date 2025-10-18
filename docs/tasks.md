# Task backlog

## Include exports in SBOM CSV
- **Problem:** The SBOM CSV export currently only serializes node-level metadata (id, statuses, type, package, size, side effects, external flag, and degree counts). It omits module-level export information that the viewer already tracks for JavaScript modules, making it hard to audit which exports are exposed by each node.
- **Proposed change:** Extend the CSV generation logic in `public/nuros_nexus.html` to include an additional column that concatenates the names of exports associated with each node (for example `default`, named exports, and re-exports), and populate it when building the CSV rows. Ensure the legend describes the new column.
- **Acceptance criteria:**
  - The SBOM CSV includes a column enumerating the exports for each node when that data is available.
  - The legend section at the bottom documents the exports column.
  - Nodes without exports populate the column with an empty string.

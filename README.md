# aw-plugin-bazaar

Dual-host plugin marketplace for DSH and Claude Code. One repository, two
catalog files:

| File | Consumer | Purpose |
|---|---|---|
| `index.json` | DSH `plugin_market` | Market index, pinned by commit via jsDelivr |
| `.claude-plugin/marketplace.json` | Claude Code `/plugin marketplace` | Marketplace catalog, sources pinned by SHA |

The plugin code stays in each plugin's own repository. This repository only
contains catalog metadata and the publish helper.

## Add the marketplace

### DSH

Add the pinned index URL to the profile's `plugin-market` configuration:

```text
https://cdn.jsdelivr.net/gh/AlawnWalker/aw-plugin-bazaar@<commit>/index.json
```

`publish-index.ps1` updates that pinned URL automatically after a successful
publish.

### Claude Code

```text
/plugin marketplace add AlawnWalker/aw-plugin-bazaar
```

Claude Code reads `.claude-plugin/marketplace.json` from the repository root.
The marketplace name is `aw-plugin-bazaar`.

## Publishing

DSH's market requires a public `http(s)` JSON URL. jsDelivr caches branch names,
so the profile pins a commit; every index change needs a new URL and a DSH
restart.

```powershell
# Validate without pushing or changing the profile
.\publish-index.ps1 -DryRun

# Refresh version / commit / publishTimestamp from each plugin repo, then push
.\publish-index.ps1 -Refresh

# Push the current index.json as-is
.\publish-index.ps1
```

The script validates the schema, pushes `index.json`, then replaces the pinned
jsDelivr URL in the DSH profile. It does not scan this repository for plugin
directories, so `.claude-plugin/` and the helper scripts are ignored.

## Index rules

The DSH index format is version 1. The rules below are the ones that have
actually broken the market:

- `versions[].publishTimestamp` is required: integer Unix seconds in `[0, 1e11)`.
- `versions[].source.commit` must be a lowercase 40-hex SHA; tags and short SHAs
  are rejected.
- Omit `repository.directory` for a single-package repository; a blank string
  is rejected.
- Every `plugins[].metadata.labels[]` id must be declared in the top-level
  `metadata.labels`.
- `plugins[].metadata` accepts only `category` / `keywords` / `labels` /
  `sortKeys`; `sortOrder` is not an index field.
- `publish-index.ps1` must stay UTF-8 with BOM for Windows PowerShell 5.1.

## Repository layout

```text
aw-plugin-bazaar/
├── index.json                     # DSH market
├── .claude-plugin/
│   └── marketplace.json           # Claude Code market
├── publish-index.ps1
└── README.md
```

Host-specific entries are allowed: `dsh-github` is DSH-only, while
`windows-mcp-plugin`, `kb-plugin`, `remote-build-plugin`, `trace32-plugin`,
`vivado-ila-plugin`, `peer-link`, `securecrt-plugin` and `onenote-plugin` are
listed for both hosts where the package supports them.

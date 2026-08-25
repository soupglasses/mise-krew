# Development Guide

## Overview

This is a mise **backend plugin** that enables version management for krew kubectl plugins. Unlike standard krew (which only installs latest), this plugin uses the [krew-index](https://github.com/kubernetes-sigs/krew-index) git history to discover and install specific versions.

## Tech Stack

- **Language**: Lua 5.1 (mise backend plugin standard)
- **Code Quality**: [stylua](https://github.com/JohnnyMorganz/StyLua) (formatting), [luacheck](https://github.com/mpeterv/luacheck) (linting)
- **Task Runner**: [mise](https://mise.jdx.dev) (via `mise.toml` tasks)
- **Git Hooks**: [hk](https://hk.jdx.dev) (optional, runs stylua/luacheck on commit)

### Tool Installation Note

luacheck is distributed via [LuaRocks](https://luarocks.org/) (the Lua package manager), not through mise's standard backends. The setup:

1. mise installs `lua` (which includes `luarocks`)
2. You install luacheck manually: `luarocks install luacheck`
3. mise.toml adds `~/.luarocks/bin` to PATH so luacheck is available

CI handles this automatically in the workflow.

## Quick Start

```bash
# Install dev tools (lua, stylua, luacheck, etc.)
mise install

# Install pre-commit hooks (optional)
hk install

# Link plugin for local testing
mise plugin link --force krew .

# Test it works
mise ls-remote krew:tree
mise install krew:tree@latest
mise exec krew:tree@latest -- kubectl-tree --version
```

## Development Workflow

### Running Tests

```bash
mise run test-unit          # Lua unit tests
mise run test-integration   # End-to-end against the linked plugin
mise run lint               # stylua + luacheck via hk
mise run test               # All of the above
```

### Testing Your Changes

1. Make changes to files in `lib/` or `hooks/`
2. Clear caches to force fresh behavior:

   ```bash
   rm -rf ~/.local/share/mise/plugins/krew/cache/*.json
   mise cache clear
   ```

3. Test the specific functionality you changed
4. Run full test suite: `mise run test`

### Available Lua Modules

Backend plugins run in a sandboxed Lua 5.1 environment with these built-in modules:

| Module | Purpose | Example |
|--------|---------|---------|
| `cmd` | Execute shell commands | `cmd.exec("git log", { cwd = "/path" })` |
| `http` | HTTP requests/downloads | `http.download_file({ url = "..." }, "/dest")` |
| `file` | File operations | `file.exists(path)`, `file.join_path(...)` |
| `archiver` | Extract archives | `archiver.decompress("archive.tar.gz", "/dest")` |
| `json` | JSON parsing | `json.decode(str)`, `json.encode(table)` |

**Note**: Some modules documented in mise's plugin docs (like `semver`, `log`) are **not available** in backend plugins. Use standard Lua functions instead.

See [mise plugin Lua modules docs](https://mise.jdx.dev/plugin-lua-modules.html) for full API.

## Project Structure

```
.
├── hooks/
│   ├── backend_list_versions.lua   # mise ls-remote hook
│   ├── backend_install.lua         # mise install hook
│   └── backend_exec_env.lua        # mise exec hook
├── lib/
│   ├── yaml.lua                    # Vendored YAML parser (MIT)
│   ├── manifest.lua                # Krew manifest parser
│   ├── registry.lua                # Git operations on krew-index
│   ├── version_index.lua           # Version extraction/caching
│   └── installer.lua               # Download/extract/install
├── tests/
│   ├── framework.lua               # Shared assertions + suite runner
│   ├── run_tests.lua               # Lua unit-test entrypoint
│   ├── test_manifest.lua           # Manifest parser unit tests
│   ├── test_installer.lua          # Installer unit tests
│   ├── integration_test.sh         # End-to-end integration tests
│   └── fixtures/                   # Test manifests
├── metadata.lua                    # Plugin metadata
├── mise.toml                       # Dev tasks & tool versions
├── .luacheckrc                     # Lua linting rules
└── stylua.toml                     # Lua formatting rules
```

## Key Files

- **registry.lua**: Clones/updates local mirror of `kubernetes-sigs/krew-index`
- **version_index.lua**: Parses git history to build version→commit map, caches in `cache/*.json`
- **manifest.lua**: Parses krew YAML, selects platform by OS/arch, handles `matchExpressions`
- **installer.lua**: Downloads from manifest URI, verifies SHA256, extracts archives, handles `files[]` mappings

## Debugging

Enable mise debug output:

```bash
mise --debug install krew:tree@v0.4.6
```

Check plugin data:

```bash
ls ~/.local/share/mise/plugins/krew/
# cache/      - JSON version indexes
# registry/   - Git clone of krew-index
```

## Caching Strategy

The plugin uses a two-level caching system to avoid expensive git operations on every command:

### Cache Levels

1. **Git Registry Cache** (`registry/`)
   - Full clone of `kubernetes-sigs/krew-index`
   - Updated if last fetch was >24 hours ago (`registry.CACHE_TTL_SECONDS`)
   - Trigger: `registry.ensure_fresh()` called at the start of every operation
   - Uses **optimistic parallelism**: one initialization-folder winner clones
     privately and publishes atomically while other jobs use jittered backoff.
     Refresh jobs rely on Git's atomic ref updates and retry clean contention.
     Reads are pinned to a captured commit, so concurrent refreshes never expose
     a partially updated registry.

2. **Version Index Cache** (`cache/<tool>.json`)
   - Per-tool version lists with commit mappings
   - Built by walking git history and parsing each manifest version
   - Stored as JSON with schema version for compatibility

### Registry Optimistic Parallelism

Bootstrap coalesces work without making the claim part of correctness:

1. Each process prepares a complete initialization claim and atomically renames
   it to `registry.initializing`; one process wins.
2. The winner clones into its own `registry.incomplete.<token>` directory, then
   atomically renames the completed clone to `registry`.
3. Other processes wait with 0.1–1.0 second jitter and use the published clone.
4. A stale claim is renamed to an owner-specific tombstone. Tombstones are
   retained for 24 hours so delayed waiters cannot retire a successor's claim,
   then garbage-collected to keep storage use bounded in practice.

Claims become stale after five minutes, allowing recovery when an initializer is
killed. A separate ten-minute deadline turns unrecoverable filesystem failures
into an error instead of leaving callers in an indefinite wait.

Refreshes do not use the initialization claim. They fetch only
`refs/remotes/origin/master`; Git atomically publishes that ref after its objects
are available, and competing fetches retry clean lock conflicts. Each reader
captures the ref's commit once and uses that commit for its complete operation.
Consequently, readers see either the old snapshot or the new snapshot, never a
partially updated worktree.

### Cache Invalidation Triggers

The version index cache is rebuilt when ANY of these conditions are met:

| Condition | Check Location | Details |
|-----------|---------------|---------|
| **Cache file missing** | `load_cached()` | First run for this tool |
| **Schema version mismatch** | `load_cached()` | Plugin updated, old cache incompatible |
| **TTL expired (24h)** | `load_cached()` | `os.time() - cache.generated_at > 86400` |
| **Registry ref changed** | `load_cached()` | krew-index has new commits |
| **Registry stale (24h)** | `ensure_fresh()` | Git fetch needed before building index |

### Cache Flow

```
mise ls-remote krew:tree
  └─> backend_list_versions.lua
      └─> version_index.get_versions("tree")
          ├─> Try load_cached("tree") ──> Cache hit? Return cached versions
          └─> Cache miss:
              ├─> registry.ensure_fresh() (update git if needed)
              ├─> build_index("tree") (walk git history, parse YAMLs)
              ├─> save_cache(index) (write to cache/tree.json)
              └─> Return fresh versions
```

### Manual Cache Management

```bash
# Clear version index cache (force rebuild on next run)
rm ~/.local/share/mise/plugins/krew/cache/*.json

# Clear git registry (force re-clone)
rm -rf ~/.local/share/mise/plugins/krew/registry/

# Clear everything
rm -rf ~/.local/share/mise/plugins/krew/cache/
rm -rf ~/.local/share/mise/plugins/krew/registry/
mise cache clear
```

## Code Style

- **Lua 5.1** compatible (no `goto`, no `semver`/`log` modules)
- 4 spaces, 120 column width
- Run `stylua` before committing (or use `hk install` for auto-format)

## Commit Messages

Commits follow the [Conventional Commits](https://www.conventionalcommits.org) format (`feat:`, `fix:`, `refactor:`, `docs:`, `chore:`, `test:`, `ci:`).

## Releasing

1. Confirm green: `mise run test`.
2. Bump `version` in `metadata.lua`, commit as `chore: prepare release X.Y.Z`, push to `main`.
3. Tag and publish (no `v` prefix):

   ```bash
   git tag -a X.Y.Z -m "Release X.Y.Z"
   git push origin X.Y.Z
   gh release create X.Y.Z --title X.Y.Z --generate-notes
   ```

## Third-Party Code

This project vendors [lua-tinyyaml](https://github.com/zepinglee/lua-tinyyaml) (MIT License) for YAML parsing. See [NOTICE](./NOTICE) for full attribution.

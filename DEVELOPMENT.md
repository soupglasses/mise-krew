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
# Unit tests
lua tests/run_tests.lua

# Linting (via mise, runs hk internally)
mise run lint

# Or directly with hk
hk check        # check formatting
hk fix          # auto-fix issues

# Full CI suite
mise run ci
```

### Testing Your Changes

1. Make changes to files in `lib/` or `hooks/`
2. Clear caches to force fresh behavior:

   ```bash
   rm -rf ~/.local/share/mise/plugins/krew/cache/*.json
   mise cache clear
   ```

3. Test the specific functionality you changed
4. Run full test suite: `mise run ci`

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
│   ├── run_tests.lua               # Test runner
│   ├── test_manifest.lua           # Unit tests
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

2. **Version Index Cache** (`cache/<tool>.json`)
   - Per-tool version lists with commit mappings
   - Built by walking git history and parsing each manifest version
   - Stored as JSON with schema version for compatibility

### Cache Invalidation Triggers

The version index cache is rebuilt when ANY of these conditions are met:

| Condition | Check Location | Details |
|-----------|---------------|---------|
| **Cache file missing** | `load_cached()` | First run for this tool |
| **Schema version mismatch** | `load_cached()` | Plugin updated, old cache incompatible |
| **TTL expired (24h)** | `load_cached()` | `os.time() - cache.generated_at > 86400` |
| **Registry HEAD changed** | `load_cached()` | krew-index has new commits |
| **Registry stale (24h)** | `refresh_if_stale()` | Git fetch needed before building index |

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

## Releasing

1. Ensure CI passes: `mise run ci`
2. Update version in `metadata.lua`
3. Tag and push:

   ```bash
   git tag v2.0.0
   git push origin v2.0.0
   ```

4. Verify installation works:

   ```bash
   mise plugin install krew-test https://github.com/soupglasses/mise-krew
   mise use krew-test:tree
   ```

## Third-Party Code

This project vendors [lua-yaml](https://github.com/exosite/lua-yaml) (MIT License) for YAML parsing. See [NOTICE](./NOTICE) for full attribution.

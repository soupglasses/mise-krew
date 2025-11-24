# mise-krew

A mise backend plugin for krew tools using the vfox-style backend architecture.

## Install

```bash
mise plugin install krew https://github.com/soupglasses/mise-krew
```

## Usage

Example usage using `kubectl-volsync`:

```bash
mise use krew:volsync
kubectl-volsync --version
# also accessible through kubectl
kubectl volsync --version
```

## What are Backend Plugins?

Backend plugins in mise extend the standard tool plugin system to manage **multiple tools** using the `plugin:tool` format. They're perfect for:

- **Package managers** (npm, pip, cargo, gem)
- **Tool families** (multiple related tools from one ecosystem)
- **Custom installations** that need to manage many tools

Unlike tool plugins that manage one tool, backend plugins can install and manage multiple tools like `npm:prettier`, `npm:eslint`, `cargo:ripgrep`, etc.

## Development Workflow

### Setting up development environment

1. Install pre-commit hooks (optional but recommended):

```bash
hk install
```

This sets up automatic linting and formatting on git commits.

### Local Testing

1. Link your plugin for development:

```bash
mise plugin link --force krew .
```

2. Test version listing:

```bash
mise ls-remote krew:<some-tool>
```

3. Test installation:

```bash
mise install krew:<some-tool>@latest
```

4. Test execution:

```bash
mise exec krew:<some-tool>@latest -- <some-tool> --version
```

5. Run tests:

```bash
mise run test
```

6. Run linting:

```bash
mise run lint
```

7. Run full CI suite:

```bash
mise run ci
```

### Code Quality

This template uses [hk](https://hk.jdx.dev) for modern linting and pre-commit hooks:

- **Automatic formatting**: `stylua` formats Lua code
- **Static analysis**: `luacheck` catches Lua issues  
- **GitHub Actions linting**: `actionlint` validates workflows
- **Pre-commit hooks**: Runs all checks automatically on git commit

Manual commands:

```bash
hk check      # Run all linters (same as mise run lint)
hk fix        # Run linters and auto-fix issues
```

### Debugging

Enable debug output:

```bash
mise --debug install <BACKEND>:<tool>@<version>
```

## Files

- `metadata.lua` – Backend plugin metadata and configuration
- `hooks/backend_list_versions.lua` – Lists available versions for tools
- `hooks/backend_install.lua` – Installs specific versions of tools
- `hooks/backend_exec_env.lua` – Sets up environment variables for tools
- `.github/workflows/ci.yml` – GitHub Actions CI/CD pipeline
- `mise.toml` – Development tools and configuration
- `mise-tasks/` – Task scripts for testing
- `hk.pkl` – Modern linting and pre-commit hook configuration
- `.luacheckrc` – Lua linting configuration
- `stylua.toml` – Lua formatting configuration

## Context Variables Reference

### BackendListVersions Context

| Variable | Type | Description | Example |
|----------|------|-------------|---------|
| `ctx.tool` | string | Tool name | `"browse-pvc"` |

### BackendInstall and BackendExecEnv Context  

| Variable | Type | Description | Example |
|----------|------|-------------|---------|
| `ctx.tool` | string | Tool name | `"browse-pvc"` |
| `ctx.version` | string | Tool version | `"v1.3.0"` |
| `ctx.install_path` | string | Installation directory | `"/home/user/.local/share/mise/installs/krew-browse-pvc/v1.3.0"` |

### Available Lua Modules

Backend plugins have access to these built-in modules:

- `cmd` - Execute shell commands
- `http` - HTTP client for downloads and API calls  
- `json` - JSON parsing and encoding
- `file` - File system operations

## Publishing

1. Ensure all tests pass: `mise run ci`
2. Create a GitHub repository for your plugin
3. Push your code
4. Test with: `mise plugin install mybackend https://github.com/soupglasses/mise-krew`
5. (Optional) Request to transfer to [mise-plugins](https://github.com/mise-plugins) organization
6. Add to the [mise registry](https://github.com/jdx/mise/blob/main/registry.toml) via PR

## Documentation

- [Backend Plugin Development](https://mise.jdx.dev/backend-plugin-development.html) - Complete guide
- [Backend Architecture](https://mise.jdx.dev/dev-tools/backend_architecture.html) - How backends work
- [Lua modules reference](https://mise.jdx.dev/plugin-lua-modules.html) - Available modules
- [mise-plugins organization](https://github.com/mise-plugins) - Community plugins

## License

MIT

# mise backend plugin template

This is a GitHub template for building a mise backend plugin using the vfox-style backend architecture.

## What are Backend Plugins?

Backend plugins in mise extend the standard tool plugin system to manage **multiple tools** using the `plugin:tool` format. They're perfect for:

- **Package managers** (npm, pip, cargo, gem)
- **Tool families** (multiple related tools from one ecosystem) 
- **Custom installations** that need to manage many tools

Unlike tool plugins that manage one tool, backend plugins can install and manage multiple tools like `npm:prettier`, `npm:eslint`, `cargo:ripgrep`, etc.

## Using this template

### Option 1: Use GitHub's template feature (recommended)
1. Click "Use this template" button on GitHub
2. Name your repository (e.g., `mise-mybackend` or `vfox-mybackend`)
3. Clone your new repository
4. Follow the setup instructions below

### Option 2: Clone and modify
```bash
git clone https://github.com/jdx/mise-backend-plugin-template mise-mybackend
cd mise-mybackend
rm -rf .git
git init
```

## Setup Instructions

### 1. Replace placeholders

Search and replace these placeholders throughout the project:
- `<BACKEND>` → your backend name (e.g., `npm`, `cargo`, `pip`)
- `<GITHUB_USER>` → your GitHub username or organization  
- `<TEST_TOOL>` → a real tool name your backend can install (for testing)

Files to update:
- `metadata.lua` - Update name, description, author, homepage
- `hooks/*.lua` - Replace placeholders and implement your backend logic
- `mise-tasks/test` - Update test tool name and commands
- `README.md` - Update this file with your backend's information

### 2. Implement the backend hooks

Backend plugins require three main hooks:

#### `hooks/backend_list_versions.lua`
Lists available versions for a tool in your backend.

```lua
function PLUGIN:BackendListVersions(ctx)
    local tool = ctx.tool
    -- Your logic to fetch versions for the tool
    -- Return: {versions = {"1.0.0", "1.1.0", "2.0.0"}}
end
```

**Examples**:
- **API-based**: Query npm registry, PyPI, crates.io APIs
- **Command-based**: Run `npm view <tool> versions`, `pip index versions <tool>`
- **File-based**: Parse registry files or manifests

#### `hooks/backend_install.lua` 
Installs a specific version of a tool.

```lua
function PLUGIN:BackendInstall(ctx)
    local tool = ctx.tool
    local version = ctx.version  
    local install_path = ctx.install_path
    -- Your logic to install the tool
    -- Return: {}
end
```

**Examples**:
- **Package manager**: `npm install <tool>@<version>`, `pip install <tool>==<version>`
- **Download & extract**: Download binary/archive and extract to install_path
- **Build from source**: Clone repository, checkout version, build and install

#### `hooks/backend_exec_env.lua`
Sets up environment variables for a tool.

```lua
function PLUGIN:BackendExecEnv(ctx)
    local install_path = ctx.install_path
    -- Your logic to set up environment
    -- Return: {env_vars = {{key = "PATH", value = install_path .. "/bin"}}}
end
```

**Examples**:
- **Basic**: Add `bin/` directory to PATH
- **Complex**: Set tool-specific environment variables, library paths
- **Ecosystem-specific**: Like `node_modules/.bin` for npm, site-packages for Python

### 3. Platform considerations

Your backend may need to handle different operating systems:

```lua
-- Available in all hooks via RUNTIME object
if RUNTIME.osType == "Darwin" then
    -- macOS-specific logic
elseif RUNTIME.osType == "Linux" then  
    -- Linux-specific logic
elseif RUNTIME.osType == "Windows" then
    -- Windows-specific logic
end
```

### 4. Error handling

Provide meaningful error messages:

```lua
function PLUGIN:BackendListVersions(ctx)
    local tool = ctx.tool
    
    if not tool or tool == "" then
        error("Tool name cannot be empty")
    end
    
    -- ... your implementation ...
    
    if #versions == 0 then
        error("No versions found for " .. tool)
    end
    
    return {versions = versions}
end
```

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
mise plugin link --force <BACKEND> .
```

2. Test version listing:
```bash
mise ls-remote <BACKEND>:<some-tool>
```

3. Test installation:
```bash
mise install <BACKEND>:<some-tool>@latest
```

4. Test execution:
```bash
mise exec <BACKEND>:<some-tool>@latest -- <some-tool> --version
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

## Backend Examples

### Package Manager Backend (npm-style)
```lua
-- backend_list_versions.lua
function PLUGIN:BackendListVersions(ctx)
    local cmd = require("cmd")
    local json = require("json")
    local result = cmd.exec("mypm view " .. ctx.tool .. " versions --json")
    return {versions = json.decode(result)}
end

-- backend_install.lua  
function PLUGIN:BackendInstall(ctx)
    local cmd = require("cmd")
    cmd.exec("mypm install " .. ctx.tool .. "@" .. ctx.version .. " --prefix " .. ctx.install_path)
    return {}
end

-- backend_exec_env.lua
function PLUGIN:BackendExecEnv(ctx)
    return {
        env_vars = {
            {key = "PATH", value = ctx.install_path .. "/bin"}
        }
    }
end
```

### Binary Download Backend (GitHub releases-style)
```lua
-- backend_list_versions.lua
function PLUGIN:BackendListVersions(ctx)
    local http = require("http")
    local json = require("json")
    local resp = http.get({url = "https://api.github.com/repos/owner/" .. ctx.tool .. "/releases"})
    local releases = json.decode(resp.body)
    local versions = {}
    for _, release in ipairs(releases) do
        table.insert(versions, release.tag_name:gsub("^v", ""))
    end
    return {versions = versions}
end

-- backend_install.lua
function PLUGIN:BackendInstall(ctx)
    local platform = RUNTIME.osType:lower()
    local arch = RUNTIME.archType
    local url = "https://github.com/owner/" .. ctx.tool .. "/releases/download/v" .. ctx.version .. 
                "/" .. ctx.tool .. "-" .. platform .. "-" .. arch .. ".tar.gz"
    
    local http = require("http")
    local temp_file = ctx.install_path .. "/tool.tar.gz"
    http.download({url = url, output = temp_file})
    
    local cmd = require("cmd")
    cmd.exec("cd " .. ctx.install_path .. " && tar -xzf tool.tar.gz")
    cmd.exec("rm " .. temp_file)
    return {}
end
```

## Real-World Examples

- [vfox-npm](https://github.com/jdx/vfox-npm) - Backend for npm packages
- Study existing mise backends: npm, cargo, pip, gem

## Context Variables Reference

### BackendListVersions Context
| Variable | Type | Description | Example |
|----------|------|-------------|---------|
| `ctx.tool` | string | Tool name | `"prettier"` |

### BackendInstall and BackendExecEnv Context  
| Variable | Type | Description | Example |
|----------|------|-------------|---------|
| `ctx.tool` | string | Tool name | `"prettier"` |
| `ctx.version` | string | Tool version | `"3.0.0"` |
| `ctx.install_path` | string | Installation directory | `"/home/user/.local/share/mise/installs/npm/prettier/3.0.0"` |

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
4. Test with: `mise plugin install mybackend https://github.com/user/mise-mybackend`
5. (Optional) Request to transfer to [mise-plugins](https://github.com/mise-plugins) organization
6. Add to the [mise registry](https://github.com/jdx/mise/blob/main/registry.toml) via PR

## Documentation

- [Backend Plugin Development](https://mise.jdx.dev/backend-plugin-development.html) - Complete guide
- [Backend Architecture](https://mise.jdx.dev/dev-tools/backend_architecture.html) - How backends work
- [Lua modules reference](https://mise.jdx.dev/plugin-lua-modules.html) - Available modules
- [mise-plugins organization](https://github.com/mise-plugins) - Community plugins

## License

MIT
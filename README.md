# mise-krew

A [mise](https://mise.jdx.dev) backend plugin that installs [krew](https://krew.sigs.k8s.io) kubectl plugins with version pinning support.

## What is this?

[Krew](https://krew.sigs.k8s.io) is the package manager for kubectl plugins. Normally, krew only installs the latest version of a plugin. This mise backend lets you install **specific versions** of krew plugins and manage them via mise's standard tooling.

## Install

### Via mise.toml (recommended)

Add to your `mise.toml`:

```toml
[plugins]
krew = "https://github.com/soupglasses/mise-krew"

[tools]
"krew:tree" = "latest"
```

Then run `mise install`.

### Via CLI

```bash
mise plugin install krew https://github.com/soupglasses/mise-krew
```

## Usage

Install a krew plugin (latest version):

```bash
mise use krew:tree          # Installs kubectl-tree
kubectl-tree --version      # v0.4.6
```

Pin a specific version:

```bash
mise use krew:volsync@v0.10.0
```

List available versions:

```bash
mise ls-remote krew:volsync
# v0.6.0
# v0.6.1
# ...
# v0.10.0
```

Configure in `mise.toml`:

```toml
[tools]
"krew:volsync" = "v0.10.0"
"krew:tree" = "latest"
```

**Note:** First run for a tool fetches version history from [krew-index](https://github.com/kubernetes-sigs/krew-index) and may take a few seconds.

## How it Works

1. Fetches plugin manifests from the krew-index git repository
2. Extracts version history from git commits
3. Downloads platform-specific artifacts directly from upstream URLs
4. Verifies SHA256 checksums
5. Extracts and installs according to manifest `files[]` mappings

## Development

See [DEVELOPMENT.md](./DEVELOPMENT.md).

## License

MIT - see [LICENSE](./LICENSE) and [NOTICE](./NOTICE) for third-party licenses.

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

## Known limitations

Currently, only the latest package versions in `krew-index` can be installed.
This is because `krew-index` only holds onto the latest version of any package,
making it difficult to fetch previous versions.

All previously installed versions of krew packages will stay around without issue,
only the download of older packages is affected.

## Development

See [DEVELOPMENT.md](./DEVELOPMENT.md).

## License

MIT

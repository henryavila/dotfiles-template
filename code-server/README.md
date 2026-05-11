# code-server Scaffold

`dev-bootstrap/85-code-server` installs and runs the editor. This directory is
only a public scaffold for preferences that are safe to version in your private
dotfiles fork.

Safe to copy and customize:

- `settings.json.example` -> `settings.json`
- `extensions.txt.example` -> `extensions.txt`

Do not commit:

- real `config.yaml`, because it contains the local password
- OAuth tokens, GitHub tokens, or extension secrets
- `~/.local/share/code-server` data, caches, workspace storage, logs, machine
  IDs, or extension runtime state

GitHub auth is handled by the bootstrap service wrapper. At launch time it runs
`gh auth token` and exports `GITHUB_TOKEN` only to the `code-server` process, so
the token does not need to live in this repo, the LaunchAgent plist, or
`config.yaml`.

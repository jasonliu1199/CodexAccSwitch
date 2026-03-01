# Codex Account Switch

Simple CLI tool for switching between multiple Codex accounts by managing `auth.json` profiles.

## What it does

- Saves current Codex auth as a named profile
- Switches active auth to another saved profile
- Backs up current auth before each switch
- Shows which profile is currently active

## Install

From this repo root:

```bash
chmod +x ./codex-account-switch
```

Optional global command:

```bash
ln -s "$(pwd)/codex-account-switch" /usr/local/bin/codex-account-switch
```

## Usage

```bash
./codex-account-switch save work
./codex-account-switch save personal
./codex-account-switch list
./codex-account-switch switch personal
./codex-account-switch status
./codex-account-switch rename personal alt
./codex-account-switch delete alt
```

## Storage layout

Default Codex home: `~/.codex`

- Profiles: `~/.codex/account-switch/profiles/*.json`
- Backups: `~/.codex/account-switch/backups/auth-YYYYmmdd-HHMMSS.json`
- Active auth: `~/.codex/auth.json`

You can override the location with `CODEX_HOME`:

```bash
CODEX_HOME=/path/to/custom/.codex ./codex-account-switch list
```

## Safety notes

- Profile names are limited to: letters, numbers, `.`, `_`, `-`
- Auth files are chmod to `600` when possible.
- This tool copies files only; it does not edit token contents.

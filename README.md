# DockerLabCTL

An unofficial Bash CLI to discover, filter, download, deploy, and track machines from [DockerLabs](https://dockerlabs.es/).

> **Independent project:** Not affiliated with or endorsed by DockerLabs. Machines and deployment scripts are third-party content. Review downloaded scripts before running them with elevated privileges, and use labs only in isolated, authorized environments.

## Features

- Browse and search the DockerLabs catalog by machine name or full metadata.
- Filter by difficulty, category, author, and completion status.
- Sort results and show colorized tables or JSON output.
- Download machine ZIP archives and validate basic file structure.
- Deploy locally downloaded labs or download and deploy with `run`.
- Track solved machines independently of downloaded files.
- Synchronize completion with your DockerLabs profile, reading CSRF automatically from your authenticated page when available.
- Cache the online catalog for 24 hours.

## Requirements

- Linux and Bash 4.4+ recommended.
- **Catalog/search/download:** `curl`, `jq`, `perl`, `file`, `iconv`, and Perl `HTML::Parser` / `HTML::Entities`.
- **Deployment:** Docker, `sudo`, `unzip`, `zipinfo` and standard Unix tools.

For Kali Linux / Debian:

```bash
sudo apt update
sudo apt install -y bash curl jq perl libhtml-parser-perl file unzip
```

Install and configure Docker separately to use `deploy` and `run`.

## Installation

```bash
git clone https://github.com/Scan0r/DockerLabCTL.git
cd DockerLabCTL
chmod +x dockerlabctl.sh
sudo install -m 755 dockerlabctl.sh /usr/local/bin/dockerlabctl
```

Or run `./dockerlabctl.sh` directly without system-wide installation.

## Usage

```bash
dockerlabctl --help
```

### Discover machines

```bash
dockerlabctl list
dockerlabctl list -r
dockerlabctl list -d easy -c 'Hacking Web' -p no
dockerlabctl list -t -b --sort difficulty
dockerlabctl search Analyst -rt
dockerlabctl name analyst
dockerlabctl random -d hard -p no
dockerlabctl info Analyst
dockerlabctl list --json --limit 10
```

`name` searches machine names only; `search` also indexes descriptions and other catalog metadata.

### Download and deploy

```bash
dockerlabctl link Analyst
dockerlabctl download Analyst
dockerlabctl download Analyst -o ~/Labs/DockerLabs
dockerlabctl local
dockerlabctl deploy Analyst
# You can also use the catalog ID: dockerlabctl deploy <ID>
dockerlabctl run Analyst
dockerlabctl remove Analyst
# You can also use the catalog ID: dockerlabctl remove <ID>
```

- `download` saves the ZIP without extracting or executing it.
- `deploy` uses an existing local lab without downloading it. Both `deploy` and `remove` accept names or catalog IDs. ID lookups use the cached catalog when available and refresh it if missing; names remain usable offline.
- `run` downloads the lab if needed, then attempts to deploy it.
- `--yes` skips confirmation for deployment and local removal. Only use it after reviewing the relevant files.
- `remove` deletes local lab files **only**; it does not stop or delete Docker containers, images, or networks.

**Important:** Deployment executes a supplied `auto_deploy.sh` using `sudo`. These scripts are not independently audited by this project. Some password-protected ZIPs may require manual extraction before deployment.

### Completion tracking: local and website

Progress syntax in `--help`:

```text
dockerlabctl progress done <Name|All>
dockerlabctl progress fetch <Name|All>
dockerlabctl progress list [local|remote|both]  # local is the default
dockerlabctl progress push <Name|All>
dockerlabctl progress undone <Name|All>
```

`NAME...` means one or more names or IDs; `all` is used alone. `done/undone all` affect locally downloaded machines, whereas `fetch/push all` traverse the full catalog.

All operations use the `progress` command. **Local changes are the default**, and `-p` / `--push` explicitly applies the same `done` or `undone` operation to the website.

```bash
dockerlabctl progress done Analyst           # local only
dockerlabctl progress undone Analyst         # local only
dockerlabctl progress done Analyst -p        # local + website
dockerlabctl progress undone Analyst --push  # local + website (long option)
dockerlabctl progress list                 # local only (default)
dockerlabctl progress list local           # explicit local listing
dockerlabctl progress list remote          # completed on website
dockerlabctl progress list both            # compare both, identify conflicts
dockerlabctl progress fetch Analyst          # website -> local
dockerlabctl progress push Analyst           # local -> website
dockerlabctl progress fetch all --yes       # website -> local, entire catalog
dockerlabctl progress push all --yes        # local -> website, entire catalog
```

To authenticate on Kali Linux, save the **Cookie header value** from your own logged-in browser in a private file:

```bash
mkdir -p ~/.config/dockerlabs
chmod 700 ~/.config/dockerlabs
nano ~/.config/dockerlabs/cookie
chmod 600 ~/.config/dockerlabs/cookie
```

**Cookie file format** (`~/.config/dockerlabs/cookie`): one line of plain text, without quotes or JSON. For example:

```text
session=YOUR_SESSION_VALUE; cf_clearance=YOUR_CLEARANCE_VALUE
```

Copy the values from the `Cookie` header of **your own** authenticated browser session. The `Cookie: ` prefix is optional. Do not add `Bearer`, quote marks, or any other HTTP headers.

**Optional CSRF file format** (`~/.config/dockerlabs/csrf`): a single token value, with no `X-CSRFToken:` prefix, quotes, or JSON. For example:

```text
YOUR_CSRF_TOKEN_VALUE
```

If automatic CSRF detection fails, create the file using `umask 077; nano ~/.config/dockerlabs/csrf` and then use `--csrf-file ~/.config/dockerlabs/csrf`. Keep this file out of Git, as with your cookie.

The file can contain `session=...; cf_clearance=...` or `Cookie: session=...; cf_clearance=...`. The CLI reads `~/.config/dockerlabs/cookie` automatically for remote commands, or you can specify `--cookie-file /private/path`. **Never commit credentials.** Prefer the file option over `--cookie`, which may expose secrets in shell history and process listings. If you have disclosed a real session cookie, sign out/revoke the session and obtain fresh credentials.

The script attempts to extract a CSRF token from the authenticated homepage; use `--csrf-file` only if automatic extraction fails. This depends on the current DockerLabs site layout and has **not been verified with a real signed-in profile**.

| Local | Website | `fetch` (website wins) | `push` (local wins) |
| --- | --- | --- | --- |
| Completed | Completed | No change | No change |
| Completed | Not completed | Unmark locally | Mark on website |
| Not completed | Completed | Mark locally | Unmark on website |
| Not completed | Not completed | No change | No change |

`done -p` / `done --push` and `undone -p` / `undone --push` set the **explicitly requested state** on the website before modifying the local record. Without `-p`, they only update local progress, even if a cookie is configured. Remote writes first check `GET /api/completed_machines/NAME` so the toggle endpoint is not called unnecessarily, then verify the result. `fetch` is read-only for the website. `push` is an intentional overwrite of website state, **including unmarking completed machines**. `fetch all` / `push all` operate on every catalog machine and require confirmation or `--yes`, not just locally downloaded machines. `done all` / `undone all` operate on downloaded local machines.

`-p` is context-sensitive: for **progress done/undone**, it means `--push`; for **list/name/search/random**, `-p yes/no` still filters local completion status. `-s` remains `--sort` for catalog commands and is not a progress sync option. The older `progress sync` command is removed.

If authentication, CSRF parsing, a remote GET, POST or verification fails, the command stops without *intentionally* changing the local state of that machine. A timed-out POST can still have reached the website. Multiple-machine operations may have successfully updated earlier machines before a later failure; they are **not transactional**. Concurrent browser changes can race because the website exposes a toggle endpoint rather than an atomic set-state endpoint. Local completion filters (`-p yes/no`) and `progress list` (or `progress list local`) do not query the website. `progress list remote` lists completed machines from the website; `progress list both` compares local and website states and reports differences. Remote listing checks each catalog machine and requires authentication, but never changes either state.

## Common options

| Option | Purpose |
| --- | --- |
| `-d, --difficulty` | Filter difficulty (`very easy`, `easy`, `medium`, `hard`) |
| `-c, --category` | Filter category |
| `-a, --author` | Filter author |
| `-p, --completed` | Filter `yes` / `no` |
| `-l, --limit` | Limit displayed or JSON results |
| `-p, --push` (progress done/undone) | Also apply the requested state to the website; requires authenticated cookie |
| `-s, --sort` (catalog commands) | Sort by `id`, `name`, `difficulty`, `category`, or `author` |
| `-t, --description` | Show descriptions |
| `-b, --bold` | Highlight terms in descriptions (`-t` required) |
| `-r, --color` | Colorize table output |
| `-o, --output` | Use a different local storage directory |
| `--json` | Output JSON for catalog commands |
| `--refresh` | Bypass the 24-hour catalog cache |
| `--cookie`, `--cookie-file` | Authenticate progress synchronization using a cookie value or private file |
| `--csrf`, `--csrf-file` | Override automatic CSRF detection (optional) |

See `dockerlabctl --help` for the complete reference.

## Tests

The included tests don't need Docker or access to DockerLabs:

```bash
bash -n dockerlabctl.sh
bash tests/tests.sh
```

`tests/tests.sh` creates a temporary mock catalog and checks filtering, sorting, JSON limits, machine lookup, progress tracking, local file removal, and mocked authenticated HTML, CSRF extraction, and profile API responses. GitHub Actions runs these tests on pushes and pull requests.

The test runner prints each named check as **[PASS]** or **[FAIL]**, followed by a total count and final result. All API tests use a local mock with **Analyst**; no real profile or Docker deployment is modified.

## Known limitations

- Catalog parsing relies on the current HTML layout of the DockerLabs website; changes to its markup could require parser updates.
- Archive filenames are derived automatically from machine names; exceptions may require manual handling.
- Archive checks do not establish that the contents are trustworthy.
- End-to-end deployments are **not** run in CI.

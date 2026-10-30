# sluice-engines

Build scripts for the open-source VPN engines bundled with the Sluice macOS app.
This repository exists to meet the source-availability terms of the GPL: everything
needed to rebuild the shipped engine binaries from pinned upstream sources is here.

| Engine | Version | License |
|---|---|---|
| [OpenSSL](https://www.openssl.org/) | 3.5.9 (LTS) | Apache-2.0 |
| [strongSwan](https://www.strongswan.org/) (charon) | 6.1.0 | GPL-2.0-or-later |
| [openfortivpn](https://github.com/adrienverge/openfortivpn) | planned | GPL-3.0 |

All engines are built as static, universal (arm64 + x86_64) binaries targeting macOS 15+,
with no Homebrew or other runtime dependencies.

## Requirements

- macOS on Apple Silicon or Intel, Xcode (or Command Line Tools)
- `curl`, `perl`, `make` (all ship with macOS)

## Build

```sh
scripts/fetch.sh            # download pinned sources, verify sha256
scripts/build-openssl.sh    # -> build/openssl/universal/{include,lib}
```

Pinned versions and checksums live in [`versions.env`](versions.env). A download whose
sha256 differs from the pinned value aborts the build.

Outputs:
- `build/<engine>/<arch>/` — per-architecture source tree and install prefix
- `build/<engine>/universal/` — merged universal result
- `dist/licenses/` — upstream license texts that ship next to the binaries

`sources/`, `build/` and `dist/` are not tracked.

## Project docs

- [docs/STATUS.md](docs/STATUS.md) — what's done, what's next, open questions
- [docs/DECISIONS.md](docs/DECISIONS.md) — build decisions and why

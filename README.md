# sluice-engines

Build scripts for the open-source VPN engines bundled with the Sluice macOS app.
This repository exists to meet the source-availability terms of the GPL: everything
needed to rebuild the shipped engine binaries from pinned upstream sources is here.

| Engine | Version | License |
|---|---|---|
| [OpenSSL](https://www.openssl.org/) | 3.5.9 (LTS) | Apache-2.0 |
| [strongSwan](https://www.strongswan.org/) (charon, swanctl) | 6.1.0 | GPL-2.0-or-later |
| [openfortivpn](https://github.com/adrienverge/openfortivpn) | 1.24.1 | GPL-3.0 (with OpenSSL exception) |

All engines are built as static, universal (arm64 + x86_64) binaries targeting macOS 15+,
with no Homebrew or other runtime dependencies.

## Requirements

- macOS on Apple Silicon or Intel, Xcode (or Command Line Tools)
- `curl`, `perl`, `make` (all ship with macOS)

## Build

```sh
scripts/fetch.sh            # download pinned sources, verify sha256
scripts/build-openssl.sh    # -> build/openssl/universal/{include,lib}
scripts/build-strongswan.sh # -> build/strongswan/universal/bin/{charon,swanctl}
scripts/build-tools.sh      # build-only m4/autoconf/automake -> build/tools (needed by the next step)
scripts/build-openfortivpn.sh # -> build/openfortivpn/universal/bin/openfortivpn
sudo scripts/smoke-charon.sh  # optional: run charon as root, verify loaded plugins
```

Live test against a FortiGate (IKEv2 dial-up, PSK + EAP-MSCHAPv2): copy
`scripts/connect-test.env.example` outside the repo, fill it in, then
`sudo scripts/connect-test.sh <env-file> [--arch x86_64] [--hold] [--public-ip]`.

Live test against a FortiGate SSL-VPN with openfortivpn: same idea with
`scripts/connect-test-sslvpn.env.example` and
`sudo scripts/connect-test-sslvpn.sh <env-file> [--arch x86_64] [--hold] [--otp]`.

Each build script verifies its output: all architectures present, `minos` 15.0 in
every object, only system libraries linked, no build-machine paths compiled in.

charon includes one plugin of our own, [`plugins/sluice-dns`](plugins/sluice-dns/sluice_dns_plugin.c)
(GPL-2.0-or-later): it requests DNS configuration attributes from the gateway and
publishes them per IKE_SA as files under `/var/run/sluice/dns/` for the host app,
instead of changing system DNS itself.

All paths compiled into the binaries (config files, plugin and module directories)
point into `/var/empty`; the host app supplies the real configuration at runtime
via `STRONGSWAN_CONF`. `pkg-config` is not required (a stub in `scripts/` stands in).
openfortivpn upstream ships only git tag archives, so its `configure` is generated
with autotools built from pinned GNU sources; no Homebrew is involved.

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

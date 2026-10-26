# Security Policy

> [!NOTE]
> This is a basic draft. The project is a work in progress and this policy may change.

## Supported versions

Security fixes are provided on a best-effort basis for:

* the `master` branch
* the latest release tag

## Reporting a vulnerability

Please report vulnerabilities privately via
[GitHub private vulnerability reporting](https://github.com/bitcoinix/bitcoinix/security/advisories/new).

**Do not open a public issue or pull request for a vulnerability.**

Please include:

* a description of the vulnerability and its impact
* the affected module, package or file, and the revision (commit or release tag)
* the configuration needed to reproduce it
* steps to reproduce or a proof of concept
* a suggested fix, if you have one

## What to expect

bitcoinix is maintained by volunteers. Reports are handled on a best-effort basis,
without a guaranteed response time or fix time.

There is no security fund and no bug bounty (this may be reconsidered in the future).
The project relies on responsible reports and on the good faith of the community.
Reporters are credited in the [Wall of Fame](#wall-of-fame), unless they wish to remain anonymous.

Please follow [coordinated vulnerability disclosure](https://en.wikipedia.org/wiki/Coordinated_vulnerability_disclosure)
and give the maintainers a reasonable time to fix an issue before publishing it.

## Scope

In scope are bugs in the bitcoinix modules, packages and tooling in this repository,
including insecure defaults and documentation that suggests insecure practices.

Vulnerabilities in upstream dependencies (e.g. Bitcoin Core, Core Lightning, LND, nixpkgs)
should be reported to the respective upstream project first.

## Dependency CVE scan

A CI job runs every Monday and Thursday at 06:00 UTC. It scans the runtime closure of a
representative node (the secure-node preset with all shipped services, defined in
`test/ci/scan-node.nix`) for known CVEs with
[vulnix](https://github.com/nix-community/vulnix). These are known issues in upstream
packages, not private reports.

Running twice a week keeps the cached NVD data within vulnix's seven-day window for
incremental updates. A missing cache or a longer gap still requires the yearly feeds.

Every run writes a summary of the findings that are not whitelisted to the run's step summary,
and uploads the full report as the `vulnix-report` artifact.

Maintainers can set the repository variable `CVE_SCAN_ISSUE` to the number of a pinned
tracking issue. The job then writes its report into that issue below a `<!-- cve-scan-report -->`
line and leaves everything above the line alone, so the description and triage notes can live
there. The body shows the report of the last run that changed the set of active CVEs. The job
comments only when that set changes, and the comment lists the new and the resolved CVEs. The
job never opens or closes issues.

### Triage

When the report changes (in practice, after a nixpkgs pin bump), a maintainer reads each new
CVE and picks one of these:

* move the nixpkgs pin to a revision with the fix (`helper/update-flake.sh`)
* override the package in `pkgs/` until nixpkgs has the fix
* add a whitelist entry, if the CVE does not apply to the package in the closure

A whitelist entry in [`.github/cve-whitelist.toml`](.github/cve-whitelist.toml) needs:

* a `[pname]` section for the package
* an explicit `cve = [...]` list, so that new CVEs for the package are still reported
* a `comment` that gives the reason, the date and how it was verified

The code owners review every change to the whitelist, because an entry can hide a real
vulnerability.

## Release signing

A bitcoinix release is a **signed, annotated git tag** (`v<version>`). There are no release
archives and no GitHub release assets. A tag that is not signed by one of the keys below
must not be trusted.

Releases are signed with SSH keys, not with GPG. The authoritative, machine-readable list is
[`helper/release-keys/ssh-allowed-signers`](helper/release-keys/ssh-allowed-signers);
the fingerprints below mirror it.

### Maintainer keys

**seberm** (GitHub: [seberm](https://github.com/seberm))

| Purpose | Type | Fingerprint |
| :-- | :-- | :-- |
| Release tags and commits | `sk-ecdsa-sha2-nistp256@openssh.com` | `SHA256:2o/0Op+64zKgF4oMaS0LGOiGPNDsibaqX6g8qMf5Hz0` |
| Offline rotation key | `ssh-ed25519` | `SHA256:BMLBnWuEhqLzNH+xUFRo0saOvOV/0ohz+OFqq93J+ec` |

The offline rotation key is listed like any other key, so it is also valid for release tags.
Its private half is kept offline and used only to announce key changes.

**prusnak** (GitHub: [prusnak](https://github.com/prusnak))

| Purpose | Type | Fingerprint |
| :-- | :-- | :-- |
| Release tags (and commits) | `ssh-ed25519` | `SHA256:oLKvKy47vtNC8pxFbbC18h1xdP6zAzEeAyzdjN3jWZE` |

Release tags are signed with this key only. This key is also listed at
<https://github.com/prusnak.keys>.

prusnak signs commits with this key or with the GPG key
`86E6 792F C27B FD47 8860  C110 91F3 B339 B9A0 2A3D` (`0x91F3B339B9A02A3D`), published at
<https://github.com/prusnak.gpg>. The GPG key is not valid for releases.

Keys whose signatures must be rejected are listed in
[`helper/release-keys/ssh-revoked-keys`](helper/release-keys/ssh-revoked-keys).

### Verifying a release

First check the keys file out of band. It lives in the repository it certifies, so it
cannot vouch for itself. The release tag key
(`SHA256:2o/0Op+64zKgF4oMaS0LGOiGPNDsibaqX6g8qMf5Hz0`) is also published outside this
repository at <https://seberm.com/ssh.html> (source: <https://github.com/seberm/seberm.com>),
in a statement signed with seberm's GPG key
`0AF6 4C3B 1F12 14B3 8C8C  5786 1FA2 DBE6 7438 7CC3` (`0x1FA2DBE674387CC3`) and with the
SSH key itself. Verify that statement as described on that page and compare the fingerprint
with the table above and with `helper/release-keys/ssh-allowed-signers`. GitHub also
independently marks tags and commits made with these keys as *Verified*.

Then verify the release tag and check it out, so that the scripts and key files you use
afterwards are the signed ones.

In a clone of this repository:

```bash
git config gpg.ssh.allowedSignersFile helper/release-keys/ssh-allowed-signers
git config gpg.ssh.revocationFile helper/release-keys/ssh-revoked-keys
git tag -l 'v*' --sort=-v:refname | head -1    # the latest release, e.g. v0.1.0
git tag -v v<version>
git checkout v<version>
```

A good signature prints
`Good "git" signature for seberm@seberm.com with ECDSA-SK key SHA256:2o/0Op+...`.
The same setting makes `git log --show-signature` verify commits.

`helper/fetch-release.sh` performs this verification itself and refuses to emit a hash for an
unsigned tag, a lightweight tag, a tag signed by a key that is not in the list, or a tag
signed by a revoked key.

### Key rotation

Keys are never removed from `ssh-allowed-signers`. A key that is retired, but not
compromised, gets `valid-before="YYYYMMDD"` instead, so that tags signed while it was still
valid keep verifying. A rotation is announced in a commit signed by the offline rotation key
and in a GitHub security advisory.

### Key compromise

`valid-before` does **not** protect against a compromised key: git checks it against the
date recorded in the tag, which whoever holds the key chooses. A leaked key could sign a
backdated tag for a new, higher version.

A compromised key is therefore added to
[`helper/release-keys/ssh-revoked-keys`](helper/release-keys/ssh-revoked-keys), and its line
stays in `ssh-allowed-signers`. Every tag signed by a revoked key is rejected, whatever date it
claims, including releases made before the compromise. Those releases are re-cut under a new
version, signed by a valid key. The compromise is announced in a GitHub security advisory.
CI verifies only the latest release tag. If the revoked key signed it, CI fails until the
re-cut release is published.

### Known limitation

Releases carry no signed "latest version" metadata. An attacker who can withhold tags can
keep a user on an older but validly signed release. Pass `releaseVersion=` to `fetch-release` to
pin a release explicitly.

Release tags are protected on GitHub, so they cannot be deleted or force-pushed. In case
that protection is bypassed, `fetch-release` records the version in `nix-bitcoin-release.nix`
and `update-nix-bitcoin` refuses to move to a release older than the one pinned there.

## Wall of Fame

### bitcoinix

| Researcher | Report | Advisory | Fix |
| :-- | :-- | :-- | :-- |
| [ostermayer](https://github.com/ostermayer), [bobberb](https://github.com/bobberb) | `lnd-create-macaroons` and the RTL credential scripts followed symlinks in service-user directories as root | [GHSA-m72m-4gw2-mfqw](https://github.com/bitcoinix/bitcoinix/security/advisories/GHSA-m72m-4gw2-mfqw) | [#34](https://github.com/bitcoinix/bitcoinix/pull/34), [#47](https://github.com/bitcoinix/bitcoinix/pull/47) |
| [ostermayer](https://github.com/ostermayer) | `onion-addresses` copied Tor hostname files unchecked as root (config injection, operator-to-root race) | [GHSA-cc4h-g372-wqv3](https://github.com/bitcoinix/bitcoinix/security/advisories/GHSA-cc4h-g372-wqv3) | [#43](https://github.com/bitcoinix/bitcoinix/pull/43) |
| [ostermayer](https://github.com/ostermayer) | The clightning config was written through a symlink in a group-writable data dir (operator to clightning code execution) | [GHSA-m787-rw34-jpm3](https://github.com/bitcoinix/bitcoinix/security/advisories/GHSA-m787-rw34-jpm3) | [#94](https://github.com/bitcoinix/bitcoinix/pull/94), [#114](https://github.com/bitcoinix/bitcoinix/pull/114) |

All three are fixed in 0.1.1.

### Upstream nix-bitcoin

These reports were handled by the upstream nix-bitcoin project.

| Researcher | Report | Fix | Reward | Payout transaction |
| :-- | :-- | :-- | :-- | :-- |
| [haoxucu](https://github.com/haoxucu) | `netns-exec` was executable by all normal users | [`34a18f92`](https://github.com/fort-nix/nix-bitcoin/commit/34a18f92eeacc754e5857249aaf8decf24e98cde) | 5% of the fund | [`5b93fbad…eb888`](https://mempool.space/tx/5b93fbad4b9a2c35daaf40b74fc76f0b69d2b75bc4da927cd3398dbc432eb888) |
| [haoxucu](https://github.com/haoxucu) | `lnd-create-macaroons` exposed the LND admin macaroon in `curl`'s process arguments | [`df184b6e`](https://github.com/fort-nix/nix-bitcoin/commit/df184b6e06cc3404add42ccf5ae68306395e8d6c) | 10% of the fund | [`5b93fbad…eb888`](https://mempool.space/tx/5b93fbad4b9a2c35daaf40b74fc76f0b69d2b75bc4da927cd3398dbc432eb888) |
| Mehdi Kerimov | `fetch-release` did not verify `nar-hash.txt` when `nar-hash.txt.asc` contained an inline signed message | [`da27f270`](https://github.com/fort-nix/nix-bitcoin/commit/da27f27026d92841e3ea91e100608ed9854ac013) | 15% of the fund | [`a0c5821e…83f3`](https://mempool.space/tx/a0c5821edcd45af98e5c0818560535a24c1a6dba29b5a4a05149ab1003c783f3) |

## Historical: upstream security fund

The upstream nix-bitcoin security fund is closed. Do not send donations to its former address.
The former policy is preserved in the upstream repository history and in the `forked` tag of this repository.

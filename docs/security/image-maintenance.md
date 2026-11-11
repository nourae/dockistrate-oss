# Image Maintenance

Dockistrate pins its fresh-state Nginx and Certbot defaults to multi-platform
manifest digests. A digest selects immutable content, including the platform
manifest Docker chooses for the host. The version tag makes the selection
readable; the digest is what pins it. A digest does not authenticate a publisher,
validate a signature, or establish that the image has no vulnerabilities.
[Docker documents this distinction and the need to refresh pinned images](https://docs.docker.com/reference/cli/docker/image/pull/#pull-an-image-by-digest-immutable-identifier).

Existing saved selections and custom operator overrides remain supported. This
change does not migrate state, enforce an image allowlist, change pull behavior,
or add runtime vulnerability warnings. `status` and `upgrade-preflight` do not
scan images or determine whether an existing custom selection is patched.

## Reviewed Defaults

Registry and upstream metadata reviewed on **2026-10-17**:

```text
nginx:1.31.7@sha256:6c3fee1d7a4686ea271e9cc60d9c741cdfbc44ecf11d343025e1cff4c5522f47
certbot/certbot:v5.8.0@sha256:f70ad0adbb7e117f0fe42a63c553f28ea451edabc0148757b6efcd9735acaa20
```

Both indexes were fetched from Docker Hub by their exact digests. The requested
digest, registry `Docker-Content-Digest` header and SHA-256 of the retrieved bytes
matched. The published runnable platform manifests are:

| Image | Platform | Manifest digest |
| --- | --- | --- |
| Nginx | `linux/amd64` | `sha256:6c7972b94d62ce93357d1e0d0ef6d3db8a2e9b8b6f3234d943d60ecbc4f4eb31` |
| Nginx | `linux/arm/v5` | `sha256:eb43f419aa7992710bc3afefa85f9785333bcee1c877239aab2065363c0fa57e` |
| Nginx | `linux/arm/v7` | `sha256:f0d9c93ec657dc6480e8ec9f6f1322aee68fc2b6f2468b378c38c0ae7b39b42d` |
| Nginx | `linux/arm64/v8` | `sha256:e95ac52a5d8e9737ac362e9e4ff84c1584061fa9305a6832d66536d85dba0850` |
| Nginx | `linux/386` | `sha256:08da49e7dbe959c3082b2ec7086171946aa917c17db70ff7fe7add1687595688` |
| Nginx | `linux/ppc64le` | `sha256:62fb280e72986681013df7ebd82f5d62fc8b7947a7ab8c8b9e3267297fece451` |
| Nginx | `linux/s390x` | `sha256:43ed5d45d5cca454ac50736b4427f2d31bae943ffde159f06d9f8a2e40528b7c` |
| Certbot | `linux/amd64` | `sha256:398c47284a6d6782825be71685f677ef3a1e65b8b5c278a8b1e99f6da84b4eb9` |
| Certbot | `linux/arm/v6` | `sha256:0392d1a47ed8a0b9d030be8dffae205ccae1013eb6e81decc73fa49cdb8cf6cf` |
| Certbot | `linux/arm64` | `sha256:778be53ef0aaea7ab52e14d251c17847dd212e70221e99dc88d8ce6c84716cca` |

Nginx's `unknown/unknown` index entries are attestations, not runnable platforms.
Although the upstream build listing included `riscv64`, that platform was absent
from the retrieved index; this pin does not claim to provide it.

Nginx `1.31.7`, released on 2026-10-14, preserves the project's mainline Debian
image family. Its [Dockerfile at source revision `4b9f658`](https://github.com/nginx/docker-nginx/blob/4b9f658be76820b24e4ef4605413a5c08707a512/mainline/debian/Dockerfile)
uses `debian:trixie-slim`. The
[official image listing](https://github.com/docker-library/official-images/blob/master/library/nginx)
and [published artifact details](https://github.com/docker-library/repo-info/blob/master/repos/nginx/remote/1.31.7.md)
were compared with registry metadata.

The [Nginx advisory review](https://nginx.org/en/security_advisories.html) found
the former default `1.31.2` in these affected ranges; `1.31.7` includes the listed
fixes:

| First fixed mainline release | Advisories |
| --- | --- |
| `1.31.3` | CVE-2026-42533, CVE-2026-60005, CVE-2026-56434 |
| `1.31.6` | CVE-2026-90439 |
| `1.31.7` | CVE-2026-15176, CVE-2026-93479, CVE-2026-95101, CVE-2026-97629, CVE-2026-97205 |

The advisory prerequisites differ by module and configuration. This version
comparison does not establish exploitability of Dockistrate's generated config
and is not a scan of every image package. Consult the
[upstream changelog](https://nginx.org/en/CHANGES) and current advisories when
reviewing a later refresh.

Certbot `v5.8.0` retains the supported major version while updating the image
base. Its [Dockerfile at source revision `d050f5c`](https://github.com/certbot/certbot/blob/d050f5ced828d90faf4304a752c9a6848416216a/tools/docker/Dockerfile)
uses Python 3.14 on Alpine 3.23; the retrieved AMD64 config records Python 3.14.7
and Alpine 3.23.5. The old `v5.2.1` image used Alpine 3.20.6, whose branch ended
normal support on 2026-04-01 according to the
[Alpine release lifecycle](https://alpinelinux.org/releases/). This is a
maintenance update, not a claim that Certbot `v5.2.1` itself had a demonstrated
vulnerability. See the [Certbot release](https://github.com/certbot/certbot/releases/tag/v5.8.0)
and [support policy](https://github.com/certbot/certbot/blob/main/SECURITY.md).

### Evidence and Limits

- Nginx AMD64 and ARM64 SPDX 2.3 SBOMs and SLSA v0.2 provenance statements were
  retrieved. Their blob hashes and subjects match the corresponding platform
  manifests, and the source revision matches the Dockerfile above. The retrieved
  statements are unsigned in-toto JSON; this verifies content relationships,
  not an independent publisher signature. Other platform attestations were not
  assessed in this review.
- For the selected Certbot index, the checked OCI referrers endpoint returned
  no entries, the index contained no embedded attestations, and the checked
  legacy `.sig`, `.att` and `.sbom` locations returned 404. No container signature,
  provenance statement or SBOM was verified through those locations. Certbot's
  source-release `SHA256SUMS.asc` does not authenticate this container image.
- The bounded package assessment below found remaining dependency advisories.
  It does not establish that either image is vulnerability-free or fully
  authenticated.

The retrieved Nginx evidence blobs are addressable in the same registry
repository:

| Platform | Evidence | Blob SHA-256 |
| --- | --- | --- |
| AMD64 | SPDX SBOM | `2b7d75aa46525a15dbefcce68efa47e142d5f0d05bbd195f548d011e71436482` |
| AMD64 | SLSA provenance | `3a5a894bf2b2310d1e9d7f51750d82afaecdc46edca3da6c80aa867548c86b98` |
| ARM64 | SPDX SBOM | `0e0b97939a66c747e14638cdd8091868c669bdc694196006a5f7c9dd6fb4392d` |
| ARM64 | SLSA provenance | `e7c92ea269f5475759a74c2f3557fc44915e33de069e5775fbccbeb7d337e2b5` |

### Package Assessment and Follow-up

An OSV API v1 package-metadata assessment completed on **2026-10-17 at
12:15 UTC**, covering `linux/amd64` and `linux/arm64` for both pins. It used
Nginx's attached SBOMs mapped to Debian source packages, and Certbot's APK/Python
metadata read from digest-verified layers. This was not a complete filesystem
scan or exploitability test. Trivy's database exceeded the available storage
budget; the Grype database endpoint returned 403. Live OSV query times and record
modification times were retained; OSV provides no single immutable database
snapshot for these requests.

| Image, per assessed platform | Package queries | Advisory matches |
| --- | --- | --- |
| Nginx | 110 Debian source packages | 178 distinct Debian IDs across 36 source packages |
| Certbot | 57 nonvirtual APK-source/PyPI packages | 13 advisory IDs, deduplicating to 10 CVEs across 3 packages |

These are package-version matches, not demonstrated exploits. Debian classified
66 matches as `unimportant` and 112 as urgency not yet assigned. Six Expat
records have a fixed trixie source version of `2.9.0-1~deb13u1`, while the image
contains `2.8.3-1~deb13u1`; see [DSA-6566-1](https://security-tracker.debian.org/tracker/DSA-6566-1).
Application reachability was not established, and one matched record concerns
32-bit arithmetic. The other 172 Debian records had no fixed trixie version in
their OSV ranges; this does not mean no upstream or other-distribution fix exists.

Certbot contains urllib3 `2.7.0`, with these vendor advisories fixed in `2.8.0`:

| Advisory | Vendor severity | Relevant behavior |
| --- | --- | --- |
| [CVE-2026-97687](https://github.com/urllib3/urllib3/security/advisories/GHSA-8988-9cw3-xx77) | High | HTTPS proxy and target TLS settings can be mixed under specific proxy configurations |
| [CVE-2026-97688](https://github.com/urllib3/urllib3/security/advisories/GHSA-gh4c-6fx4-qh6g) | Moderate | A crafted chunked Deflate response can cause a CPU loop |
| [CVE-2026-97689](https://github.com/urllib3/urllib3/security/advisories/GHSA-vxq7-64xx-v4gw) | High | An unbounded HTTP chunk-size line can exhaust memory |

The [ACME client](https://github.com/certbot/certbot/blob/d050f5ced828d90faf4304a752c9a6848416216a/acme/src/acme/client.py)
uses Requests. Its default `stream=False` still consumes `Response.content`
through urllib3's `raw.stream`, so it does not rule out the response-processing
issues; see [Requests' body-reading implementation](https://github.com/psf/requests/blob/v2.34.2/src/requests/models.py).
Those issues require a malicious ACME HTTP response; no exploit or compromise
of an ACME service was demonstrated. The proxy-specific conditions were not
established in the default client setup.

The six Certbot util-linux matches concern mount/libmount or nsenter, whereas
only `libuuid` from that source package appeared in the retained APK inventory.
They are source-package matches, not six established privilege-escalation paths.
Its zlib `1.3.2-r0` also matches CVE-2026-85091, fixed by Alpine in `1.3.2-r1`;
the nonblocking `gzwrite`/`gzprintf` trigger was not established in Certbot.
See [Alpine's package advisory feed](https://secdb.alpinelinux.org/v3.23/main.json).

Coverage excludes other published platforms, Certbot's Python interpreter and
native bundled libraries outside APK/PyPI metadata. Nginx inventories are
publisher-provided and were not independently authenticated. Package matching
and source-path review do not establish runtime reachability or complete
advisory coverage; an empty match list would not prove safety.

The release-tag checks at 12:17–12:22 UTC on 2026-10-17 still returned the selected
digests: Nginx `1.31.7`, and Certbot `v5.8.0`/`latest` with no newer stable rebuild.
The defaults retain these official released images. Follow up when
official rebuilds incorporate urllib3 `2.8.0` or newer and the vendor package
fixes, then refresh the digests and repeat the platform assessment. Nightly
substitution or in-place `pip` overrides are not part of this maintenance change.

### Reassessment on 2026-10-20

A bounded registry and advisory reassessment completed on **2026-10-20**.
The 2026-10-17 inventory and counts above remain the historical
baseline. This follow-up retrieved registry indexes, AMD64/ARM64 platform
manifests and Nginx's attached SBOMs again, checking their content digests.
It repeated advisory matching against the retained package inventories and
checked vendor records for the outstanding and newly matched advisories.
It did not pull or rebuild images, run a filesystem scanner, or test exploits.

The Nginx `1.31.7` and `latest` tags now resolve to index
`sha256:bc4cad49969aaf95eb4eecec5572846f86e59f1e8332aba36ed64b91aff8b724`.
All seven runnable platform digests shared with the configured default index
remain unchanged, including AMD64 and ARM64. The new index adds `linux/riscv64`
at `sha256:f3f61eaa75222f6c02904a61bcfb87f8fff220e38fe9479cac37b281fe328b70`;
that platform's packages were not assessed. An updated index therefore does
not establish a package-fix rebuild for the existing platforms. See the
[official image artifact listing](https://github.com/docker-library/repo-info/blob/master/repos/nginx/remote/1.31.7.md).

Certbot `v5.8.0` and `latest` still resolve to the selected
`sha256:f70ad0adbb7e117f0fe42a63c553f28ea451edabc0148757b6efcd9735acaa20`
index and the same three runnable platform manifests. The
[latest stable source release](https://github.com/certbot/certbot/releases/tag/v5.8.0)
remains `v5.8.0`; newer entries in the
[publisher's tag listing](https://hub.docker.com/r/certbot/certbot/tags)
are nightly builds.

The unchanged AMD64/ARM64 images retain the documented Expat, urllib3 and zlib
versions. Their vendor fixes remain Expat `2.9.0-1~deb13u1`, urllib3 `2.8.0`,
and Alpine zlib `1.3.2-r1`; the reachability limits above still apply.
The [Debian Expat advisory](https://security-tracker.debian.org/tracker/DSA-6566-1),
[urllib3 vendor advisories](https://github.com/urllib3/urllib3/security/advisories),
and [Alpine package feed](https://secdb.alpinelinux.org/v3.23/main.json)
were checked again. Nginx `1.31.7` remains outside the affected ranges for the
version-specific issues in the current
[Nginx advisory list](https://nginx.org/en/security_advisories.html).

Two new package matches require follow-up:
[CVE-2026-112060](https://security-tracker.debian.org/tracker/CVE-2026-112060)
and [CVE-2026-112061](https://security-tracker.debian.org/tracker/CVE-2026-112061),
published on 2026-10-18. The Nginx inventories include `librtmp1` from
`rtmpdump` source version `2.4+20151223.gitfa8646d.1-2`. The advisories concern
memory errors while decoding malicious RTMP responses. Debian currently marks
the trixie package's status **undetermined** and lists no fixed version.
No affected RTMP execution path in Dockistrate or exploit was demonstrated.
These additions bring the Nginx match count to **180 Debian IDs across 37
source packages per assessed platform**; Certbot remains at **13 advisory IDs
covering 10 CVEs across three packages**. These remain metadata matches, not
counts of demonstrated vulnerabilities in a deployment.

The official default pins remain unchanged. Continue tracking official
rebuilds and vendor dispositions before proposing a digest refresh. Saved
selections and custom operator choices remain supported; this reassessment
does not upgrade containers or install packages inside them.

## Updating an Existing Installation

Image updates are separate from a Dockistrate release update. Checking out new
code preserves saved image selections; use the [update guide](../guides/updates.md)
for release checkout and state migration.

Back up state and record the current references with `status`. Apply each image
selection explicitly:

```bash
./dockistrate.sh create-backup
./dockistrate.sh status
./dockistrate.sh set-nginx-image nginx:1.31.7@sha256:6c3fee1d7a4686ea271e9cc60d9c741cdfbc44ecf11d343025e1cff4c5522f47 if-missing
./dockistrate.sh set-certbot-image certbot/certbot:v5.8.0@sha256:f70ad0adbb7e117f0fe42a63c553f28ea451edabc0148757b6efcd9735acaa20 if-missing
./dockistrate.sh check-config
./dockistrate.sh status
```

In `./dockistrate.sh -i`, select `set-nginx-image` or `set-certbot-image`, choose
manual image entry, paste the full reference, select the pull mode and review
the command. Both modes use the same setters. The Nginx setter recreates the
proxy; the Certbot setter affects subsequent certificate operations.

Before upgrading Certbot from `v5.2.1`, review existing deploy directory hooks.
Since `5.3.0`, those hooks also run during new `certonly`/`run` issuance, not just
renewals. This upstream behavior change matters to operators with custom hooks;
see the [Certbot changelog](https://github.com/certbot/certbot/blob/d050f5ced828d90faf4304a752c9a6848416216a/certbot/CHANGELOG.md).
Validate issuance and renewal in a staging environment before updating a
production installation that relies on them.

Existing pull semantics remain unchanged: `:latest` without a digest attempts
an explicit pull in both `always` and `if-missing` modes; `never` skips that pull.
Non-`latest` tags and all digest references skip explicit pulls in every mode.
Docker may fetch any missing reference during container creation, so `never`
does not promise offline operation. See the
[pull-policy table](../guides/advanced-nginx-docker-options.md#images).

## Controlled Digest Refresh

1. Review upstream releases, security advisories and base-distribution support
   dates. Record the review date, source URLs, selected source revision, build
   recipe and known compatibility changes. Do not rely only on the tag name.
2. Retrieve the registry index, calculate its SHA-256 and compare it with the
   registry header. Fetch it again by that digest, record every runnable
   platform manifest and inspect the deployment platforms' image/config
   manifests. Separate attestation entries from runnable platforms. Registry
   inspection tools such as `docker buildx imagetools inspect` are appropriate
   here because Dockistrate has no registry-metadata command.
3. Check available publisher signatures against an independently selected
   trusted identity or key. Verify attestation subjects, source revisions,
   builder identity and materials. Record exactly what was authenticated and
   what only had matching content hashes. If signatures or provenance are
   absent or unsupported, record that limitation explicitly.
4. Retrieve or generate a platform-specific SBOM and scan OS and language
   packages with a current vulnerability database. Record the image/platform
   digest, SBOM hash, scanner/version, database version/time, scan command,
   findings and disposition. Record a blocked or unavailable scan as such;
   do not replace missing results with an upstream version check.
5. Update default references, this evidence record, README, affected guides,
   function-reference narrative and Unreleased changelogs, including the public
   packaging override. Update the default-image sync and image/pull-mode tests.
   Preserve saved/custom selections and document any deliberate behavior change.
6. Regenerate function-reference appendices and HTML. Run relevant Bash 3 and
   GNU Bash tests and Linux/macOS CI. Use Dockistrate in an isolated live fixture
   to validate a backend request, `check-config`, configured TLS/HTTP features,
   and any affected certificate workflow. Record the exact tested digests.
7. Review the evidence and outstanding limitations in the maintenance PR before
   merging. Operators then update saved selections explicitly using the workflow
   above. Recheck advisories and refresh deliberately: pinned content does not
   receive later base-package fixes merely because the version tag was rebuilt.

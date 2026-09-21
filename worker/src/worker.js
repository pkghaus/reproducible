// reproducible.pkg.haus - the archive's reproducibility verdicts.
//
// Reads one JSON verdict per published artifact from R2 and renders them. It
// never writes: the verdicts are produced by scripts/verify.sh in CI and
// uploaded from there, and this Worker's binding is to a DIFFERENT bucket from
// the archive's on purpose. Not because this Worker would abuse a shared one
// -- buildinfos reads the archive's bucket and is fine -- but because R2 API
// tokens scope to whole buckets, so the CI credential that writes verdicts
// would equally be able to write pool/ and dists/. See wrangler.toml.
//
// The page furniture below is a COPY of buildinfos.pkg.haus's, which is a copy
// of apt.pkg.haus's, not an approximation. Three hosts, one surface, and a
// reader moves between them. the estate style registry records it; when a
// surface and that page disagree, one of them is wrong and it gets fixed in the
// same change.

const PREFIX = "verify/";

const DESCRIPTION =
  "Whether each package in the pkg.haus archive rebuilds byte-for-byte from its own build record.";

// 16px hardcoded-color variant, per the size ladder: at or below 48px the cut
// is the straight-tape one.
const FAVICON = `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 64 64" width="16" height="16">
<path d="M32 8 L54 19 V45 L32 56 L10 45 V19 Z" fill="#FFFFFF"/>
<g stroke="#141414" stroke-width="4.5" stroke-linejoin="round" stroke-linecap="round" fill="none">
<path d="M10 19 L32 30 L54 19"/><path d="M32 30 V56"/>
<path d="M32 8 L54 19 V45 L32 56 L10 45 V19 Z"/></g>
<path d="M14.484 14.242 L22.484 10.242 L47 22.5 L47 28.5 L39 32.5 L39 26.5 Z" fill="#E0421B"/>
<path d="M21 20 L27 26 V33 H15 V26 Z" fill="#141414" transform="matrix(1,0.5,0,1,0,0)"/></svg>`;

const PAGE_MAX_AGE = 300;
const JSON_MAX_AGE = 300;

// rebuilderd's vocabulary, kept so this page reads the same way as
// reproducible.archlinux.org and reproduce.debian.net.
const STATUSES = ["GOOD", "BAD", "UNKWN"];
const INVENTORY_KEY = "inventory.json";
const INDEX_KEY = "verdicts.json";

function esc(s) {
  return String(s).replace(/[&<>"]/g, (c) =>
    ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" })[c]);
}

export async function listAll(bucket, prefix, delimiter) {
  const objects = [];
  const prefixes = [];
  let cursor;
  do {
    const page = await bucket.list({ prefix, delimiter, cursor, limit: 1000 });
    objects.push(...page.objects);
    if (page.delimitedPrefixes) prefixes.push(...page.delimitedPrefixes);
    cursor = page.truncated ? page.cursor : undefined;
  } while (cursor);
  return { objects, prefixes };
}

const STYLE = `
/* Tokens, and every shared rule below, are apt.pkg.haus's. This host is a copy
   rather than an approximation; the estate style registry records it. */
:root{
--paper:#FFFFFF;--ink:#141414;--muted:#6B6B66;
--line:#E4E4DF;--accent:#E0421B;
/* The brand red measures 4.23:1 on white: fine for the mark, the dots and
   headings, which are large text needing 3:1, and short of the 4.5:1 small
   text needs. Small text gets a darker step; everything seen at size keeps the
   brand value. Dark mode passes at 5.92:1, so there the two are the same. */
--accent-text:#CC3B18;--code-bg:#F7F6F3;
/* The news chips' green and amber, reused: GOOD is the archive's "added",
   UNKWN its "updated". BAD takes --accent-text, which the chips give security.
   Registered as consumers in web-style.md's optional-token table. */
--ok:#4A7C3A;--chg:#8A6012;
--mono:ui-monospace,Menlo,Consolas,monospace}
@media(prefers-color-scheme:dark){:root{
--paper:#0E0E0E;--ink:#F0F0EC;--muted:#8F8F88;
--line:#2A2A27;--accent:#F0603C;--accent-text:#F0603C;--code-bg:#131311;
--ok:#7FB56F;--chg:#D9A853}}
*{box-sizing:border-box}
body{background:var(--paper);color:var(--ink);
font-family:system-ui,"Segoe UI",Roboto,"Helvetica Neue",sans-serif;
line-height:1.55;margin:0;padding:0 1.25rem 4rem}
main{max-width:46rem;margin:0 auto}
header{display:flex;align-items:center;gap:1rem;flex-wrap:wrap;
padding:2.25rem 0 1.25rem;border-bottom:3px solid var(--ink)}
/* Same clear space under the header's rule as above the footer's. */
header+*{margin-top:0;padding-top:2rem}
h1{font-family:var(--mono);font-size:clamp(1.9rem,6vw,2.6rem);letter-spacing:-.03em;
margin:0;line-height:1.15;min-width:0}
h1 .dot,h1 .sep{color:var(--accent)}
h1 .path{font-size:.65em}
h1 .gap{color:var(--muted)}
h1 a{color:inherit;text-decoration:none}
h1 a:hover{text-decoration:underline;text-decoration-color:var(--accent);text-underline-offset:.18em;text-decoration-thickness:.07em}
.tagline{flex-basis:100%;color:var(--muted);margin:.75rem 0 0;max-width:38rem}
.tablewrap{overflow-x:auto;padding:1.5rem 0}
.tablewrap:has(+ footer){padding-bottom:0}
table{border-collapse:collapse;width:100%;font-size:.92rem}
th,td{text-align:left;padding:.5rem .75rem .5rem 0;
border-bottom:1px dashed var(--line);vertical-align:top}
th{font-family:var(--mono);font-size:.7rem;letter-spacing:.12em;
text-transform:uppercase;color:var(--muted);font-weight:600}
td.size{text-align:right;color:var(--muted);
font-variant-numeric:tabular-nums;white-space:nowrap}
th.size{text-align:right}
code{font-family:var(--mono)}
a{color:var(--accent-text);text-decoration:none}
a:hover{text-decoration:underline}
footer{border-top:3px solid var(--ink);margin-top:2rem;
padding-top:1.5rem;display:flex;gap:1.5rem;
flex-wrap:wrap;font-size:.85rem;color:var(--muted)}
footer a{color:inherit}
footer a:hover{color:var(--accent-text)}

/* This host's own. A verdict is a word, and the word is the data: it gets the
   mono face the table headers use so GOOD and UNKWN line up in a column. */
.v{font-family:var(--mono);font-size:.72rem;letter-spacing:.08em;font-weight:600;
white-space:nowrap}
.v.good{color:var(--ok)}
.v.bad{color:var(--accent-text)}
.v.unkwn{color:var(--chg)}
.v.none{color:var(--muted)}
td.pkg{font-family:var(--mono);white-space:nowrap}
td.ver{font-family:var(--mono);font-size:.85rem;color:var(--muted);white-space:nowrap}
td.tgt{white-space:nowrap}
/* The matrix cell: six verdicts on one row, suite-major. A fixed column width
   keeps them aligned down the table without a nested table's row rules. */
.matrix{display:flex;gap:.55rem;flex-wrap:wrap}
.matrix span{min-width:3.4rem}
.pct{font-variant-numeric:tabular-nums;white-space:nowrap}
/* The registry: "tabular-nums on numeric cells, numeric/size columns
   right-aligned". good/bad/unkwn are counts, so they take it too. Styling them
   as text also put a right-aligned cell next to a left-aligned one, and with
   .75rem of right padding and no left padding that was the tightest boundary
   in the table while every other one looked twice as wide. */
td.num,th.num{text-align:right;font-variant-numeric:tabular-nums;white-space:nowrap}
/* The archive's own line, so it reads as the sum of the column rather than
   another target. */
tr.tot td{border-top:2px solid var(--ink);border-bottom:none;padding-top:.6rem}
tr.tot td.size{color:var(--ink)}

.about{border-top:1px solid var(--line);margin-top:2rem;padding-top:2rem}
.about h2{font-family:var(--mono);font-size:.78rem;font-weight:600;
letter-spacing:.16em;text-transform:uppercase;color:var(--muted);
margin:1.75rem 0 .6rem}
.about h2:first-child{margin-top:0}
.about h2::before{content:"~ ";color:var(--accent)}
.about p{margin:0 0 .9rem;max-width:38rem}
.about>:last-child{margin-bottom:0}
.about code{font-size:.9em}
pre{background:var(--code-bg);border:1px solid var(--line);
border-left:3px solid var(--accent);padding:1rem 1.1rem;overflow-x:auto;
font-family:var(--mono);font-size:.82rem;line-height:1.6;margin:.75rem 0}
pre .c{color:var(--muted)}
`;

const MARK = `<svg width="80" height="80" viewBox="0 0 64 64" role="img" aria-label="pkg.haus - a taped parcel with a haus stenciled on its face">
<path d="M32 8 L54 19 V45 L32 56 L10 45 V19 Z" fill="var(--paper)"/>
<g stroke="currentColor" stroke-width="2.4" stroke-linejoin="round" stroke-linecap="round" fill="none">
<path d="M10 19 L32 30 L54 19"/><path d="M32 30 V56"/>
<path d="M32 8 L54 19 V45 L32 56 L10 45 V19 Z"/></g>
<path d="M15.658 14.829 L23.658 10.829 L47 22.5 L47 28.5 L45.7 27.2 L44.3 29.8 L43 28.5 L41.7 31.2 L40.3 29.8 L39 32.5 L39 26.5 Z" fill="var(--accent)"/>
<path d="M21 20 L27 26 V33 H15 V26 Z" fill="currentColor" transform="matrix(1,0.5,0,1,0,0)"/></svg>`;

function footer() {
  const now = new Date();
  const iso = now.toISOString().replace(/\.\d+Z$/, "Z");
  const stamp = iso.replace("T", " ").replace("Z", " UTC");
  return `<footer><a href="https://pkg.haus">pkg.haus</a>
<a href="https://apt.pkg.haus">apt</a>
<a href="https://buildinfos.pkg.haus">buildinfos</a>
<a href="https://github.com/pkghaus">github.com/pkghaus</a>
<span>listed <time datetime="${iso}">${stamp}</time></span>
<span>Apache-2.0</span></footer>`;
}

// Byte-identical to the block apt.pkg.haus, /stats and buildinfos run, so all
// four agree on the format.
const LOCALISE = `
  document.querySelectorAll("time[datetime]").forEach(function (t) {
    t.textContent = new Date(t.getAttribute("datetime")).toLocaleString([], {
      year: "numeric", month: "2-digit", day: "2-digit",
      hour: "2-digit", minute: "2-digit", second: "2-digit",
      hour12: false, timeZoneName: "short"
    });
  });
`;

const PLAUSIBLE_INIT = `
  window.plausible=window.plausible||function(){(plausible.q=plausible.q||[]).push(arguments)},plausible.init=plausible.init||function(i){plausible.o=i||{}};
  plausible.init({ endpoint: "/zk/api/event" })
`;

function page(title, body) {
  return `<!doctype html><html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="description" content="${esc(DESCRIPTION)}">
<link rel="icon" type="image/svg+xml" href="/favicon.svg">
<title>${esc(title)}</title>
<script defer src="/zk/js/script.js"></script>
<script>${PLAUSIBLE_INIT}</script>
<style>${STYLE}</style></head><body><main>
${body}${footer()}</main><script>${LOCALISE}</script></body></html>`;
}

export function breadcrumb(rel) {
  const wordmark = '<a href="/">reproducible<span class="dot">.</span>pkg'
    + '<span class="dot">.</span>haus</a>';
  if (!rel) return wordmark;
  const sep = '<span class="sep">/</span>';
  return `${wordmark}<span class="path">${sep}${esc(rel)}</span>`;
}

function header(rel, tagline) {
  return `<header>${MARK}<h1>${breadcrumb(rel)}</h1>`
    + (tagline ? `<p class="tagline">${tagline}</p>` : "") + `</header>`;
}

// Stable first, so the column order matches how a reader upgrades.
export const SUITES = ["trixie", "testing", "unstable"];
export const ARCHES = ["amd64", "arm64"];

// trixie's X~haus13+1 and testing's X~testing1 are the same upstream release
// and Debian revision as unstable's bare X. The package row names that shared
// version once rather than three near-identical strings.
export function baseVersion(v) {
  return String(v).replace(/~(haus\d+\+\d+|testing\d+)$/, "");
}

export function verdictClass(status) {
  return { GOOD: "good", BAD: "bad", UNKWN: "unkwn" }[status] || "none";
}

// One cell per suite+arch. A target with no verdict yet is "-" rather than a
// guess: an artifact nobody has tried is not the same as one that failed, and
// the summary counts it separately for the same reason.
function verdictCell(status, title) {
  const s = status || "-";
  return `<span class="v ${verdictClass(status)}" title="${esc(title)}">${esc(s)}</span>`;
}

// Coverage and reproducibility are two different numbers and a page that
// shows one while hiding the other turns absence into success. `checked`
// counts verdicts; `published` counts what the archive actually serves, which
// only the inventory knows - an artifact nobody has tried leaves no verdict to
// count. The percentage stays over DECIDED verdicts, because a denominator of
// everything published would fall as the fleet grows and say nothing about
// reproducibility. UNKWN is reported beside it, never folded in.
export function summarise(verdicts, inventory) {
  const rows = [];
  for (const suite of SUITES) {
    for (const arch of ARCHES) {
      const hits = verdicts.filter((v) => v.suite === suite && v.arch === arch);
      const counts = Object.fromEntries(
        STATUSES.map((s) => [s, hits.filter((v) => v.status === s).length]));
      const decided = counts.GOOD + counts.BAD;
      rows.push({
        suite, arch, ...counts, decided,
        checked: hits.length,
        published: publishedFor(inventory, suite, arch),
        pct: decided ? Math.round((counts.GOOD / decided) * 1000) / 10 : null,
      });
    }
  }
  return rows;
}

// An absent or malformed inventory reports 0 published rather than guessing
// from the verdicts, which would make coverage read 100% exactly when the
// inventory is the thing that broke.
export function publishedFor(inventory, suite, arch) {
  const list = inventory && inventory.targets && inventory.targets[`${suite}/${arch}`];
  return Array.isArray(list) ? list.length : 0;
}

export function totals(rows) {
  const sum = (k) => rows.reduce((n, r) => n + r[k], 0);
  const good = sum("GOOD");
  const decided = good + sum("BAD");
  return {
    GOOD: good, BAD: sum("BAD"), UNKWN: sum("UNKWN"),
    checked: sum("checked"), published: sum("published"),
    pct: decided ? Math.round((good / decided) * 1000) / 10 : null,
  };
}

// The percentage AND what it is a percentage of. "100%" next to "checked 22"
// reads as 22 of 22, and when one of those 22 is UNKWN it is 21 of 21 - the
// reader has no way to know that from a bare percentage, and the arithmetic
// they can do lands on 95.5%. Naming the denominator in the cell is cheaper
// than a legend nobody reads.
function pctCell(r) {
  if (r.pct === null) return "-";
  return `${r.pct}% of ${r.GOOD + r.BAD}`;
}

function countCells(r) {
  return `<td class="num"><span class="v good">${r.GOOD}</span></td>` +
    `<td class="num"><span class="v ${r.BAD ? "bad" : "none"}">${r.BAD}</span></td>` +
    `<td class="num"><span class="v ${r.UNKWN ? "unkwn" : "none"}">${r.UNKWN}</span></td>`;
}

function summaryTable(rows, tot) {
  const body = rows.map((r) =>
    `<tr><td class="tgt"><code>${esc(r.suite)}</code></td>` +
    `<td class="tgt"><code>${esc(r.arch)}</code></td>` +
    `<td class="size pct">${r.checked} / ${r.published}</td>` +
    countCells(r) +
    `<td class="size pct">${pctCell(r)}</td></tr>`).join("\n");
  const total = `<tr class="tot"><td class="tgt"><code>all</code></td>` +
    `<td class="tgt"><code>all</code></td>` +
    `<td class="size pct">${tot.checked} / ${tot.published}</td>` +
    countCells(tot) +
    `<td class="size pct">${pctCell(tot)}</td></tr>`;
  return `<div class="tablewrap"><table>
<thead><tr><th>suite</th><th>arch</th><th class="size">checked</th>
<th class="num">good</th><th class="num">bad</th><th class="num">unkwn</th>
<th class="size">reproducible</th></tr></thead>
<tbody>${body}\n${total}</tbody></table></div>`;
}

// Seeded from the inventory, then filled from the verdicts. Driving it from
// the verdicts alone made a package nobody had checked invisible rather than
// unchecked, which is the same substitution of absence for success the summary
// row guards against - and it left the archive's own package count unstated on
// the one page claiming to cover it.
export function byPackage(verdicts, inventory) {
  const map = new Map();
  for (const [name, version] of inventoryPackages(inventory)) {
    map.set(name, { package: name, version, targets: {} });
  }
  for (const v of verdicts) {
    const entry = map.get(v.package) || { package: v.package, version: "", targets: {} };
    entry.targets[`${v.suite}/${v.arch}`] = v;
    // Every suite carries the same base version, so the last writer is as
    // right as the first; a real divergence is a publish in flight.
    entry.version = baseVersion(v.version);
    map.set(v.package, entry);
  }
  return [...map.values()].sort((a, b) => a.package.localeCompare(b.package));
}

// name -> base version, from whichever target lists it. The qualifier differs
// per suite and the base version does not, so the first one seen is the answer.
export function inventoryPackages(inventory) {
  const out = new Map();
  const targets = (inventory && inventory.targets) || {};
  for (const key of Object.keys(targets)) {
    const list = targets[key];
    if (!Array.isArray(list)) continue;
    for (const item of list) {
      if (!item || !item.package) continue;
      if (!out.has(item.package)) out.set(item.package, baseVersion(item.version || ""));
    }
  }
  return out;
}

function packageTable(entries) {
  const body = entries.map((e) => {
    const cells = SUITES.flatMap((suite) => ARCHES.map((arch) => {
      const v = e.targets[`${suite}/${arch}`];
      return verdictCell(v && v.status, `${suite} ${arch}`
        + (v ? ` - checked ${v.checked_at}` : " - not yet checked"));
    })).join("");
    return `<tr><td class="pkg"><a href="/${esc(e.package)}/">${esc(e.package)}</a></td>` +
      `<td class="ver">${esc(e.version)}</td>` +
      `<td><div class="matrix">${cells}</div></td></tr>`;
  }).join("\n");
  // Escape the DATA, not the markup. Building the string first and passing
  // the whole thing through esc() turned the separator into a literal
  // "&middot;" on the page: esc() escapes the ampersand of an entity just as
  // happily as one in a package name. It shipped that way and the assertion
  // below now covers the whole class, not this one entity.
  const head = SUITES.map(esc).join(" &middot; ");
  return `<div class="tablewrap"><table>
<thead><tr><th>package</th><th>version</th><th>${head} &nbsp;(amd64, arm64)</th></tr></thead>
<tbody>${body}</tbody></table></div>`;
}

// The prose lives here rather than in a README beside the verdicts: a second
// copy of the same explanation is a second thing to keep current.
const ABOUT = `<div class="about">
<h2>What a verdict means</h2>
<p>Every package in the archive is built from an upstream release tag, and the
build writes a <code>.buildinfo</code> recording the exact version of everything
installed in the build environment. A verdict is the result of taking that
record, reconstructing the environment from
<a href="https://snapshot.debian.org">snapshot.debian.org</a>, rebuilding, and
comparing the bytes.</p>
<p><span class="v good">GOOD</span> the rebuild produced the same bytes.
<span class="v bad">BAD</span> the rebuild completed and the bytes differed.
<span class="v unkwn">UNKWN</span> the rebuild could not be completed, so
nothing is claimed either way.</p>
<p><strong><span class="v unkwn">UNKWN</span> is not a soft failure.</strong> snapshot.debian.org is a
rate-limited volunteer service that times out under load, and a build
dependency can stop being resolvable years after the fact. Recording either as
<span class="v bad">BAD</span> would be a claim about this archive that the
evidence does not support, so
only a completed rebuild with differing checksums earns that word.</p>
<p>That is also why the table's last column counts only the verdicts a rebuild
decided. A <span class="v unkwn">UNKWN</span> is not evidence in either
direction, so folding it in would let a bad afternoon at snapshot.debian.org
read as packages that stopped reproducing. The column names its own
denominator for that reason, and the <em>checked</em> column beside it counts
every artifact tried, unknowns included.</p>

<h2>Checking it yourself</h2>
<p>Nothing here needs to be taken on trust. Every input is published, and the
rebuild is <code>debrebuild</code> from Debian's own devscripts:</p>
<pre><span class="c"># everything the rebuild needs, for one package</span>
B=https://buildinfos.pkg.haus/buildinfo-pool/b/berry
curl -fsSLO $B/berry_0.1.13-4~haus13+1_amd64.buildinfo
curl -fsSLO $B/berry_0.1.13-4~haus13+1.dsc
curl -fsSLO $B/berry_0.1.13-4~haus13+1.debian.tar.xz
curl -fsSLO $B/berry_0.1.13.orig.tar.gz

<span class="c"># rebuild and compare all four checksums</span>
debrebuild --builder=dpkg --buildresult=./rebuilt berry_0.1.13-4~haus13+1_amd64.buildinfo</pre>

<h2>What this does not prove</h2>
<p>These rebuilds run in the same CI that produced the packages, so this is a
regression detector and not a trust root: a compromised build pipeline would
take the rebuilder with it. What it does catch is unintentional
non-determinism - a build reading the host's CPU, a toolchain recorded rather
than pinned, a timestamp leaking into an archive - which is the failure that
has actually happened here. An <em>independent</em> rebuild, by someone who
did not build the package, is the stronger property, and everything needed
for one is published above.</p>
</div>`;

export function renderRoot(verdicts, inventory) {
  const rows = summarise(verdicts, inventory);
  const entries = byPackage(verdicts, inventory);
  const body = header("", DESCRIPTION)
    + summaryTable(rows, totals(rows))
    + packageTable(entries)
    + ABOUT;
  return page("reproducible.pkg.haus", body);
}

// What a row has to say beyond the word. On GOOD the two checksums are equal
// by definition, so one is the fact; on BAD the pair IS the finding and
// showing only the rebuilt half would make a reader fetch the record to learn
// what it should have been; on UNKWN there is no checksum to show and the
// reason is the only thing that helps.
function detailCell(v) {
  if (v.status === "UNKWN") return esc(v.unknown_reason || "no reason recorded");
  const short = (h) => esc(String(h || "").slice(0, 16));
  if (v.status === "BAD" && v.rebuilt_sha256 && v.recorded_sha256) {
    return `<code>${short(v.rebuilt_sha256)}</code> != `
      + `<code>${short(v.recorded_sha256)}</code>`;
  }
  return `<code>${short(v.rebuilt_sha256 || v.recorded_sha256)}</code>`;
}

export function renderPackage(name, verdicts) {
  const sorted = SUITES.flatMap((suite) =>
    ARCHES.map((arch) => ({
      suite, arch,
      v: verdicts.find((x) => x.suite === suite && x.arch === arch),
    })));
  const body = sorted.map(({ suite, arch, v }) => {
    if (!v) {
      return `<tr><td class="tgt"><code>${esc(suite)}</code></td>` +
        `<td class="tgt"><code>${esc(arch)}</code></td>` +
        `<td>${verdictCell(null, "not yet checked")}</td>` +
        `<td colspan="2" class="ver">not yet checked</td></tr>`;
    }
    const detail = detailCell(v);
    return `<tr><td class="tgt"><code>${esc(suite)}</code></td>` +
      `<td class="tgt"><code>${esc(arch)}</code></td>` +
      `<td>${verdictCell(v.status, v.debrebuild || v.status)}</td>` +
      `<td class="ver">${esc(v.version)}</td>` +
      `<td class="ver">${detail}</td></tr>`;
  }).join("\n");
  const inner = `<div class="tablewrap"><table>
<thead><tr><th>suite</th><th>arch</th><th>verdict</th><th>version</th>
<th>rebuilt / recorded sha256</th></tr></thead><tbody>${body}</tbody></table></div>`;
  const tagline = `Reproducibility of <code>${esc(name)}</code> across every suite and architecture the archive serves.`;
  return page(`reproducible.pkg.haus/${name}`,
    header(name, tagline) + inner + ABOUT);
}

const CSP_TAIL =
  "style-src 'unsafe-inline'; img-src 'self' data:; base-uri 'none'; form-action 'none'; frame-ancestors 'none'";

const SECURITY_HEADERS = {
  "x-content-type-options": "nosniff",
  "referrer-policy": "no-referrer",
  "content-security-policy": `default-src 'none'; ${CSP_TAIL}`,
};

let htmlHeaders = null;
async function htmlSecurityHeaders() {
  if (!htmlHeaders) {
    const hashes = await Promise.all([PLAUSIBLE_INIT, LOCALISE].map(async (body) => {
      const digest = await crypto.subtle.digest(
        "SHA-256", new TextEncoder().encode(body));
      return `'sha256-${btoa(String.fromCharCode(...new Uint8Array(digest)))}'`;
    }));
    htmlHeaders = {
      ...SECURITY_HEADERS,
      "content-security-policy":
        `default-src 'none'; script-src 'self' ${hashes.join(" ")}; ` +
        `connect-src 'self'; ${CSP_TAIL}`,
    };
  }
  return htmlHeaders;
}

async function html(bodyText, maxAge) {
  return new Response(bodyText, {
    status: 200,
    headers: {
      "content-type": "text/html; charset=utf-8",
      "cache-control": `public, max-age=${maxAge}`,
      ...(await htmlSecurityHeaders()),
    },
  });
}

async function errorPage(status, title, tagline) {
  return new Response(
    page(`reproducible.pkg.haus - ${title}`, header("", esc(tagline))),
    {
      status,
      headers: {
        "content-type": "text/html; charset=utf-8",
        ...(await htmlSecurityHeaders()),
      },
    });
}

const notFound = () => errorPage(404, "not found", "No such page.");
const badRequest = () => errorPage(400, "bad request", "That is not a valid URL.");

// This function and resolveRange below are identical in pkghaus/apt and
// pkghaus/buildinfos worker/src/worker.js. A bug in any one is a bug in all
// three: the NaN content-range was. Fix them together.
//
// R2 signals an unsatisfiable range by throwing, with no typed error to match
// on. Matches both the message and the code it actually emits, because either
// alone is one upstream wording change away from silently reverting this to a
// 500.
export function isUnsatisfiableRange(e) {
  const msg = String(e?.message ?? e);
  return /range is not satisfiable/i.test(msg) || /\(10039\)/.test(msg);
}

export function resolveRange(range, size) {
  if (!range) return { offset: 0, length: size };
  const offset = typeof range.offset === "number" ? range.offset : 0;
  const length = typeof range.length === "number" ? range.length : size - offset;
  return { offset, length };
}

function unsatisfiable(size) {
  return new Response(null, {
    status: 416,
    headers: {
      "content-range": `bytes */${size}`,
      "cache-control": "no-store",
      ...SECURITY_HEADERS,
    },
  });
}

export default {
  async fetch(request, env, ctx) {
    const url = new URL(request.url);

    if (request.method !== "GET" && request.method !== "HEAD") {
      return new Response(null, { status: 405, headers: SECURITY_HEADERS });
    }

    // A truncated escape like /%E0%A4%A throws in decodeURIComponent, and
    // unhandled that is Cloudflare's 1101 page: a 500 blaming the server for
    // the client's address.
    let path;
    try {
      path = decodeURIComponent(url.pathname);
    } catch {
      return badRequest();
    }

    // A C0 control does not survive the URL parse the cache key is built from:
    // tab, LF and CR are stripped from anywhere and the rest are trimmed off
    // the ends, so two spellings would share one entry and the answer would
    // depend on cache warmth. Same guard, and same reason, as buildinfos.
    if (/[\x00-\x20#]/.test(path)) return badRequest();

    if (!env.VERDICTS) return new Response("Not configured", { status: 503 });

    try {
      return await serve(request, env, ctx, path);
    } catch (e) {
      // Everything below serve() talks to R2: the list() loop behind every
      // page, and the get() behind every verdict. A throw there is Cloudflare's
      // 1101 page unhandled, a 500 blaming the server for the client's request.
      // buildinfos and pkghaus-archive both answer 503 here and the reasoning
      // carries: a 500 is not retryable and a 404 would claim the verdict does
      // not exist. Logged, because a silent 503 and a broken binding look the
      // same from outside.
      console.error("serve failed:", e?.message ?? e);
      return new Response("Service unavailable", {
        status: 503,
        headers: { "content-type": "text/plain; charset=utf-8", ...SECURITY_HEADERS },
      });
    }
  },
};

// Every verdict, from the rolled-up index the verifier writes.
//
// This used to read one R2 object per artifact and the comment here said the
// fleet was "small enough to read whole". It was not: 75 verdicts took 5.6 to
// 8.1 seconds on a cache miss, measured 2026-09-21, and 216 would have been
// three times that. Binding reads are capped per invocation on the free plan
// too, and a render was already making about eighty of them.
//
// scripts/roll-index.py builds verdicts.json from the whole bucket at every
// publish. The per-artifact objects are untouched: they are the documented
// machine-readable endpoint and this is a derived view of them.
export async function loadVerdicts(bucket) {
  const index = await bucket.get(INDEX_KEY);
  if (index) {
    try {
      const parsed = JSON.parse(await index.text());
      if (Array.isArray(parsed.verdicts)) return parsed.verdicts;
      console.error(`${INDEX_KEY} has no verdicts array`);
    } catch (e) {
      console.error(`${INDEX_KEY} will not parse:`, e?.message ?? e);
    }
  }
  // Fall back to the per-artifact scan. Slow, and that is the point: the page
  // stays CORRECT when the index is missing or broken, rather than rendering
  // a fleet where nothing has been verified, which is the one failure this
  // surface must never produce. The log line is how anyone finds out.
  console.error(`${INDEX_KEY} unusable; falling back to the per-object scan`);
  return scanVerdicts(bucket);
}

export async function scanVerdicts(bucket) {
  const { objects } = await listAll(bucket, PREFIX);
  const out = [];
  for (const o of objects) {
    if (!o.key.endsWith(".json")) continue;
    const body = await bucket.get(o.key);
    if (!body) continue;
    try {
      out.push(JSON.parse(await body.text()));
    } catch {
      // A verdict that will not parse is a bug in the verifier, and dropping
      // it is right: rendering half a record would put a wrong word on the
      // page. It stays in the bucket for whoever looks.
    }
  }
  return out;
}

// What the archive publishes, written by the same ingest that triggers the
// verifications. Kept OUTSIDE `verify/` so loadVerdicts cannot read it as a
// verdict: it has no suite, arch or status, and would file itself under the
// package name `undefined`.
export async function loadInventory(bucket) {
  const object = await bucket.get(INVENTORY_KEY);
  if (!object) return null;
  try {
    return JSON.parse(await object.text());
  } catch {
    // Same reasoning as a malformed verdict, one level up: a half-read
    // inventory would understate coverage, and understating it is the failure
    // this file exists to prevent. Null reports 0 published, which is visibly
    // broken rather than quietly wrong.
    return null;
  }
}

export function inventoryHas(inventory, name) {
  return inventoryPackages(inventory).has(name);
}

async function serve(request, env, ctx, path) {
  const cache = caches.default;
  // Keyed on the decoded path so the encoded and literal spellings share one
  // entry and a query string cannot multiply them. HEAD is excluded rather
  // than sharing the GET's key: it would otherwise store a body-less answer.
  const cacheKey = new Request(`https://reproducible.pkg.haus${path}`);
  const cacheable = request.method === "GET" && !request.headers.get("range");
  if (cacheable) {
    const hit = await cache.match(cacheKey);
    if (hit) return hit;
  }

  const send = async (res) => {
    if (cacheable && res.status === 200) ctx.waitUntil(cache.put(cacheKey, res.clone()));
    return res;
  };

  // RFC 9116. Rendered rather than shipped as an asset, which is the whole
  // advantage of having no asset layer: Expires is a year from NOW on every
  // request, so it can never lapse. apt renders its copy per publish and the
  // website's is static with a hand-set date that someone has to remember --
  // both are reminders this file goes stale, and this host cannot.
  //
  // Same four fields and the same order as the other two copies, so the
  // three read identically to anyone comparing them.
  if (path === "/.well-known/security.txt") {
    const expires = new Date(Date.now() + 365 * 24 * 60 * 60 * 1000)
      .toISOString().replace(/\.\d+Z$/, ".000Z");
    return send(new Response(
      "Contact: mailto:security@pkg.haus\n"
      + `Expires: ${expires}\n`
      + "Preferred-Languages: en\n"
      + "Canonical: https://reproducible.pkg.haus/.well-known/security.txt\n",
      {
        status: 200,
        headers: {
          "content-type": "text/plain; charset=utf-8",
          "cache-control": `public, max-age=${PAGE_MAX_AGE}`,
          ...SECURITY_HEADERS,
        },
      }));
  }

  if (path === "/favicon.svg") {
    return send(new Response(FAVICON, {
      status: 200,
      headers: {
        "content-type": "image/svg+xml; charset=utf-8",
        "cache-control": `public, max-age=${PAGE_MAX_AGE}`,
        ...SECURITY_HEADERS,
      },
    }));
  }

  // The raw verdict, for anyone who would rather read the data than the page.
  // A machine endpoint, so no Plausible and no HTML CSP.
  if (path === `/${INVENTORY_KEY}` || path === `/${INDEX_KEY}`
      || (path.startsWith(`/${PREFIX}`) && path.endsWith(".json"))) {
    const key = path.slice(1);
    let object;
    try {
      object = await env.VERDICTS.get(key, {
        range: request.headers.get("range")
          ? request.headers
          : undefined,
      });
    } catch (e) {
      if (isUnsatisfiableRange(e)) {
        const head = await env.VERDICTS.head(key);
        return unsatisfiable(head ? head.size : 0);
      }
      throw e;
    }
    if (!object) return notFound();
    const { offset, length } = resolveRange(object.range, object.size);
    const partial = request.headers.get("range") && length < object.size;
    return send(new Response(request.method === "HEAD" ? null : object.body, {
      status: partial ? 206 : 200,
      headers: {
        "content-type": "application/json; charset=utf-8",
        "content-length": String(length),
        "cache-control": `public, max-age=${JSON_MAX_AGE}`,
        ...(partial
          ? { "content-range": `bytes ${offset}-${offset + length - 1}/${object.size}` }
          : {}),
        "accept-ranges": "bytes",
        ...SECURITY_HEADERS,
      },
    }));
  }

  if (path === "/" || path === "") {
    const [verdicts, inventory] = await Promise.all([
      loadVerdicts(env.VERDICTS), loadInventory(env.VERDICTS)]);
    return send(await html(renderRoot(verdicts, inventory), PAGE_MAX_AGE));
  }

  // /<package>/ - one package across every target.
  const m = /^\/([A-Za-z0-9][A-Za-z0-9.+-]*)\/$/.exec(path);
  if (m) {
    const name = m[1];
    const [all, inventory] = await Promise.all([
      loadVerdicts(env.VERDICTS), loadInventory(env.VERDICTS)]);
    const verdicts = all.filter((v) => v.package === name);
    // Published but unchecked still gets a page. The root table links every
    // package it lists, and a link that 404s would say the package does not
    // exist when what is missing is the verdict.
    if (!verdicts.length && !inventoryHas(inventory, name)) return notFound();
    return send(await html(renderPackage(name, verdicts), PAGE_MAX_AGE));
  }

  return notFound();
}

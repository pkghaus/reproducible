// The serving path, against a fake R2.
//
// Three things are worth testing here and the first is not the rendering.
//
//  1. The ARITHMETIC. A reproducibility page's whole job is to state a number
//     honestly, and there are two ways to get it wrong that both read as
//     success: dividing by the verdicts instead of by what is published, so
//     an artifact nobody checked disappears; and folding UNKWN into the
//     denominator, so a rate-limited afternoon at snapshot.debian.org looks
//     like a regression in the archive.
//  2. What a request maps to in the bucket, and what happens when it maps to
//     nothing.
//  3. That a published-but-unchecked package is visible as unchecked, rather
//     than absent.
//
// fakeBucket is a trimmed copy of pkghaus/buildinfos worker/test/worker.test.js's,
// minus the conditional-request paths this Worker does not serve. The range
// semantics are the ones measured against live R2 and must stay that way.

import { test } from "node:test";
import assert from "node:assert/strict";
import worker, {
  baseVersion, byPackage, inventoryHas, inventoryPackages, listAll,
  loadInventory, loadVerdicts, publishedFor, renderPackage, renderRoot, scanVerdicts,
  sizeDelta, historyCells, historyRate, hasMixedHistory, HISTORY_SLOTS,
  resolveRange, summarise, totals, verdictClass, breadcrumb,
} from "../src/worker.js";

function fakeBucket(keys, reads = []) {
  const objects = new Map(Object.entries(keys));
  return {
    async list({ prefix = "", cursor, limit = 1000 }) {
      const all = [...objects.keys()].filter((k) => k.startsWith(prefix)).sort();
      const start = cursor ? Number(cursor) : 0;
      const page = all.slice(start, start + limit);
      const end = start + page.length;
      return {
        objects: page.map((k) => ({ key: k, size: objects.get(k).length })),
        delimitedPrefixes: [],
        truncated: end < all.length,
        cursor: String(end),
      };
    },
    async head(key) {
      return objects.has(key) ? { size: objects.get(key).length, key } : null;
    },
    async get(key, opts = {}) {
      reads.push(key);
      if (!objects.has(key)) return null;
      const body = objects.get(key);
      const size = body.length;

      // R2 does not return null for a range it cannot satisfy -- it THROWS,
      // with this exact wording, copied from a production log line rather
      // than invented. A fake that threw something else would let the matcher
      // rot with no test noticing.
      const rangeHeader =
        opts.range instanceof Headers ? opts.range.get("range") : null;
      const from = rangeHeader && /^bytes=(\d+)-/.exec(rangeHeader);
      if (from && Number(from[1]) >= size) {
        throw new Error("get: The requested range is not satisfiable (10039)");
      }
      // Real R2 takes an R2Range or a Headers here and throws on a string.
      if (typeof opts.range === "string") {
        throw new TypeError("Incorrect type for the 'range' field");
      }

      // Measured against live R2. A GET with no Range still comes back with
      // `range` set to the whole object, and all three keys are own
      // properties with `suffix` always undefined -- so `"suffix" in range`
      // is true on every result and cannot be used to detect one.
      let [offset, length] = [0, size];
      let slice = body;
      const m = rangeHeader ? /^bytes=(\d*)-(\d*)$/.exec(rangeHeader) : null;
      if (m) {
        if (m[1] === "") {
          length = Number(m[2]);
          offset = size - length;
        } else {
          offset = Number(m[1]);
          length = m[2] === "" ? size - offset : Number(m[2]) - offset + 1;
        }
        slice = body.slice(offset, offset + length);
      }
      return {
        size,
        range: { offset, length, suffix: undefined },
        text: async () => slice,
        body: slice,
      };
    },
  };
}

const verdict = (o) => JSON.stringify({
  package: "croc", version: "11.5.3-2", suite: "unstable", arch: "amd64",
  status: "GOOD", checked_at: "2026-09-20T10:00:00Z",
  buildinfo: "https://buildinfos.pkg.haus/x.buildinfo",
  debrebuild: "all OK", unknown_reason: null,
  rebuilt_sha256: "a".repeat(64), recorded_sha256: "a".repeat(64),
  run: "https://example.invalid/run/1", ...o,
});

// Two packages. croc is verified everywhere; zola is BAD on one leg, UNKWN on
// another and never checked on the rest, which is the mixture the page has to
// be honest about.
const FIXTURE = {
  "verify/unstable/amd64/croc.json": verdict({}),
  "verify/unstable/arm64/croc.json": verdict({ arch: "arm64" }),
  "verify/trixie/amd64/croc.json": verdict({ suite: "trixie", version: "11.5.3-2~haus13+1" }),
  "verify/unstable/amd64/zola.json": verdict({
    package: "zola", version: "0.23.6-3", status: "BAD",
    debrebuild: "value of sha256 differs for zola_0.23.6-3_amd64.deb",
    rebuilt_sha256: "b".repeat(64), recorded_sha256: "c".repeat(64),
  }),
  "verify/unstable/arm64/zola.json": verdict({
    package: "zola", version: "0.23.6-3", arch: "arm64", status: "UNKWN",
    debrebuild: null, unknown_reason: "snapshot.debian.org timed out",
    rebuilt_sha256: null, recorded_sha256: null,
  }),
  // Not JSON. The reader must drop it rather than render half a record.
  "verify/unstable/amd64/broken.json": '{"package":',
  // Not a verdict. Nothing should serve or count it.
  "verify/notes.txt": "ignored",
  "verdicts.json": JSON.stringify({
    generated_at: "2026-09-21T00:00:00Z",
    verdicts: [
      JSON.parse(verdict({})),
      JSON.parse(verdict({ arch: "arm64" })),
      JSON.parse(verdict({ suite: "trixie", version: "11.5.3-2~haus13+1" })),
      JSON.parse(verdict({
        package: "zola", version: "0.23.6-3", status: "BAD",
        debrebuild: "value of sha256 differs for zola_0.23.6-3_amd64.deb",
        rebuilt_sha256: "b".repeat(64), recorded_sha256: "c".repeat(64),
      })),
      JSON.parse(verdict({
        package: "zola", version: "0.23.6-3", arch: "arm64", status: "UNKWN",
        debrebuild: null, unknown_reason: "snapshot.debian.org timed out",
        rebuilt_sha256: null, recorded_sha256: null,
      })),
    ],
  }),
  "inventory.json": JSON.stringify({
    generated_at: "2026-09-21T00:00:00Z",
    archive: "https://apt.pkg.haus",
    targets: Object.fromEntries(
      ["trixie", "testing", "unstable"].flatMap((s) => ["amd64", "arm64"].map((a) => [
        `${s}/${a}`, [
          { package: "croc", version: "11.5.3-2", build_arch: a, buildinfo: "u" },
          { package: "zola", version: "0.23.6-3", build_arch: a, buildinfo: "u" },
          { package: "berry", version: "0.1.7-2", build_arch: a, buildinfo: "u" },
        ],
      ]))),
  }),
};

const reads = [];
const env = { VERDICTS: fakeBucket(FIXTURE, reads) };

// A cache that stores, not a pair of no-ops: which responses come back on a
// second request, and which R2 read never happens, is half of what is being
// tested.
const store = new Map();
const tasks = [];
globalThis.caches = {
  default: {
    async match(req) { const hit = store.get(req.url); return hit ? hit.clone() : undefined; },
    async put(req, res) { store.set(req.url, res.clone()); },
  },
};
const ctx = { waitUntil: (p) => tasks.push(p) };
const settle = () => Promise.allSettled(tasks.splice(0));
const resetCache = () => { store.clear(); reads.length = 0; tasks.length = 0; };

const get = (p, init) =>
  worker.fetch(new Request(`https://reproducible.pkg.haus${p}`, init), env, ctx);

const brokenBucket = {
  async get() { throw new Error("R2 is having a moment"); },
  async head() { throw new Error("R2 is having a moment"); },
  async list() { throw new Error("R2 is having a moment"); },
};

const INVENTORY = JSON.parse(FIXTURE["inventory.json"]);
const VERDICTS = Object.entries(FIXTURE)
  .filter(([k]) => k.startsWith("verify/") && k.endsWith(".json") && k !== "verify/unstable/amd64/broken.json")
  .map(([, v]) => JSON.parse(v));

test("the three suites share one base version, so a package row names it once", () => {
  assert.equal(baseVersion("11.5.3-2~haus13+1"), "11.5.3-2");
  assert.equal(baseVersion("11.5.3-2~testing1"), "11.5.3-2");
  assert.equal(baseVersion("11.5.3-2"), "11.5.3-2");
  // A tilde that is not a suite qualifier belongs to the version.
  assert.equal(baseVersion("1.0~rc1-1"), "1.0~rc1-1");
});

test("a verdict maps to its own colour and anything else to none", () => {
  assert.equal(verdictClass("GOOD"), "good");
  assert.equal(verdictClass("BAD"), "bad");
  assert.equal(verdictClass("UNKWN"), "unkwn");
  assert.equal(verdictClass(undefined), "none");
  assert.equal(verdictClass("PROBABLY"), "none");
});

test("the percentage is over decided verdicts, never over what is published", () => {
  const rows = summarise(VERDICTS, INVENTORY);
  const unstableAmd = rows.find((r) => r.suite === "unstable" && r.arch === "amd64");
  assert.equal(unstableAmd.GOOD, 1);
  assert.equal(unstableAmd.BAD, 1);
  assert.equal(unstableAmd.UNKWN, 0);
  // One GOOD and one BAD is 50%, not 33% of the three published. A
  // denominator of everything published would fall as the fleet grows and
  // would say nothing about reproducibility.
  assert.equal(unstableAmd.pct, 50);
  assert.equal(unstableAmd.checked, 2);
  assert.equal(unstableAmd.published, 3);
});

test("UNKWN is reported beside the percentage, never folded into it", () => {
  const rows = summarise(VERDICTS, INVENTORY);
  const unstableArm = rows.find((r) => r.suite === "unstable" && r.arch === "arm64");
  assert.equal(unstableArm.GOOD, 1);
  assert.equal(unstableArm.UNKWN, 1);
  // A rate-limited afternoon at snapshot.debian.org must not read as a
  // regression in the archive: one GOOD and one UNKWN is 100% of what was
  // decided, and the UNKWN is shown in its own column.
  assert.equal(unstableArm.pct, 100);
  assert.equal(unstableArm.checked, 2);
});

test("a target with no decided verdict has no percentage rather than a zero", () => {
  const rows = summarise(
    [{ suite: "testing", arch: "amd64", status: "UNKWN", package: "croc", version: "1" }],
    INVENTORY);
  const row = rows.find((r) => r.suite === "testing" && r.arch === "amd64");
  assert.equal(row.pct, null);
  // 0% would say every rebuild failed. Nothing was decided.
  assert.equal(row.GOOD + row.BAD, 0);
});

test("every suite and arch gets a row even with no verdicts at all", () => {
  const rows = summarise([], INVENTORY);
  assert.equal(rows.length, 6);
  assert.deepEqual(rows.map((r) => r.checked), [0, 0, 0, 0, 0, 0]);
  assert.deepEqual(rows.map((r) => r.published), [3, 3, 3, 3, 3, 3]);
});

test("a missing inventory reports nothing published, not everything verified", () => {
  // The failure this guards: deriving the denominator from the verdicts makes
  // coverage read 100% at exactly the moment the inventory is what broke.
  assert.equal(publishedFor(null, "unstable", "amd64"), 0);
  assert.equal(publishedFor({}, "unstable", "amd64"), 0);
  assert.equal(publishedFor({ targets: { "unstable/amd64": "nonsense" } }, "unstable", "amd64"), 0);
  const tot = totals(summarise(VERDICTS, null));
  assert.equal(tot.published, 0);
  assert.equal(tot.checked, 5);
});

test("the totals row sums the columns and recomputes its own percentage", () => {
  const tot = totals(summarise(VERDICTS, INVENTORY));
  assert.equal(tot.GOOD, 3);
  assert.equal(tot.BAD, 1);
  assert.equal(tot.UNKWN, 1);
  assert.equal(tot.checked, 5);
  assert.equal(tot.published, 18);
  // 3 of 4 decided. Averaging the six rows' percentages would give a
  // different, meaningless number.
  assert.equal(tot.pct, 75);
});

test("a package nobody has checked is still a row, from the inventory", () => {
  const entries = byPackage(VERDICTS, INVENTORY);
  assert.deepEqual(entries.map((e) => e.package), ["berry", "croc", "zola"]);
  const berry = entries.find((e) => e.package === "berry");
  assert.equal(Object.keys(berry.targets).length, 0);
  assert.equal(berry.version, "0.1.7-2");
});

test("without an inventory only the checked packages appear, which is the bug", () => {
  // Kept as a test rather than deleted: this is what the page did before the
  // inventory existed, and the difference is the whole point of threading it
  // through. berry is published and invisible here.
  const entries = byPackage(VERDICTS, null);
  assert.deepEqual(entries.map((e) => e.package), ["croc", "zola"]);
});

test("the inventory's package list survives a malformed target", () => {
  assert.deepEqual([...inventoryPackages(null).keys()], []);
  assert.deepEqual([...inventoryPackages({ targets: { "a/b": null } }).keys()], []);
  assert.deepEqual(
    [...inventoryPackages({ targets: { "a/b": [{ package: "x" }, {}, null] } }).keys()],
    ["x"]);
  assert.equal(inventoryHas(INVENTORY, "berry"), true);
  assert.equal(inventoryHas(INVENTORY, "nosuch"), false);
});

test("listAll follows the cursor rather than stopping at one page", async () => {
  const many = {};
  for (let i = 0; i < 25; i += 1) many[`verify/unstable/amd64/p${i}.json`] = "{}";
  const bucket = fakeBucket(many);
  const orig = bucket.list.bind(bucket);
  bucket.list = (o) => orig({ ...o, limit: 10 });
  const { objects } = await listAll(bucket, "verify/");
  assert.equal(objects.length, 25);
});

test("a verdict that will not parse is dropped, not rendered half-read", async () => {
  const loaded = await scanVerdicts(env.VERDICTS);
  assert.equal(loaded.length, 5);
  assert.equal(loaded.filter((v) => v.package === undefined).length, 0);
});

test("a page is rendered from one read, not one per artifact", async () => {
  // 75 per-artifact reads took 5.6-8.1s on a cache miss and the fleet is 216.
  // Binding reads are capped per invocation too. This is the assertion that
  // keeps the render cheap: the count must not grow with the fleet.
  resetCache();
  await get("/");
  await settle();
  assert.deepEqual(reads.sort(), ["inventory.json", "verdicts.json"]);
});

test("a broken index falls back rather than rendering nothing verified", async () => {
  // The one failure this surface must never produce is an empty page that
  // looks like a fleet nobody has checked. Slow and correct beats fast and
  // silent.
  for (const broken of ["{oops", JSON.stringify({ generated_at: "x" })]) {
    const bucket = fakeBucket({ ...FIXTURE, "verdicts.json": broken });
    const loaded = await loadVerdicts(bucket);
    assert.equal(loaded.length, 5, `fell back for ${broken.slice(0, 12)}`);
  }
  // Absent entirely, same.
  const { "verdicts.json": _drop, ...without } = FIXTURE;
  assert.equal((await loadVerdicts(fakeBucket(without))).length, 5);
});

test("the index is served as a machine endpoint beside the inventory", async () => {
  resetCache();
  const r = await get("/verdicts.json");
  assert.equal(r.status, 200);
  assert.equal(r.headers.get("content-type"), "application/json; charset=utf-8");
  assert.equal(JSON.parse(await r.text()).verdicts.length, 5);
});

test("the inventory is outside verify/, so the reader cannot mistake it for one", async () => {
  const loaded = await loadVerdicts(env.VERDICTS);
  // An inventory read as a verdict has no suite, arch or status and would
  // file itself on the page under the package name `undefined`.
  assert.equal(loaded.filter((v) => v.targets !== undefined).length, 0);
  const inv = await loadInventory(env.VERDICTS);
  assert.equal(Object.keys(inv.targets).length, 6);
});

test("an unreadable inventory is null, which shows as nothing published", async () => {
  const inv = await loadInventory(fakeBucket({ "inventory.json": "{oops" }));
  assert.equal(inv, null);
  assert.equal(await loadInventory(fakeBucket({})), null);
});

test("the root page carries the coverage column and the totals row", async () => {
  resetCache();
  const body = await (await get("/")).text();
  assert.match(body, /<th class="size">checked<\/th>/);
  assert.match(body, /<tr class="tot">/);
  // checked / published, per target and in total.
  assert.match(body, /<td class="size pct">2 \/ 3<\/td>/);
  assert.match(body, /<td class="size pct">5 \/ 18<\/td>/);
  assert.match(body, /<td class="size pct">75% of 4<\/td>/);
});

test("the percentage names its own denominator", async () => {
  // "100%" beside "checked 22" reads as 22 of 22. When one of those is UNKWN
  // it is 21 of 21, and the arithmetic a reader can actually do lands on
  // 95.5%. The cell has to say which.
  resetCache();
  const body = await (await get("/")).text();
  // unstable/amd64 in the fixture: 1 GOOD, 1 BAD, 0 UNKWN -> 50% of 2.
  assert.match(body, /<td class="size pct">50% of 2<\/td>/);
  // unstable/arm64: 1 GOOD, 0 BAD, 1 UNKWN -> 100% of 1, NOT 100% of 2.
  assert.match(body, /<td class="size pct">100% of 1<\/td>/);
  assert.doesNotMatch(body, /<td class="size pct">\d+(\.\d+)?%<\/td>/,
    "a bare percentage with no denominator is back");
});

test("the prose says what the percentage is over", () => {
  const html = renderRoot(VERDICTS, INVENTORY);
  assert.match(html, /decided/);
  assert.match(html, /checked/);
});

test("the count columns are right-aligned with tabular figures", async () => {
  resetCache();
  const body = await (await get("/")).text();
  // The registry's table rule, and the reason the Checked and Good columns
  // read as one number before it was applied.
  assert.match(body, /<th class="num">good<\/th>/);
  assert.match(body, /<td class="num"><span class="v good">/);
  assert.match(body, /td\.num,th\.num\{text-align:right;font-variant-numeric:tabular-nums/);
});

test("a published package with no verdict is listed as unchecked, not omitted", async () => {
  resetCache();
  const body = await (await get("/")).text();
  assert.match(body, /berry/);
  assert.match(body, /href="\/berry\/"/);
  // Six dashes, one per target, and no verdict word anywhere on its row.
  const row = /<td class="pkg"><a href="\/berry\/">berry<\/a>.*?<\/tr>/s.exec(body)[0];
  assert.equal((row.match(/>-</g) || []).length, 6);
  assert.doesNotMatch(row, /GOOD|BAD|UNKWN/);
});

test("its package page renders rather than 404ing", async () => {
  resetCache();
  const r = await get("/berry/");
  assert.equal(r.status, 200);
  const body = await r.text();
  assert.equal((body.match(/not yet checked/g) || []).length > 0, true);
  // The root links here; a 404 would say the package does not exist when
  // what is missing is the verdict.
  assert.match(body, /<title>reproducible\.pkg\.haus\/berry<\/title>/);
});

test("a package that is neither published nor verified is a 404", async () => {
  resetCache();
  const r = await get("/nosuchpackage/");
  assert.equal(r.status, 404);
  assert.match(await r.text(), /<title>reproducible\.pkg\.haus - not found<\/title>/);
});

test("a package page shows the recorded checksum beside the rebuilt one on BAD", async () => {
  resetCache();
  const body = await (await get("/zola/")).text();
  assert.match(body, /BAD/);
  assert.match(body, /bbbbbbbbbbbbbbbb/);
  assert.match(body, /cccccccccccccccc/);
  // UNKWN says why instead of showing a checksum it does not have.
  assert.match(body, /snapshot\.debian\.org timed out/);
});

test("the raw verdict is served as JSON for anyone who prefers the data", async () => {
  resetCache();
  const r = await get("/verify/unstable/amd64/croc.json");
  assert.equal(r.status, 200);
  assert.equal(r.headers.get("content-type"), "application/json; charset=utf-8");
  assert.equal(JSON.parse(await r.text()).status, "GOOD");
});

test("the inventory is served too, and only at its own path", async () => {
  resetCache();
  assert.equal((await get("/inventory.json")).status, 200);
  assert.equal((await get("/verify/notes.txt")).status, 404);
  assert.equal((await get("/verify/unstable/amd64/nope.json")).status, 404);
});

test("a range past the end is 416 with the size, never 404 and never 500", async () => {
  resetCache();
  const size = FIXTURE["verify/unstable/amd64/croc.json"].length;
  const r = await get("/verify/unstable/amd64/croc.json",
    { headers: { range: `bytes=${size + 10}-` } });
  // 404 here was an apt-update outage on the archive: a client resuming a
  // partial download reads it as "the file is gone".
  assert.equal(r.status, 416);
  assert.equal(r.headers.get("content-range"), `bytes */${size}`);
  assert.equal(r.headers.get("cache-control"), "no-store");
});

test("a satisfiable range is a 206 with a real content-range", async () => {
  resetCache();
  const r = await get("/verify/unstable/amd64/croc.json", { headers: { range: "bytes=0-9" } });
  assert.equal(r.status, 206);
  assert.equal(r.headers.get("content-range").startsWith("bytes 0-9/"), true);
  assert.doesNotMatch(r.headers.get("content-range"), /NaN/);
});

test("resolveRange fills in what R2 leaves out", () => {
  assert.deepEqual(resolveRange(undefined, 100), { offset: 0, length: 100 });
  assert.deepEqual(resolveRange({ offset: 10, length: 5 }, 100), { offset: 10, length: 5 });
  // suffix is an own property that is always undefined, so a resolver reading
  // it computes NaN. Two Workers in this estate did.
  assert.deepEqual(resolveRange({ offset: 90, length: undefined, suffix: undefined }, 100),
    { offset: 90, length: 10 });
});

test("a GET is cached and the next one never reaches R2; a HEAD is not", async () => {
  resetCache();
  await get("/");
  await settle();
  const after = reads.length;
  assert.equal(after > 0, true);
  await get("/");
  assert.equal(reads.length, after, "the second GET read R2 again");

  resetCache();
  await get("/verify/unstable/amd64/croc.json", { method: "HEAD" });
  await settle();
  assert.equal(store.size, 0, "a HEAD stored a body-less answer under the GET's key");
});

test("every page carries the furniture the estate's other hosts carry", async () => {
  resetCache();
  for (const path of ["/", "/croc/", "/nosuchpackage/"]) {
    const body = await (await get(path)).text();
    assert.match(body, /<span>listed <time datetime="\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z">/, path);
    assert.match(body, /\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2} UTC<\/time>/, path);
    assert.match(body, /toLocaleString/, path);
    assert.match(body, /<link rel="icon" type="image\/svg\+xml" href="\/favicon\.svg">/, path);
    assert.match(body, /\/zk\/js\/script\.js/, path);
    assert.match(body, /<html lang="en">/, path);
    assert.match(body, /<meta name="description"/, path);
    // No em dashes anywhere, ever.
    assert.doesNotMatch(body, /—/, path);
  }
});

test("the footer names siblings by label and the apex in full", async () => {
  resetCache();
  const foot = /<footer>[\s\S]*?<\/footer>/.exec(await (await get("/")).text())[0];
  // Four hostnames plus a <time> measured about 800px in a 736px column and
  // wrapped. The wordmark directly above already says pkg.haus, so a sibling
  // repeating it is width spent on nothing, and a fifth host would spend it
  // again on every page in the estate at once.
  assert.match(foot, /<a href="https:\/\/apt\.pkg\.haus">apt<\/a>/);
  assert.match(foot, /<a href="https:\/\/buildinfos\.pkg\.haus">buildinfos<\/a>/);
  assert.match(foot, /<a href="https:\/\/pkg\.haus">pkg\.haus<\/a>/);
  // github is not on this domain, so the label alone would be ambiguous.
  assert.match(foot, /<a href="https:\/\/github\.com\/pkghaus">github\.com\/pkghaus<\/a>/);
  // The host being read is not in its own footer.
  assert.doesNotMatch(foot, /href="https:\/\/reproducible\.pkg\.haus"/);
});

test("no HTML entity is double-escaped into visible text", async () => {
  resetCache();
  // esc() cannot tell the ampersand of an entity from one in a package name,
  // so any markup built into a string BEFORE it is escaped arrives on the
  // page as literal text. The suite separator shipped as "&middot;" that way.
  for (const path of ["/", "/croc/", "/nosuchpackage/"]) {
    const body = await (await get(path)).text();
    assert.doesNotMatch(body, /&amp;(#\d+|[a-z]+);/i,
      `${path} renders a double-escaped entity as visible text`);
  }
});

test("the wordmark links home and spells the real hostname", () => {
  assert.equal(breadcrumb(""),
    '<a href="/">reproducible<span class="dot">.</span>pkg<span class="dot">.</span>haus</a>');
  const withPath = breadcrumb("croc");
  assert.match(withPath, /<span class="sep">\/<\/span>croc/);
  // The path stays outside the anchor, so a hover lights exactly where the
  // link goes.
  assert.equal(withPath.indexOf("</a>") < withPath.indexOf("croc"), true);
});

test("security.txt is rendered, so its Expires can never lapse", async () => {
  resetCache();
  const r = await get("/.well-known/security.txt");
  assert.equal(r.status, 200);
  assert.equal(r.headers.get("content-type"), "text/plain; charset=utf-8");
  const body = await r.text();
  assert.match(body, /^Contact: mailto:security@pkg\.haus$/m);
  assert.match(body, /^Canonical: https:\/\/reproducible\.pkg\.haus\/\.well-known\/security\.txt$/m);
  // apt renders its copy once per publish and the website's is a static file
  // with a hand-set date; both can lapse and one is on a yearly reminder.
  // This one is a year out on every request.
  const expires = /^Expires: (.+)$/m.exec(body)[1];
  const days = (Date.parse(expires) - Date.now()) / 86400000;
  assert.equal(days > 364 && days < 366, true, `Expires is ${days} days out`);
});

test("the favicon is served with its own content type", async () => {
  resetCache();
  const r = await get("/favicon.svg");
  assert.equal(r.status, 200);
  assert.equal(r.headers.get("content-type"), "image/svg+xml; charset=utf-8");
  assert.match(await r.text(), /<svg/);
});

test("the CSP names the two inline scripts by hash and allows nothing else", async () => {
  resetCache();
  const csp = (await get("/")).headers.get("content-security-policy");
  assert.equal((csp.match(/'sha256-/g) || []).length, 2);
  assert.doesNotMatch(csp, /unsafe-inline'[^;]*script/);
  assert.match(csp, /default-src 'none'/);
  assert.match(csp, /frame-ancestors 'none'/);
  for (const h of ["x-content-type-options", "referrer-policy"]) {
    assert.equal((await get("/")).headers.get(h) !== null, true, h);
  }
});

test("a JSON response carries the security headers but not the page CSP", async () => {
  resetCache();
  const r = await get("/verify/unstable/amd64/croc.json");
  assert.equal(r.headers.get("x-content-type-options"), "nosniff");
  assert.doesNotMatch(r.headers.get("content-security-policy"), /sha256-/);
});

test("anything but GET and HEAD is a 405", async () => {
  for (const method of ["POST", "PUT", "DELETE"]) {
    assert.equal((await get("/", { method })).status, 405, method);
  }
});

test("a malformed escape is the client's fault, not a 500", async () => {
  const r = await worker.fetch(
    new Request("https://reproducible.pkg.haus/%E0%A4%A"), env, ctx);
  assert.equal(r.status, 400);
});

test("a path with a control character cannot reach the cache key", async () => {
  // Two spellings would otherwise share one entry and the answer would depend
  // on cache warmth.
  const r = await worker.fetch(
    new Request("https://reproducible.pkg.haus/%09croc/"), env, ctx);
  assert.equal(r.status, 400);
});

test("an interpolated package name is escaped", async () => {
  resetCache();
  const nasty = '<script>alert(1)</script>';
  const html = renderPackage(nasty, []);
  assert.doesNotMatch(html, /<script>alert/);
  assert.match(html, /&lt;script&gt;/);
});

test("an R2 read that throws is a 503, not a 500 or a 404", async () => {
  resetCache();
  const r = await worker.fetch(
    new Request("https://reproducible.pkg.haus/"), { VERDICTS: brokenBucket }, ctx);
  assert.equal(r.status, 503);
});

test("no binding at all is a 503 too", async () => {
  const r = await worker.fetch(new Request("https://reproducible.pkg.haus/"), {}, ctx);
  assert.equal(r.status, 503);
});

test("every verdict word in the prose wears its verdict colour", () => {
  // The definitions paragraph styled all three; the paragraph explaining
  // UNKWN had it as bare <strong>, so the word was amber everywhere except
  // where it was being explained. The rule, not the instance.
  const html = renderRoot(VERDICTS, INVENTORY);
  const about = /<div class="about">[\s\S]*?<\/div>/.exec(html)[0];
  const prose = about.replace(/<pre>[\s\S]*?<\/pre>/g, "");
  for (const [word, cls] of [["GOOD", "good"], ["BAD", "bad"], ["UNKWN", "unkwn"]]) {
    const styled = new RegExp(`<span class="v ${cls}">${word}</span>`, "g");
    const total = new RegExp(`\\b${word}\\b`, "g");
    assert.equal((prose.match(total) || []).length,
                 (prose.match(styled) || []).length,
                 `${word} appears in the prose unstyled`);
  }
});

test("the root page explains what each word means and what it does not prove", () => {
  const html = renderRoot(VERDICTS, INVENTORY);
  // The prose lives in the page rather than a README beside the verdicts, so
  // there is one copy to keep current.
  assert.match(html, /is not a soft failure/);
  assert.match(html, /debrebuild/);
  assert.match(html, /snapshot\.debian\.org/);
  // The honest caveat: same CI, so this is a regression detector rather than
  // a trust root.
  assert.match(html, /What this does not prove/);
  assert.match(html, /independent/);
});

// A BAD that a later rebuild did not reproduce is a different finding from one
// that repeats, and the page has to say which. scripts/sticky-bad.py is what
// keeps the BAD standing; this is the half a reader sees.
//
// Scoped to the TABLE, not the whole page: the legend explains the same word,
// so a bare match against the document passes whatever the row says. That is
// the assertion this test exists to make, so it must not be the assertion it
// accidentally makes.
function tableOf(html) {
  const cut = html.indexOf('<div class="about"');
  assert.ok(cut > 0, "renderPackage should still have an about section to cut at");
  return html.slice(0, cut);
}

test("a flapped BAD is rendered as non-deterministic, and an ordinary one is not", () => {
  const base = {
    package: "zola", suite: "testing", arch: "arm64", status: "BAD",
    version: "0.23.6-3~testing1",
    rebuilt_sha256: "fa744fb4e24c1a9275f90435123aa92452f02cd001839b224ffee8ffe2d638da",
    recorded_sha256: "bacef9dd4ace326f5d2b900df71982317ff8172082bb6286ac89389537ad41ab",
  };

  const plain = tableOf(renderPackage("zola", [base]));
  assert.match(plain, /class="v bad"[^>]*>BAD</);
  assert.doesNotMatch(plain, /non-deterministic/);

  const flapped = tableOf(renderPackage("zola", [{ ...base, flapped: true }]));
  assert.match(flapped, /non-deterministic/);
  // Still BAD. The whole point is that the later GOOD does not take it back.
  assert.match(flapped, /class="v bad"[^>]*>BAD</);
  // Both checksums stay visible: on a BAD the pair IS the finding.
  assert.match(flapped, /fa744fb4e24c1a92/);
  assert.match(flapped, /bacef9dd4ace326f/);
});

test("a flapped GOOD does not claim non-determinism", () => {
  // sticky-bad.py never sets flapped on a GOOD. If it somehow did, the row
  // must not read as a failure.
  const html = tableOf(renderPackage("croc", [{
    package: "croc", suite: "trixie", arch: "amd64", status: "GOOD",
    version: "11.5.3-2~haus13+1", flapped: true,
    rebuilt_sha256: "aaaabbbbccccdddd", recorded_sha256: "aaaabbbbccccdddd",
  }]));
  assert.doesNotMatch(html, /non-deterministic/);
  assert.match(html, /class="v good"[^>]*>GOOD</);
});

test("the legend explains that a BAD stays and what a new version does", () => {
  const html = renderRoot([], { targets: {} });
  assert.match(html, /BAD<\/span> stays once it has happened/);
  assert.match(html, /new version starts clean/);
});

// "size differs" is debrebuild's commonest BAD wording and it prints neither
// number. The delta is the thing a reader can act on: 128 bytes reads as
// codegen, megabytes as a missing file.
test("sizeDelta is signed, and empty whenever it would be meaningless", () => {
  assert.equal(sizeDelta({ rebuilt_size: 10569260, recorded_size: 10569132 }), 
    ' <span class="v none">+128 B</span>');
  assert.match(sizeDelta({ rebuilt_size: 10569000, recorded_size: 10569132 }), /\u2212132 B/);
  // Equal, missing, and null all render as nothing. Verdicts written before
  // these fields existed carry neither, and must not produce "NaN B".
  assert.equal(sizeDelta({ rebuilt_size: 5, recorded_size: 5 }), "");
  assert.equal(sizeDelta({}), "");
  assert.equal(sizeDelta({ rebuilt_size: null, recorded_size: 10 }), "");
  assert.equal(sizeDelta({ rebuilt_size: 10, recorded_size: null }), "");
});

test("a BAD row shows the size delta; a GOOD row does not", () => {
  const bad = renderPackage("zola", [{
    package: "zola", suite: "unstable", arch: "arm64", status: "BAD",
    version: "0.23.6-3",
    rebuilt_sha256: "a4b9001e5625869b", recorded_sha256: "5ced33258b9f1a51",
    rebuilt_size: 10569260, recorded_size: 10569132,
  }]);
  assert.match(bad.slice(0, bad.indexOf('<div class="about"')), /\+128 B/);

  const good = renderPackage("croc", [{
    package: "croc", suite: "trixie", arch: "amd64", status: "GOOD",
    version: "11.5.3-2~haus13+1",
    rebuilt_sha256: "aaaabbbbccccdddd", recorded_sha256: "aaaabbbbccccdddd",
    rebuilt_size: 100, recorded_size: 100,
  }]);
  assert.doesNotMatch(good.slice(0, good.indexOf('<div class="about"')), / B<\/span>/);
});

// --- verdict history ---------------------------------------------------------
// A verdict is one word about the most recent rebuild. These are what let the
// page say whether the package has always answered that way.

const h = (...st) => ({ history: st.map((x, i) => ({ status: x, at: `2026-09-2${i}T00:00:00Z` })) });

test("the strip is padded to a fixed width, oldest first", () => {
  const cells = historyCells(h("BAD", "GOOD"));
  assert.equal((cells.match(/<i /g) || []).length, HISTORY_SLOTS);
  // Three empties, then BAD, then GOOD: padding leads so the newest sits at
  // the right and the column stays aligned down the table.
  assert.match(cells, /^(<i class="none"><\/i>){3}<i class="bad"[^>]*><\/i><i class="good"/);
});

test("a mark names its status in the title, not only by colour", () => {
  // The mark is a coloured block with no text. Without the status in the
  // title the only thing distinguishing a failed rebuild from a passing one
  // is green against red, and the rate beside the strip gives the count but
  // never which of the five it was.
  const cells = historyCells(h("GOOD", "BAD", "UNKWN"));
  for (const status of ["GOOD", "BAD", "UNKWN"]) {
    assert.match(cells, new RegExp(`<i class="[a-z]+" title="${status} - [^"]+"`));
  }
  // Padding carries no title: there is nothing to name.
  assert.match(cells, /^(<i class="none"><\/i>){2}<i class="good" title=/);
});

test("an artifact with no history renders as all-empty, not as a failure", () => {
  // Every verdict written before this feature has no history key at all, and
  // the whole fleet is in that state on the first deploy.
  for (const v of [null, {}, { history: null }, { history: [] }]) {
    assert.equal((historyCells(v).match(/<i class="none">/g) || []).length, HISTORY_SLOTS);
    assert.equal(historyRate(v), "0/0");
    assert.equal(hasMixedHistory(v), false);
  }
});

test("the rate counts decided rebuilds only", () => {
  assert.equal(historyRate(h("GOOD", "GOOD", "GOOD")), "3/3");
  assert.equal(historyRate(h("BAD", "GOOD", "BAD")), "1/3");
  // An UNKWN is a rebuild that could not be completed. Counting it against
  // the package would turn a bad afternoon at snapshot.debian.org into a
  // worse-looking record, which is why the summary column excludes it too.
  assert.equal(historyRate(h("UNKWN", "GOOD")), "1/1");
  assert.equal(historyRate(h("UNKWN", "UNKWN")), "0/0");
});

test("only more than one decided answer counts as mixed", () => {
  assert.equal(hasMixedHistory(h("GOOD", "GOOD", "GOOD")), false);
  assert.equal(hasMixedHistory(h("BAD", "BAD")), false);
  assert.equal(hasMixedHistory(h("BAD", "GOOD")), true);
  // An UNKWN beside a run of GOODs is not a flap.
  assert.equal(hasMixedHistory(h("GOOD", "UNKWN", "GOOD")), false);
});

test("only the last five are kept when more arrive", () => {
  const many = h("BAD", "BAD", "BAD", "GOOD", "GOOD", "GOOD", "GOOD");
  assert.equal((historyCells(many).match(/<i /g) || []).length, HISTORY_SLOTS);
  assert.equal(historyRate(many), "4/5");   // the leading BAD has aged out
});

test("the package table carries a strip per row", () => {
  const html = renderPackage("zola", [{
    package: "zola", suite: "testing", arch: "arm64", status: "BAD",
    version: "0.23.6-3", rebuilt_sha256: "aaaa", recorded_sha256: "bbbb",
    history: [{ status: "BAD", at: "x" }, { status: "BAD", at: "y" }, { status: "GOOD", at: "z" }],
  }]);
  const table = html.slice(0, html.indexOf('<div class="about"'));
  assert.match(table, /<th>last five<\/th>/);
  assert.match(table, /class="hist"/);
  assert.match(table, /class="rate">1\/3</);
});

test("the summary names what its percentage measures, and counts mixed windows", () => {
  const inv = { targets: { "testing/arm64": [{ package: "zola" }] } };
  const verdicts = [{
    package: "zola", suite: "testing", arch: "arm64", status: "BAD",
    history: [{ status: "BAD", at: "x" }, { status: "GOOD", at: "y" }],
  }];
  const html = renderRoot(verdicts, inv);
  const table = html.slice(0, html.indexOf('<div class="about"'));
  // "reproducible" claimed a property of the archive; the figure is about the
  // most recent rebuild of each artifact and now says so.
  assert.doesNotMatch(table, /<th[^>]*>reproducible<\/th>/);
  assert.match(table, /<th[^>]*>latest rebuild<\/th>/);
  assert.match(table, /<th[^>]*>mixed<\/th>/);

  const rows = summarise(verdicts, inv);
  const row = rows.find((r) => r.suite === "testing" && r.arch === "arm64");
  assert.equal(row.mixed, 1);
  assert.equal(totals(rows).mixed, 1);
});

test("the summary's mixed count and a row's non-deterministic are separate", () => {
  // A verdict that flapped long ago and has since reproduced five times in a
  // row: `flapped` is permanent, so the row still says non-deterministic,
  // while the window holds only GOODs and the summary counts it as settled.
  // Sharing one word between these was the bug this pins.
  const v = {
    package: "zola", suite: "testing", arch: "arm64", status: "BAD",
    version: "0.23.6-1~testing1", flapped: true, checked_at: "2026-10-09T00:00:00Z",
    history: ["GOOD", "GOOD", "GOOD", "GOOD", "GOOD"].map((status, i) =>
      ({ status, at: `2026-10-0${i + 1}T00:00:00Z` })),
  };
  assert.equal(hasMixedHistory(v), false);
  assert.equal(totals(summarise([v], null)).mixed, 0);
  assert.match(renderPackage("zola", [v]), /non-deterministic/);
});

// A section boundary is 3.5rem of gap with its rule in the middle, set
// 2026-09-22 across this host, the landing and buildinfos; stats already had
// it. This host and buildinfos were the 5.5rem pair; the landing was a milder
// 4rem. Asserted on the rendered page rather than the source string, because
// what ships is what a reader sees. the estate style registry carries the why.
test("a section boundary is 3.5rem with its rule centred", () => {
  const html = renderRoot([], { targets: {} });
  assert.match(html, /\.about\{[^}]*margin-top:1\.75rem[^}]*padding-top:1\.75rem/);
  // The tablewrap next to a boundary adds nothing of its own. Its 1.5rem on
  // top of the boundary's is what made the gap 5.5rem and pushed the rule to
  // one side of it.
  assert.match(html, /\.tablewrap:has\(\+ \.about\)\{padding-bottom:0\}/);
  assert.doesNotMatch(html, /\.about\{[^}]*margin-top:2rem/);
});

// The section eyebrow. pkg.haus, stats and reproducible all set this rule;
// buildinfos was the one surface with an h2 that did not, until 2026-09-22.
// Asserted because a heading style is exactly the kind of thing that gets
// "tidied" back to a plain size by someone who has not seen the siblings.
test("section headings use the estate eyebrow", () => {
  const html = renderRoot([], { targets: {} });
  assert.match(html, /\.about h2\{[^}]*font-size:\.78rem/);
  assert.match(html, /\.about h2\{[^}]*text-transform:uppercase/);
  assert.match(html, /\.about h2::before\{content:"~ ";color:var\(--accent\)\}/);
});

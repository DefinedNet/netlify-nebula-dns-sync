#!/usr/bin/env node
// Sync Defined Networking host names into a Netlify DNS zone as A/AAAA records, then tag each
// host that has one with dns:synced. Requires Node.js 20 or newer; no dependencies.
import { domainToASCII, domainToUnicode } from "node:url";

const DN_API_KEY = required("DN_API_KEY", "your Defined Networking API key");
const NETLIFY_TOKEN = required("NETLIFY_TOKEN", "a Netlify personal access token");
const DOMAIN = required("DOMAIN", "the domain of your Netlify DNS zone");
const SUBDOMAIN = process.env.SUBDOMAIN ?? "dn";

function required(name, what) {
  if (!process.env[name]) {
    console.error(`Set ${name} to ${what}`);
    process.exit(1);
  }
  return process.env[name];
}

async function api(url, token, init = {}) {
  const res = await fetch(url, {
    ...init,
    headers: {
      Authorization: `Bearer ${token}`,
      "Content-Type": "application/json",
    },
  });
  if (!res.ok) throw new Error(`HTTP ${res.status} from ${url}: ${await res.text()}`);
  const body = await res.text();
  return body ? JSON.parse(body) : null;
}
const dn = (path, init) => api(`https://api.defined.net${path}`, DN_API_KEY, init);
const netlify = (path, init) => api(`https://api.netlify.com/api/v1${path}`, NETLIFY_TOKEN, init);

// Turn a host name into a DNS label. Letters, digits, dashes and emoji from any script
// survive, apostrophes vanish ("Caleb's" -> "calebs"), and every other run of characters
// becomes one dash, except at the edges or next to a dash the name already has, so
// "c-----aleb" keeps its dashes and "a - b" is "a-b". Anything left that is not ASCII goes
// through the same IDNA (UTS-46) encoding a browser applies to an address, so "東京" becomes
// "xn--1lqs71d"; a name that is already punycode ("xn--...") is used as-is. Returns "" when
// the result is not a legal label (1 to 63 characters, alphanumeric at both ends).
const APOSTROPHES = /['‘’ʼ]/g;
const JUNK = /[^\p{L}\p{N}\p{Extended_Pictographic}-]+/gu;
const LEGAL_LABEL = /^[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?$/;
function toLabel(name) {
  let kept = name.normalize("NFKC").toLowerCase();
  if (!kept.startsWith("xn--")) {
    kept = kept.replace(APOSTROPHES, "").replace(JUNK, (run, at, s) => {
      const edge = at === 0 || at + run.length === s.length;
      return edge || s[at - 1] === "-" || s[at + run.length] === "-" ? "" : "-";
    });
  }
  // The URL parser reads all-digit names like "2024" as IPv4 addresses, so only hand it non-ASCII
  const label = /^[a-z0-9-]*$/.test(kept) ? kept : domainToASCII(kept);
  return LEGAL_LABEL.test(label) ? label : "";
}

const warn = (message) => console.warn(`::warning::${message}`);

// A punycode hostname is logged with its Unicode spelling alongside, e.g. "xn--fr8h.dn.example.com (💀.dn.example.com)"
const shown = (hostname) => {
  const unicode = domainToUnicode(hostname);
  return unicode === hostname ? hostname : `${hostname} (${unicode})`;
};

// Look up the Netlify DNS zone ID from the domain name
const zone = (await netlify("/dns_zones")).find((z) => z.name === DOMAIN);
if (!zone) {
  console.error(`Error: no Netlify DNS zone found for ${DOMAIN}`);
  process.exit(1);
}
console.log(`Found zone ${zone.id} for ${DOMAIN}`);

// Fetch all hosts from the Defined Networking API, following pagination
const hosts = [];
let cursor = "";
do {
  const page = await dn(`/v2/hosts${cursor && `?cursor=${encodeURIComponent(cursor)}`}`);
  hosts.push(...page.data);
  cursor = page.metadata.hasNextPage ? page.metadata.nextCursor : "";
} while (cursor);

// Sanitize each host name into a DNS label, keeping the rest of the host record
const labeled = hosts.map((host) => ({ ...host, label: toLabel(host.name) }));

// Warn about names with no usable label (they get no record) and about collisions
for (const { name } of labeled.filter((h) => !h.label))
  warn(`"${name}" does not sanitize to a legal DNS label, skipping`);
const byLabel = new Map();
for (const h of labeled.filter((h) => h.label))
  byLabel.set(h.label, [...(byLabel.get(h.label) ?? []), h.name]);
for (const [label, names] of byLabel) {
  if (names.length > 1) {
    warn(
      `${names.map((n) => `"${n}"`).join(", ")} ${names.length === 2 ? "both" : "all"} sanitize to "${label}"`
    );
  }
}

// Build the desired record set: one A or AAAA record per address
const desired = labeled
  .filter((h) => h.label)
  .flatMap((h) =>
    h.ipAddresses.map((value) => ({
      hostname: `${h.label}.${SUBDOMAIN}.${DOMAIN}`,
      type: value.includes(":") ? "AAAA" : "A",
      value,
    }))
  );

// Fetch the A/AAAA records already under our subdomain
const suffix = `.${SUBDOMAIN}.${DOMAIN}`;
const existing = (await netlify(`/dns_zones/${zone.id}/dns_records`)).filter(
  (r) => r.hostname.endsWith(suffix) && (r.type === "A" || r.type === "AAAA")
);

const key = (r) => `${r.type} ${r.hostname} ${r.value}`;
const desiredKeys = new Set(desired.map(key));
const existingKeys = new Set(existing.map(key));

// Delete stale records (in Netlify but not in the desired set)
for (const r of existing.filter((r) => !desiredKeys.has(key(r)))) {
  console.log(`Deleting stale record: ${r.type} ${shown(r.hostname)} -> ${r.value}`);
  await netlify(`/dns_zones/${zone.id}/dns_records/${r.id}`, {
    method: "DELETE",
  });
}

// Create missing records (in the desired set but not in Netlify)
for (const r of desired.filter((r) => !existingKeys.has(key(r)))) {
  console.log(`Creating record: ${r.type} ${shown(r.hostname)} -> ${r.value}`);
  await netlify(`/dns_zones/${zone.id}/dns_records`, {
    method: "POST",
    body: JSON.stringify({ ...r, ttl: 3600 }),
  });
}

// Tag every host that has a record and untag the rest, so the admin panel shows which names
// resolve. Editing a host resets every field the request leaves out, so each PUT sends the host
// back whole and changes only its tags.
const SYNCED = "dns:synced";
for (const h of labeled) {
  if (h.tags.includes(SYNCED) === Boolean(h.label)) continue;
  const tags = h.label ? [...h.tags, SYNCED] : h.tags.filter((t) => t !== SYNCED);
  console.log(`${h.label ? "Tagging" : "Untagging"} "${h.name}" ${SYNCED}`);
  const { name, roleID, staticAddresses, listenPort, configOverrides } = h;
  await dn(`/v3/hosts/${h.id}`, {
    method: "PUT",
    body: JSON.stringify({ name, roleID, staticAddresses, listenPort, configOverrides, tags }),
  });
}

console.log("Sync complete.");

// App Store Connect API calls with the team key: P8 is the key file, ASC_KEY_ID and ASC_ISSUER_ID
// its ids, from kv at run time. As a command: OUT=<file> node asc.mjs <METHOD> <path> [body].
import crypto from "node:crypto";
import fs from "node:fs";

function token() {
  const key = fs.readFileSync(process.env.P8 ?? "");
  const b64 = (o) => Buffer.from(JSON.stringify(o)).toString("base64url");
  const now = Math.floor(Date.now() / 1000);
  const head = b64({ alg: "ES256", kid: process.env.ASC_KEY_ID, typ: "JWT" });
  const body = b64({
    iss: process.env.ASC_ISSUER_ID,
    iat: now,
    exp: now + 1100,
    aud: "appstoreconnect-v1",
  });
  const sig = crypto.sign("sha256", Buffer.from(`${head}.${body}`), {
    key,
    dsaEncoding: "ieee-p1363",
  });
  return `${head}.${body}.${sig.toString("base64url")}`;
}

export async function asc(method, path, body) {
  const url = path.startsWith("http") ? path : `https://api.appstoreconnect.apple.com${path}`;
  const r = await fetch(url, {
    method,
    headers: { Authorization: `Bearer ${token()}`, "Content-Type": "application/json" },
    ...(body ? { body: typeof body === "string" ? body : JSON.stringify(body) } : {}),
  });
  const text = await r.text();
  let json;
  try {
    json = JSON.parse(text);
  } catch {
    json = text;
  }
  return { status: r.status, text, json };
}

export async function all(path) {
  let next = path;
  const data = [];
  const included = [];
  while (next) {
    const { status, json } = await asc("GET", next);
    if (status >= 300) throw new Error(`${status} ${JSON.stringify(json).slice(0, 800)}`);
    data.push(...json.data);
    included.push(...(json.included ?? []));
    next = json.links?.next;
  }
  return { data, included };
}

if (import.meta.url === `file://${process.argv[1]}`) {
  const [, , method, path, body] = process.argv;
  const r = await asc(method, path, body);
  if (process.env.OUT) fs.writeFileSync(process.env.OUT, r.text);
  console.log(r.status, r.text.slice(0, 4000));
}

// P8=<key> ASC_KEY_ID=.. ASC_ISSUER_ID=.. node ensure-app.mjs <out dir>
// Gets Kanban Code iOS ready on App Store Connect and the developer portal:
// - the App ID io.kanbancode.mobile, with the Push Notifications capability;
// - an ACTIVE App Store profile on the team's distribution certificate whose
//   entitlements carry aps-environment, written to <out dir>/app.mobileprovision;
// - the app record (the API cannot create one: it must exist already);
// - the internal TestFlight group "Team" that gets every build.
// Prints `APP_ID=<id>` for the caller. Exits 2 when Apple refuses the
// provisioning calls, 3 when the app record is missing.
import fs from "node:fs";
import path from "node:path";

import { all, asc } from "./asc.mjs";

const BUNDLE = process.env.KC_IOS_BUNDLE ?? "io.kanbancode.mobile";
const NAME = "Kanban Code";
const out = process.argv[2];
const stamp = new Date().toISOString().slice(0, 10);

function entitlementsOf(content) {
  const xml = Buffer.from(content, "base64").toString("latin1");
  const start = xml.indexOf("<key>Entitlements</key>");
  return start < 0 ? "" : xml.slice(start, xml.indexOf("</dict>", start));
}

function fail(code, message) {
  console.error(message);
  process.exit(code);
}

async function provisioning() {
  const ids = await asc("GET", `/v1/bundleIds?filter[identifier]=${BUNDLE}&filter[platform]=IOS`);
  if (ids.status === 403 || ids.status === 401)
    fail(
      2,
      `Apple refused the provisioning API (${ids.status}): ${JSON.stringify(ids.json).slice(0, 400)}\n` +
        "Pass --profile <App Store .mobileprovision for " + BUNDLE + "> to sign with a profile made in the developer portal.",
    );
  if (ids.status >= 300) throw new Error(`bundleIds: ${ids.status} ${ids.text.slice(0, 400)}`);
  let bundleId = ids.json.data.find((b) => b.attributes.identifier === BUNDLE);
  if (!bundleId) {
    const made = await asc("POST", "/v1/bundleIds", {
      data: { type: "bundleIds", attributes: { identifier: BUNDLE, name: NAME, platform: "IOS" } },
    });
    if (made.status >= 300) throw new Error(`App ID ${BUNDLE}: ${made.status} ${made.text.slice(0, 400)}`);
    bundleId = made.json.data;
    console.error(`registered App ID ${BUNDLE} (${bundleId.id})`);
  }
  const caps = await all(`/v1/bundleIds/${bundleId.id}/bundleIdCapabilities`);
  if (!caps.data.some((c) => c.attributes.capabilityType === "PUSH_NOTIFICATIONS")) {
    const made = await asc("POST", "/v1/bundleIdCapabilities", {
      data: {
        type: "bundleIdCapabilities",
        attributes: { capabilityType: "PUSH_NOTIFICATIONS" },
        relationships: { bundleId: { data: { type: "bundleIds", id: bundleId.id } } },
      },
    });
    if (made.status >= 300) throw new Error(`push capability: ${made.status} ${made.text.slice(0, 400)}`);
    console.error(`turned on Push Notifications for ${BUNDLE}`);
  }
  const certs = await all("/v1/certificates?filter[certificateType]=DISTRIBUTION,IOS_DISTRIBUTION&limit=200");
  const cert = certs.data
    .filter((c) => new Date(c.attributes.expirationDate) > new Date())
    .toSorted((a, b) => b.attributes.expirationDate.localeCompare(a.attributes.expirationDate))[0];
  if (!cert) throw new Error("no valid distribution certificate on the team");
  const profiles = await all(`/v1/bundleIds/${bundleId.id}/profiles?limit=200`);
  let profile = profiles.data
    .filter((p) => p.attributes.profileType === "IOS_APP_STORE" && p.attributes.profileState === "ACTIVE")
    .filter((p) => entitlementsOf(p.attributes.profileContent).includes("aps-environment"))
    .toSorted((a, b) => b.attributes.expirationDate.localeCompare(a.attributes.expirationDate))[0];
  if (!profile) {
    const taken = new Set(profiles.data.map((p) => p.attributes.name));
    let name = `${NAME} App Store ${stamp}`;
    for (let n = 2; taken.has(name); n++) name = `${NAME} App Store ${stamp} ${n}`;
    const made = await asc("POST", "/v1/profiles", {
      data: {
        type: "profiles",
        attributes: { name, profileType: "IOS_APP_STORE" },
        relationships: {
          bundleId: { data: { type: "bundleIds", id: bundleId.id } },
          certificates: { data: [{ type: "certificates", id: cert.id }] },
        },
      },
    });
    if (made.status >= 300) throw new Error(`profile: ${made.status} ${made.text.slice(0, 400)}`);
    profile = made.json.data;
    console.error(`made profile ${name} (${profile.id})`);
  }
  fs.writeFileSync(path.join(out, "app.mobileprovision"), Buffer.from(profile.attributes.profileContent, "base64"));
  console.error(`${BUNDLE}: ${profile.attributes.name} until ${profile.attributes.expirationDate.slice(0, 10)}`);
}

async function appRecord() {
  const apps = await asc("GET", `/v1/apps?filter[bundleId]=${BUNDLE}`);
  if (apps.status >= 300) throw new Error(`apps: ${apps.status} ${apps.text.slice(0, 400)}`);
  const app = apps.json.data.find((a) => a.attributes.bundleId === BUNDLE);
  if (!app)
    fail(
      3,
      `No App Store Connect app for ${BUNDLE}. The API cannot create one: add it once in App Store Connect ` +
        `(Apps, +, New App: iOS, name "${NAME}", bundle id ${BUNDLE}, SKU kanban-code-ios).`,
    );
  const groups = await all(`/v1/apps/${app.id}/betaGroups`);
  if (!groups.data.some((g) => g.attributes.isInternalGroup)) {
    const made = await asc("POST", "/v1/betaGroups", {
      data: {
        type: "betaGroups",
        attributes: { name: "Team", isInternalGroup: true, hasAccessToAllBuilds: true },
        relationships: { app: { data: { type: "apps", id: app.id } } },
      },
    });
    if (made.status >= 300) throw new Error(`beta group: ${made.status} ${made.text.slice(0, 400)}`);
    const group = made.json.data;
    // The account holder tests every build.
    const users = await all("/v1/users?limit=200");
    const holder = users.data.find((u) => u.attributes.roles.includes("ACCOUNT_HOLDER"));
    if (holder) {
      const tester = await asc("POST", "/v1/betaTesters", {
        data: {
          type: "betaTesters",
          attributes: {
            email: holder.attributes.username,
            firstName: holder.attributes.firstName,
            lastName: holder.attributes.lastName,
          },
          relationships: { betaGroups: { data: [{ type: "betaGroups", id: group.id }] } },
        },
      });
      console.error(`internal group Team made; tester ${holder.attributes.username}: ${tester.status}`);
    }
  }
  console.log(`APP_ID=${app.id}`);
}

if (!process.argv.includes("--app-only")) await provisioning();
await appRecord();

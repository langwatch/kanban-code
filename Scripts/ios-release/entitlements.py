"""Usage: entitlements.py <profile.mobileprovision> <source .entitlements> <out plist>

Writes the entitlements an App Store build is signed with: the app and team
identifiers from the profile, get-task-allow off, and each key the source
entitlements ask for with the profile's value (aps-environment becomes
production). A key the profile does not grant is left out, with a warning.
"""
import plistlib
import subprocess
import sys

profile_path, source_path, out_path = sys.argv[1:4]
decoded = subprocess.run(["security", "cms", "-D", "-i", profile_path], check=True, capture_output=True).stdout
granted = plistlib.loads(decoded)["Entitlements"]
with open(source_path, "rb") as f:
    wanted = plistlib.load(f)

out = {
    "application-identifier": granted["application-identifier"],
    "com.apple.developer.team-identifier": granted["com.apple.developer.team-identifier"],
    "get-task-allow": False,
}
if "beta-reports-active" in granted:
    out["beta-reports-active"] = granted["beta-reports-active"]
for key, value in wanted.items():
    if key in granted:
        out[key] = granted[key]
    elif key == "com.apple.developer.usernotifications.time-sensitive":
        # Needs no profile grant: Xcode signs it in as the source has it.
        out[key] = value
    else:
        print(f"entitlements: the profile does not grant {key}, left out", file=sys.stderr)
with open(out_path, "wb") as f:
    plistlib.dump(out, f)
print("entitlements: " + ", ".join(sorted(out)), file=sys.stderr)

#!/bin/sh
# Set up how this project deploys to Vercel so build CPU stays down: no
# branch builds, nothing for changes that do not ship, at most one deploy
# per interval. Writes vercel.json in the app's folder (merging into one
# that exists, so crons and other keys stay), .claude/deploy.json, and for
# the scheduled paths the cron of .github/workflows/deploy.yml.
#
# Usage: sh scripts/deploy-setup.sh [PATH] [APP_ROOT] [INTERVAL_MINUTES]
#   PATH      runner, vercel or guard; omitted, it is chosen from what the
#             project has (a self-hosted runner, the Vercel secrets).
#   APP_ROOT  the app's folder, "." by default; "web" in a monorepo.
#   INTERVAL  minutes between deploys at most, 60 by default.
# Needs node (to edit JSON) and, to choose the path or set the variable,
# gh signed in. It commits nothing; review the diff and open a PR.
set -e
here=$(dirname "$0")
. "$here/ci/deploy-lib.sh"
path=$1; app=${2:-.}; interval=${3:-60}
app=${app%/}; [ -n "$app" ] || app=.
[ -d "$app" ] || { echo "No folder $app; give the app's folder as the second argument." >&2; exit 2; }
command -v node >/dev/null 2>&1 || { echo "node is needed to edit vercel.json." >&2; exit 2; }

if [ -z "$path" ]; then
  runner=no; secrets=no
  if command -v gh >/dev/null 2>&1; then
    [ "$(gh api 'repos/{owner}/{repo}/actions/runners' --jq '.total_count' 2>/dev/null || echo 0)" -gt 0 ] && runner=yes
    names=$(gh api 'repos/{owner}/{repo}/actions/secrets' --jq '.secrets[].name' 2>/dev/null || true)
    printf '%s\n' "$names" | grep -qx VERCEL_TOKEN && printf '%s\n' "$names" | grep -qx VERCEL_ORG_ID && printf '%s\n' "$names" | grep -qx VERCEL_PROJECT_ID && secrets=yes
  fi
  path=$(deploy_path yes "$runner" "$secrets")
  echo "Chose the $path path (a runner: $runner; the Vercel secrets: $secrets)."
fi
case "$path" in runner|vercel|guard) ;; *) echo "PATH is runner, vercel or guard." >&2; exit 2 ;; esac

rel=$(rel_to_root "$app")
DS_FILE="$app/vercel.json" DS_PATH="$path" DS_CMD="sh ${rel}scripts/ci/vercel-ignore.sh" node -e '
  const fs = require("fs");
  const f = process.env.DS_FILE;
  let j = {};
  try { j = JSON.parse(fs.readFileSync(f, "utf8")); } catch (e) { if (fs.existsSync(f)) { console.error("vercel.json is not valid JSON; fix it first."); process.exit(1); } }
  if (!j.$schema) j = { $schema: "https://openapi.vercel.sh/vercel.json", ...j };
  j.git = j.git || {};
  if (process.env.DS_PATH === "guard") {
    j.git.deploymentEnabled = { main: true, "*": false, "**": false };
    j.ignoreCommand = process.env.DS_CMD;
  } else {
    j.git.deploymentEnabled = false;
    delete j.ignoreCommand;
  }
  fs.writeFileSync(f, JSON.stringify(j, null, 2) + "\n");
'
mkdir -p .claude
printf '{\n  "_comment": "How this project deploys, written by scripts/deploy-setup.sh. path: runner, vercel or guard. The brief and the audit read it.",\n  "path": "%s",\n  "appRoot": "%s",\n  "intervalMinutes": %s\n}\n' "$path" "$app" "$interval" > .claude/deploy.json
echo "Wrote $app/vercel.json and .claude/deploy.json."

if [ "$path" = guard ]; then
  echo "Git deploys now come from main only, skip changes that do not ship, and wait at least $interval minutes between builds."
  [ "$interval" = 60 ] || echo "Set DEPLOY_INTERVAL_MINUTES=$interval in the Vercel project's environment variables, for the ignore step."
  echo "No secrets are needed. Commit both files and open a pull request; Vercel reads them on the next push to main."
  exit 0
fi

cron=$(interval_cron "$interval")
if [ -f .github/workflows/deploy.yml ]; then
  DS_CRON="$cron" node -e '
    const fs = require("fs"); const f = ".github/workflows/deploy.yml";
    const s = fs.readFileSync(f, "utf8").replace(/- cron: "[^"]*"/, "- cron: \"" + process.env.DS_CRON + "\"");
    fs.writeFileSync(f, s);'
  echo "The Deploy workflow runs at \"$cron\"."
else
  echo "Copy .github/workflows/deploy.yml from the plugin's templates (the sync does), then run this again to set its schedule."
fi
if command -v gh >/dev/null 2>&1 && gh variable set DEPLOY_PATH --body "$path" >/dev/null 2>&1; then
  echo "Set the repository variable DEPLOY_PATH to $path."
else
  echo "Could not set the repository variable DEPLOY_PATH; set it to $path by hand (Settings, Secrets and variables, Actions, Variables)."
fi
cat <<EOF
Before the first scheduled run, set three repository secrets (Settings, Secrets and variables, Actions):
  VERCEL_TOKEN       a token from vercel.com/account/tokens
  VERCEL_ORG_ID      and VERCEL_PROJECT_ID, from .vercel/project.json after "npx vercel link"
Optional: ADMIN_TOKEN, so the plan can see whether a runner is online.
Then run the Deploy workflow once from the Actions tab; it records the deployed commit.
Vercel's Git deploys are off from the moment vercel.json reaches main; until the Deploy workflow runs, main is not deployed.
EOF

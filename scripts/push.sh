#!/usr/bin/env bash
# push the repo + release to github. account-agnostic on purpose:
#   export GH_OWNER=your-handle
#   export GH_TOKEN=<PAT with repo scope>
#   bash scripts/push.sh
# the token is read from the environment only - never written to disk,
# never embedded in .git/config.
set -euo pipefail
cd "$(dirname "$0")/.."

: "${GH_OWNER:?set GH_OWNER}"
: "${GH_TOKEN:?set GH_TOKEN}"

REPO="${GH_REPO:-ghost-box}"
BRANCH="main"
# the helper must expand the vars at helper-runtime, not now
# shellcheck disable=SC2016
CRED='!f(){ echo "username=${GH_OWNER}"; echo "password=${GH_TOKEN}"; };f'

echo "== ensure repo ${GH_OWNER}/${REPO} exists =="
HTTP_CODE=$(curl -sS -o /tmp/repo-create.json -w "%{http_code}" \
  -X POST \
  -H "Authorization: Bearer ${GH_TOKEN}" \
  -H "Accept: application/vnd.github+json" \
  https://api.github.com/user/repos \
  -d "{\"name\":\"${REPO}\",\"private\":false,\"description\":\
\"Anonymous whistleblower submission box: private EKS, tor-only ingress, ephemeral pods, sealed OpenPGP envelopes\"}")
if [ "$HTTP_CODE" = "201" ]; then
  echo "created"
elif [ "$HTTP_CODE" = "422" ]; then
  echo "already exists"
else
  python3 -c "import json;d=json.load(open('/tmp/repo-create.json'));\
print('unexpected:', d.get('message'), d.get('errors'))"
  exit 1
fi

echo "== push ${BRANCH} =="
git -c "credential.helper=${CRED}" push -u \
  "https://github.com/${GH_OWNER}/${REPO}.git" "${BRANCH}"

echo "== push tags =="
git -c "credential.helper=${CRED}" push \
  "https://github.com/${GH_OWNER}/${REPO}.git" --tags || true

echo "== release =="
if [ -f release/SHA256SUMS.txt ]; then
  TAG="v1.0.0"
  curl -sS -X POST \
    -H "Authorization: Bearer ${GH_TOKEN}" \
    -H "Accept: application/vnd.github+json" \
    "https://api.github.com/repos/${GH_OWNER}/${REPO}/releases" \
    -d "{\"tag_name\":\"${TAG}\",\"name\":\"${REPO} ${TAG}\",\
\"body\":\"See CHANGELOG.md. Archives and SHA256SUMS attached.\"}" \
    | python3 -c "import json,sys;d=json.load(sys.stdin);\
print('release:', d.get('html_url') or d.get('message'))"
  REL_ID=$(curl -sS -H "Authorization: Bearer ${GH_TOKEN}" \
    "https://api.github.com/repos/${GH_OWNER}/${REPO}/releases/tags/${TAG}" \
    | python3 -c "import json,sys;print(json.load(sys.stdin)['id'])")
  for f in release/*.zip release/*.tar.gz release/*.tar.xz \
           release/SHA256SUMS.txt; do
    [ -f "$f" ] || continue
    NAME=$(basename "$f")
    echo "  uploading ${NAME}"
    curl -sS -X POST \
      -H "Authorization: Bearer ${GH_TOKEN}" \
      -H "Content-Type: application/octet-stream" \
      --data-binary "@${f}" \
      "https://uploads.github.com/repos/${GH_OWNER}/${REPO}/releases/${REL_ID}/assets?name=${NAME}" \
      | python3 -c "import json,sys;d=json.load(sys.stdin);\
print('   ', d.get('name') or d.get('message'))"
  done
fi

echo "== done: https://github.com/${GH_OWNER}/${REPO} =="

#!/usr/bin/env bash
set -euo pipefail

TARGET_TAG="${TARGET_TAG:?TARGET_TAG must be set}"
UPSTREAM_REPO="${UPSTREAM_REPO:-fawney19/Aether}"
PATCH_FILE="${PATCH_FILE:-$(pwd)/.github/patches/custom_bind_host.patch}"

if [[ ! -f "${PATCH_FILE}" ]]; then
  echo "Error: Patch file not found at ${PATCH_FILE}" >&2
  exit 1
fi

echo "=== Syncing upstream tag ${TARGET_TAG} from ${UPSTREAM_REPO} ==="
git remote add upstream "https://github.com/${UPSTREAM_REPO}.git" 2>/dev/null || true
git fetch upstream "refs/tags/${TARGET_TAG}:refs/tags/${TARGET_TAG}"

git checkout -B "sync-release-${TARGET_TAG}" "refs/tags/${TARGET_TAG}"

TARGET_RS="apps/aether-gateway/src/main.rs"
if [[ ! -f "${TARGET_RS}" ]]; then
  echo "Error: ${TARGET_RS} not found in checked out tag ${TARGET_TAG}!" >&2
  exit 1
fi

if grep -q "APP_HOST" "${TARGET_RS}"; then
  echo "Notice: ${TARGET_RS} already contains APP_HOST logic."
else
  echo "Applying custom bind host patch..."
  PATCH_APPLIED=false

  if git apply "${PATCH_FILE}" 2>/dev/null; then
    echo "Successfully applied patch via standard git apply."
    PATCH_APPLIED=true
  elif git apply --ignore-whitespace --ignore-space-change "${PATCH_FILE}" 2>/dev/null; then
    echo "Successfully applied patch via git apply with whitespace tolerance."
    PATCH_APPLIED=true
  else
    echo "git apply failed, attempting node fallback replacement..."
    node -e '
      const fs = require("fs");
      const file = "apps/aether-gateway/src/main.rs";
      let code = fs.readFileSync(file, "utf8");
      const targetRegex = /fn\s+gateway_bind_addr\s*\(\s*app_port\s*:\s*u16\s*\)\s*->\s*Result\s*<\s*std::net::SocketAddr\s*,\s*std::io::Error\s*>\s*\{[\s\S]*?validate_app_port\s*\(\s*app_port\s*\)\s*\?[\s\S]*?\)\s*\)\s*\}/m;
      const replacement = `fn gateway_bind_addr(app_port: u16) -> Result<std::net::SocketAddr, std::io::Error> {
    let host_str = std::env::var("APP_HOST")
        .or_else(|_| std::env::var("AETHER_BIND_ADDR"))
        .unwrap_or_else(|_| "0.0.0.0".to_string());
    let ip: std::net::IpAddr = host_str.trim().parse().map_err(|e| {
        std::io::Error::new(
            std::io::ErrorKind::InvalidInput,
            format!("Invalid bind IP \x27{host_str}\x27: {e}"),
        )
    })?;
    Ok(std::net::SocketAddr::new(ip, validate_app_port(app_port)?))
}`;
      if (targetRegex.test(code)) {
        code = code.replace(targetRegex, replacement);
        fs.writeFileSync(file, code, "utf8");
        console.log("Fallback replacement succeeded.");
      } else {
        console.error("Could not locate gateway_bind_addr function in target file!");
        process.exit(1);
      }
    '
    PATCH_APPLIED=true
  fi

  if ! grep -q "APP_HOST" "${TARGET_RS}"; then
    echo "Error: Verification failed! APP_HOST was not found in ${TARGET_RS}" >&2
    exit 1
  fi
fi

echo "=== Committing changes and creating tag ${TARGET_TAG} ==="
git config user.name "github-actions[bot]"
git config user.email "github-actions[bot]@users.noreply.github.com"
git commit -am "feat(gateway): bind host via APP_HOST/AETHER_BIND_ADDR env for ${TARGET_TAG}" || echo "Nothing new to commit"

git tag -f -a "${TARGET_TAG}" -m "Release ${TARGET_TAG} with custom bind host"

echo "Attempting to push tag to origin..."
if git push origin "${TARGET_TAG}" --force 2>/dev/null; then
  echo "Successfully pushed tag ${TARGET_TAG} to origin."
else
  echo "::warning::git push tag was rejected (GITHUB_TOKEN lacks workflow permission). Proceeding to build and publish via Release API."
fi

# Phase 4 — 1Password Service Account Token Provisioning (mac-dev-server-setup)

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Provision the 1Password service account token (`op-service-account-claude-automation`) to new Mac Mini dev-server targets via the existing external-keychain airdrop flow, so `claude-wrapper` can fetch runtime credentials (`GH_TOKEN`) from `op://Automation/*` on first boot.

**Architecture:** Piggyback on the existing external-keychain pattern used for TimeMachine and WiFi credentials. On the dev machine, `prep-airdrop.sh` reads the token from the local login Keychain and writes it to the external keychain bundle. On the target, `first-boot.sh` extracts it from the external keychain and installs it into the admin user's login keychain under account `${ADMIN_USERNAME}` — matching `claude-wrapper`'s `id -un` lookup in `lib/credentials.sh:36`.

**Tech Stack:** bash, macOS `security` CLI, claude-wrapper (`lib/credentials.sh`).

**Out of scope for this PR:** Caddy / CF_API_TOKEN / System-keychain hop (those live in `mac-server-setup`, which will get a parallel PR after this merges).

**Account-name invariant (critical):**

- External keychain storage: `-a "${SERVER_NAME_LOWER}"` (consistent with existing TimeMachine/WiFi entries)
- Login keychain on target: `-a "${ADMIN_USERNAME}"` (= `whoami` = `id -un`, which is what claude-wrapper looks up)

---

## Task 1: prep-airdrop.sh — provision service account token

**Files:**

- Modify: `prep-airdrop.sh` (add block after existing WiFi block, before `init_external_keychain` definition — i.e., insert between lines 499 and 501; add manifest entry in `create_keychain_manifest` at line 611)

Wait — `init_external_keychain` is *called* at line 625, after all the credential collection is done reading from 1Password. The right spot is alongside the TimeMachine block (line 627–662) so it's part of the "Setting up credentials" section.

**Step 1: Insert provisioning block after the TimeMachine block**

Insert at `prep-airdrop.sh:663` (after the TimeMachine `fi` on line 662, before the Apple ID block on line 664):

```bash
# Provision 1Password service account token for target machine
# Sourced from the dev machine's login Keychain (created during Phase 1–3 bootstrap).
# Stored under SERVER_NAME_LOWER account in external keychain; first-boot.sh
# re-installs it under ADMIN_USERNAME so claude-wrapper's id -un lookup matches.
echo "Provisioning 1Password service account token..."
op_service_token="$(security find-generic-password \
  -a "${USER}" \
  -s "op-service-account-claude-automation" \
  -w 2>/dev/null || true)"

if [[ -n "${op_service_token}" ]]; then
  store_external_keychain_credential \
    "op-service-account-claude-automation" \
    "${SERVER_NAME_LOWER}" \
    "${op_service_token}" \
    "Mac Server Setup - 1Password Service Account Token"
  unset op_service_token
  echo "✅ 1Password service account token staged for target"
else
  collect_warning "1Password service account token not found in dev Keychain — target will not have op CLI access"
fi
```

**Step 2: Add manifest entry in `create_keychain_manifest`**

Modify `prep-airdrop.sh:611–621`. Add `KEYCHAIN_OP_SERVICE` line to the heredoc:

```bash
create_keychain_manifest() {
  cat >"${OUTPUT_PATH}/config/keychain_manifest.conf" <<EOF
# External keychain service identifiers for credential retrieval
KEYCHAIN_TIMEMACHINE_SERVICE="timemachine-${SERVER_NAME_LOWER}"
KEYCHAIN_WIFI_SERVICE="wifi-${SERVER_NAME_LOWER}"
KEYCHAIN_OP_SERVICE="op-service-account-claude-automation"
KEYCHAIN_ACCOUNT="${SERVER_NAME_LOWER}"
EOF
  chmod 600 "${OUTPUT_PATH}/config/keychain_manifest.conf"
  add_to_manifest "config/keychain_manifest.conf" "REQUIRED"
  echo "✅ Keychain manifest created"
}
```

**Step 3: Verify shellcheck clean**

Run: `shellcheck -S info /Users/andrewrich/Developer/mac-dev-server-setup/prep-airdrop.sh`
Expected: no new warnings/errors introduced.

**Step 4: Commit**

```bash
git -C /Users/andrewrich/Developer/mac-dev-server-setup add prep-airdrop.sh
git -C /Users/andrewrich/Developer/mac-dev-server-setup commit -m "feat(prep-airdrop): stage 1Password service account token in external keychain"
```

---

## Task 2: first-boot.sh — import service account token to admin login keychain

**Files:**

- Modify: `scripts/server/first-boot.sh:455–467` (add new extraction block immediately after the WiFi block)

**Step 1: Insert extraction block after WiFi block**

Insert at `scripts/server/first-boot.sh:468` (before the `return 0` on line 469):

```bash
  # Import 1Password service account token (optional)
  # Written under ADMIN_USERNAME so claude-wrapper's `id -un` lookup matches
  # (see claude-wrapper/lib/credentials.sh: security find-generic-password -a "$(id -un)").
  # shellcheck disable=SC2154 # KEYCHAIN_OP_SERVICE loaded from sourced manifest
  if op_service_token=$(security find-generic-password -s "${KEYCHAIN_OP_SERVICE}" -a "${KEYCHAIN_ACCOUNT}" -w "${EXTERNAL_KEYCHAIN}" 2>/dev/null); then
    security delete-generic-password -s "${KEYCHAIN_OP_SERVICE}" -a "${ADMIN_USERNAME}" &>/dev/null || true
    if security add-generic-password -s "${KEYCHAIN_OP_SERVICE}" -a "${ADMIN_USERNAME}" -w "${op_service_token}" -D "1Password Service Account - claude-automation" -A -U; then
      show_log "✅ 1Password service account token imported to administrator keychain"
    else
      collect_warning "Failed to import 1Password service account token to administrator keychain"
    fi
    unset op_service_token
  else
    show_log "⚠️ 1Password service account token not found in external keychain (optional)"
  fi
```

**Step 2: Verify shellcheck clean**

Run: `shellcheck -S info /Users/andrewrich/Developer/mac-dev-server-setup/scripts/server/first-boot.sh`
Expected: no new warnings/errors.

**Step 3: Commit**

```bash
git -C /Users/andrewrich/Developer/mac-dev-server-setup add scripts/server/first-boot.sh
git -C /Users/andrewrich/Developer/mac-dev-server-setup commit -m "feat(first-boot): import 1Password service account token to admin keychain"
```

---

## Task 3: CLAUDE.md — clarify op vs opp dev commands

**Files:**

- Modify: `CLAUDE.md:28–36`

**Step 1: Edit Dev Commands block**

Replace:

```bash
# Verify 1Password connectivity (dev machine only — verify hostname first!)
op vault list
```

With:

```bash
# Verify 1Password connectivity (dev machine only — verify hostname first!)
op vault list      # service account — Automation vault only, non-interactive
opp vault list     # interactive auth — Personal vault access (prep-airdrop.sh requires this)
```

**Step 2: Commit**

```bash
git -C /Users/andrewrich/Developer/mac-dev-server-setup add CLAUDE.md
git -C /Users/andrewrich/Developer/mac-dev-server-setup commit -m "docs(CLAUDE.md): clarify op vs opp for service account vs interactive auth"
```

---

## Task 4: Pre-push review

**Step 1: Re-run shellcheck on all modified files**

```bash
cd /Users/andrewrich/Developer/mac-dev-server-setup && shellcheck -S info prep-airdrop.sh scripts/server/first-boot.sh
```

Expected: no errors/warnings/info items introduced.

**Step 2: Confirm last pre-commit hook passed for each commit**

```bash
head -6 /Users/andrewrich/Developer/mac-dev-server-setup/.git/last-review-result.log
```

Expected: timestamp recent, repo = mac-dev-server-setup, branch = claude/phase4-op-service-account-token-*, VERDICT READY.

**Step 3: Push and open PR**

```bash
git -C /Users/andrewrich/Developer/mac-dev-server-setup push -u origin HEAD
gh pr create --repo smartwatermelon/mac-dev-server-setup --title "feat: provision 1Password service account token to new targets" --body "$(cat <<'EOF'
## Summary

Phase 4 of the 1Password service-account migration. Uses the existing
external-keychain airdrop flow to provision `op-service-account-claude-automation`
to new Mac Mini dev-server targets, so `claude-wrapper` can fetch `GH_TOKEN`
from `op://Automation/GitHub - CCCLI/Token` on first boot.

**Scope:** dev-server only. No Caddy, no runtime rotation, no System-keychain
hop. `mac-server-setup` will get a parallel PR covering those.

## Changes

- `prep-airdrop.sh`: read token from dev Keychain, stage in external keychain
  under `SERVER_NAME_LOWER` account; add `KEYCHAIN_OP_SERVICE` to manifest
- `scripts/server/first-boot.sh`: import token from external keychain, install
  in admin login keychain under `ADMIN_USERNAME` (matches `claude-wrapper`'s
  `id -un` lookup in `lib/credentials.sh`)
- `CLAUDE.md`: clarify `op` (service account, non-interactive) vs `opp`
  (Personal vault, interactive)

## Test plan

- [ ] `shellcheck -S info` clean on modified files
- [ ] Dry run on ASIAGO: `prep-airdrop.sh` produces a bundle with the token in
      the external keychain (verify with `security find-generic-password -s
      op-service-account-claude-automation -a <server>-lower -w mac-server-setup`)
- [ ] Manual backfill on MIMOLETTE (one-time, not in this PR): `security
      add-generic-password -s op-service-account-claude-automation -a
      andrewrich -w <token>`
- [ ] Post-backfill verification on MIMOLETTE: `claude-wrapper` starts, `gh
      auth status` shows token from `op://Automation/GitHub - CCCLI/Token`

🤖 Generated with [Claude Code](https://claude.com/claude-code)
EOF
)"
```

Expected: PR URL returned. **STOP — wait for user authorization before merge.**

---

## Task 5: Post-merge MIMOLETTE backfill (user-assisted)

Not in this PR. After merge:

```bash
# On ASIAGO — read the token
TOKEN="$(security find-generic-password -a "$USER" -s op-service-account-claude-automation -w)"
# Copy into clipboard
printf '%s' "$TOKEN" | pbcopy
unset TOKEN
```

```bash
# On MIMOLETTE — paste the token
ssh andrewrich@mimolette.local
security add-generic-password -s "op-service-account-claude-automation" -a "andrewrich" -w -U
# paste token when prompted
security find-generic-password -s "op-service-account-claude-automation" -w 2>&1 | head -1  # verify
```

Then verify `claude-wrapper` on MIMOLETTE picks it up: `GH_TOKEN=''; claude-wrapper --help` and watch for no "gh keyring fallback" warning.

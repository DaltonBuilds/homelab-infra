#!/usr/bin/env bash
# HOMELAB-45/46: the GCP side of OpenBao auto-unseal (Phase 0.6).
#
#   gcp/vault-kms.sh check   read-only: report what exists and whether it matches
#   gcp/vault-kms.sh apply   create anything missing; re-running changes nothing
#   gcp/vault-kms.sh key     write a NEW service-account JSON key to stdout (see README)
#
# Tier 0 bootstrap: nothing here authenticates to OpenBao. Tier 1 [1.3] imports these
# resources into OpenTofu and deletes the create path, as with roles/vault_vm.
set -euo pipefail
# Never prompt, and never enable an API as a side effect: check must stay read-only.
export CLOUDSDK_CORE_DISABLE_PROMPTS=1 CLOUDSDK_CORE_SHOULD_PROMPT_TO_ENABLE_API=false

# Project IDs are global, so the dedicated "homelab-vault" project (HOMELAB-43) is
# daltonbuilds-homelab-vault (number 598884619232). Override any of these from the env.
GCP_PROJECT="${GCP_PROJECT:-daltonbuilds-homelab-vault}"
GCP_BILLING_ACCOUNT="${GCP_BILLING_ACCOUNT:-}"
GCP_REGION="${GCP_REGION:-us-central1}"
KEY_RING="vault-unseal"
CRYPTO_KEY="vault-unseal-key"
ROTATION_PERIOD="90d"
SA_NAME="vault-unseal-sa"
ROLE_ID="vaultUnseal"
# Exactly what the gcpckms seal uses: encrypt, decrypt, and key metadata at startup.
ROLE_PERMISSIONS="cloudkms.cryptoKeyVersions.useToDecrypt,cloudkms.cryptoKeyVersions.useToEncrypt,cloudkms.cryptoKeys.get"

die() { echo "error: $*" >&2; exit 1; }
say() { echo "$*" >&2; }

SA="${SA_NAME}@${GCP_PROJECT}.iam.gserviceaccount.com"
ROLE="projects/${GCP_PROJECT}/roles/${ROLE_ID}"
KEY_ARGS=(--location="$GCP_REGION" --keyring="$KEY_RING" --project="$GCP_PROJECT")

exists() { "$@" >/dev/null 2>&1; }

# BSD date (macOS) first, GNU date as the fallback.
next_rotation() {
  date -u -v+90d +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d '+90 days' +%Y-%m-%dT%H:%M:%SZ
}

project_iam_roles() {
  gcloud projects get-iam-policy "$GCP_PROJECT" --flatten='bindings[].members' \
    --filter="bindings.members:${SA}" --format='value(bindings.role)'
}

check() {
  local ok=0
  report() { if "${@:2}"; then say "ok      $1"; else say "MISSING $1"; ok=1; fi; }

  report "project $GCP_PROJECT" exists gcloud projects describe "$GCP_PROJECT"
  [[ $ok -eq 0 ]] || return 1
  report "billing enabled" test "$(gcloud billing projects describe "$GCP_PROJECT" --format='value(billingEnabled)')" = True
  report "cloudkms API" test -n "$(gcloud services list --enabled --project="$GCP_PROJECT" \
    --filter='config.name=cloudkms.googleapis.com' --format='value(config.name)')"
  report "keyring $KEY_RING ($GCP_REGION)" exists gcloud kms keyrings describe "$KEY_RING" \
    --location="$GCP_REGION" --project="$GCP_PROJECT"
  report "key $CRYPTO_KEY" exists gcloud kms keys describe "$CRYPTO_KEY" "${KEY_ARGS[@]}"
  if exists gcloud kms keys describe "$CRYPTO_KEY" "${KEY_ARGS[@]}"; then
    report "key rotation $ROTATION_PERIOD" test "$(gcloud kms keys describe "$CRYPTO_KEY" "${KEY_ARGS[@]}" \
      --format='value(rotationPeriod)')" = 7776000s
  fi
  report "service account $SA_NAME" exists gcloud iam service-accounts describe "$SA" --project="$GCP_PROJECT"
  report "role $ROLE_ID has exactly the seal permissions" test \
    "$(gcloud iam roles describe "$ROLE_ID" --project="$GCP_PROJECT" --format='value(includedPermissions)' 2>/dev/null \
      | tr ';' '\n' | LC_ALL=C sort | paste -sd, -)" = "$(tr , '\n' <<<"$ROLE_PERMISSIONS" | LC_ALL=C sort | paste -sd, -)"
  report "key binding: $SA_NAME -> $ROLE_ID" test -n "$(gcloud kms keys get-iam-policy "$CRYPTO_KEY" "${KEY_ARGS[@]}" \
    --flatten='bindings[].members' --filter="bindings.role:${ROLE_ID} AND bindings.members:${SA}" \
    --format='value(bindings.role)' 2>/dev/null)"
  report "no project-level roles for $SA_NAME" test -z "$(project_iam_roles 2>/dev/null)"
  say "user-managed SA keys: $(gcloud iam service-accounts keys list --iam-account="$SA" --project="$GCP_PROJECT" \
    --managed-by=user --format='value(name.basename(),validAfterTime.date("%Y-%m-%d"))' 2>/dev/null | paste -sd' ' - || true)"
  return $ok
}

apply() {
  if ! exists gcloud projects describe "$GCP_PROJECT"; then
    [[ -n "$GCP_BILLING_ACCOUNT" ]] || die "set GCP_BILLING_ACCOUNT to create the project"
    say "creating project $GCP_PROJECT"
    gcloud projects create "$GCP_PROJECT" --name="Homelab Vault"
  fi
  if [[ "$(gcloud billing projects describe "$GCP_PROJECT" --format='value(billingEnabled)')" != True ]]; then
    [[ -n "$GCP_BILLING_ACCOUNT" ]] || die "set GCP_BILLING_ACCOUNT to link billing"
    say "linking billing"
    gcloud billing projects link "$GCP_PROJECT" --billing-account="$GCP_BILLING_ACCOUNT"
  fi
  gcloud services enable cloudkms.googleapis.com iam.googleapis.com --project="$GCP_PROJECT"

  if ! exists gcloud kms keyrings describe "$KEY_RING" --location="$GCP_REGION" --project="$GCP_PROJECT"; then
    say "creating keyring $KEY_RING"
    gcloud kms keyrings create "$KEY_RING" --location="$GCP_REGION" --project="$GCP_PROJECT"
  fi
  # Rotation adds versions; OpenBao keeps decrypting with older ones. Never disable or
  # destroy a version: the one that wrapped the root key is the only way back in.
  if ! exists gcloud kms keys describe "$CRYPTO_KEY" "${KEY_ARGS[@]}"; then
    say "creating key $CRYPTO_KEY"
    gcloud kms keys create "$CRYPTO_KEY" "${KEY_ARGS[@]}" --purpose=encryption \
      --protection-level=software --rotation-period="$ROTATION_PERIOD" --next-rotation-time="$(next_rotation)"
  fi

  if ! exists gcloud iam service-accounts describe "$SA" --project="$GCP_PROJECT"; then
    say "creating service account $SA_NAME"
    gcloud iam service-accounts create "$SA_NAME" --display-name="OpenBao auto-unseal" --project="$GCP_PROJECT"
  fi
  if exists gcloud iam roles describe "$ROLE_ID" --project="$GCP_PROJECT"; then
    gcloud iam roles update "$ROLE_ID" --project="$GCP_PROJECT" --permissions="$ROLE_PERMISSIONS" --quiet >/dev/null
  else
    say "creating role $ROLE_ID"
    gcloud iam roles create "$ROLE_ID" --project="$GCP_PROJECT" --title="OpenBao auto-unseal" \
      --permissions="$ROLE_PERMISSIONS" >/dev/null
  fi
  # Idempotent: adding a binding that exists changes nothing. Key-level only.
  gcloud kms keys add-iam-policy-binding "$CRYPTO_KEY" "${KEY_ARGS[@]}" \
    --member="serviceAccount:${SA}" --role="$ROLE" >/dev/null

  [[ -z "$(project_iam_roles)" ]] || die "$SA_NAME has project-level roles: $(project_iam_roles | paste -sd' ' -)"
  check
}

# Writes a new private key to stdout and nowhere else. Refuses a terminal so the key
# can't land on screen; capture it in a variable and pipe it into pass (README).
key() {
  [[ ! -t 1 ]] || die "stdout is a terminal; capture the key, e.g. KEY=\$(gcp/vault-kms.sh key)"
  exists gcloud iam service-accounts describe "$SA" --project="$GCP_PROJECT" || die "run apply first"
  # gcloud checks the output path before creating the key, so a bad path leaves no key.
  gcloud iam service-accounts keys create /dev/stdout --iam-account="$SA" --project="$GCP_PROJECT"
}

case "${1:-}" in
  check) check ;;
  apply) apply ;;
  key) key ;;
  *) die "usage: $0 check|apply|key" ;;
esac

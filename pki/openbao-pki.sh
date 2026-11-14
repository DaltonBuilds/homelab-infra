#!/usr/bin/env bash
# HOMELAB-54: the OpenBao intermediate CA, its issuance roles and PKI hygiene (Phase 0.7c).
#
#   pki/openbao-pki.sh apply   mount pki_int, have the root sign its CSR, name the issuers,
#                              set URLs and auto-tidy, write both roles, then run check
#   pki/openbao-pki.sh check   report what exists and test issuance from both roles
#
# Run it from a plain terminal: no session recording, no AI-assisted shell. Every bao call
# runs over SSH on the active node against its own localhost. The root token goes from pass
# into the node's token helper without being shown, and is removed from the node on exit.
# Only public material (the CSR and certificates) reaches the workstation. apply is safe to
# re-run: it reuses the mount, the intermediate key and a signed certificate that matches.
set -euo pipefail
umask 077

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OPENBAO_NODES="${OPENBAO_NODES:-192.168.40.20 192.168.40.21 192.168.40.22}"
OPENBAO_SSH_USER="${OPENBAO_SSH_USER:-dalton}"
OPENBAO_SSH="${OPENBAO_SSH:-ssh}"   # overridable for tests
OPENBAO_ROOT_TOKEN_ENTRY="${OPENBAO_ROOT_TOKEN_ENTRY:-homelab/vault/recovery-keys}"
ROOT_CA_CERT="${ROOT_CA_CERT:-$ROOT_DIR/pki/homelab-root-ca.crt}"
INT_NAME="homelab-intermediate-2026"
INT_CERT="${INT_CERT:-$ROOT_DIR/pki/$INT_NAME.crt}"
ROOT_ISSUER_NAME="homelab-root"
MOUNT="pki_int"
CLUSTER_PATH="https://vault.homelab.internal:8200/v1/$MOUNT"
LISTENER_IPS_CIDR="127.0.0.1/32,192.168.40.20/32,192.168.40.21/32,192.168.40.22/32"
LISTENER_DOMAINS="vault.homelab.internal,vault-01.homelab.internal,vault-02.homelab.internal,vault-03.homelab.internal,localhost"
SERVICE_DOMAINS="homelab.internal,svc.cluster.local,homelab-prod.homelab.internal,homelab-dev.homelab.internal,mgmt.homelab.internal"

die() { echo "error: $*" >&2; exit 1; }
say() { echo "$*" >&2; }

NODE=""
ADDR=""
LOGGED_IN=0

# Run a command on the node. Arguments are quoted for the remote shell, so values with
# spaces or {{templates}} arrive intact.
on_node() {
  # shellcheck disable=SC2029  # expanding on the client side is the point
  "$OPENBAO_SSH" "${OPENBAO_SSH_USER}@${NODE}" "$(printf '%q ' "$@")"
}
# shellcheck disable=SC2086  # ADDR holds one or two VAR=value words
bao_() { on_node env $ADDR bao "$@"; }

logout() {
  if [[ $LOGGED_IN -eq 1 ]]; then
    on_node rm -f .vault-token || say "warning: remove ~/.vault-token on $NODE by hand"
    LOGGED_IN=0
  fi
}
trap logout EXIT

# The active node (or the only node of a non-HA test server); sys/leader is unauthenticated.
find_active() {
  local n leader
  for n in $OPENBAO_NODES; do
    NODE="$n"
    # The node's listener: HTTPS once 0.7d has installed the certificate, HTTP before.
    if on_node test -f /etc/openbao/tls/listener.pem 2>/dev/null; then
      ADDR="VAULT_ADDR=https://127.0.0.1:8200 VAULT_CACERT=/etc/openbao/ca.pem"
    else
      ADDR="VAULT_ADDR=http://127.0.0.1:8200"
    fi
    leader="$(bao_ read -format=json sys/leader 2>/dev/null)" || continue
    if jq -e '.data.ha_enabled == false or .data.is_self == true' >/dev/null <<<"$leader"; then
      say "active node: $NODE ($ADDR)"
      return 0
    fi
  done
  die "no active node among $OPENBAO_NODES"
}

login() {
  pass ls "$OPENBAO_ROOT_TOKEN_ENTRY" >/dev/null 2>&1 || die "pass entry $OPENBAO_ROOT_TOKEN_ENTRY not found"
  LOGGED_IN=1
  pass show "$OPENBAO_ROOT_TOKEN_ENTRY" | jq -r '.root_token // empty' | bao_ login -no-print - >/dev/null \
    || die "bao login failed on $NODE"
}

# SHA-256 of a certificate's or CSR's public key, so keys are compared without printing them.
cert_key_id() { openssl x509 -noout -pubkey | openssl pkey -pubin -outform DER | openssl dgst -sha256 -r | cut -d' ' -f1; }
csr_key_id() { openssl req -noout -pubkey | openssl pkey -pubin -outform DER | openssl dgst -sha256 -r | cut -d' ' -f1; }
fingerprint() { openssl x509 -noout -fingerprint -sha256 | cut -d= -f2; }

ensure_mount() {
  if bao_ secrets list -format=json | jq -e --arg m "$MOUNT/" 'has($m)' >/dev/null; then
    say "ok      mount $MOUNT"
  else
    say "enabling $MOUNT"
    bao_ secrets enable -path="$MOUNT" pki >/dev/null
  fi
  # 5 years: the intermediate's lifetime caps every certificate it issues anyway.
  bao_ secrets tune -max-lease-ttl=43800h "$MOUNT" >/dev/null
}

has_default_issuer_with_key() {
  local ref
  ref="$(bao_ read -format=json "$MOUNT/config/issuers" 2>/dev/null | jq -r '.data.default // empty')"
  [[ -n "$ref" ]] || return 1
  [[ -n "$(bao_ read -format=json "$MOUNT/issuer/$ref" | jq -r '.data.key_id // empty')" ]]
}

ensure_intermediate() {
  if has_default_issuer_with_key; then
    say "ok      intermediate issuer imported"
    return 0
  fi
  local csr
  # Reuse the key if an earlier run generated it, so an aborted run leaves no orphan keys.
  # The key is generated in OpenBao and never returned.
  if bao_ read "$MOUNT/key/$INT_NAME" >/dev/null 2>&1; then
    say "reusing key $INT_NAME"
    csr="$(bao_ write -field=csr "$MOUNT/intermediate/generate/existing" \
      common_name="Homelab Intermediate CA" key_ref="$INT_NAME")"
  else
    say "generating key $INT_NAME (ECDSA P-256, inside OpenBao)"
    csr="$(bao_ write -field=csr "$MOUNT/intermediate/generate/internal" \
      common_name="Homelab Intermediate CA" key_type=ec key_bits=256 key_name="$INT_NAME")"
  fi

  if [[ -f "$INT_CERT" ]] && [[ "$(cert_key_id <"$INT_CERT")" == "$(csr_key_id <<<"$csr")" ]]; then
    say "reusing $INT_CERT (signed for this key)"
  else
    say "signing with the offline root (pki/root-ca.sh prompts)"
    # root-ca.sh reads the CSR several times, so it gets a file. A CSR is public.
    local tmp="$INT_CERT.tmp" csr_file
    csr_file="$(mktemp)"
    printf '%s\n' "$csr" >"$csr_file"
    "$ROOT_DIR/pki/root-ca.sh" sign "$csr_file" >"$tmp" || { rm -f "$tmp" "$csr_file"; die "signing failed"; }
    rm -f "$csr_file"
    mv "$tmp" "$INT_CERT"
    chmod 0644 "$INT_CERT"
    say "wrote $INT_CERT (public; commit it)"
  fi

  cat "$INT_CERT" "$ROOT_CA_CERT" | bao_ write -format=json "$MOUNT/intermediate/set-signed" certificate=- >/dev/null
  say "imported the chain"
}

# set-signed imports two issuers: the intermediate (with its key) and the root (no key).
name_issuers() {
  local id info root_fp
  root_fp="$(fingerprint <"$ROOT_CA_CERT")"
  for id in $(bao_ list -format=json "$MOUNT/issuers" | jq -r '.[]'); do
    info="$(bao_ read -format=json "$MOUNT/issuer/$id")"
    if [[ -n "$(jq -r '.data.key_id // empty' <<<"$info")" ]]; then
      [[ "$(jq -r .data.certificate <<<"$info" | cert_key_id)" == "$(cert_key_id <"$INT_CERT")" ]] \
        || die "issuer $id has a key but isn't $INT_CERT; inspect $MOUNT/issuers by hand"
      bao_ write "$MOUNT/issuer/$id" issuer_name="$INT_NAME" >/dev/null
    else
      [[ "$(jq -r .data.certificate <<<"$info" | fingerprint)" == "$root_fp" ]] \
        || die "issuer $id has no key and isn't the committed root; inspect $MOUNT/issuers by hand"
      bao_ write "$MOUNT/issuer/$id" issuer_name="$ROOT_ISSUER_NAME" >/dev/null
    fi
  done
  bao_ write "$MOUNT/config/issuers" default="$INT_NAME" >/dev/null
  say "ok      issuers named; default $INT_NAME"
}

configure() {
  # AIA/CRL/OCSP on the cluster name, templated per issuer. The name resolves from Tier 2
  # (VyOS static mapping); every consumer is given the full chain meanwhile.
  bao_ write "$MOUNT/config/cluster" path="$CLUSTER_PATH" aia_path="$CLUSTER_PATH" >/dev/null
  bao_ write "$MOUNT/config/urls" enable_templating=true \
    issuing_certificates='{{cluster_aia_path}}/issuer/{{issuer_id}}/der' \
    crl_distribution_points='{{cluster_aia_path}}/issuer/{{issuer_id}}/crl/der' \
    ocsp_servers='{{cluster_path}}/ocsp' >/dev/null
  bao_ write "$MOUNT/config/auto-tidy" enabled=true interval_duration=12h safety_buffer=72h \
    tidy_cert_store=true tidy_revoked_certs=true tidy_revoked_cert_issuer_associations=true \
    tidy_expired_issuers=true >/dev/null
  say "ok      cluster URLs, templated AIA/CRL/OCSP, auto-tidy"

  # Service certificates from Tier 2 on. no_store: under 30 days, expiry is the revocation.
  # Tier 2 splits this per consumer and excludes vault*.homelab.internal.
  bao_ write "$MOUNT/roles/internal-services" issuer_ref=default \
    key_type=ec key_bits=256 key_usage=DigitalSignature \
    allowed_domains="$SERVICE_DOMAINS" allow_subdomains=true require_cn=false \
    ttl=24h max_ttl=24h no_store=true >/dev/null
  # OpenBao's own listener: exact names and IPs only. The client flag makes the certificate
  # the node's cert-auth identity for renewal (0.7e). Stored, so it can be revoked by serial.
  bao_ write "$MOUNT/roles/openbao-listener" issuer_ref=default \
    key_type=ec key_bits=256 key_usage=DigitalSignature server_flag=true client_flag=true \
    allowed_domains="$LISTENER_DOMAINS" allow_bare_domains=true allow_subdomains=false \
    allow_glob_domains=false allow_wildcard_certificates=false allow_localhost=true \
    allow_ip_sans=true allowed_ip_sans_cidr="$LISTENER_IPS_CIDR" \
    ttl=720h max_ttl=720h no_store=false >/dev/null
  say "ok      roles internal-services, openbao-listener"
}

# Issue a test certificate and check it on the workstation. Only the certificate field
# crosses; OpenBao's response also carries the test key, which is discarded on the node.
# Prints the serial in OpenBao's form (aa:bb:...).
test_issue() {
  local role="$1" hours="$2" cert
  shift 2
  cert="$(bao_ write -field=certificate "$MOUNT/issue/$role" "$@")" || die "$role: test issuance failed"
  openssl verify -CAfile "$ROOT_CA_CERT" -untrusted "$INT_CERT" <(printf '%s\n' "$cert") >/dev/null \
    || die "$role: test certificate does not chain to the root"
  printf '%s\n' "$cert" | openssl x509 -noout -text | grep -q 'NIST CURVE: P-256' || die "$role: key is not P-256"
  # The role's TTL, within an hour: valid an hour short of it, expired an hour past it.
  if ! printf '%s\n' "$cert" | openssl x509 -noout -checkend $(((hours - 1) * 3600)) >/dev/null \
    || printf '%s\n' "$cert" | openssl x509 -noout -checkend $(((hours + 1) * 3600)) >/dev/null; then
    die "$role: test certificate does not live ${hours}h"
  fi
  say "ok      $role: chains to the root, P-256, ${hours}h, $(printf '%s\n' "$cert" | openssl x509 -noout -ext subjectAltName | tail -n +2 | sed 's/^ *//')"
  printf '%s\n' "$cert" | openssl x509 -noout -serial | cut -d= -f2 | tr 'A-F' 'a-f' | sed 's/../&:/g; s/:$//'
}

refused() {
  local what="$1"
  shift
  if bao_ write -field=serial_number "$MOUNT/issue/openbao-listener" "$@" >/dev/null 2>&1; then
    die "openbao-listener issued $what; it must refuse"
  fi
  say "ok      openbao-listener refuses $what"
}

check() {
  local serial int_fp
  [[ -f "$INT_CERT" ]] || die "$INT_CERT not found; run apply"
  int_fp="$(fingerprint <"$INT_CERT")"
  [[ "$(bao_ read -field=certificate "$MOUNT/issuer/default" | fingerprint)" == "$int_fp" ]] \
    || die "the default issuer is not $INT_CERT"
  [[ "$(bao_ read -field=issuer_name "$MOUNT/issuer/default")" == "$INT_NAME" ]] || die "default issuer is not named $INT_NAME"
  openssl verify -CAfile "$ROOT_CA_CERT" "$INT_CERT" >/dev/null || die "$INT_CERT does not chain to the root"
  ! bao_ secrets list -format=json | jq -e 'has("pki_root/")' >/dev/null || die "a pki_root mount exists; the root must stay offline"
  [[ "$(bao_ read -field=enabled "$MOUNT/config/auto-tidy")" == true ]] || die "auto-tidy is off"
  say "ok      default issuer $INT_NAME, chains to the root, auto-tidy on, no pki_root"

  serial="$(test_issue internal-services 24 common_name=test.homelab.internal)"
  ! bao_ read "$MOUNT/cert/$serial" >/dev/null 2>&1 || die "internal-services stored its certificate; no_store is off"
  say "ok      internal-services stores nothing (no_store)"
  serial="$(test_issue openbao-listener 720 common_name=vault-01.homelab.internal \
    alt_names=vault.homelab.internal,localhost ip_sans=127.0.0.1,192.168.40.20)"
  # Stored, so it can be revoked: prove it on the test certificate, which nothing uses.
  bao_ read "$MOUNT/cert/$serial" >/dev/null 2>&1 || die "openbao-listener did not store its certificate"
  bao_ write "$MOUNT/revoke" serial_number="$serial" >/dev/null
  say "ok      openbao-listener stores its certificates; revoked the test one ($serial)"
  refused "a name outside its list" common_name=evil.homelab.internal
  refused "an IP outside its list" common_name=vault-01.homelab.internal ip_sans=192.168.40.99

  say ""
  say "Record on HOMELAB-54 (all public):"
  bao_ list -format=json "$MOUNT/issuers" | jq -r '.[]' | while read -r id; do
    say "  issuer $id  $(bao_ read -field=issuer_name "$MOUNT/issuer/$id")"
  done
  openssl x509 -in "$INT_CERT" -noout -subject -issuer -serial -startdate -enddate -fingerprint -sha256 \
    -ext basicConstraints,keyUsage,nameConstraints 2>&1 | sed 's/^/  /' >&2
}

case "${1:-}" in
  apply)
    find_active; login
    ensure_mount; ensure_intermediate; name_issuers; configure
    check ;;
  check)
    find_active; login
    check ;;
  *) die "usage: $0 apply|check" ;;
esac

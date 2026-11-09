#!/usr/bin/env bash
# HOMELAB-53: the offline root CA ceremony (Phase 0.7b).
#
#   pki/root-ca.sh create          new P-384 key into pass, self-signed root into pki/
#   pki/root-ca.sh sign <csr>      sign an intermediate CSR; the certificate goes to stdout
#   pki/root-ca.sh backup          the key as passphrase-encrypted PKCS#8 on stdout (the safe copy)
#   pki/root-ca.sh check [<file>]  read-only: the root, the pass entry, and optionally a safe copy
#
# Run it in a plain terminal: no session recording, no AI-assisted shell. The key never
# enters OpenBao and never sits unencrypted in a file. It lives in a shell variable, goes
# straight into pass, and reaches openssl through a pipe. Nothing here talks to the LAN.
set -euo pipefail
umask 077

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# Overridable so the script can be exercised against a throwaway store and file.
ROOT_CA_PASS_ENTRY="${ROOT_CA_PASS_ENTRY:-homelab/pki/root-ca-key}"
ROOT_CA_CERT="${ROOT_CA_CERT:-$ROOT_DIR/pki/homelab-root-ca.crt}"
ROOT_SUBJECT="/CN=Homelab Root CA"
ROOT_DAYS=3653   # 10 years
INT_SUBJECT="subject=CN=Homelab Intermediate CA"
INT_DAYS=1826    # 5 years; repeat the ceremony around 2031
# Every certificate under the intermediate must fall inside these names. DNS only: the
# IP side is left unconstrained so node, pod and Tailscale IP SANs keep working. A DNS
# constraint covers the name and its subdomains (cluster.local covers svc.cluster.local),
# and localhost is permitted because the listener certificate carries it (0.7c).
INT_NAME_CONSTRAINTS="critical,permitted;DNS:homelab.internal,permitted;DNS:cluster.local,permitted;DNS:localhost"

die() { echo "error: $*" >&2; exit 1; }
say() { echo "$*" >&2; }

KEY=""
trap 'unset KEY' EXIT

require_openssl3() {
  # LibreSSL (macOS /usr/bin/openssl) lacks parts of what follows; use Homebrew's OpenSSL 3.
  openssl version | grep -q '^OpenSSL 3\.' || die "need OpenSSL 3.x first on PATH, found: $(openssl version)"
}

# SHA-256 of a public key (DER), so keys are compared without printing them.
# key_id reads a private key on stdin, pub_id a public one.
key_id() { openssl pkey -pubout -outform DER | openssl dgst -sha256 -r | cut -d' ' -f1; }
pub_id() { openssl pkey -pubin -outform DER | openssl dgst -sha256 -r | cut -d' ' -f1; }
root_id() { openssl x509 -in "$ROOT_CA_CERT" -noout -pubkey | pub_id; }

load_key() {
  pass ls "$ROOT_CA_PASS_ENTRY" >/dev/null 2>&1 || die "pass entry $ROOT_CA_PASS_ENTRY not found"
  [[ -f "$ROOT_CA_CERT" ]] || die "$ROOT_CA_CERT not found"
  KEY="$(pass show "$ROOT_CA_PASS_ENTRY")"
  [[ "$(printf '%s\n' "$KEY" | key_id)" == "$(root_id)" ]] \
    || die "the key in $ROOT_CA_PASS_ENTRY does not match $ROOT_CA_CERT"
}

# Public metadata only. Reads its argument once, so a pipe works too.
describe() {
  local cert
  cert="$(cat "$1")"
  printf '%s\n' "$cert" | openssl x509 -noout -subject -issuer -serial -startdate -enddate -fingerprint -sha256 >&2
  printf '%s\n' "$cert" | openssl x509 -noout -ext basicConstraints,keyUsage,nameConstraints,subjectKeyIdentifier,authorityKeyIdentifier >&2
}

root_config() {
  cat <<'EOF'
[req]
distinguished_name = dn
x509_extensions    = v3_root
string_mask        = utf8only
utf8               = yes
[dn]
[v3_root]
basicConstraints       = critical,CA:TRUE,pathlen:1
keyUsage               = critical,keyCertSign,cRLSign
subjectKeyIdentifier   = hash
authorityKeyIdentifier = keyid:always
EOF
}

# No AIA or CRL distribution point: nothing hosts the offline root's CRL. A compromised
# intermediate means a new root and new trust everywhere; the name constraints limit
# what it could sign meanwhile.
intermediate_config() {
  cat <<EOF
[v3_int]
basicConstraints       = critical,CA:TRUE,pathlen:0
keyUsage               = critical,keyCertSign,cRLSign
subjectKeyIdentifier   = hash
authorityKeyIdentifier = keyid:always
nameConstraints        = $INT_NAME_CONSTRAINTS
EOF
}

confirm() {
  [[ "${ROOT_CA_YES:-}" == 1 ]] && return 0
  local answer
  read -r -p "$1 Type yes: " answer </dev/tty
  [[ "$answer" == yes ]] || die "aborted"
}

create() {
  require_openssl3
  [[ ! -e "$ROOT_CA_CERT" ]] || die "$ROOT_CA_CERT exists; a second root would replace the trust anchor"
  ! pass ls "$ROOT_CA_PASS_ENTRY" >/dev/null 2>&1 || die "pass entry $ROOT_CA_PASS_ENTRY exists"
  # Prove the store works before there is a key to lose (the HOMELAB-32 lesson).
  echo test | pass insert -m "${ROOT_CA_PASS_ENTRY}-smoke" >/dev/null
  [[ "$(pass show "${ROOT_CA_PASS_ENTRY}-smoke")" == test ]] || die "pass smoke test failed"
  pass rm -f "${ROOT_CA_PASS_ENTRY}-smoke" >/dev/null

  KEY="$(openssl genpkey -algorithm EC -pkeyopt ec_paramgen_curve:P-384 -pkeyopt ec_param_enc:named_curve)"
  printf '%s\n' "$KEY" | pass insert -m "$ROOT_CA_PASS_ENTRY" >/dev/null
  [[ "$(pass show "$ROOT_CA_PASS_ENTRY" | key_id)" == "$(printf '%s\n' "$KEY" | key_id)" ]] \
    || die "pass entry does not hold the new key; nothing was signed, run create again after pass rm"
  say "stored the key in pass: $ROOT_CA_PASS_ENTRY"

  mkdir -p "$(dirname "$ROOT_CA_CERT")"
  openssl req -x509 -new -key <(printf '%s\n' "$KEY") -config <(root_config) \
    -subj "$ROOT_SUBJECT" -days "$ROOT_DAYS" -sha384 -set_serial "0x$(openssl rand -hex 16)" \
    -out "$ROOT_CA_CERT"
  chmod 0644 "$ROOT_CA_CERT"
  unset KEY
  say "wrote $ROOT_CA_CERT (public; commit it)"
  describe "$ROOT_CA_CERT"
  say "next: make the safe copy with backup, then confirm it with check <file>"
}

sign() {
  require_openssl3
  local csr="${1:-}"
  [[ -f "$csr" ]] || die "usage: $0 sign <csr-file>"
  [[ ! -t 1 ]] || die "stdout is a terminal; redirect it, e.g. $0 sign int.csr > int.crt"
  openssl req -in "$csr" -noout -verify 2>/dev/null || die "CSR signature does not verify"
  [[ "$(openssl req -in "$csr" -noout -subject -nameopt RFC2253)" == "$INT_SUBJECT" ]] \
    || die "CSR $(openssl req -in "$csr" -noout -subject -nameopt RFC2253), expected $INT_SUBJECT"
  openssl req -in "$csr" -noout -text | grep -q 'NIST CURVE: P-256' || die "CSR key is not ECDSA P-256"
  # The intermediate must not outlive the root.
  openssl x509 -in "$ROOT_CA_CERT" -noout -checkend $((INT_DAYS * 86400)) >/dev/null \
    || die "the root expires within $INT_DAYS days; this is the time to make a new root"

  say "CSR: $(openssl req -in "$csr" -noout -subject -nameopt RFC2253)"
  say "CSR public key sha256: $(openssl req -in "$csr" -noout -pubkey | pub_id)"
  confirm "Sign it for $INT_DAYS days, pathlen:0, name constraints $INT_NAME_CONSTRAINTS?"

  load_key
  local cert
  # CSR extensions are never copied; every extension comes from intermediate_config.
  cert="$(openssl x509 -req -in "$csr" -CA "$ROOT_CA_CERT" -CAkey <(printf '%s\n' "$KEY") \
    -extfile <(intermediate_config) -extensions v3_int -copy_extensions none \
    -days "$INT_DAYS" -sha384 -set_serial "0x$(openssl rand -hex 16)")"
  unset KEY
  openssl verify -CAfile "$ROOT_CA_CERT" <(printf '%s\n' "$cert") >/dev/null || die "the new certificate does not verify"
  printf '%s\n' "$cert"
  say "signed; record this on the ticket:"
  describe <(printf '%s\n' "$cert")
}

backup() {
  require_openssl3
  load_key
  say "Choose a passphrase for the safe copy; keep it apart from the copy itself."
  # Passphrase prompts go to the terminal; the encrypted PEM goes to stdout.
  printf '%s\n' "$KEY" | openssl pkcs8 -topk8 -v2 aes-256-cbc -v2prf hmacWithSHA512 -iter 600000
  unset KEY
}

check() {
  require_openssl3
  local copy="${1:-}"
  [[ -f "$ROOT_CA_CERT" ]] || die "$ROOT_CA_CERT not found"
  describe "$ROOT_CA_CERT"
  openssl verify -CAfile "$ROOT_CA_CERT" "$ROOT_CA_CERT" >/dev/null || die "the root does not verify against itself"
  load_key
  unset KEY
  say "ok      pass entry $ROOT_CA_PASS_ENTRY matches the root"
  if [[ -n "$copy" ]]; then
    say "Enter the safe copy's passphrase."
    [[ "$(openssl pkey -in "$copy" | key_id)" == "$(root_id)" ]] \
      || die "the safe copy does not match the root"
    say "ok      safe copy $copy matches the root"
  fi
}

case "${1:-}" in
  create) create ;;
  sign) sign "${2:-}" ;;
  backup) backup ;;
  check) check "${2:-}" ;;
  *) die "usage: $0 create|sign <csr>|backup|check [<safe-copy>]" ;;
esac

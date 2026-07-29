#!/usr/bin/env bash
# Fetch a real Polymer proof for a Solana transaction log and emit it as a 0x-hex string.
#
# Usage:
#   test/oracle/polymer/fetch_solana_proof.sh <txSignature> <programID> [srcChainId]
#
# Requires POLYMER_PROOF_API_KEY in the environment (or in ./.env).
# Prints the 0x-prefixed proof bytes to stdout (nothing else), so it can be captured:
#   PROOF_HEX=$(test/oracle/polymer/fetch_solana_proof.sh <sig> <programID>)
#
# Docs: POST https://proof.testnet.polymer.zone  (JSON-RPC, Bearer auth)
#   polymer_requestProof [{srcChainId, txSignature, programID}] -> jobID
#   polymer_queryProof   [jobID] -> {status:"complete", proof:"<base64>"}
set -euo pipefail

TX_SIG="${1:?usage: fetch_solana_proof.sh <txSignature> <programID> [srcChainId]}"
PROGRAM_ID="${2:?missing programID (Base58)}"
SRC_CHAIN_ID="${3:-2}"
ENDPOINT="${POLYMER_PROOF_ENDPOINT:-https://proof.testnet.polymer.zone}"

# Load POLYMER_PROOF_API_KEY from .env if not already exported.
if [[ -z "${POLYMER_PROOF_API_KEY:-}" && -f ".env" ]]; then
  POLYMER_PROOF_API_KEY="$(grep -E '^POLYMER_PROOF_API_KEY=' .env | head -1 | cut -d= -f2- | tr -d '"'"'"'"' )"
fi
: "${POLYMER_PROOF_API_KEY:?POLYMER_PROOF_API_KEY not set (export it or put it in ./.env)}"

log() { echo "[fetch_solana_proof] $*" >&2; }

req() {
  curl -sS --max-time 30 -X POST "$ENDPOINT" \
    -H "Authorization: Bearer ${POLYMER_PROOF_API_KEY}" \
    -H "Content-Type: application/json" \
    -d "$1"
}

log "requesting proof: srcChainId=${SRC_CHAIN_ID} tx=${TX_SIG} program=${PROGRAM_ID}"
REQ_BODY=$(printf '{"jsonrpc":"2.0","id":1,"method":"polymer_requestProof","params":[{"srcChainId":%s,"txSignature":"%s","programID":"%s"}]}' \
  "$SRC_CHAIN_ID" "$TX_SIG" "$PROGRAM_ID")
RESP=$(req "$REQ_BODY")

JOB_ID=$(printf '%s' "$RESP" | python3 -c 'import sys,json; d=json.load(sys.stdin); print(d.get("result",""))' 2>/dev/null || true)
if [[ -z "$JOB_ID" ]]; then
  log "requestProof failed / no jobID. Raw response:"; printf '%s\n' "$RESP" >&2; exit 1
fi
log "jobID=${JOB_ID}; polling polymer_queryProof ..."

QUERY_BODY=$(printf '{"jsonrpc":"2.0","id":1,"method":"polymer_queryProof","params":[%s]}' "$JOB_ID")
for i in $(seq 1 30); do
  QRESP=$(req "$QUERY_BODY")
  read -r STATUS B64 <<<"$(printf '%s' "$QRESP" | python3 -c '
import sys,json
d=json.load(sys.stdin).get("result",{})
print(d.get("status",""), d.get("proof",""))
' 2>/dev/null || echo " ")"
  log "  poll ${i}: status=${STATUS:-<none>}"
  if [[ "$STATUS" == "complete" && -n "$B64" ]]; then
    printf '%s' "$B64" | python3 -c 'import sys,base64; sys.stdout.write("0x"+base64.b64decode(sys.stdin.read()).hex())'
    echo >&2; log "done."
    exit 0
  fi
  if [[ "$STATUS" == "error" ]]; then
    log "prover returned error:"; printf '%s\n' "$QRESP" >&2; exit 1
  fi
  sleep 3
done
log "timed out waiting for proof"; exit 1

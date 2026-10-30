#!/bin/sh
# Usage: DESEC_TOKEN=... ./import.sh   (domain must already exist in the deSEC account)
set -eu
: "${DESEC_TOKEN:?set DESEC_TOKEN}"
curl -sS --fail-with-body -X PATCH \
    -H "Authorization: Token $DESEC_TOKEN" -H "Content-Type: application/json" \
    --data @"$(dirname "$0")/rrsets.json" \
    https://desec.io/api/v1/domains/example.org/rrsets/
echo

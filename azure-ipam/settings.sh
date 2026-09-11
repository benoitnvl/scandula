# shellcheck shell=bash
# Committed, non-secret settings for azure-ipam/ipam.sh. An environment variable of
# the same name overrides each one, e.g. `IPAM_DISABLE_UI=true make ipam-apps`.

# --- The pin. Change all three together, in a PR (README: "Upgrading"). ----------
# v3.6.0 is a lightweight tag on 12e41f4…; the zip digest is GitHub's own for the
# release asset.
IPAM_VERSION="${IPAM_VERSION:-v3.6.0}"
IPAM_COMMIT="${IPAM_COMMIT:-12e41f4b93a7e5f3c61a859428c32137440037b2}"
IPAM_ZIP_SHA256="${IPAM_ZIP_SHA256:-0ac8d7cb95eb7b3b13622470aff42a26bda8a3233689938ac16b042ab31c4abe}"

# --- Part 2 (infrastructure) -----------------------------------------------------
IPAM_LOCATION="${IPAM_LOCATION:-eastasia}"
IPAM_NAME_PREFIX="${IPAM_NAME_PREFIX:-scipam}"   # 1-7 lowercase letters/digits (deploy.ps1's limit)

# --- Part 1 (identities) ---------------------------------------------------------
IPAM_UI_APP_NAME="${IPAM_UI_APP_NAME:-scandula-ipam-ui}"
IPAM_ENGINE_APP_NAME="${IPAM_ENGINE_APP_NAME:-scandula-ipam-engine}"
# Where the engine gets Reader: empty = the tenant root (Microsoft's default). It
# must cover every landing-zone subscription (docs/azure-ipam-plan.md, decision 1).
IPAM_MGMT_GROUP="${IPAM_MGMT_GROUP:-}"
# true = API only: no UI app registration, so no Graph Directory.Read.All consent.
IPAM_DISABLE_UI="${IPAM_DISABLE_UI:-false}"

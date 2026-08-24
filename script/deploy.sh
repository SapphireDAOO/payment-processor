#!/usr/bin/env bash
#
# Runs script/Deploy.s.sol against a network and verifies the deployed contracts.
#
# Usage:
#   script/deploy.sh local            # anvil, no verification
#   script/deploy.sh testnet          # Base Sepolia, verified
#   script/deploy.sh mainnet          # Base mainnet, verified (prompts first)
#   script/deploy.sh testnet --dry-run  # simulate only, no broadcast
#
# Reads from .env: TEST_NET_RPC_URL, MAINNET_RPC, ETHERSCAN_API_KEY, SENDER,
# and optionally FEE_SIGNER and CREATE2_SALT (both consumed by Deploy.s.sol).

set -euo pipefail

cd "$(dirname "$0")/.."

NETWORK="${1:-}"
DRY_RUN=false
[[ "${2:-}" == "--dry-run" ]] && DRY_RUN=true

die() { echo "error: $*" >&2; exit 1; }

require() {
    local name=$1
    [[ -n "${!name:-}" ]] || die "$name is not set (add it to .env)"
}

[[ -f .env ]] && { set -a; . ./.env; set +a; }

ANVIL_KEY=0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80

case "$NETWORK" in
    local)
        RPC_URL="http://127.0.0.1:8545"
        cast block-number --rpc-url "$RPC_URL" >/dev/null 2>&1 \
            || die "no node at $RPC_URL — start one with: anvil"
        SIGNING_ARGS=(--private-key "$ANVIL_KEY")
        VERIFY_ARGS=()
        ;;
    testnet)
        require TEST_NET_RPC_URL
        require ETHERSCAN_API_KEY
        require SENDER
        RPC_URL="$TEST_NET_RPC_URL"
        SIGNING_ARGS=(--account sp-key --sender "$SENDER")
        VERIFY_ARGS=(--verify --etherscan-api-key "$ETHERSCAN_API_KEY")
        ;;
    mainnet)
        require MAINNET_RPC
        require ETHERSCAN_API_KEY
        require SENDER
        RPC_URL="$MAINNET_RPC"
        SIGNING_ARGS=(--account sp-key --sender "$SENDER")
        VERIFY_ARGS=(--verify --etherscan-api-key "$ETHERSCAN_API_KEY")
        if [[ "$DRY_RUN" == false ]]; then
            read -rp "Deploy to MAINNET as $SENDER? [y/N] " reply
            [[ "$reply" == "y" || "$reply" == "Y" ]] || die "aborted"
        fi
        ;;
    *)
        die "usage: $0 {local|testnet|mainnet} [--dry-run]"
        ;;
esac

BROADCAST_ARGS=(--broadcast)
if [[ "$DRY_RUN" == true ]]; then
    BROADCAST_ARGS=()
    VERIFY_ARGS=()
    echo "--- dry run: simulating only, nothing is broadcast ---"
fi

echo "Network:    $NETWORK"
echo "RPC:        $RPC_URL"
echo "Fee signer: ${FEE_SIGNER:-<Deploy.s.sol default>}"
echo ""

forge script script/Deploy.s.sol \
    --tc Deploy \
    --rpc-url "$RPC_URL" \
    "${SIGNING_ARGS[@]}" \
    "${BROADCAST_ARGS[@]}" \
    "${VERIFY_ARGS[@]}" \
    -vvv

[[ "$DRY_RUN" == true ]] && exit 0

CHAIN_ID=$(cast chain-id --rpc-url "$RPC_URL")
echo ""
echo "Broadcast log: broadcast/Deploy.s.sol/$CHAIN_ID/run-latest.json"

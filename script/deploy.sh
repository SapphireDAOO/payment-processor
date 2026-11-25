#!/usr/bin/env bash
#
# Runs a deploy script against a network and verifies the deployed contracts.
#
# Usage:
#   script/deploy.sh <local|testnet|mainnet> <simple|intermediated> [--dry-run]
#
#   intermediated  MultiSig, PaymentProcessorStorage, Sweeper, IntermediatedPaymentProcessor, OracleManager
#   simple         SimplePaymentProcessor, PaymentAutomation, Notes
#
# Reads from .env: TEST_NET_RPC_URL, MAINNET_RPC, ETHERSCAN_API_KEY, SENDER, and optionally
# FEE_SIGNER, CREATE2_SALT, MULTISIG, PP_STORAGE, SWEEPER, ORACLE_MANAGER and HANDOVER.
# MULTISIG, PP_STORAGE, SWEEPER and ORACLE_MANAGER reuse a deployed contract; unset ones are deployed.
# Set HANDOVER=true on the last run to transfer storage ownership to the MultiSig.

set -euo pipefail

cd "$(dirname "$0")/.."

NETWORK="${1:-}"
TARGET=""
DRY_RUN=false
for arg in "${@:2}"; do
    case "$arg" in
        --dry-run) DRY_RUN=true ;;
        *) TARGET="$arg" ;;
    esac
done

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
        SIGNER_ADDR=$(cast wallet address --private-key "$ANVIL_KEY")
        ;;
    testnet)
        require TEST_NET_RPC_URL
        require ETHERSCAN_API_KEY
        require SENDER
        RPC_URL="$TEST_NET_RPC_URL"
        SIGNING_ARGS=(--account sp-key --sender "$SENDER")
        VERIFY_ARGS=(--verify --etherscan-api-key "$ETHERSCAN_API_KEY")
        SIGNER_ADDR="$SENDER"
        ;;
    mainnet)
        require MAINNET_RPC
        require ETHERSCAN_API_KEY
        require SENDER
        RPC_URL="$MAINNET_RPC"
        SIGNING_ARGS=(--account sp-key --sender "$SENDER")
        VERIFY_ARGS=(--verify --etherscan-api-key "$ETHERSCAN_API_KEY")
        SIGNER_ADDR="$SENDER"
        if [[ "$DRY_RUN" == false ]]; then
            read -rp "Deploy $TARGET to MAINNET as $SENDER? [y/N] " reply
            [[ "$reply" == "y" || "$reply" == "Y" ]] || die "aborted"
        fi
        ;;
    *)
        die "usage: $0 {local|testnet|mainnet} {simple|intermediated} [--dry-run]"
        ;;
esac

case "$TARGET" in
    simple)        SCRIPT=script/DeploySimple.s.sol;        CONTRACT=DeploySimple ;;
    intermediated) SCRIPT=script/DeployIntermediated.s.sol; CONTRACT=DeployIntermediated ;;
    *)             die "usage: $0 {local|testnet|mainnet} {simple|intermediated} [--dry-run]" ;;
esac

[[ -n "${RPC_OVERRIDE:-}" ]] && RPC_URL="$RPC_OVERRIDE"

# forge fixes the nonce for every transaction before sending the first one, so anything still in
# flight from an earlier run lands underneath it and the whole run aborts on "nonce too low".
latest=$(cast nonce "$SIGNER_ADDR" --rpc-url "$RPC_URL")
pending=$(cast nonce "$SIGNER_ADDR" --rpc-url "$RPC_URL" --block pending)
if [[ "$latest" != "$pending" ]]; then
    die "$SIGNER_ADDR has transactions in flight ($latest confirmed, $pending pending) — wait for them to settle"
fi

FORGE_ARGS=("$SCRIPT" --tc "$CONTRACT" --rpc-url "$RPC_URL")
FORGE_ARGS+=("${SIGNING_ARGS[@]}")
FORGE_ARGS+=(--gas-estimate-multiplier "${GAS_MULTIPLIER:-130}")

if [[ "$DRY_RUN" == true ]]; then
    echo "--- dry run: simulating only, nothing is broadcast ---"
else
    FORGE_ARGS+=(--broadcast --slow)
    if [[ ${#VERIFY_ARGS[@]} -gt 0 ]]; then
        FORGE_ARGS+=("${VERIFY_ARGS[@]}")
    fi
fi

FORGE_ARGS+=(-vvv)

echo "Network:    $NETWORK"
echo "Target:     $TARGET ($SCRIPT)"
echo "RPC:        $RPC_URL"
echo "Signer:     $SIGNER_ADDR (nonce $latest, settled)"
echo "Fee signer: ${FEE_SIGNER:-<DeployConfig.s.sol default>}"
echo "Gas mult:   ${GAS_MULTIPLIER:-130}%"
echo "Salt:       ${CREATE2_SALT:-<DeployConfig.s.sol default>}"
echo "MultiSig:   ${MULTISIG:-<deploy>}"
echo "Storage:    ${PP_STORAGE:-<deploy>}"
echo "Sweeper:    ${SWEEPER:-<deploy>}"
echo "Oracle:     ${ORACLE_MANAGER:-<deploy>}"
echo "Handover:   ${HANDOVER:-false}"
echo ""

forge script "${FORGE_ARGS[@]}"

[[ "$DRY_RUN" == true ]] && exit 0

CHAIN_ID=$(cast chain-id --rpc-url "$RPC_URL")
echo ""
echo "Broadcast log: broadcast/$(basename "$SCRIPT")/$CHAIN_ID/run-latest.json"

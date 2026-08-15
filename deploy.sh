#!/usr/bin/env bash
# Automated build, push, and deploy script for LangGraph SPCS app
# Author: Sunil Khaire

set -euo pipefail

# ═══════════════════════════════════════════════════════════════
# CONFIGURATION (override via environment or .env file)
# ═══════════════════════════════════════════════════════════════

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Load .env if it exists
if [[ -f "$SCRIPT_DIR/.env" ]]; then
    echo "Loading configuration from .env"
    set -a
    source "$SCRIPT_DIR/.env"
    set +a
fi

# Required configuration
SNOWFLAKE_ORG="${SNOWFLAKE_ORG:?'Set SNOWFLAKE_ORG (e.g. myorg)'}"
SNOWFLAKE_ACCOUNT="${SNOWFLAKE_ACCOUNT:?'Set SNOWFLAKE_ACCOUNT (e.g. myaccount)'}"

# Optional with defaults
SNOWFLAKE_DATABASE="${SNOWFLAKE_DATABASE:-LANGGRAPH_DB}"
SNOWFLAKE_SCHEMA="${SNOWFLAKE_SCHEMA:-AGENTS}"
SNOWFLAKE_REPO="${SNOWFLAKE_REPO:-LANGGRAPH_REPO}"
IMAGE_NAME="${IMAGE_NAME:-langgraph-agent}"
IMAGE_TAG="${IMAGE_TAG:-v1}"
COMPUTE_POOL="${COMPUTE_POOL:-LANGGRAPH_POOL}"
SERVICE_NAME="${SERVICE_NAME:-LANGGRAPH_SERVICE}"
WAREHOUSE="${WAREHOUSE:-COMPUTE_WH}"
SNOW_CONNECTION="${SNOW_CONNECTION:-default}"
MCP_SERVER_NAME="${MCP_SERVER_NAME:-LANGGRAPH_MCP}"
AGENT_NAME="${AGENT_NAME:-MATH_AGENT}"

# Derived values. Snowflake registry hostnames use lowercase hyphens, including
# when the account identifier supplied by the CLI contains underscores.
REGISTRY_PREFIX="$(printf '%s-%s' "${SNOWFLAKE_ORG}" "${SNOWFLAKE_ACCOUNT}" | tr '[:upper:]_' '[:lower:]-')"
REGISTRY_HOST="${REGISTRY_PREFIX}.registry.snowflakecomputing.com"
REPO_URL="${REGISTRY_HOST}/${SNOWFLAKE_DATABASE}/${SNOWFLAKE_SCHEMA}/${SNOWFLAKE_REPO}"
REPO_URL="$(echo "$REPO_URL" | tr '[:upper:]' '[:lower:]')"
FULL_IMAGE="${REPO_URL}/${IMAGE_NAME}:${IMAGE_TAG}"

render_sql() {
    local input_file="$1"
    local output_file="$2"

    sed \
        -e "s|__DATABASE__|${SNOWFLAKE_DATABASE}|g" \
        -e "s|__ACCOUNT__|${SNOWFLAKE_ACCOUNT}|g" \
        -e "s|__SCHEMA__|${SNOWFLAKE_SCHEMA}|g" \
        -e "s|__REPOSITORY__|${SNOWFLAKE_REPO}|g" \
        -e "s|__COMPUTE_POOL__|${COMPUTE_POOL}|g" \
        -e "s|__SERVICE__|${SERVICE_NAME}|g" \
        -e "s|__MCP_SERVER__|${MCP_SERVER_NAME:-LANGGRAPH_MCP}|g" \
        -e "s|__AGENT__|${AGENT_NAME:-MATH_AGENT}|g" \
        -e "s|__WAREHOUSE__|${WAREHOUSE}|g" \
        -e "s|__DATABASE_LC__|$(printf '%s' "${SNOWFLAKE_DATABASE}" | tr '[:upper:]' '[:lower:]')|g" \
        -e "s|__SCHEMA_LC__|$(printf '%s' "${SNOWFLAKE_SCHEMA}" | tr '[:upper:]' '[:lower:]')|g" \
        -e "s|__REPOSITORY_LC__|$(printf '%s' "${SNOWFLAKE_REPO}" | tr '[:upper:]' '[:lower:]')|g" \
        -e "s|__IMAGE_NAME_LC__|$(printf '%s' "${IMAGE_NAME}" | tr '[:upper:]' '[:lower:]')|g" \
        -e "s|__IMAGE_TAG__|${IMAGE_TAG}|g" \
        "${input_file}" > "${output_file}"
}


# ═══════════════════════════════════════════════════════════════
# HELPER FUNCTIONS
# ═══════════════════════════════════════════════════════════════

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

info()  { echo -e "${BLUE}[INFO]${NC}  $*"; }
ok()    { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }

check_prereqs() {
    local missing=()

    if ! command -v docker &>/dev/null; then
        missing+=("docker")
    fi

    if ! command -v snow &>/dev/null; then
        missing+=("snow (Snowflake CLI)")
    fi

    if [[ ${#missing[@]} -gt 0 ]]; then
        error "Missing prerequisites: ${missing[*]}"
        echo ""
        echo "Install instructions:"
        echo "  docker: https://docs.docker.com/get-docker/"
        echo "  snow:   pip install snowflake-cli-labs"
        exit 1
    fi

    ok "Prerequisites found: docker, snow CLI"
}


# ═══════════════════════════════════════════════════════════════
# MAIN STEPS
# ═══════════════════════════════════════════════════════════════

step_build() {
    info "Building Docker image for linux/amd64..."
    info "Image: ${FULL_IMAGE}"
    echo ""

    docker build \
        --rm \
        --platform linux/amd64 \
        -t "${FULL_IMAGE}" \
        "$SCRIPT_DIR"

    ok "Docker image built: ${FULL_IMAGE}"
}

step_login() {
    info "Authenticating Docker with Snowflake image registry..."
    info "Registry: ${REGISTRY_HOST}"
    echo ""

    snow spcs image-registry login --connection "${SNOW_CONNECTION}"

    if ! docker-credential-desktop list >/dev/null 2>&1; then
        warn "Docker Desktop credential helper is unavailable; ensure Docker Desktop is running."
    fi

    ok "Docker authenticated with ${REGISTRY_HOST}"
}

step_push() {
    info "Pushing image to Snowflake repository..."
    info "Destination: ${FULL_IMAGE}"
    echo ""

    docker push "${FULL_IMAGE}"

    ok "Image pushed: ${FULL_IMAGE}"
}

step_deploy_sql() {
    info "Running Snowflake setup SQL..."
    echo ""

    local rendered_sql
    rendered_sql="$(mktemp)"
    render_sql "$SCRIPT_DIR/setup.sql" "${rendered_sql}"

    snow sql \
        --connection "${SNOW_CONNECTION}" \
        --filename "${rendered_sql}"

    rm -f "${rendered_sql}"

    ok "Snowflake objects created"
}

step_bootstrap_sql() {
    info "Creating database, schema, image repository, and compute pool..."

    local rendered_sql
    rendered_sql="$(mktemp)"
    render_sql "$SCRIPT_DIR/bootstrap.sql" "${rendered_sql}"

    snow sql \
        --connection "${SNOW_CONNECTION}" \
        --filename "${rendered_sql}"

    rm -f "${rendered_sql}"

    ok "Bootstrap objects are ready"
}

step_cleanup_sql() {
    warn "Removing the LangGraph agent, MCP server, service, compute pool, and schema..."

    local rendered_sql
    rendered_sql="$(mktemp)"
    render_sql "$SCRIPT_DIR/cleanup.sql" "${rendered_sql}"

    snow sql \
        --connection "${SNOW_CONNECTION}" \
        --filename "${rendered_sql}"

    rm -f "${rendered_sql}"

    ok "Cleanup complete"
}

step_status() {
    info "Checking service status..."
    echo ""

    snow sql \
        --connection "${SNOW_CONNECTION}" \
        --query "DESCRIBE SERVICE ${SNOWFLAKE_DATABASE}.${SNOWFLAKE_SCHEMA}.${SERVICE_NAME};"

    echo ""
    snow sql \
        --connection "${SNOW_CONNECTION}" \
        --query "SHOW SERVICE CONTAINERS IN SERVICE ${SNOWFLAKE_DATABASE}.${SNOWFLAKE_SCHEMA}.${SERVICE_NAME};"
}


# ═══════════════════════════════════════════════════════════════
# CLI INTERFACE
# ═══════════════════════════════════════════════════════════════

usage() {
    cat <<EOF
Usage: $(basename "$0") [COMMAND]

Commands:
  all       Run full pipeline: build → login → push → deploy (default)
  build     Build Docker image only
  login     Authenticate with Snowflake registry
  push      Push image to Snowflake repository
  deploy    Run setup SQL (create pool, service, MCP server, agent)
    cleanup   Run cleanup SQL (remove deployed objects; keep database/repository)
  status    Check service status
  help      Show this help message

Environment Variables (set in .env or export):
  SNOWFLAKE_ORG       (required) Your Snowflake organization name
  SNOWFLAKE_ACCOUNT   (required) Your Snowflake account name
  SNOWFLAKE_DATABASE  (default: LANGGRAPH_DB)
  SNOWFLAKE_SCHEMA    (default: AGENTS)
  SNOWFLAKE_REPO      (default: LANGGRAPH_REPO)
  IMAGE_NAME          (default: langgraph-agent)
  IMAGE_TAG           (default: v1)
  COMPUTE_POOL        (default: LANGGRAPH_POOL)
  SERVICE_NAME        (default: LANGGRAPH_SERVICE)
  WAREHOUSE           (default: COMPUTE_WH)
  SNOW_CONNECTION     (default: default) Snowflake CLI connection name
    MCP_SERVER_NAME     (default: LANGGRAPH_MCP)
    AGENT_NAME          (default: MATH_AGENT)

Example:
  export SNOWFLAKE_ORG=myorg
  export SNOWFLAKE_ACCOUNT=myaccount
  ./deploy.sh all
EOF
}

main() {
    local cmd="${1:-all}"

    echo ""
    echo "╔══════════════════════════════════════════════════════════╗"
    echo "║  LangGraph SPCS Deployment                              ║"
    echo "╚══════════════════════════════════════════════════════════╝"
    echo ""
    info "Organization: ${SNOWFLAKE_ORG:-'NOT SET'}"
    info "Account:      ${SNOWFLAKE_ACCOUNT:-'NOT SET'}"
    info "Database:     ${SNOWFLAKE_DATABASE}"
    info "Schema:       ${SNOWFLAKE_SCHEMA}"
    info "Image:        ${FULL_IMAGE}"
    echo ""

    case "$cmd" in
        all)
            check_prereqs
            step_bootstrap_sql
            echo ""
            step_build
            echo ""
            step_login
            echo ""
            step_push
            echo ""
            step_deploy_sql
            echo ""
            step_status
            echo ""
            ok "Deployment complete!"
            echo ""
            info "Your agent is now available in Snowflake Intelligence (CoWork)."
            info "You can also call it via:"
            info "  SELECT SNOWFLAKE.CORTEX.DATA_AGENT_RUN("
            info "    '${SNOWFLAKE_DATABASE}.${SNOWFLAKE_SCHEMA}.${AGENT_NAME}',"
            info "    PARSE_JSON('{\"messages\":[{\"role\":\"user\",\"content\":[{\"type\":\"text\",\"text\":\"multiply 6 and 7\"}]}]}')"
            info "  );"
            ;;
        build)
            check_prereqs
            step_build
            ;;
        login)
            check_prereqs
            step_login
            ;;
        push)
            check_prereqs
            step_push
            ;;
        deploy)
            check_prereqs
            step_deploy_sql
            ;;
        cleanup)
            check_prereqs
            step_cleanup_sql
            ;;
        status)
            check_prereqs
            step_status
            ;;
        help|--help|-h)
            usage
            ;;
        *)
            error "Unknown command: $cmd"
            usage
            exit 1
            ;;
    esac
}

main "$@"

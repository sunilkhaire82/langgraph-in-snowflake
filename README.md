# LangGraph on Snowflake (SPCS + Custom MCP Server + Cortex Agent)

Deploy a LangGraph workflow as a Custom MCP Server on Snowpark Container Services, then expose it through a Cortex Agent accessible in Snowflake Intelligence (CoWork) and via SQL.

## Architecture

```
User (CoWork / SQL)
    │
    ▼
Cortex Agent (MATH_AGENT)
    │  MCP Streamable HTTP
    ▼
Custom MCP Server (LANGGRAPH_MCP)
    │  routes to SPCS service
    ▼
SPCS Service (LANGGRAPH_SERVICE)
    │  FastMCP transport layer
    ▼
LangGraph Workflow
    plan ─→ validate ─→ execute ─→ respond
    │         │            │
    │    Pydantic gate   Tool fns
    ▼
Snowflake Cortex LLM (planner)
```

The Cortex Agent sees a single MCP tool (`run_langgraph_workflow`). Internally, LangGraph uses a Snowflake Cortex LLM to plan which internal tool to call, validates inputs with Pydantic, executes the tool, and returns the result.

## Prerequisites

- **Docker Desktop** (running, with support for `--platform linux/amd64`)
- **Snowflake CLI** (`snow`) installed and configured
- A Snowflake account with:
  - `ACCOUNTADMIN` or a role with `CREATE COMPUTE POOL`, `CREATE SERVICE`, `CREATE AGENT` privileges
  - `BIND SERVICE ENDPOINT ON ACCOUNT` privilege (granted to PUBLIC by default since May 2026)

## Quick Start

### 1. Configure your Snowflake CLI connection

Ensure you have a connection in `~/.snowflake/connections.toml`:

```toml
[my_connection]
account = "<your_org>-<your_account>"
user = "<your_username>"
authenticator = "externalbrowser"
role = "ACCOUNTADMIN"
warehouse = "COMPUTE_WH"
database = "LANGGRAPH_DB"
schema = "AGENTS"
```

### 2. Fill in the `.env` file

Copy the example file to `.env`, then edit it with your Snowflake details:

```bash
cp example.env .env   # then edit .env
```

`.env` is git-ignored, so your real values are never committed. The committed
`example.env` only contains placeholders.

Required values to fill in:

| Variable | Description | Example |
|----------|-------------|---------|
| `SNOWFLAKE_ORG` | Your Snowflake organization name | `myorg` |
| `SNOWFLAKE_ACCOUNT` | Your Snowflake account identifier | `xy12345` |
| `SNOW_CONNECTION` | Connection name from `connections.toml` | `my_connection` |
| `WAREHOUSE` | Warehouse for the service to use | `COMPUTE_WH` |

All other variables have sensible defaults.

### 3. Deploy

```bash
chmod +x deploy.sh
./deploy.sh all
```

This runs the full pipeline: bootstrap SQL (database, schema, repo, compute pool) -> Docker build -> registry login -> push -> deploy (service, MCP server, agent).

### 4. Wait for the endpoint to provision

After deploy, the public endpoint needs 3-5 minutes to provision an ingress URL:

```sql
SHOW ENDPOINTS IN SERVICE LANGGRAPH_DB.AGENTS.LANGGRAPH_SERVICE;
```

Wait until `ingress_url` shows an actual URL (not "Endpoints provisioning in progress...").

### 5. Test

```sql
SELECT SNOWFLAKE.CORTEX.DATA_AGENT_RUN(
  'LANGGRAPH_DB.AGENTS.MATH_AGENT',
  '{"messages":[{"role":"user","content":[{"type":"text","text":"multiply 7 and 8"}]}]}'
);
```

Or open Snowflake Intelligence (CoWork) and select **MATH_AGENT** from the agent list.

## Deploy Commands

| Command | Description |
|---------|-------------|
| `./deploy.sh all` | Full pipeline (default) |
| `./deploy.sh build` | Build Docker image only |
| `./deploy.sh login` | Authenticate with Snowflake registry |
| `./deploy.sh push` | Push image to registry |
| `./deploy.sh deploy` | Run setup SQL only |
| `./deploy.sh status` | Check service status |
| `./deploy.sh cleanup` | Remove all deployed objects |

## Project Structure

```
.
├── .env                 # Your configuration (fill in before deploying)
├── app.py              # LangGraph workflow + FastMCP server
├── requirements.txt    # Python dependencies
├── Dockerfile          # Multi-stage build for linux/amd64
├── deploy.sh           # One-command build/push/deploy script
├── bootstrap.sql       # Creates database, schema, repo, compute pool
├── setup.sql           # Creates service, MCP server, agent
├── cleanup.sql         # Tears down all objects
├── docs/
│   └── architecture.html  # Visual architecture diagram
└── README.md           # This file
```

## How It Works

### MCP Transport Layer

Snowflake Custom MCP Servers require the [MCP Streamable HTTP transport](https://spec.modelcontextprotocol.io/specification/basic/transports/#streamable-http). This project uses the [`fastmcp`](https://gofastmcp.com) Python SDK which implements this transport automatically.

### LangGraph Workflow

Each tool call flows through a 4-node graph:

1. **Plan** - Uses Snowflake Cortex LLM (`ChatSnowflake`) to decide which internal tool to invoke and extract arguments
2. **Validate** - Pydantic schema validation gate; the pipeline cannot proceed without passing
3. **Execute** - Calls the selected tool function
4. **Respond** - Formats and returns the result

### Available Internal Tools

| Tool | Description |
|------|-------------|
| `multiply` | Multiply two numbers |
| `add` | Add two numbers |
| `subtract` | Subtract b from a |
| `divide` | Divide a by b |
| `get_snowflake_info` | Return current database, warehouse, and timestamp |

## Security & Access Control

The SPCS endpoint is set to `public: true`, which means Snowflake provisions an ingress URL. This does **not** expose it to the public internet — all requests require Snowflake authentication.

Access is controlled at three layers:

| Layer | Object | Grant |
|-------|--------|-------|
| Agent | `MATH_AGENT` | `GRANT USAGE ON AGENT ... TO ROLE <role>` |
| MCP Server | `LANGGRAPH_MCP` | `GRANT USAGE ON CUSTOM MCP SERVER ... TO ROLE <role>` |
| SPCS Endpoint | Service role | `GRANT SERVICE ROLE ...!ALL_ENDPOINTS_USAGE TO ROLE <role>` |

By default, `setup.sql` grants access to `SYSADMIN`. Edit lines 74-75 in `setup.sql` to change the role.

## Troubleshooting

### Check service status
```sql
SELECT SYSTEM$GET_SERVICE_STATUS('LANGGRAPH_DB.AGENTS.LANGGRAPH_SERVICE');
```

### Check container logs
```sql
SELECT SYSTEM$GET_SERVICE_LOGS('LANGGRAPH_DB.AGENTS.LANGGRAPH_SERVICE', '0', 'langgraph', 100);
```

### Agent says "no tools available"
- Endpoint may still be provisioning (wait 3-5 minutes after deploy)
- Check grants: `SHOW GRANTS ON CUSTOM MCP SERVER LANGGRAPH_DB.AGENTS.LANGGRAPH_MCP;`
- Check service role: `SHOW GRANTS ON SERVICE LANGGRAPH_DB.AGENTS.LANGGRAPH_SERVICE;`

### Image pull failures
- Ensure Docker is logged in: `./deploy.sh login`
- Ensure the image was built for `linux/amd64` (required by SPCS)
- Use `--no-cache` if layers are stale: `docker build --no-cache --platform linux/amd64 -t <image> .`

### "Planner unavailable" errors
- The service needs `SNOWFLAKE_WAREHOUSE` set in the container env (check `setup.sql`)
- The `langchain-snowflake` package must be compatible with your Cortex model

## Cleanup

```bash
./deploy.sh cleanup
```

This drops the agent, MCP server, service, compute pool, image repository, and schema. The database is intentionally preserved (uncomment in `cleanup.sql` to remove it too).


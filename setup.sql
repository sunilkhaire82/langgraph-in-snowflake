-- Snowflake setup for LangGraph SPCS deployment
-- Author: Sunil Khaire

-- ═══════════════════════════════════════════════════════════════
-- CONFIGURATION: Values are rendered by deploy.sh from .env or exported
-- environment variables. Run bootstrap.sql before pushing the image.
-- ═══════════════════════════════════════════════════════════════

SET db_name      = '__DATABASE__';
SET schema_name  = '__SCHEMA__';
SET repo_name    = '__REPOSITORY__';
SET pool_name    = '__COMPUTE_POOL__';
SET service_name = '__SERVICE__';
SET mcp_name     = '__MCP_SERVER__';
SET agent_name   = '__AGENT__';
SET warehouse    = '__WAREHOUSE__';


-- ═══════════════════════════════════════════════════════════════
-- 1. DATABASE AND SCHEMA CONTEXT
-- ═══════════════════════════════════════════════════════════════

USE DATABASE IDENTIFIER($db_name);

USE SCHEMA IDENTIFIER($schema_name);
-- ═══════════════════════════════════════════════════════════════
-- 2. SERVICE
-- ═══════════════════════════════════════════════════════════════
DROP SERVICE IF EXISTS IDENTIFIER($service_name);
CREATE SERVICE IF NOT EXISTS IDENTIFIER($service_name)
  IN COMPUTE POOL IDENTIFIER($pool_name)
  FROM SPECIFICATION $$
  spec:
    containers:
      - name: langgraph
        image: /__DATABASE_LC__/__SCHEMA_LC__/__REPOSITORY_LC__/__IMAGE_NAME_LC__:__IMAGE_TAG__
        env:
          SNOWFLAKE_ACCOUNT: "__ACCOUNT__"
          SNOWFLAKE_DATABASE: "__DATABASE__"
          SNOWFLAKE_SCHEMA: "__SCHEMA__"
          SNOWFLAKE_WAREHOUSE: "__WAREHOUSE__"
        resources:
          requests:
            cpu: 2
            memory: 4Gi
        readinessProbe:
          port: 8081
          path: /health
    endpoints:
      - name: mcp-endpoint
        port: 8080
        public: true
  $$
  QUERY_WAREHOUSE = IDENTIFIER($warehouse)
  MIN_INSTANCES = 1
  MAX_INSTANCES = 1;

-- Verify service is running
DESCRIBE SERVICE IDENTIFIER($service_name);
SHOW SERVICE CONTAINERS IN SERVICE IDENTIFIER($service_name);


-- ═══════════════════════════════════════════════════════════════
-- 3. CUSTOM MCP SERVER
-- ═══════════════════════════════════════════════════════════════

CREATE CUSTOM MCP SERVER IF NOT EXISTS IDENTIFIER($mcp_name)
  SERVICE = __SERVICE__
  ENDPOINT = 'mcp-endpoint'
  PATH = '/mcp';

-- Grant access so the agent (and users) can discover and call MCP tools
-- Change SYSADMIN to your desired role
GRANT USAGE ON CUSTOM MCP SERVER IDENTIFIER($mcp_name) TO ROLE SYSADMIN;
GRANT SERVICE ROLE __SERVICE__!ALL_ENDPOINTS_USAGE TO ROLE SYSADMIN;


-- ═══════════════════════════════════════════════════════════════
-- 4. CORTEX AGENT (visible in CoWork / Snowflake Intelligence)
-- ═══════════════════════════════════════════════════════════════

CREATE OR REPLACE AGENT IDENTIFIER($agent_name)
  COMMENT = 'Workflow agent whose planning and tool execution are controlled by LangGraph'
  FROM SPECIFICATION $$
  models:
    orchestration: auto

  instructions:
    response: |
      You are a front end for the LangGraph workflow.
      ALWAYS call run_langgraph_workflow for every user request.
      Do not perform calculations, choose internal tools, or invent results yourself.
      Present the workflow result clearly to the user.
    sample_questions:
      - question: "Multiply 7 and 8"
      - question: "What database am I connected to?"
      - question: "Add 100 and 250"

  mcp_servers:
    - server_spec:
        name: "__DATABASE__.__SCHEMA__.__MCP_SERVER__"
  $$;

-- Grant access to users
GRANT USAGE ON AGENT IDENTIFIER($agent_name) TO ROLE PUBLIC;

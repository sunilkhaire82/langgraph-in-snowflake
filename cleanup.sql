-- Remove LangGraph SPCS deployment objects.
-- Values are rendered by deploy.sh from .env or exported environment variables.
-- This does not delete the database or image repository.

SET db_name      = '__DATABASE__';
SET schema_name  = '__SCHEMA__';
SET repo_name    = '__REPOSITORY__';
SET pool_name    = '__COMPUTE_POOL__';
SET service_name = '__SERVICE__';
SET mcp_name     = '__MCP_SERVER__';
SET agent_name   = '__AGENT__';

USE DATABASE IDENTIFIER($db_name);
USE SCHEMA IDENTIFIER($schema_name);

DROP AGENT IF EXISTS IDENTIFIER($agent_name);
DROP CUSTOM MCP SERVER IF EXISTS IDENTIFIER($mcp_name);
DROP SERVICE IF EXISTS IDENTIFIER($service_name);
DROP COMPUTE POOL IF EXISTS IDENTIFIER($pool_name);
DROP IMAGE REPOSITORY IF EXISTS IDENTIFIER($repo_name);
DROP SCHEMA IF EXISTS IDENTIFIER($schema_name);

-- Highly destructive and intentionally disabled by default:
-- DROP DATABASE IF EXISTS IDENTIFIER($db_name);
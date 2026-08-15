"""LangGraph MCP server with math tools and Snowflake SQL, deployed on SPCS.
Uses FastMCP SDK for transport + LangGraph for internal workflow orchestration.
"""

__author__ = "Sunil Khaire"
__version__ = "1.0.0"
__status__ = "Development"

import json
import os
import threading
from typing import Annotated, Literal, TypedDict
from http.server import HTTPServer, BaseHTTPRequestHandler

from pydantic import BaseModel, Field
from langgraph.graph import StateGraph, END
from langgraph.graph.message import add_messages
from langchain_core.messages import HumanMessage, AIMessage, ToolMessage
from langchain_snowflake import ChatSnowflake

import snowflake.connector
from fastmcp import FastMCP

os.environ.setdefault("FASTMCP_PORT", "8080")
os.environ.setdefault("FASTMCP_HOST", "0.0.0.0")

mcp = FastMCP("langgraph-math-agent")
_planner = None


# ═══════════════════════════════════════════════════════════════
# PYDANTIC SCHEMAS FOR TOOL INPUTS
# ═══════════════════════════════════════════════════════════════

class MathInput(BaseModel):
    a: float = Field(..., description="First number")
    b: float = Field(..., description="Second number")


class EmptyInput(BaseModel):
    pass


class RouteDecision(BaseModel):
    """Structured route selected by the LLM planner."""

    tool_name: Literal[
        "multiply",
        "add",
        "divide",
        "subtract",
        "get_snowflake_info",
    ] | None = Field(
        description="Approved internal tool, or null for an unsupported request"
    )
    a: float | None = Field(default=None, description="First numeric argument")
    b: float | None = Field(default=None, description="Second numeric argument")
    explanation: str = Field(description="One short sentence describing the route")


# ═══════════════════════════════════════════════════════════════
# TOOL IMPLEMENTATIONS
# ═══════════════════════════════════════════════════════════════

def _multiply(a: float, b: float) -> float:
    return a * b

def _add(a: float, b: float) -> float:
    return a + b

def _divide(a: float, b: float) -> float:
    if b == 0:
        raise ValueError("Cannot divide by zero")
    return a / b

def _subtract(a: float, b: float) -> float:
    return a - b

def _get_snowflake_info() -> dict:
    token = open("/snowflake/session/token").read().strip()
    conn = snowflake.connector.connect(
        host=os.environ["SNOWFLAKE_HOST"],
        account=os.environ["SNOWFLAKE_ACCOUNT"],
        token=token,
        authenticator="oauth",
        database=os.environ.get("SNOWFLAKE_DATABASE", ""),
        schema=os.environ.get("SNOWFLAKE_SCHEMA", ""),
    )
    try:
        cur = conn.cursor()
        cur.execute(
            "SELECT  CURRENT_DATABASE(), CURRENT_WAREHOUSE(), CURRENT_TIMESTAMP()"
        )
        row = cur.fetchone()
        return {
            "database": row[0],
            "warehouse": row[1],
            "current_timestamp": str(row[2]),
        }
    finally:
        conn.close()


TOOL_REGISTRY = {
    "multiply": {"fn": _multiply, "schema": MathInput},
    "add": {"fn": _add, "schema": MathInput},
    "divide": {"fn": _divide, "schema": MathInput},
    "subtract": {"fn": _subtract, "schema": MathInput},
    "get_snowflake_info": {"fn": _get_snowflake_info, "schema": EmptyInput},
}


# ═══════════════════════════════════════════════════════════════
# LANGGRAPH STATE AND NODES
# ═══════════════════════════════════════════════════════════════

class AgentState(TypedDict):
    messages: Annotated[list, add_messages]
    request: str
    tool_calls_made: list[str]
    final_result: str | None
    _pending_calls: list[dict]
    _validated_calls: list[dict]
    _validation_passed: bool
    _results: list[dict]
    _planning_error: str | None


def _get_planner() -> ChatSnowflake:
    """Create the Snowflake-backed planner only when a request needs it."""
    global _planner
    if _planner is None:
        from snowflake.snowpark import Session

        token_path = "/snowflake/session/token"
        if not os.path.exists(token_path):
            raise RuntimeError("Snowflake session token is unavailable")

        with open(token_path) as token_file:
            token = token_file.read().strip()

        session_config = {
            "account": os.environ["SNOWFLAKE_ACCOUNT"],
            "token": token,
            "authenticator": "oauth",
            "database": os.environ.get("SNOWFLAKE_DATABASE", ""),
            "schema": os.environ.get("SNOWFLAKE_SCHEMA", ""),
            "warehouse": os.environ.get("SNOWFLAKE_WAREHOUSE", ""),
        }
        if os.environ.get("SNOWFLAKE_HOST"):
            session_config["host"] = os.environ["SNOWFLAKE_HOST"]

        session = Session.builder.configs(session_config).create()

        _planner = ChatSnowflake(
            model=os.getenv("CORTEX_MODEL", "claude-4-sonnet"),
            session=session,
            temperature=0,
            max_tokens=500,
        )
    return _planner


def plan_node(state: AgentState) -> dict:
    """Use Snowflake Cortex to select an approved internal tool."""
    request = state["request"].strip()
    planning_error = None

    try:
        planner = _get_planner().with_structured_output(RouteDecision)
        from langchain_core.messages import SystemMessage

        decision = planner.invoke([
            SystemMessage(content=(
                "Route the request to exactly one approved internal tool. "
                "Use multiply for row/column, length/width, or total-items questions. "
                "Use add, subtract, or divide for arithmetic. "
                "Use get_snowflake_info for Snowflake metadata. "
                "Return tool_name=null for unsupported requests. "
                "Do not calculate the answer; return only the tool and numeric inputs. "
                "Keep explanation to one short sentence."
            )),
            HumanMessage(content=request),
        ])

        pending_calls = []
        if decision.tool_name:
            args = {}
            if decision.tool_name != "get_snowflake_info":
                if decision.a is None or decision.b is None:
                    raise ValueError("Planner did not provide both numeric arguments")
                args = {"a": decision.a, "b": decision.b}
            pending_calls = [{"tool": decision.tool_name, "args": args}]
        else:
            planning_error = decision.explanation
    except Exception as exc:
        pending_calls = []
        planning_error = f"Planner unavailable: {exc}"

    return {
        "messages": [AIMessage(content=f"Planning: {[tc['tool'] for tc in pending_calls]}")],
        "tool_calls_made": [tc["tool"] for tc in pending_calls],
        "_pending_calls": pending_calls,
        "_planning_error": planning_error,
    }


def validate_node(state: AgentState) -> dict:
    """Pydantic validation gate."""
    if state.get("_planning_error"):
        return {
            "messages": [AIMessage(content=state["_planning_error"])],
            "_validated_calls": [],
            "_validation_passed": False,
        }

    pending = state.get("_pending_calls", [])
    validated = []
    errors = []

    for call in pending:
        tool_name = call["tool"]
        schema_cls = TOOL_REGISTRY[tool_name]["schema"]
        try:
            validated_input = schema_cls(**call["args"])
            validated.append({"tool": tool_name, "args": validated_input.model_dump()})
        except Exception as e:
            errors.append(f"Validation failed for {tool_name}: {e}")

    if errors:
        return {
            "messages": [AIMessage(content=f"Validation errors: {errors}")],
            "_validated_calls": [],
            "_validation_passed": False,
            "_planning_error": f"Validation errors: {errors}",
        }

    return {
        "messages": [AIMessage(content="All inputs validated successfully")],
        "_validated_calls": validated,
        "_validation_passed": True,
    }


def execute_node(state: AgentState) -> dict:
    """Run validated tools."""
    validated = state.get("_validated_calls", [])
    results = []

    for call in validated:
        tool_fn = TOOL_REGISTRY[call["tool"]]["fn"]
        try:
            result = tool_fn(**call["args"])
            results.append({"tool": call["tool"], "result": result, "status": "success"})
        except Exception as e:
            results.append({"tool": call["tool"], "error": str(e), "status": "failed"})

    return {
        "messages": [ToolMessage(content=json.dumps(results), tool_call_id="batch")],
        "_results": results,
    }


def respond_node(state: AgentState) -> dict:
    """Format the final response."""
    results = state.get("_results", [])
    parts = []

    for r in results:
        if r["status"] == "success":
            parts.append(f"{r['tool']}: {json.dumps(r['result'])}")
        else:
            parts.append(f"{r['tool']}: ERROR - {r['error']}")

    final = "\n".join(parts) if parts else state.get(
        "_planning_error",
        "No tools were called.",
    )
    return {
        "final_result": final,
        "messages": [AIMessage(content=final)],
    }


def should_execute(state: AgentState) -> Literal["execute", "respond"]:
    return "execute" if state.get("_validation_passed", False) else "respond"


# Build the LangGraph
workflow = StateGraph(AgentState)
workflow.add_node("plan", plan_node)
workflow.add_node("validate", validate_node)
workflow.add_node("execute", execute_node)
workflow.add_node("respond", respond_node)

workflow.set_entry_point("plan")
workflow.add_edge("plan", "validate")
workflow.add_conditional_edges("validate", should_execute, {"execute": "execute", "respond": "respond"})
workflow.add_edge("execute", "respond")
workflow.add_edge("respond", END)

graph = workflow.compile()


# ═══════════════════════════════════════════════════════════════
# HELPER: Run a tool call through the LangGraph pipeline
# ═══════════════════════════════════════════════════════════════

def run_through_graph(request: str) -> str:
    """Route a user request through LangGraph-owned planning and execution."""
    initial_state: AgentState = {
        "messages": [HumanMessage(content=request)],
        "request": request,
        "tool_calls_made": [],
        "final_result": None,
        "_pending_calls": [],
        "_validated_calls": [],
        "_validation_passed": False,
        "_results": [],
        "_planning_error": None,
    }
    result = graph.invoke(initial_state)
    return result["final_result"]


# ═══════════════════════════════════════════════════════════════
# PUBLIC MCP ENTRY POINT (Cortex sees only this workflow tool)
# ═══════════════════════════════════════════════════════════════

@mcp.tool()
def run_langgraph_workflow(request: str) -> str:
    """Run a user request through the LangGraph-controlled workflow."""
    return run_through_graph(request)


# ═══════════════════════════════════════════════════════════════
# HEALTH CHECK (separate port for SPCS readiness probe)
# ═══════════════════════════════════════════════════════════════

class HealthHandler(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path == "/health":
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.end_headers()
            self.wfile.write(b'{"status":"ok"}')
        else:
            self.send_response(404)
            self.end_headers()

    def log_message(self, format, *args):
        pass


def start_health_server():
    server = HTTPServer(("0.0.0.0", 8081), HealthHandler)
    server.serve_forever()


# ═══════════════════════════════════════════════════════════════
# ENTRYPOINT
# ═══════════════════════════════════════════════════════════════

if __name__ == "__main__":
    health_thread = threading.Thread(target=start_health_server, daemon=True)
    health_thread.start()
    mcp.run(transport="streamable-http", host="0.0.0.0", port=8080)

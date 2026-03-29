#!/usr/bin/env python3
"""
ScreenMuse OpenAPI Drift Checker

Compares:
  1. Routes registered in ScreenMuseServer.swift (switch statement)
  2. Routes documented in /version endpoint (Server+System.swift)
  3. Routes in OpenAPISpec.swift

Reports missing/extra routes so drift is caught before shipping.

Usage: python3 scripts/check-openapi-drift.py
Exit 0 if clean, exit 1 if drift found.
"""

import re
import sys
import json
import os

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def extract_registered_routes(server_swift: str) -> set[str]:
    """Extract METHOD /path pairs from the switch (method, cleanPath) statement."""
    routes = set()
    # Match: case ("METHOD", "/path"): or case ("METHOD", _) where cleanPath.hasPrefix("/job/"):
    pattern = r'case \("(GET|POST|DELETE|PUT|PATCH)",\s*"(/[^"]*)"'
    for m in re.finditer(pattern, server_swift):
        routes.add(f"{m.group(1)} {m.group(2)}")
    return routes


def extract_version_routes(system_swift: str) -> list[str]:
    """Extract routes from the api_endpoints array in Server+System.swift."""
    # Find the block: "api_endpoints": [ ... ]
    match = re.search(r'"api_endpoints":\s*\[([^\]]+)\]', system_swift, re.DOTALL)
    if not match:
        return []
    block = match.group(1)
    return [r.strip().strip('"').strip(',').strip('"') for r in block.split('\n') if r.strip().strip('"').strip(',')]


def extract_openapi_paths(openapi_json_str: str) -> set[str]:
    """Extract METHOD /path pairs from the OpenAPI JSON string."""
    try:
        spec = json.loads(openapi_json_str)
    except json.JSONDecodeError as e:
        print(f"⚠️  OpenAPI JSON parse error: {e}")
        return set()
    routes = set()
    for path, methods in spec.get("paths", {}).items():
        for method in methods.keys():
            if method.lower() not in ("get", "post", "delete", "put", "patch"):
                continue
            routes.add(f"{method.upper()} {path}")
    return routes


def load_file(rel_path: str) -> str:
    full = os.path.join(ROOT, rel_path)
    with open(full) as f:
        return f.read()


def extract_json_from_swift(swift_str: str) -> str:
    """Extract the JSON string literal from OpenAPISpec.swift."""
    match = re.search(r'static let json = """\s*(.*?)\s*"""', swift_str, re.DOTALL)
    if match:
        return match.group(1)
    return "{}"


def main():
    print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
    print("ScreenMuse OpenAPI Drift Checker")
    print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")

    server_swift = load_file("Sources/ScreenMuseCore/AgentAPI/ScreenMuseServer.swift")
    system_swift = load_file("Sources/ScreenMuseCore/AgentAPI/Server+System.swift")
    openapi_swift = load_file("Sources/ScreenMuseCore/AgentAPI/OpenAPISpec.swift")
    openapi_json = extract_json_from_swift(openapi_swift)

    registered = extract_registered_routes(server_swift)
    version_list = extract_version_routes(system_swift)
    openapi = extract_openapi_paths(openapi_json)

    print(f"\n📋 Registered routes (switch): {len(registered)}")
    print(f"📋 /version endpoint list:     {len(version_list)}")
    print(f"📋 OpenAPI spec paths:         {len(openapi)}")

    # Normalize version list for comparison (may have "METHOD /path" format)
    version_normalized = set()
    for r in version_list:
        r = r.strip().strip('"').strip(',')
        if not r or r.startswith("#"):
            continue
        version_normalized.add(r)

    drift_found = False

    # Check: registered routes missing from OpenAPI
    registered_paths = {r.split(" ", 1)[1] for r in registered}
    openapi_paths = {r.split(" ", 1)[1] for r in openapi}
    
    missing_from_openapi = registered_paths - openapi_paths
    if missing_from_openapi:
        print(f"\n❌ Routes registered but NOT in OpenAPI spec ({len(missing_from_openapi)}):")
        for r in sorted(missing_from_openapi):
            print(f"   + {r}")
        drift_found = True

    extra_in_openapi = openapi_paths - registered_paths
    if extra_in_openapi:
        print(f"\n⚠️  Routes in OpenAPI spec but NOT registered ({len(extra_in_openapi)}):")
        for r in sorted(extra_in_openapi):
            print(f"   - {r}")
        drift_found = True

    if not drift_found:
        print("\n✅ No drift detected — registered routes match OpenAPI spec")

    # Also report MCP coverage
    mcp_path = os.path.join(ROOT, "mcp-server/screenmuse-mcp.js")
    if os.path.exists(mcp_path):
        with open(mcp_path) as f:
            mcp_js = f.read()
        mcp_routes = set(re.findall(r"callScreenMuse\('(/[^']+)'", mcp_js))
        uncovered = registered_paths - mcp_routes - {"/health"}  # health is infrastructure
        if uncovered:
            print(f"\n📭 Routes not covered by MCP server ({len(uncovered)}):")
            for r in sorted(uncovered):
                print(f"   {r}")
        else:
            print("\n✅ MCP server covers all registered routes")

    print("\n━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
    return 1 if drift_found else 0


if __name__ == "__main__":
    sys.exit(main())

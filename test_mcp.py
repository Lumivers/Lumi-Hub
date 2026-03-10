import asyncio
import logging
import os
import sys

# Add the host directory to the path so we can import LumiMCPManager
project_root = os.path.dirname(os.path.abspath(__file__))
host_dir = os.path.join(project_root, "host")
sys.path.insert(0, host_dir)

from mcp_manager import LumiMCPManager

logging.basicConfig(level=logging.INFO)

async def test_mcp():
    data_dir = os.path.join(project_root, "data")
    print(f"Initializing MCP Manager with data_dir: {data_dir}")
    
    manager = LumiMCPManager(data_dir=data_dir)
    await manager.initialize()
    
    print("\n--- Connected Servers ---")
    print(manager.sessions.keys())
    
    print("\n--- Available Tools ---")
    tools = await manager.get_all_tools()
    for t in tools:
        print(f"[{t['server_name']}] {t['tool_name']}: {t.get('description', '')[:50]}...")
        
    await manager.shutdown()

if __name__ == "__main__":
    asyncio.run(test_mcp())

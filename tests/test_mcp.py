"""Real SDK transport test; skips explicitly if dependencies are unavailable."""
import importlib.util
import os
import asyncio
import sys
import unittest
from unittest.mock import patch


@unittest.skipUnless(importlib.util.find_spec("mcp"), "MCP SDK not installed")
class MCPTests(unittest.IsolatedAsyncioTestCase):
    async def test_stdio_process_and_validation(self):
        from mcp import ClientSession, StdioServerParameters
        from mcp.client.stdio import stdio_client

        async def exercise():
            parameters = StdioServerParameters(
                command=sys.executable, args=["-m", "master_control_program.server"],
                env=dict(os.environ, MCP_X_ENABLE_WRITES="0"),
            )
            async with stdio_client(parameters) as (reader, writer):
                async with ClientSession(reader, writer) as session:
                    await session.initialize()
                    listed = await session.list_tools()
                    self.assertEqual([tool.name for tool in listed.tools], ["fetch_x_media"])
                    result = await session.call_tool("fetch_x_media", {"url": "https://localhost/secret"})
                    self.assertTrue(result.isError)
                    self.assertIn("Validation:", result.content[0].text)

        await asyncio.wait_for(exercise(), timeout=20)

    async def test_real_mcp_content_and_write_annotations(self):
        from mcp.shared.memory import create_connected_server_and_client_session
        from master_control_program.server import build_server
        from test_boundaries import png
        import base64
        image = {"type": "image", "data": base64.b64encode(png()).decode(), "mimeType": "image/png"}
        with patch.dict(os.environ, {"MCP_X_ENABLE_WRITES": "1"}), patch(
            "master_control_program.server.fetch_result", return_value={"content": [image]}
        ):
            server = build_server()
            async with create_connected_server_and_client_session(server) as session:
                tools = await session.list_tools()
                by_name = {tool.name: tool for tool in tools.tools}
                self.assertEqual(set(by_name), {"fetch_x_media", "upload_x_media", "create_x_post"})
                self.assertFalse(by_name["create_x_post"].annotations.readOnlyHint)
                self.assertFalse(by_name["create_x_post"].annotations.idempotentHint)
                result = await session.call_tool("fetch_x_media", {"url": "https://pbs.twimg.com/media/test.png"})
                self.assertFalse(result.isError)
                self.assertEqual(result.content[0].type, "image")
                self.assertEqual(base64.b64decode(result.content[0].data), png())

    async def test_read_only_default(self):
        from master_control_program.server import build_server
        with patch.dict(os.environ, {}, clear=True):
            tools = await build_server().list_tools()
            self.assertEqual([tool.name for tool in tools], ["fetch_x_media"])

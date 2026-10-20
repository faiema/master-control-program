# SPDX-License-Identifier: AGPL-3.0-only
"""Cross-language contracts through the real Python MCP client; no live network."""
import asyncio
import base64
import importlib.util
import json
import os
from pathlib import Path
import shutil
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
IMAGES = json.loads((ROOT / "tests/fixtures/images.json").read_text())
CONTRACTS = json.loads((ROOT / "tests/fixtures/contracts.json").read_text())


def png():
    return base64.b64decode(IMAGES["png"])


@unittest.skipUnless(shutil.which("racket") and importlib.util.find_spec("mcp"), "Racket and MCP SDK required")
class RacketMCPTests(unittest.IsolatedAsyncioTestCase):
    async def with_server(self, callback, *, fixture=False, writes=False, files=False, github_writes=False, readonly_launcher=False, github_state="", reject_github_requests=False, error_log=None):
        from mcp import ClientSession, StdioServerParameters
        from mcp.client.stdio import stdio_client

        async def exercise():
            parameters = StdioServerParameters(
                command="bash" if readonly_launcher else "racket",
                args=[str(ROOT / ("scripts/serve-chatgpt-readonly" if readonly_launcher else
                                  "tests/racket-stdio-fixture.rkt" if fixture else "racket/server.rkt"))],
                env=dict(os.environ, MCP_X_ENABLE_WRITES="1" if writes else "0",
                         MCP_CHATGPT_FILES="1" if files else "0",
                         MCP_GITHUB_ENABLE_WRITES="1" if github_writes else "0",
                         MCP_GITHUB_TEXT_STATE_DIR=github_state,
                         MCP_TEST_GITHUB_REJECT_REQUESTS="1" if reject_github_requests else "0",
                         MCP_CHATGPT_FILE_HOSTS="files.example.test" if files else ""),
            )
            async with stdio_client(parameters, **({"errlog": error_log} if error_log else {})) as (reader, writer):
                async with ClientSession(reader, writer) as session:
                    initialized = await session.initialize()
                    self.assertEqual(initialized.serverInfo.name, "master-control-program-racket")
                    self.assertEqual(initialized.protocolVersion, "2025-11-25")
                    await callback(session)

        await asyncio.wait_for(exercise(), timeout=20)

    async def test_production_handshake_read_only_and_validation(self):
        async def check(session):
            await session.send_ping()
            tools = (await session.list_tools()).tools
            self.assertEqual([tool.name for tool in tools], ["fetch_x_media", "fetch_github_image", "fetch_github_text"])
            self.assertTrue(tools[0].annotations.readOnlyHint)
            result = await session.call_tool("fetch_x_media", {"url": "https://localhost/secret"})
            self.assertTrue(result.isError)
            self.assertIn("Validation:", result.content[0].text)

        await self.with_server(check)

    async def test_actual_image_block_matches_python_prototype(self):
        async def check(session):
            url = "https://pbs.twimg.com/media/synthetic.png"
            result = await session.call_tool("fetch_x_media", {"url": url, "post_id": "123", "media_key": "3_456"})
            self.assertFalse(result.isError)
            self.assertEqual(json.loads(result.content[0].text), CONTRACTS["fetch_metadata"])
            self.assertEqual(result.content[1].type, "image")
            self.assertEqual(result.content[1].mimeType, "image/png")
            self.assertEqual(base64.b64decode(result.content[1].data), png())

        await self.with_server(check, fixture=True)

    async def test_mocked_write_contracts_and_annotations(self):
        async def check(session):
            tools = {tool.name: tool for tool in (await session.list_tools()).tools}
            self.assertEqual(set(tools), {"fetch_x_media", "fetch_github_image", "fetch_github_text", "upload_x_media", "create_x_post"})
            for name in ["upload_x_media", "create_x_post"]:
                self.assertFalse(tools[name].annotations.readOnlyHint)
                self.assertFalse(tools[name].annotations.idempotentHint)
                self.assertTrue(tools[name].annotations.destructiveHint)
            uploaded = await session.call_tool("upload_x_media", {"image_base64": base64.b64encode(png()).decode()})
            self.assertFalse(uploaded.isError)
            self.assertEqual(json.loads(uploaded.content[0].text), CONTRACTS["upload_result"])
            posted = await session.call_tool("create_x_post", {"text": "hello", "media_ids": ["123"], "reply_to": "456"})
            self.assertFalse(posted.isError)
            self.assertEqual(json.loads(posted.content[0].text), CONTRACTS["post_result"])

        await self.with_server(check, fixture=True, writes=True)

    async def test_chatgpt_file_handoff_and_upload(self):
        async def check(session):
            tools = {tool.name: tool for tool in (await session.list_tools()).tools}
            for name in ["inspect_chatgpt_image", "upload_x_media"]:
                descriptor = tools[name].model_dump(by_alias=True)
                self.assertEqual(descriptor["_meta"]["openai/fileParams"], ["file"])
                schema = tools[name].inputSchema["properties"]["file"]
                self.assertEqual(set(schema["required"]), {"download_url", "file_id"})
                self.assertEqual(set(schema["properties"]),
                                 {"download_url", "file_id", "mime_type", "file_name"})
            file = {"download_url": "https://files.example.test/image?signature=synthetic-secret",
                    "file_id": "synthetic-file", "mime_type": "image/png"}
            inspected = await session.call_tool("inspect_chatgpt_image", {"file": file})
            self.assertFalse(inspected.isError)
            self.assertEqual(base64.b64decode(inspected.content[1].data), png())
            self.assertNotIn("synthetic-secret", inspected.model_dump_json())
            uploaded = await session.call_tool("upload_x_media", {"file": file})
            self.assertFalse(uploaded.isError)
            self.assertEqual(json.loads(uploaded.content[0].text), CONTRACTS["upload_result"])

        await self.with_server(check, fixture=True, writes=True, files=True)

    async def test_github_image_content_and_provenance(self):
        import hashlib

        async def check(session):
            result = await session.call_tool("fetch_github_image", {
                "repository_full_name": "owner/repo", "path": "face.png", "ref": "main"})
            self.assertFalse(result.isError)
            metadata = json.loads(result.content[0].text)
            raw = png()
            expected = hashlib.sha1(f"blob {len(raw)}\0".encode() + raw).hexdigest()
            self.assertEqual(metadata["blob_sha"], expected)
            self.assertEqual(metadata["path"], "face.png")
            self.assertEqual(metadata["ref"], "main")
            self.assertEqual(result.content[1].type, "image")
            self.assertEqual(result.content[1].mimeType, "image/png")
            self.assertEqual(base64.b64decode(result.content[1].data), raw)

        await self.with_server(check, fixture=True)

    async def test_github_upload_create_replace_and_file_handoff(self):
        async def check(session):
            tools = {tool.name: tool for tool in (await session.list_tools()).tools}
            self.assertNotIn("upload_x_media", tools)
            tool = tools["upload_github_image"]
            self.assertFalse(tool.annotations.readOnlyHint)
            self.assertFalse(tool.annotations.idempotentHint)
            self.assertTrue(tool.annotations.destructiveHint)
            self.assertEqual(tool.model_dump(by_alias=True)["_meta"]["openai/fileParams"], ["file"])
            destination = dict(repository_full_name="owner/repo", path="face.png", branch="art", message="Add reference")
            sources = [dict(image_base64=IMAGES["png"]), dict(file={
                "download_url": "https://files.example.test/image?signature=synthetic-secret",
                "file_id": "synthetic-file", "mime_type": "image/png"})]
            for source in sources:
                for sha in [None, "b" * 40]:
                    result = await session.call_tool("upload_github_image", dict(destination, **source, expected_sha=sha))
                    self.assertFalse(result.isError)
                    metadata = json.loads(result.content[0].text)
                    self.assertEqual(metadata["commit_sha"], "a" * 40)
                    self.assertEqual(metadata["operation"], "replace" if sha else "create")
                    self.assertNotIn("synthetic-secret", result.model_dump_json())
            both = await session.call_tool("upload_github_image", dict(destination, **sources[0], **sources[1]))
            self.assertTrue(both.isError)

        await self.with_server(check, fixture=True, files=True, github_writes=True)

    async def test_github_text_roundtrip_and_structured_conflict(self):
        async def check(session):
            tools = {tool.name: tool for tool in (await session.list_tools()).tools}
            self.assertTrue(tools["fetch_github_text"].annotations.readOnlyHint)
            self.assertFalse(tools["upload_github_text"].annotations.readOnlyHint)
            prose = '# Faië and Maië\r\n\n“I need time,” she said.\n'
            destination = dict(repository_full_name="owner/repo", path="canon.md", branch="test",
                               message="Update character", content=prose)
            created = await session.call_tool("upload_github_text", destination)
            self.assertFalse(created.isError)
            receipt = created.structuredContent
            self.assertTrue(receipt["verified"])
            self.assertEqual(json.loads(created.content[0].text), receipt)
            fetched = await session.call_tool("fetch_github_text", dict(
                repository_full_name="owner/repo", path="canon.md", ref="test"))
            self.assertEqual(fetched.structuredContent["content"], prose)
            self.assertEqual(fetched.structuredContent["blob_sha"], receipt["blob_sha"])
            conflict = await session.call_tool("upload_github_text", destination)
            self.assertTrue(conflict.isError)
            self.assertEqual(conflict.structuredContent["category"], "SHA_CONFLICT")
            self.assertEqual(conflict.structuredContent["current_sha"], receipt["blob_sha"])
            updated = await session.call_tool("upload_github_text", dict(
                destination, content=prose + "**Trust**\n", expected_sha=receipt["blob_sha"]))
            self.assertFalse(updated.isError)
            self.assertEqual(updated.structuredContent["operation"], "replace")

        await self.with_server(check, fixture=True, github_writes=True)

    async def test_github_text_receipt_survives_server_restart(self):
        destination = dict(repository_full_name="owner/repo", path="canon.md", branch="test",
                           message="Create canon", content="Faië and Maië\n", idempotency_key="restart")
        receipts = []

        async def check(session):
            result = await session.call_tool("upload_github_text", destination)
            self.assertFalse(result.isError)
            self.assertTrue(result.structuredContent["verified"])
            receipts.append(result.structuredContent)

        with tempfile.TemporaryDirectory() as journal:
            await self.with_server(check, fixture=True, github_writes=True, github_state=journal)
            # A new Racket process has no fixture file state. It must replay the
            # on-disk receipt, without requiring GitHub lookup or another PUT.
            await self.with_server(check, fixture=True, github_writes=True, github_state=journal,
                                   reject_github_requests=True)
        self.assertEqual(receipts[0], receipts[1])

    async def test_github_upload_base64_schema_without_files(self):
        async def check(session):
            tools = {tool.name: tool for tool in (await session.list_tools()).tools}
            self.assertNotIn("file", tools["upload_github_image"].inputSchema["properties"])
            result = await session.call_tool("upload_github_image", {
                "repository_full_name": "owner/repo", "path": "face.png", "branch": "art",
                "message": "Add reference", "image_base64": IMAGES["png"]})
            self.assertFalse(result.isError)

        await self.with_server(check, fixture=True, github_writes=True)

    async def test_readonly_launcher_overrides_all_write_flags(self):
        async def check(session):
            tools = {tool.name: tool for tool in (await session.list_tools()).tools}
            self.assertNotIn("upload_github_image", tools)
            self.assertNotIn("upload_github_text", tools)
            self.assertNotIn("patch_github_text", tools)
            self.assertNotIn("upload_x_media", tools)
            self.assertNotIn("create_x_post", tools)
            self.assertIn("fetch_github_image", tools)
            git = tools["git_repository"]
            self.assertTrue(git.annotations.readOnlyHint)
            self.assertNotIn("push", git.inputSchema["properties"]["action"]["enum"])
            self.assertNotIn("commit", git.inputSchema["properties"]["action"]["enum"])

        with tempfile.TemporaryDirectory() as cache, patch.dict(os.environ, {
                "MCP_GIT_DIRECTORY": cache, "MCP_GIT_REPOSITORIES": "test.git",
                "MCP_GIT_ENABLE_WRITES": "1"}):
            await self.with_server(check, writes=True, github_writes=True, readonly_launcher=True)

    async def test_github_patch_roundtrip_diagnostics_and_restart(self):
        patch_args = {}
        receipts = []
        first_id, replay_id = "1" * 32, "2" * 32
        prose = '\ufeff# Faië and Maië\r\n日本語 🌿\n'

        async def initial(session):
            tools = {tool.name: tool for tool in (await session.list_tools()).tools}
            self.assertFalse(tools["patch_github_text"].annotations.readOnlyHint)
            self.assertIn("expected_sha", tools["patch_github_text"].inputSchema["required"])
            created = await session.call_tool("upload_github_text", dict(
                repository_full_name="owner/repo", path="canon.md", branch="test",
                message="Create fixture", content=prose))
            self.assertFalse(created.isError)
            patch_args.update(repository_full_name="owner/repo", path="canon.md", branch="test",
                              message="Patch fixture", expected_sha=created.structuredContent["blob_sha"],
                              operation="replace_exact", anchor="日本語 🌿", replacement="**Trust**",
                              idempotency_key="patch-restart")
            result = await session.call_tool("patch_github_text", dict(patch_args, request_id=first_id))
            self.assertFalse(result.isError)
            self.assertTrue(result.structuredContent["verified"])
            self.assertEqual(result.model_dump(by_alias=True)["_meta"]["request_id"], first_id)
            receipts.append(result.structuredContent)
            fetched = await session.call_tool("fetch_github_text", dict(
                repository_full_name="owner/repo", path="canon.md", ref="test"))
            self.assertEqual(fetched.structuredContent["content"], prose.replace("日本語 🌿", "**Trust**"))
            stale = await session.call_tool("patch_github_text", dict(patch_args, idempotency_key=None))
            self.assertTrue(stale.isError)
            self.assertEqual(stale.structuredContent["category"], "SHA_CONFLICT")

        async def replay(session):
            result = await session.call_tool("patch_github_text", dict(patch_args, request_id=replay_id))
            self.assertFalse(result.isError)
            receipts.append(result.structuredContent)
            self.assertEqual(result.model_dump(by_alias=True)["_meta"]["request_id"], replay_id)

        with tempfile.TemporaryDirectory() as journal, tempfile.TemporaryFile(mode="w+") as logs:
            await self.with_server(initial, fixture=True, github_writes=True, github_state=journal, error_log=logs)
            await self.with_server(replay, fixture=True, github_writes=True, github_state=journal,
                                   reject_github_requests=True, error_log=logs)
            logs.seek(0)
            logged = logs.read()
            events = [json.loads(line) for line in logged.splitlines()]
            for request_id in (first_id, replay_id):
                stages = [e["stage"] for e in events if e["request_id"] == request_id]
                self.assertEqual(stages[0], "request_received")
                self.assertEqual(stages[-1], "request_completed")
            self.assertNotIn("Faië", logged)
            self.assertNotIn("Trust", logged)
            self.assertNotIn("patch-restart", logged)
        self.assertEqual(receipts[0], receipts[1])

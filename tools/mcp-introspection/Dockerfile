# Introspection-only Native Screen MCP server, for directories that check MCP servers in a container.
# Build from the repository root: docker build -f tools/mcp-introspection/Dockerfile .
FROM node:22-alpine
WORKDIR /app
COPY macos/NativeScreen/Resources/MCPTools.json macos/NativeScreen/Resources/MCPTools.json
COPY tools/mcp-introspection/server.mjs tools/mcp-introspection/server.mjs
CMD ["node", "tools/mcp-introspection/server.mjs"]

# MCP introspection server

Native Screen's MCP server is the app itself (`Native Screen --mcp`, see the main README). It needs macOS or Windows
and a running app, so it cannot start in a Linux container. Some MCP directories only list servers that start in
Docker and answer `initialize` and `tools/list`.

`server.mjs` does just that: it serves the real tool list from `macos/NativeScreen/Resources/MCPTools.json` (the file
both apps load) and answers every tool call with an error that points to the app. No dependencies, Node 18 or later.

```bash
node tools/mcp-introspection/server.mjs
docker build -f tools/mcp-introspection/Dockerfile -t nativescreen-mcp-introspection .
```

For a directory that asks for a Dockerfile on its own and builds it from a clone, use:

```dockerfile
FROM node:22-alpine
RUN apk add --no-cache git && git clone --depth 1 https://github.com/maitrungduc1410/NativeScreen /app
WORKDIR /app
CMD ["node", "tools/mcp-introspection/server.mjs"]
```

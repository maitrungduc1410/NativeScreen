import { defineConfig } from "astro/config";

export default defineConfig({
  site: "https://nativescreen.app",
  output: "static",
  trailingSlash: "always",
  build: { format: "directory" },
  devToolbar: { enabled: false },
});

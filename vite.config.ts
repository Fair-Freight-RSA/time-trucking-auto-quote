import { readdirSync } from "node:fs";
import { resolve } from "node:path";
import { defineConfig } from "vite";

const projectRoot = __dirname;
const publicRoot = resolve(projectRoot, "public");
const publicHtmlPages = Object.fromEntries(
  readdirSync(publicRoot)
    .filter((file) => file.endsWith(".html"))
    .map((file) => [file.replace(/\.html$/, ""), resolve(publicRoot, file)])
);

export default defineConfig({
  root: publicRoot,
  envDir: projectRoot,
  publicDir: false,
  build: {
    outDir: resolve(projectRoot, "dist"),
    emptyOutDir: true,
    rollupOptions: {
      input: publicHtmlPages
    }
  },
  server: {
    fs: {
      allow: [projectRoot]
    }
  }
});

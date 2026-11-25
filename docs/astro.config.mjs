// @ts-check
import { defineConfig } from "astro/config";
import tailwindcss from "@tailwindcss/vite";
import press from "@fumapress/astro";
import process from "node:process";

export default defineConfig({
  site: process.env.DOCS_SITE_URL,
  base: process.env.DOCS_BASE_PATH ?? "/",
  // Fumadocs highlights the original code element after restoring it.
  markdown: { syntaxHighlight: false },
  integrations: [
    press({
      collections: { docs: { dir: "content" } },
      includeProcessedMarkdown: true,
      mdastPlugins: [{
        name: "preserve-code-element",
        code(node, ctx) {
          ctx.setProperty(node, "data", { ...node.data, hName: "code" });
        },
      }],
    }),
  ],
  vite: { plugins: [tailwindcss()] },
});

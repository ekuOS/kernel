import { getCollection } from "astro:content";
import { toFumadocsSource } from "@fumadocs/astro/source";
import { createPress } from "@fumapress/astro/config";
import { i18n, translations } from "./src/i18n";

export default createPress(
  toFumadocsSource(await getCollection("docs"), await getCollection("meta")),
  { i18n },
).config({
  site: { name: "ekuOS Kernel" },
  ui: {
    translations,
    layoutProps: { githubUrl: "https://github.com/ekuOS/kernel" },
    renderPage(props) {
      return props.renderDefault({
        layout: "notebook",
        layoutProps: { nav: { mode: "top" } },
      });
    },
  },
});

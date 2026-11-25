import { defineI18n } from "fumadocs-core/i18n";
import { uiTranslations } from "fumadocs-ui/i18n";

export const i18n = defineI18n({
  languages: ["en", "ja", "zh-CN"],
  defaultLanguage: "en",
  parser: "dir",
  fallbackLanguage: null,
});

export const translations = i18n.translations().extend(uiTranslations()).add({
  en: { displayName: "English" },
  ja: {
    displayName: "日本語",
    "Search(search trigger)": "検索",
    "Search(search dialog)": "検索",
    "No results found(search dialog)": "検索結果がありません",
    "Choose a language(language switcher)(aria-label)": "言語を選択",
    "On this page(table of contents)": "このページの内容",
    "Previous Page(pagination)": "前のページ",
    "Next Page(pagination)": "次のページ",
  },
  "zh-CN": {
    displayName: "简体中文",
    "Search(search trigger)": "搜索",
    "Search(search dialog)": "搜索",
    "No results found(search dialog)": "没有搜索结果",
    "Choose a language(language switcher)(aria-label)": "选择语言",
    "On this page(table of contents)": "本页内容",
    "Previous Page(pagination)": "上一页",
    "Next Page(pagination)": "下一页",
  },
});

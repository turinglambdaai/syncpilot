#!/usr/bin/env node
// Generate linux/GeneratedStrings.h from the shared/i18n single source
// (zh.json / en.json). Run from the repo root:
//   node scripts/gen-c-strings.mjs
//
// The JSON values use NAMED placeholders ({version}, {error}, ...). The
// generator records each key's placeholder names in order of first
// appearance, and l10n::t() binds them positionally from its args vector.
import { readFileSync, writeFileSync } from "node:fs";

const zh = JSON.parse(readFileSync("shared/i18n/zh.json", "utf8"));
const en = JSON.parse(readFileSync("shared/i18n/en.json", "utf8"));

const keys = Object.keys(zh);
const missingEn = keys.filter((k) => !(k in en));
if (missingEn.length > 0) {
  console.error(`en.json is missing keys: ${missingEn.join(", ")}`);
  process.exit(1);
}

const esc = (s) =>
  String(s)
    .replace(/\\/g, "\\\\")
    .replace(/"/g, '\\"')
    .replace(/\n/g, "\\n")
    .replace(/\r/g, "\\r")
    .replace(/\t/g, "\\t");

const table = (obj) =>
  Object.entries(obj)
    .map(([k, v]) => `    {"${esc(k)}", "${esc(String(v))}"},`)
    .join("\n");

const placeholderNames = (s) => {
  const names = [];
  for (const match of String(s).matchAll(/\{([a-zA-Z_][a-zA-Z0-9_]*)\}/g)) {
    if (!names.includes(match[1])) names.push(match[1]);
  }
  return names;
};

const placeholders = keys
  .map((k) => ({ key: k, names: placeholderNames(zh[k]) }))
  .filter(({ names }) => names.length > 0)
  .map(
    ({ key, names }) =>
      `    {"${esc(key)}", {${names.map((n) => `"${esc(n)}"`).join(", ")}}},`,
  )
  .join("\n");

const out = `// Generated from shared/i18n/{zh,en}.json — the single i18n source.
// Do not edit; run: node scripts/gen-c-strings.mjs
#pragma once

#include <cstddef>
#include <map>
#include <string>
#include <vector>

namespace l10n {

// Active UI language: "zh" (default) or "en".
inline std::string language = "zh";

// zh is the default language (byte-identical copy of shared/i18n/zh.json).
inline const std::map<std::string, std::string> kZh = {
${table(zh)}
};

inline const std::map<std::string, std::string> kEn = {
${table(en)}
};

// Placeholder names per key, in the order l10n::t binds its args.
inline const std::map<std::string, std::vector<std::string>> kPlaceholders = {
${placeholders}
};

// Look up a key in the active language, falling back to zh then the key
// itself. The i-th arg replaces the key's i-th named placeholder.
inline std::string t(std::string const& key,
                     std::vector<std::string> const& args = {}) {
  auto const find = [&](std::map<std::string, std::string> const& table)
      -> std::string const* {
    auto const it = table.find(key);
    return it == table.end() ? nullptr : &it->second;
  };
  std::string const* text = language == "en" ? find(kEn) : find(kZh);
  if (text == nullptr) text = find(kZh);
  std::string out = text != nullptr ? *text : key;

  auto const names = kPlaceholders.find(key);
  if (names != kPlaceholders.end()) {
    std::size_t const count =
        names->second.size() < args.size() ? names->second.size() : args.size();
    for (std::size_t i = 0; i < count; ++i) {
      std::string const placeholder = "{" + names->second[i] + "}";
      std::size_t pos = 0;
      while ((pos = out.find(placeholder, pos)) != std::string::npos) {
        out.replace(pos, placeholder.size(), args[i]);
        pos += args[i].size();
      }
    }
  }
  return out;
}

}  // namespace l10n
`;

writeFileSync("linux/GeneratedStrings.h", out);
console.log(
  `GeneratedStrings.h: ${keys.length} zh / ${Object.keys(en).length} en keys, ` +
    `${placeholders ? placeholders.split("\n").length : 0} keys with placeholders`,
);

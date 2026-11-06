import { site } from "../config/site.ts";
import en, { type Dictionary } from "./en.ts";

// Add new languages here, e.g. `sv: () => import("./sv.ts")`.
const dictionaries: Record<string, Dictionary> = { en };

export const defaultLocale = "en";

export function getDictionary(locale: string = defaultLocale): Dictionary {
  return dictionaries[locale] ?? en;
}

// Replaces {name} (and any other {key}) in a copy string.
export function t(text: string, vars: Record<string, string> = {}): string {
  const all: Record<string, string> = { name: site.name, support: site.supportEmail, ...vars };
  return text.replace(/\{(\w+)\}/g, (m, k: string) => all[k] ?? m);
}

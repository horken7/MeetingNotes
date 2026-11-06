import type { Platform } from "./site";

// All prices are placeholders. Amounts are in cents, VAT included (see `taxBehavior`).
export const currency = "eur";
export const taxBehavior = "inclusive" as const;

export type ProductId = "mac" | "windows" | "android" | "bundle";

export type Product = {
  id: ProductId;
  name: string;
  amount: number;
  platforms: Platform[];
  blurb: string;
  // Name of the env var that can hold a Stripe Price ID instead of the inline price.
  priceEnv: string;
  featured?: boolean;
};

export const products: Record<ProductId, Product> = {
  mac: {
    id: "mac",
    name: "Mac",
    amount: 2900,
    platforms: ["mac"],
    blurb: "macOS 15 or newer, Apple silicon or Intel",
    priceEnv: "STRIPE_PRICE_MAC",
  },
  windows: {
    id: "windows",
    name: "Windows",
    amount: 2900,
    platforms: ["windows"],
    blurb: "Windows 10 or 11, 64-bit",
    priceEnv: "STRIPE_PRICE_WINDOWS",
  },
  android: {
    id: "android",
    name: "Android",
    amount: 2900,
    platforms: ["android"],
    blurb: "In-person meetings, fully on the phone (Android 10+)",
    priceEnv: "STRIPE_PRICE_ANDROID",
  },
  bundle: {
    id: "bundle",
    name: "All platforms",
    amount: 5900,
    platforms: ["mac", "windows", "android"],
    blurb: "Mac, Windows and Android in one purchase",
    priceEnv: "STRIPE_PRICE_BUNDLE",
    featured: true,
  },
};

export const productOrder: ProductId[] = ["mac", "windows", "android", "bundle"];

export function isProductId(v: unknown): v is ProductId {
  return typeof v === "string" && Object.prototype.hasOwnProperty.call(products, v);
}

export function formatPrice(amount: number, locale = "en-IE"): string {
  return new Intl.NumberFormat(locale, {
    style: "currency",
    currency: currency.toUpperCase(),
    minimumFractionDigits: amount % 100 === 0 ? 0 : 2,
  }).format(amount / 100);
}

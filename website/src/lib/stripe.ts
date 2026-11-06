import "server-only";
import Stripe from "stripe";

let client: Stripe | null = null;

// Returns null when no key is configured: the site then runs in demo mode (no real checkout).
export function getStripe(): Stripe | null {
  const key = process.env.STRIPE_SECRET_KEY;
  if (!key) return null;
  client ??= new Stripe(key, { appInfo: { name: "meetingnotes-website" } });
  return client;
}

export function isTestMode(): boolean {
  return !process.env.STRIPE_SECRET_KEY?.startsWith("sk_live_");
}

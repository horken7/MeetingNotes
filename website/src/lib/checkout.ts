import type Stripe from "stripe";
import { currency, products, taxBehavior, type ProductId } from "../config/pricing.ts";
import { downloads, site } from "../config/site.ts";

type Env = Record<string, string | undefined>;

// Builds the Stripe Checkout Session for one product. Pure, so it can be tested without Stripe.
export function checkoutParams(
  productId: ProductId,
  baseUrl: string,
  env: Env,
): Stripe.Checkout.SessionCreateParams {
  const product = products[productId];
  const automaticTax = env.STRIPE_AUTOMATIC_TAX === "true";
  const priceId = env[product.priceEnv];
  const fileList = product.platforms.map((p) => downloads[p].file).join(", ");

  const lineItem: Stripe.Checkout.SessionCreateParams.LineItem = priceId
    ? { price: priceId, quantity: 1 }
    : {
        quantity: 1,
        price_data: {
          currency,
          unit_amount: product.amount,
          tax_behavior: taxBehavior,
          product_data: {
            name: `${site.name} for ${product.name}`,
            description: `One-time purchase: ready-to-install app (${fileList}), updates and setup help.`,
            metadata: { app: "meeting-notes", product: product.id },
          },
        },
      };

  return {
    mode: "payment",
    line_items: [lineItem],
    success_url: `${baseUrl}/success?session_id={CHECKOUT_SESSION_ID}`,
    cancel_url: `${baseUrl}/#pricing`,
    // "app" tags every Stripe object with the product, since the Stripe account (Frinkle AB) may sell other things too.
    metadata: { app: "meeting-notes", product: product.id, platforms: product.platforms.join(",") },
    payment_intent_data: {
      description: `${site.name} for ${product.name}`,
      // Card statements read "<account prefix>* MEETING NOTES".
      statement_descriptor_suffix: "MEETING NOTES",
      metadata: { app: "meeting-notes", product: product.id },
    },
    customer_creation: "always",
    allow_promotion_codes: true,
    // Stripe Tax: calculates VAT from the buyer's address. Needs Stripe Tax turned on in the Dashboard.
    automatic_tax: { enabled: automaticTax },
    billing_address_collection: automaticTax ? "required" : "auto",
    ...(automaticTax ? { tax_id_collection: { enabled: true } } : {}),
    custom_text: {
      submit: { message: "You will get the download links right after paying." },
    },
  };
}

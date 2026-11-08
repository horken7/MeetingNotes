import assert from "node:assert/strict";
import { test } from "node:test";
import Stripe from "stripe";
import { checkoutParams } from "../src/lib/checkout.ts";
import { isProductId, products } from "../src/config/pricing.ts";

const base = "https://example.test";

test("inline price, tax off by default", () => {
  const p = checkoutParams("mac", base, {});
  assert.equal(p.mode, "payment");
  assert.equal(p.automatic_tax?.enabled, false);
  const li = p.line_items![0];
  assert.equal(li.price_data?.unit_amount, products.mac.amount);
  assert.equal(li.price_data?.currency, "eur");
  assert.equal(li.price_data?.tax_behavior, "inclusive");
  assert.equal(p.metadata?.product, "mac");
  assert.equal(p.metadata?.app, "meeting-notes");
  assert.equal(p.payment_intent_data?.statement_descriptor_suffix, "MEETING NOTES");
  assert.equal(p.success_url, `${base}/success?session_id={CHECKOUT_SESSION_ID}`);
});

test("automatic tax and price IDs from env", () => {
  const p = checkoutParams("bundle", base, { STRIPE_AUTOMATIC_TAX: "true", STRIPE_PRICE_BUNDLE: "price_123" });
  assert.equal(p.automatic_tax?.enabled, true);
  assert.equal(p.billing_address_collection, "required");
  assert.deepEqual(p.line_items, [{ price: "price_123", quantity: 1 }]);
  assert.equal(p.metadata?.platforms, "mac,windows,android");
});

test("product ids are validated", () => {
  assert.ok(isProductId("windows"));
  assert.ok(!isProductId("iphone"));
  assert.ok(!isProductId("toString"));
});

test("webhook signature check accepts signed and rejects tampered payloads", () => {
  const stripe = new Stripe("sk_test_dummy");
  const secret = "whsec_dummy";
  const payload = JSON.stringify({ id: "evt_1", object: "event", type: "checkout.session.completed", data: { object: {} } });
  const header = stripe.webhooks.generateTestHeaderString({ payload, secret });
  assert.equal(stripe.webhooks.constructEvent(payload, header, secret).id, "evt_1");
  assert.throws(() => stripe.webhooks.constructEvent(payload + " ", header, secret));
});

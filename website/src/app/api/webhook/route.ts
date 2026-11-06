import { NextResponse, type NextRequest } from "next/server";
import type Stripe from "stripe";
import { getStripe } from "@/lib/stripe";

// Stripe calls this after a payment. The signature is verified with STRIPE_WEBHOOK_SECRET.
// Fulfilment is the download links on the success page and Stripe's own receipt email,
// so this only records the sale in the logs (Vercel > Project > Logs).
export async function POST(req: NextRequest) {
  const stripe = getStripe();
  const secret = process.env.STRIPE_WEBHOOK_SECRET;
  if (!stripe || !secret) {
    return NextResponse.json({ error: "Webhook not configured" }, { status: 503 });
  }

  const signature = req.headers.get("stripe-signature");
  if (!signature) return NextResponse.json({ error: "Missing signature" }, { status: 400 });

  let event: Stripe.Event;
  try {
    event = stripe.webhooks.constructEvent(await req.text(), signature, secret);
  } catch (err) {
    console.warn("webhook: bad signature", err instanceof Error ? err.message : err);
    return NextResponse.json({ error: "Invalid signature" }, { status: 400 });
  }

  switch (event.type) {
    case "checkout.session.completed":
    case "checkout.session.async_payment_succeeded": {
      const session = event.data.object;
      if (session.payment_status === "paid") {
        console.log(
          JSON.stringify({
            sale: session.id,
            product: session.metadata?.product,
            amount: session.amount_total,
            currency: session.currency,
            livemode: session.livemode,
          }),
        );
      }
      break;
    }
    case "charge.refunded":
      console.log(JSON.stringify({ refund: event.data.object.id }));
      break;
  }
  return NextResponse.json({ received: true });
}

import { NextResponse, type NextRequest } from "next/server";
import { isProductId } from "@/config/pricing";
import { siteUrl } from "@/config/site";
import { checkoutParams } from "@/lib/checkout";
import { getStripe } from "@/lib/stripe";

// POST from the pricing form: creates a hosted Stripe Checkout Session and redirects to it.
export async function POST(req: NextRequest) {
  const form = await req.formData();
  const product = form.get("product");
  if (!isProductId(product)) {
    return NextResponse.json({ error: "Unknown product" }, { status: 400 });
  }
  const baseUrl = siteUrl();

  const stripe = getStripe();
  if (!stripe) {
    // Demo mode: no Stripe key configured yet. Show the thank-you page with a demo banner.
    return NextResponse.redirect(`${baseUrl}/success?demo=${product}`, 303);
  }

  try {
    const session = await stripe.checkout.sessions.create(checkoutParams(product, baseUrl, process.env));
    if (!session.url) throw new Error("Stripe returned no checkout URL");
    return NextResponse.redirect(session.url, 303);
  } catch (err) {
    console.error("checkout: could not create session", err);
    return NextResponse.redirect(`${baseUrl}/?checkout=error#pricing`, 303);
  }
}

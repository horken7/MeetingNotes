import type { Metadata } from "next";
import Link from "next/link";
import { isProductId, products, type ProductId } from "@/config/pricing";
import { downloads, site } from "@/config/site";
import { getDictionary, t } from "@/content";
import { getStripe } from "@/lib/stripe";

export const metadata: Metadata = { title: "Thank you", robots: { index: false, follow: false } };
export const dynamic = "force-dynamic";

type Result =
  | { state: "paid"; product: ProductId; email: string | null; mode: "live" | "test" | "demo" }
  | { state: "unpaid" };

async function verify(params: { session_id?: string; demo?: string }): Promise<Result> {
  const stripe = getStripe();
  if (!stripe) {
    // No Stripe keys: demo mode, so the flow can be clicked through on a preview.
    return isProductId(params.demo) ? { state: "paid", product: params.demo, email: null, mode: "demo" } : { state: "unpaid" };
  }
  const id = params.session_id;
  if (!id || !/^cs_(test|live)_[A-Za-z0-9]+$/.test(id)) return { state: "unpaid" };
  try {
    const session = await stripe.checkout.sessions.retrieve(id);
    const product = session.metadata?.product;
    if (session.payment_status !== "paid" || !isProductId(product)) return { state: "unpaid" };
    return {
      state: "paid",
      product,
      email: session.customer_details?.email ?? null,
      mode: session.livemode ? "live" : "test",
    };
  } catch (err) {
    console.error("success: could not retrieve session", err instanceof Error ? err.message : err);
    return { state: "unpaid" };
  }
}

export default async function Success({ searchParams }: { searchParams: Promise<{ session_id?: string; demo?: string }> }) {
  const d = getDictionary().success;
  const result = await verify(await searchParams);

  if (result.state !== "paid") {
    return (
      <div className="mx-auto max-w-2xl px-4 py-24 text-center sm:px-6">
        <h1 className="text-3xl font-semibold tracking-tight">{d.unpaid}</h1>
        <p className="mt-4 text-zinc-600 dark:text-zinc-400">{t(d.unpaidBody)}</p>
        <Link href="/" className="mt-8 inline-block text-accent-700 underline underline-offset-4 dark:text-accent-400">{d.back}</Link>
      </div>
    );
  }

  const product = products[result.product];
  return (
    <div className="mx-auto max-w-2xl px-4 py-20 sm:px-6">
      {result.mode === "demo" && (
        <p className="mb-8 rounded-lg border border-amber-300 bg-amber-50 px-4 py-3 text-sm text-amber-900 dark:border-amber-800 dark:bg-amber-950 dark:text-amber-200">{d.demo}</p>
      )}
      {result.mode === "test" && (
        <p className="mb-8 rounded-lg border border-amber-300 bg-amber-50 px-4 py-3 text-sm text-amber-900 dark:border-amber-800 dark:bg-amber-950 dark:text-amber-200">{d.test}</p>
      )}
      <h1 className="text-4xl font-semibold tracking-tight">{d.title}</h1>
      <p className="mt-3 text-lg text-zinc-600 dark:text-zinc-400">
        {t(d.lead, { product: `${site.name} for ${product.name}` })}
      </p>

      <div className="mt-8 space-y-3">
        {product.platforms.map((p) => (
          <a
            key={p}
            href={downloads[p].url}
            className="flex items-center justify-between rounded-xl border border-zinc-200 px-5 py-4 hover:border-accent-600 hover:bg-accent-50 dark:border-zinc-800 dark:hover:border-accent-500 dark:hover:bg-accent-700/15"
          >
            <span className="font-medium">{downloads[p].label}</span>
            <span className="font-mono text-sm text-zinc-500">{downloads[p].file} ↓</span>
          </a>
        ))}
      </div>

      <p className="mt-6 text-sm text-zinc-600 dark:text-zinc-400">
        {result.email ? t(d.receipt, { email: result.email }) : d.receiptNoEmail}
      </p>

      <h2 className="mt-12 text-xl font-semibold">{d.next}</h2>
      <ol className="mt-4 list-decimal space-y-2 pl-6 text-zinc-700 dark:text-zinc-300">
        {d.steps.map((s) => (
          <li key={s}>{s}</li>
        ))}
      </ol>
      <p className="mt-8 text-sm text-zinc-600 dark:text-zinc-400">
        {t(d.help)}{" "}
        <Link href="/#faq" className="text-accent-700 underline underline-offset-4 dark:text-accent-400">FAQ</Link>
      </p>
    </div>
  );
}

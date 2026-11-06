import { Suspense } from "react";
import { formatPrice, productOrder, products } from "@/config/pricing";
import { site } from "@/config/site";
import { t } from "@/content";
import type { Dictionary } from "@/content/en";
import { CheckoutError } from "./CheckoutError";

function Check() {
  return (
    <svg viewBox="0 0 20 20" className="mt-0.5 size-4 shrink-0 text-accent-600 dark:text-accent-400" aria-hidden="true">
      <path fill="currentColor" d="M8.1 13.6 4.5 10l-1.1 1.1 4.7 4.7 9-9-1.1-1.1z" />
    </svg>
  );
}

export function Pricing({ dict }: { dict: Dictionary }) {
  const p = dict.pricing;
  return (
    <section id="pricing" className="scroll-mt-20 py-20 sm:py-28">
      <div className="mx-auto max-w-6xl px-4 sm:px-6">
        <div className="mx-auto mb-12 max-w-2xl text-center">
          <h2 className="text-3xl font-semibold tracking-tight sm:text-4xl">{p.title}</h2>
          <p className="mt-4 text-lg text-zinc-600 dark:text-zinc-400">{t(p.lead)}</p>
        </div>
        <Suspense>
          <CheckoutError message={t(p.error)} />
        </Suspense>
        <div className="grid gap-5 sm:grid-cols-2 lg:grid-cols-4">
          {productOrder.map((id) => {
            const prod = products[id];
            return (
              <form
                key={id}
                action="/api/checkout"
                method="post"
                className={`flex flex-col rounded-2xl border p-6 ${
                  prod.featured
                    ? "border-accent-600 bg-accent-50 ring-1 ring-accent-600 dark:border-accent-500 dark:bg-accent-700/15 dark:ring-accent-500"
                    : "border-zinc-200 dark:border-zinc-800"
                }`}
              >
                <input type="hidden" name="product" value={id} />
                <div className="flex items-center justify-between gap-2">
                  <h3 className="text-lg font-semibold">{prod.name}</h3>
                  {prod.featured && (
                    <span className="rounded-full bg-accent-700 px-2.5 py-0.5 text-xs font-medium text-white">{p.best}</span>
                  )}
                </div>
                <p className="mt-4">
                  <span className="text-4xl font-semibold tracking-tight">{formatPrice(prod.amount)}</span>
                  <span className="ml-1 text-sm text-zinc-500">{p.perPlatform}</span>
                </p>
                <p className="mt-3 text-sm text-zinc-600 dark:text-zinc-400">{prod.blurb}</p>
                <ul className="mt-5 mb-6 space-y-2 text-sm">
                  {p.includes.map((i) => (
                    <li key={i} className="flex gap-2"><Check />{i}</li>
                  ))}
                </ul>
                <button
                  type="submit"
                  className={`mt-auto rounded-full px-4 py-2.5 text-sm font-medium ${
                    prod.featured
                      ? "bg-accent-700 text-white hover:bg-accent-600"
                      : "bg-zinc-900 text-white hover:bg-zinc-700 dark:bg-white dark:text-zinc-900 dark:hover:bg-zinc-200"
                  }`}
                >
                  {p.buy} {prod.name}
                </button>
              </form>
            );
          })}
        </div>
        <div className="mt-5 flex flex-col gap-4 rounded-2xl border border-dashed border-zinc-300 p-6 sm:flex-row sm:items-center sm:justify-between dark:border-zinc-700">
          <div>
            <h3 className="text-lg font-semibold">{p.iphone.name}</h3>
            <p className="mt-1 text-sm text-zinc-600 dark:text-zinc-400">{p.iphone.blurb}</p>
          </div>
          <span className="shrink-0 rounded-full border border-zinc-300 px-4 py-2.5 text-center text-sm text-zinc-500 dark:border-zinc-700">
            {p.iphone.cta}
          </span>
        </div>
        <p className="mt-8 text-center text-sm text-zinc-500">{p.vatNote}</p>
        <p className="mt-2 text-center text-sm">
          <a href={site.githubUrl} className="text-accent-700 underline underline-offset-4 dark:text-accent-400">{p.openSource}</a>
        </p>
      </div>
    </section>
  );
}

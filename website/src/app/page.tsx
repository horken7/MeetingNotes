import Link from "next/link";
import { formatPrice, productOrder, products } from "@/config/pricing";
import { site, siteUrl } from "@/config/site";
import { getDictionary, t } from "@/content";
import { Pricing } from "@/components/Pricing";
import { Screenshot } from "@/components/Screenshot";

function Section({ id, title, lead, children }: { id: string; title: string; lead?: string; children: React.ReactNode }) {
  return (
    <section id={id} className="scroll-mt-20 py-20 sm:py-28">
      <div className="mx-auto max-w-6xl px-4 sm:px-6">
        <div className="mx-auto mb-12 max-w-2xl text-center">
          <h2 className="text-3xl font-semibold tracking-tight sm:text-4xl">{title}</h2>
          {lead && <p className="mt-4 text-lg text-zinc-600 dark:text-zinc-400">{lead}</p>}
        </div>
        {children}
      </div>
    </section>
  );
}

function Dot() {
  return <span className="mt-2 size-1.5 shrink-0 rounded-full bg-accent-600 dark:bg-accent-400" aria-hidden="true" />;
}

export default function Home() {
  const d = getDictionary();
  const jsonLd = {
    "@context": "https://schema.org",
    "@type": "SoftwareApplication",
    name: site.name,
    description: site.description,
    applicationCategory: "BusinessApplication",
    operatingSystem: "macOS, Windows, Android",
    url: siteUrl(),
    offers: productOrder.map((id) => ({
      "@type": "Offer",
      name: `${site.name} for ${products[id].name}`,
      price: (products[id].amount / 100).toFixed(2),
      priceCurrency: "EUR",
    })),
  };

  return (
    <>
      <script type="application/ld+json" dangerouslySetInnerHTML={{ __html: JSON.stringify(jsonLd) }} />

      {/* Hero */}
      <section className="relative overflow-hidden">
        <div
          aria-hidden="true"
          className="pointer-events-none absolute inset-x-0 -top-40 -z-10 h-[36rem] bg-[radial-gradient(ellipse_at_top,var(--color-accent-100),transparent_65%)] dark:bg-[radial-gradient(ellipse_at_top,color-mix(in_oklch,var(--color-accent-700)_35%,transparent),transparent_65%)]"
        />
        <div className="mx-auto max-w-6xl px-4 pt-16 pb-12 text-center sm:px-6 sm:pt-24">
          <p className="text-sm font-medium text-accent-700 dark:text-accent-400">{d.hero.eyebrow}</p>
          <h1 className="mx-auto mt-4 max-w-3xl text-4xl font-semibold tracking-tight text-balance sm:text-6xl">
            {d.hero.title}
          </h1>
          <p className="mx-auto mt-6 max-w-2xl text-lg text-pretty text-zinc-600 sm:text-xl dark:text-zinc-400">{t(d.hero.lead)}</p>
          <div className="mt-8 flex flex-wrap justify-center gap-3">
            <Link href="#pricing" className="rounded-full bg-accent-700 px-6 py-3 font-medium text-white hover:bg-accent-600">
              {d.hero.primary} · {formatPrice(products.mac.amount)}
            </Link>
            <Link
              href="#how"
              className="rounded-full border border-zinc-300 px-6 py-3 font-medium hover:bg-zinc-50 dark:border-zinc-700 dark:hover:bg-zinc-900"
            >
              {d.hero.secondary}
            </Link>
          </div>
          <p className="mt-4 text-sm text-zinc-500">
            <a href={site.githubUrl} className="underline underline-offset-4 hover:text-zinc-800 dark:hover:text-zinc-200">
              {d.hero.note}
            </a>
          </p>
          <div className="mx-auto mt-14 max-w-5xl overflow-hidden rounded-xl border border-zinc-200 shadow-2xl shadow-zinc-900/10 dark:border-zinc-800 dark:shadow-black/40">
            <Screenshot
              light="/images/window.png"
              dark="/images/window-dark.png"
              alt={t(d.screenshots.windowAlt)}
              width={2000}
              height={1320}
              priority
              sizes="(min-width: 1024px) 1024px, 100vw"
              className="h-auto w-full"
            />
          </div>
        </div>
      </section>

      {/* Pitch */}
      <Section id="why" title={d.pitch.title}>
        <div className="grid gap-5 sm:grid-cols-2 lg:grid-cols-4">
          {d.pitch.items.map((i) => (
            <div key={i.title} className="rounded-2xl border border-zinc-200 p-6 dark:border-zinc-800">
              <h3 className="font-semibold">
                <span className="text-zinc-400 line-through decoration-accent-600/70 decoration-2">{i.title}</span>
              </h3>
              <p className="mt-2 text-sm text-zinc-600 dark:text-zinc-400">{t(i.body)}</p>
            </div>
          ))}
        </div>
      </Section>

      {/* How it works */}
      <div className="bg-zinc-50 dark:bg-zinc-900/50">
        <Section id="how" title={d.how.title}>
          <div className="grid items-center gap-12 lg:grid-cols-2">
            <ol className="space-y-8">
              {d.how.steps.map((s, n) => (
                <li key={s.title} className="flex gap-4">
                  <span className="flex size-9 shrink-0 items-center justify-center rounded-full bg-accent-700 text-sm font-semibold text-white">
                    {n + 1}
                  </span>
                  <div>
                    <h3 className="font-semibold">{s.title}</h3>
                    <p className="mt-1 text-zinc-600 dark:text-zinc-400">{t(s.body)}</p>
                  </div>
                </li>
              ))}
            </ol>
            <figure className="mx-auto w-full max-w-md">
              <div className="overflow-hidden rounded-xl border border-zinc-200 shadow-xl shadow-zinc-900/10 dark:border-zinc-800">
                <Screenshot
                  light="/images/prompt-dark.png"
                  dark="/images/prompt-dark.png"
                  alt={t(d.screenshots.promptAlt)}
                  width={680}
                  height={268}
                  sizes="(min-width: 768px) 448px, 100vw"
                  className="h-auto w-full"
                />
              </div>
              <figcaption className="mt-3 text-center text-sm text-zinc-500">{d.screenshots.promptCaption}</figcaption>
            </figure>
          </div>
        </Section>
      </div>

      {/* Features */}
      <Section id="features" title={d.features.title}>
        <div className="grid gap-6 lg:grid-cols-2">
          {[d.features.computer, d.features.phone].map((f) => (
            <div key={f.title} className="rounded-2xl border border-zinc-200 p-8 dark:border-zinc-800">
              <p className="text-sm font-medium text-accent-700 dark:text-accent-400">{f.subtitle}</p>
              <h3 className="mt-1 text-xl font-semibold">{f.title}</h3>
              <ul className="mt-6 space-y-3">
                {f.items.map((i) => (
                  <li key={i} className="flex gap-3 text-zinc-700 dark:text-zinc-300">
                    <Dot />
                    {t(i)}
                  </li>
                ))}
              </ul>
            </div>
          ))}
        </div>
      </Section>

      {/* Privacy */}
      <div className="bg-zinc-50 dark:bg-zinc-900/50">
        <Section id="privacy" title={d.privacy.title} lead={d.privacy.lead}>
          <dl className="mx-auto max-w-3xl divide-y divide-zinc-200 rounded-2xl border border-zinc-200 bg-white dark:divide-zinc-800 dark:border-zinc-800 dark:bg-zinc-950">
            {d.privacy.rows.map((r) => (
              <div key={r.what} className="grid gap-1 px-6 py-4 sm:grid-cols-3 sm:gap-4">
                <dt className="font-medium">{r.what}</dt>
                <dd className="text-zinc-600 sm:col-span-2 dark:text-zinc-400">{r.where}</dd>
              </div>
            ))}
          </dl>
        </Section>
      </div>

      <Pricing dict={d} />

      {/* FAQ */}
      <div className="bg-zinc-50 dark:bg-zinc-900/50">
        <Section id="faq" title={d.faq.title}>
          <div className="mx-auto max-w-3xl space-y-3">
            {d.faq.items.map((f) => (
              <details
                key={f.q}
                className="group rounded-xl border border-zinc-200 bg-white px-5 py-4 dark:border-zinc-800 dark:bg-zinc-950"
              >
                <summary className="flex cursor-pointer list-none items-center justify-between gap-4 font-medium [&::-webkit-details-marker]:hidden">
                  {f.q}
                  <span className="text-xl text-zinc-400 transition group-open:rotate-45" aria-hidden="true">+</span>
                </summary>
                <p className="mt-3 text-zinc-600 dark:text-zinc-400">{t(f.a)}</p>
              </details>
            ))}
          </div>
        </Section>
      </div>
    </>
  );
}

import type { Metadata } from "next";
import { site } from "@/config/site";

export const metadata: Metadata = { title: "Terms", alternates: { canonical: "/terms" } };

export default function Terms() {
  return (
    <article className="prose-legal mx-auto max-w-3xl px-4 py-16 sm:px-6">
      <h1 className="text-4xl font-semibold tracking-tight">Terms of sale</h1>
      <p className="mt-2 text-sm text-zinc-500">Last updated: 8 November 2026</p>

      <h2>What you buy</h2>
      <p>
        A one-time purchase of the ready-to-install {site.name} app for the platform(s) you choose: the installer, updates
        published while we maintain the app, and setup help by email. There is no subscription. The seller is {site.legalEntity}.
      </p>

      <h2>Open source</h2>
      <p>
        The source code is published under the <a href={`${site.githubUrl}/blob/main/LICENSE`}>MIT license</a>. Your purchase
        pays for the packaged app and support; it does not change the license of the code.
      </p>

      <h2>Payment and prices</h2>
      <p>
        Payment is processed by Stripe. Prices are shown in euros and include VAT (Swedish VAT, as the seller is a Swedish
        company). Stripe calculates the VAT at checkout and shows it on the receipt it sends you by email.
      </p>

      <h2>Delivery and right of withdrawal</h2>
      <p>
        The download links are shown right after payment. You can cancel the purchase and get a full refund within 14 days, even
        after downloading: email <a href={`mailto:${site.supportEmail}`}>{site.supportEmail}</a> with your receipt.
      </p>

      <h2>Using the app</h2>
      <ul>
        <li>
          You are responsible for having the consent required by law from everyone you record, and for how you use recordings,
          transcripts and notes.
        </li>
        <li>
          Notes written with Claude or Codex use your own Anthropic or OpenAI account and their terms. AI-written notes can contain
          mistakes; check important details against the transcript.
        </li>
        <li>
          The installers are not yet signed with Apple or Microsoft certificates, so your operating system warns the first time you
          open them. This is expected; see the FAQ.
        </li>
      </ul>

      <h2>Warranty and liability</h2>
      <p>
        The app is provided as is, as in the MIT license. Your statutory consumer rights are not affected. To the extent the law
        allows, our liability is limited to the amount you paid.
      </p>

      <h2>Law</h2>
      <p>Swedish law applies. Consumers keep the protection of the mandatory law of the country they live in.</p>
    </article>
  );
}

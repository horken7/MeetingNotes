import type { Metadata } from "next";
import { site } from "@/config/site";

export const metadata: Metadata = { title: "Privacy policy", alternates: { canonical: "/privacy" } };

export default function Privacy() {
  return (
    <article className="prose-legal mx-auto max-w-3xl px-4 py-16 sm:px-6">
      <h1 className="text-4xl font-semibold tracking-tight">Privacy policy</h1>
      <p className="mt-2 text-sm text-zinc-500">Last updated: 8 November 2026</p>

      <h2>The short version</h2>
      <p>
        This website only processes what is needed to sell you the app, and payment is handled by Stripe. The {site.name} apps
        record and process your meetings on your own device; we never receive your recordings, transcripts or notes.
      </p>

      <h2>Who is responsible</h2>
      <p>
        {site.legalEntity} is the controller for the data described here. Contact:{" "}
        <a href={`mailto:${site.supportEmail}`}>{site.supportEmail}</a>.
      </p>

      <h2>This website</h2>
      <ul>
        <li>
          <strong>Payments.</strong> When you buy, you are sent to Stripe Checkout. Stripe collects your email address, payment
          details and, where needed for VAT, your billing address. We receive your email, country, the product you bought and the
          payment status, never your full card number. Stripe processes this as described in the{" "}
          <a href="https://stripe.com/privacy">Stripe Privacy Policy</a>. Legal basis: performing the purchase contract and our
          bookkeeping and tax obligations. Records are kept for as long as accounting law requires (7 years in Sweden).
        </li>
        <li>
          <strong>Hosting.</strong> The site is hosted on Vercel, which processes technical data such as IP addresses in server
          logs to deliver and protect the site.
        </li>
        <li>
          <strong>No tracking.</strong> The site uses no analytics or advertising cookies.
        </li>
        <li>
          <strong>Downloads.</strong> The installers are downloaded from GitHub Releases, which is subject to{" "}
          <a href="https://docs.github.com/site-policy/privacy-policies/github-general-privacy-statement">GitHub’s privacy statement</a>.
        </li>
      </ul>

      <h2>The apps</h2>
      <ul>
        <li>
          Audio is recorded and stored only on your device, and is deleted as soon as the transcript is ready unless you turn on
          Keep audio recordings in Settings.
        </li>
        <li>Transcription runs on your device with Whisper.</li>
        <li>
          On Mac and Windows, if you choose Claude or Codex to write notes, the text transcript (not the audio) is sent to Anthropic
          or OpenAI using your own account, under their terms. With the local model, nothing leaves your computer.
        </li>
        <li>
          On the phone, transcripts and notes are made on the phone. The models are built into the app; the internet is used only
          to download optional models, and transcripts or notes leave the phone only when you share them.
        </li>
        <li>The optional MCP server is read-only and runs on your computer; what you look up is shared with the AI app you ask.</li>
        <li>The apps contain no analytics or telemetry.</li>
      </ul>
      <p>
        Recording conversations may require the consent of everyone involved where you live. You are responsible for getting it.
      </p>

      <h2>Your rights</h2>
      <p>
        Under the GDPR you can ask for access to, correction or deletion of your data, object to processing, and complain to the
        supervisory authority (in Sweden, IMY). Email <a href={`mailto:${site.supportEmail}`}>{site.supportEmail}</a>.
      </p>
    </article>
  );
}

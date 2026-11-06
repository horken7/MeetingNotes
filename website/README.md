# Website

Marketing site and checkout for the packaged apps. Next.js (App Router) + Tailwind, hosted on Vercel, payments with
Stripe Checkout.

```bash
npm install
npm run dev        # http://localhost:3000
npm test           # checkout and webhook unit tests
npm run build
```

- **Name, domain, links, support email:** `src/config/site.ts` (the product name appears only there).
- **Prices:** `src/config/pricing.ts`.
- **All page copy:** `src/content/en.ts`. To add Swedish, add `sv.ts` with the same shape and register it in `src/content/index.ts`.
- **Payments:** `src/app/api/checkout/route.ts` creates the Checkout Session, `src/app/success/page.tsx` verifies it
  with the Stripe API and shows the downloads, `src/app/api/webhook/route.ts` receives Stripe's events.
  Without `STRIPE_SECRET_KEY` the site runs in demo mode. Setup: [STRIPE_SETUP.md](STRIPE_SETUP.md).
- **Downloads:** link to `https://github.com/horken7/MeetingNotes/releases/latest/download/<file>`, uploaded by the release
  workflows.

On Vercel the project's **Root Directory** is `website`.

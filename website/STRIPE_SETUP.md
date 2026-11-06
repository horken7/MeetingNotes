# Setting up Stripe payments

The site works without Stripe ("demo mode": the Buy buttons go straight to the thank-you page and no money moves).
To take real payments, give it your Stripe keys. You paste them into Vercel yourself; they never go in the code.

Do everything in **test mode** first (the "Test mode" switch at the top of the Stripe Dashboard). Test mode uses fake
cards and no real money.

## 1. Create a Stripe account

1. Go to <https://dashboard.stripe.com/register> and sign up.
2. You can use test mode right away. To take real payments later, click **Activate payments** and fill in your
   business details and bank account.
3. Under **Settings > Business > Public details**, set the business name and support email (hello@frinkle.se). These appear on
   the checkout page and receipts.
4. Under **Settings > Customer emails**, turn on **Successful payments** so Stripe emails a receipt. (Stripe does not send
   receipt emails in test mode; it does in live mode.)

## 2. Copy the secret key

1. In the Dashboard, open **Developers > API keys** (with test mode on).
2. Click **Reveal** on the **Secret key** (it starts with `sk_test_`) and copy it.

## 3. Add the webhook

The webhook lets Stripe tell the site about each sale (it shows up in the Vercel logs).

1. **Developers > Webhooks > Add endpoint**.
2. Endpoint URL: `https://meetingnotes.frinkle.se/api/webhook` (or your preview URL + `/api/webhook`).
3. Select events: `checkout.session.completed`, `checkout.session.async_payment_succeeded` and `charge.refunded`.
4. Save, then click **Reveal** under **Signing secret** (it starts with `whsec_`) and copy it.

## 4. Paste them into Vercel

1. Open the project on <https://vercel.com> > **Settings > Environment Variables**.
2. Add:
   | Name | Value |
   |---|---|
   | `STRIPE_SECRET_KEY` | the `sk_test_...` key |
   | `STRIPE_WEBHOOK_SECRET` | the `whsec_...` secret |
3. Tick the environments (Production and Preview), save, and **redeploy** (Deployments > ⋯ > Redeploy) so the new values are used.

## 5. Try a test purchase

1. Open the site, click **Buy** on any plan.
2. On Stripe's checkout page use card `4242 4242 4242 4242`, any future date, any CVC and any postcode.
3. You land on the thank-you page with the download links and a "Test mode" note. The payment appears under
   **Payments** in the Dashboard, and the webhook delivery under **Developers > Webhooks**.

## VAT (you handle this)

You chose Stripe directly rather than a "merchant of record", so **you** are the seller and responsible for EU VAT.
Selling digital products to consumers in other EU countries means charging their country's VAT rate and reporting it,
usually through the EU **OSS** (One-Stop Shop) scheme via Skatteverket. Ask your accountant if unsure.

Stripe Tax can calculate the right VAT at checkout:

1. In the Dashboard, open **Tax** (Settings > Tax), add your head office address and set the default product tax category
   to **Software as a service**/**Digital products** as appropriate, and add your registrations (Sweden, and OSS when you have it).
2. In Vercel, add `STRIPE_AUTOMATIC_TAX` = `true` and redeploy. Checkout then asks for the billing address and adds VAT.
   Prices on the site are VAT-inclusive, so the customer pays the shown price and VAT is taken out of it.

Stripe Tax costs a small fee per transaction; see <https://stripe.com/tax#pricing>.

## Going live

When you are ready to sell for real: activate your account, switch the Dashboard to live mode, repeat steps 2 to 4 with
the live key (`sk_live_...`) and a new live webhook, and redeploy.

## Prices

Prices are in `src/config/pricing.ts` (in cents, e.g. `2900` = €29). The checkout creates them on the fly, so no setup is
needed in Stripe. If you would rather manage prices in the Stripe Dashboard, create a Product with a one-time Price there
and put its ID (`price_...`) in `STRIPE_PRICE_MAC`, `STRIPE_PRICE_WINDOWS`, `STRIPE_PRICE_ANDROID` or `STRIPE_PRICE_BUNDLE`.
Remember to update the displayed price in `pricing.ts` too.

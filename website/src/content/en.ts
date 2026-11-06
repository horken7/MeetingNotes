// All page copy in English. To add Swedish, copy this file to sv.ts, translate it,
// and register it in ./index.ts. `{name}` is replaced with the product name from config/site.ts.
const en = {
  locale: "en",
  nav: {
    how: "How it works",
    features: "Features",
    privacy: "Privacy",
    pricing: "Pricing",
    faq: "FAQ",
    buy: "Buy",
    github: "Source on GitHub",
  },
  hero: {
    eyebrow: "Mac · Windows · Android · iPhone soon",
    title: "Meeting notes that stay yours.",
    lead:
      "{name} hears your calls without a bot joining them, transcribes on your own device and hands you a summary, decisions and action items a few minutes after you hang up. Pay once. No subscription.",
    primary: "See pricing",
    secondary: "How it works",
    note: "Open source (MIT). Buy the ready-made app, or build it yourself for free.",
  },
  pitch: {
    title: "Tired of AI notetakers?",
    items: [
      { title: "Another subscription", body: "Most notetakers cost every month. {name} is a one-time purchase per platform." },
      { title: "A bot in your call", body: "No “Notetaker has joined” for your guests. It records your mic and the call audio right on your computer." },
      { title: "Waiting for processing", body: "Transcription runs locally with Whisper as soon as the call ends. No upload queue." },
      { title: "Audio on someone’s servers", body: "Your recordings never leave your device. You choose where the notes are written." },
    ],
  },
  how: {
    title: "How it works",
    steps: [
      { title: "Join your call", body: "Zoom, Teams, Google Meet (in any browser) or FaceTime. {name} notices when an app starts using the microphone and asks if you want notes." },
      { title: "It records two tracks", body: "Your microphone and the call audio are captured separately, so the transcript knows what you said and what others said." },
      { title: "Hang up", body: "Recording stops a few seconds after the call ends, and Whisper transcribes it on your device." },
      { title: "Read your notes", body: "Summary, decisions, action items and open questions, written by Claude, Codex or a fully local model. You get a notification when they are ready." },
    ],
  },
  screenshots: {
    windowAlt: "The {name} window showing notes for a meeting: summary, decisions and action items",
    promptAlt: "The prompt shown when a call is detected, with Start notes and Not now buttons",
    promptCaption: "When a call starts, a small prompt offers to take notes.",
  },
  features: {
    title: "One app for your calls, one for the meeting room",
    computer: {
      title: "On your Mac or Windows PC",
      subtitle: "For video calls",
      items: [
        "Detects Zoom, Teams and Google Meet calls automatically (and FaceTime on Mac)",
        "Records your mic and the call audio as two tracks, no bot and no virtual audio driver",
        "Local transcription with Whisper",
        "Structured notes: summary, decisions, action items, open questions, key points",
        "Notes with Claude, Codex, or a fully local model through Ollama",
        "Names meetings from the call’s browser tab title",
        "Search across all meetings, and find within a note",
        "Read-only MCP server: ask Claude Desktop and other AI apps about your meetings",
        "Swedish, Danish and English, or automatic language detection",
        "Lives in the menu bar or tray and starts at login",
      ],
    },
    phone: {
      title: "On your phone",
      subtitle: "For in-person meetings",
      items: [
        "Put the phone on the table and press record; it keeps going with the screen off",
        "Transcript and notes made fully on the phone, with on-device Whisper and Gemma models",
        "Works offline: the internet is only used once, to download the models",
        "Swedish, Danish, English and more, with notes in the meeting’s language",
        "Search, rename and share notes and transcripts",
        "Android available now (Android 10 or newer), iPhone coming to the App Store",
      ],
    },
  },
  privacy: {
    title: "Private by design",
    lead: "Here is exactly what goes where.",
    rows: [
      { what: "Audio recordings", where: "Stay on your device. Always." },
      { what: "Transcription", where: "On your device, with Whisper." },
      { what: "Notes with the local model", where: "Written on your computer with Ollama. Nothing leaves it." },
      { what: "Notes with Claude or Codex", where: "Only the text transcript is sent to Anthropic or OpenAI, using your own account, to write the notes." },
      { what: "Notes on the phone", where: "Written on the phone. Nothing leaves it." },
      { what: "This website", where: "Only handles your payment, through Stripe. We never see your meetings." },
    ],
  },
  pricing: {
    title: "Pay once. Keep it.",
    lead:
      "The source is open (MIT) and free to build yourself. Buying gets you the convenience: a ready-to-install app, updates and setup help.",
    includes: ["Ready-to-install app", "Updates", "Setup help by email"],
    perPlatform: "one-time",
    buy: "Buy",
    best: "Best value",
    iphone: {
      name: "iPhone",
      price: "Coming soon",
      blurb: "Coming to the App Store. Apple only allows iPhone apps to be sold there.",
      cta: "Coming to the App Store",
    },
    vatNote: "Prices include VAT where it applies. Secure payment by Stripe.",
    error: "Checkout could not start. Please try again, or email {support}.",
    openSource: "Prefer to build it yourself? The full source is on GitHub.",
  },
  faq: {
    title: "Questions",
    items: [
      {
        q: "Why does my Mac or Windows PC warn about an unidentified developer?",
        a: "The installers are not yet signed with a paid Apple or Microsoft certificate, so the operating system shows a warning the first time. On a Mac: open the app once, then go to System Settings > Privacy & Security and click Open Anyway (or right-click the app and choose Open). On Windows: in the SmartScreen dialog click More info, then Run anyway. The app is open source, so you can read exactly what it does on GitHub.",
      },
      {
        q: "Is it really a one-time payment?",
        a: "Yes. You pay once per platform and keep the app. There is no subscription. If you use Claude or Codex for the notes, those run on your own Claude or OpenAI account, under its own terms and plan.",
      },
      {
        q: "Do I need a Claude or OpenAI account?",
        a: "Only if you want notes from Claude or Codex. Choose the local model instead and everything runs on your computer with no account. It needs about 8 GB of disk and works best with 16 GB of memory.",
      },
      {
        q: "Does a bot join my calls?",
        a: "No. {name} records your microphone and the call’s audio on your own computer. Nobody in the call sees a bot.",
      },
      {
        q: "Should I tell people I am recording?",
        a: "Yes. Recording laws differ by country, and many require consent from everyone in the conversation. Let the others know before you start.",
      },
      {
        q: "Which languages does it support?",
        a: "Swedish, Danish and English, or automatic detection. The Android app also handles other languages. Notes are written in the meeting’s language.",
      },
      {
        q: "If it is open source, what am I paying for?",
        a: "Convenience. The code is MIT licensed and you can build it yourself. Buying gets you a ready-to-install app without developer tools, updates, and help with setup. It also funds development.",
      },
      {
        q: "Why is iPhone not for sale here?",
        a: "Apple only lets iPhone apps be sold through the App Store. The iPhone app will be listed there when it is ready.",
      },
      {
        q: "Can I get a refund?",
        a: "Yes, within 14 days of purchase. Email {support} with your receipt number.",
      },
    ],
  },
  success: {
    title: "Thank you!",
    lead: "Your payment for {product} went through. Here are your downloads.",
    receipt: "Stripe has emailed your receipt to {email}. Bookmark this page: the download links below always point to the latest version.",
    receiptNoEmail: "Stripe will email your receipt. Bookmark this page: the download links below always point to the latest version.",
    next: "Next steps",
    steps: [
      "Download and open the installer.",
      "If your computer warns about an unidentified developer, see the FAQ: it is expected for now.",
      "Follow the first-run setup. It downloads the speech model and asks for microphone access.",
    ],
    help: "Stuck? Email {support} and we will help you set it up.",
    demo: "Demo mode: no Stripe keys are configured on this deployment, so no payment was taken.",
    test: "Test mode: this was a Stripe test payment.",
    unpaid: "We could not confirm this payment yet.",
    unpaidBody: "If you just paid, wait a moment and reload this page. If it keeps happening, email {support} with your receipt number.",
    back: "Back to the homepage",
  },
  footer: {
    privacy: "Privacy policy",
    terms: "Terms",
    source: "Source code (MIT)",
    contact: "Contact",
  },
};

export default en;
export type Dictionary = typeof en;

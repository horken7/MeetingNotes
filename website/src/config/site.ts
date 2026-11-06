// The product name and links live here, and only here. Change `name` to rebrand the whole site.
export const site = {
  name: "Ekko Notes",
  // Short line used in the <title> and social previews.
  tagline: "Private meeting notes, without the bot",
  description:
    "A one-time purchase meeting notes app for Mac, Windows and Android. Records your calls without a bot, transcribes on your device and writes notes with Claude, Codex or a fully local model.",
  // The site's own domain (production).
  domain: "meetingnotes.frinkle.se",
  githubUrl: "https://github.com/horken7/MeetingNotes",
  releasesUrl: "https://github.com/horken7/MeetingNotes/releases/latest",
  // Where buyers get help.
  supportEmail: "hello@frinkle.se",
  // Seller shown on the legal pages. Replace with your company name and address before selling.
  legalEntity: "Ekko Notes (sole trader, Sweden)",
} as const;

export function siteUrl(): string {
  const explicit = process.env.NEXT_PUBLIC_SITE_URL;
  if (explicit) return explicit.replace(/\/$/, "");
  // Previews redirect back to themselves; production uses the real domain.
  if (process.env.VERCEL_ENV === "production") return `https://${site.domain}`;
  if (process.env.VERCEL_URL) return `https://${process.env.VERCEL_URL}`;
  return "http://localhost:3000";
}

const download = (file: string) => `${site.githubUrl}/releases/latest/download/${file}`;

// Installer files uploaded to GitHub Releases by the release workflows.
export const downloads = {
  mac: { label: "Download for Mac", file: "MeetingNotes.dmg", url: download("MeetingNotes.dmg") },
  windows: { label: "Download for Windows", file: "MeetingNotes-Setup.exe", url: download("MeetingNotes-Setup.exe") },
  android: { label: "Download for Android", file: "MeetingNotes.apk", url: download("MeetingNotes.apk") },
} as const;

export type Platform = keyof typeof downloads;

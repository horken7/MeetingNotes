// The product name and links live here, and only here. Change `name` to rebrand the whole site.
export const site = {
  name: "Meeting Notes",
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
  // Seller shown on the legal pages.
  legalEntity: "Frinkle AB (Sweden)",
} as const;

export function siteUrl(): string {
  const explicit = process.env.NEXT_PUBLIC_SITE_URL;
  if (explicit) return explicit.replace(/\/$/, "");
  // Previews redirect back to themselves; production uses the real domain.
  if (process.env.VERCEL_ENV === "production") return `https://${site.domain}`;
  if (process.env.VERCEL_URL) return `https://${process.env.VERCEL_URL}`;
  return "http://localhost:3000";
}

// Installer files from the latest GitHub Release, unless an env var points somewhere else
// (DOWNLOAD_URL_MAC, DOWNLOAD_URL_WINDOWS, DOWNLOAD_URL_ANDROID): installers over GitHub's 2 GB limit are hosted
// elsewhere, for example a shared Google Drive link. Read on the server, so changing one needs only a redeploy.
const download = (file: string, envName: string, hosted?: string) =>
  process.env[envName]?.trim() || hosted || `${site.githubUrl}/releases/latest/download/${file}`;

// The Mac and Windows installers (about 4 GB each, with the built-in notes model) are over GitHub's 2 GB limit for a
// release file, so they're on Google Drive. Update these when a new version is uploaded.
const hosted = {
  mac: "https://drive.google.com/file/d/1-FQzOC9lc7zP0iSmVUwCQ9DwP-oJm7Ku/view?usp=sharing",
  windows: "https://drive.google.com/file/d/1EU8sMa9FQU9WQxFmeQGM_VDFuMABvnr7/view?usp=sharing",
};

export const downloads = {
  mac: { label: "Download for Mac", file: "MeetingNotes.dmg", url: download("MeetingNotes.dmg", "DOWNLOAD_URL_MAC", hosted.mac) },
  windows: { label: "Download for Windows", file: "MeetingNotes-Setup.zip", url: download("MeetingNotes-Setup.zip", "DOWNLOAD_URL_WINDOWS", hosted.windows) },
  android: { label: "Download for Android", file: "MeetingNotes.apk", url: download("MeetingNotes.apk", "DOWNLOAD_URL_ANDROID") },
} as const;

export type Platform = keyof typeof downloads;

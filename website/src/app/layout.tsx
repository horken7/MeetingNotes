import type { Metadata, Viewport } from "next";
import { Inter } from "next/font/google";
import { site, siteUrl } from "@/config/site";
import { getDictionary } from "@/content";
import { Header } from "@/components/Header";
import { Footer } from "@/components/Footer";
import "./globals.css";

const inter = Inter({ subsets: ["latin"], variable: "--font-inter", display: "swap" });

export const metadata: Metadata = {
  metadataBase: new URL(siteUrl()),
  title: { default: `${site.name} – ${site.tagline}`, template: `%s – ${site.name}` },
  description: site.description,
  applicationName: site.name,
  keywords: [
    "meeting notes",
    "AI notetaker",
    "transcription",
    "Whisper",
    "private",
    "local",
    "Zoom",
    "Teams",
    "Google Meet",
    "no bot",
  ],
  alternates: { canonical: "/" },
  openGraph: {
    type: "website",
    siteName: site.name,
    title: `${site.name} – ${site.tagline}`,
    description: site.description,
    images: [{ url: "/images/window.png", width: 2000, height: 1320, alt: `${site.name} window` }],
    locale: "en_US",
  },
  twitter: { card: "summary_large_image", title: site.name, description: site.description, images: ["/images/window.png"] },
  robots: process.env.VERCEL_ENV === "preview" ? { index: false, follow: false } : { index: true, follow: true },
};

export const viewport: Viewport = {
  themeColor: [
    { media: "(prefers-color-scheme: light)", color: "#ffffff" },
    { media: "(prefers-color-scheme: dark)", color: "#09090b" },
  ],
};

export default function RootLayout({ children }: { children: React.ReactNode }) {
  const dict = getDictionary();
  return (
    <html lang={dict.locale} className={inter.variable}>
      <body className="flex min-h-screen flex-col font-sans">
        <Header dict={dict} />
        <main className="flex-1">{children}</main>
        <Footer dict={dict} />
      </body>
    </html>
  );
}

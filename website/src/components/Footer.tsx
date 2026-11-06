import Link from "next/link";
import { site } from "@/config/site";
import type { Dictionary } from "@/content/en";
import { Logo } from "./Logo";

export function Footer({ dict }: { dict: Dictionary }) {
  return (
    <footer className="border-t border-zinc-200 dark:border-zinc-800">
      <div className="mx-auto flex max-w-6xl flex-col gap-6 px-4 py-10 text-sm text-zinc-600 sm:flex-row sm:items-center sm:justify-between sm:px-6 dark:text-zinc-400">
        <div className="flex flex-col gap-2">
          <Logo className="text-zinc-900 dark:text-white" />
          <span>© {new Date().getFullYear()} {site.name}</span>
        </div>
        <nav className="flex flex-wrap gap-x-6 gap-y-2">
          <Link href="/privacy" className="hover:text-zinc-900 dark:hover:text-white">{dict.footer.privacy}</Link>
          <Link href="/terms" className="hover:text-zinc-900 dark:hover:text-white">{dict.footer.terms}</Link>
          <a href={site.githubUrl} className="hover:text-zinc-900 dark:hover:text-white">{dict.footer.source}</a>
          <a href={`mailto:${site.supportEmail}`} className="hover:text-zinc-900 dark:hover:text-white">{dict.footer.contact}</a>
        </nav>
      </div>
    </footer>
  );
}

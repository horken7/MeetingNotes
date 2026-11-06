import Link from "next/link";
import type { Dictionary } from "@/content/en";
import { Logo } from "./Logo";

export function Header({ dict }: { dict: Dictionary }) {
  const links = [
    ["/#how", dict.nav.how],
    ["/#features", dict.nav.features],
    ["/#privacy", dict.nav.privacy],
    ["/#pricing", dict.nav.pricing],
    ["/#faq", dict.nav.faq],
  ] as const;
  return (
    <header className="sticky top-0 z-30 border-b border-zinc-200/70 bg-white/80 backdrop-blur dark:border-zinc-800/70 dark:bg-zinc-950/80">
      <div className="mx-auto flex h-16 max-w-6xl items-center justify-between px-4 sm:px-6">
        <Link href="/" aria-label="Home">
          <Logo />
        </Link>
        <nav className="hidden items-center gap-6 text-sm text-zinc-600 md:flex dark:text-zinc-400">
          {links.map(([href, label]) => (
            <Link key={href} href={href} className="hover:text-zinc-900 dark:hover:text-white">
              {label}
            </Link>
          ))}
        </nav>
        <Link
          href="/#pricing"
          className="rounded-full bg-accent-700 px-4 py-2 text-sm font-medium text-white hover:bg-accent-600"
        >
          {dict.nav.buy}
        </Link>
      </div>
    </header>
  );
}

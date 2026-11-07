import { site } from "@/config/site";

// The app icon: the same white waveform on a green gradient as the Mac, Windows, iPhone and Android apps.
export function Logo({ className = "" }: { className?: string }) {
  return (
    <span className={`inline-flex items-center gap-2 font-semibold tracking-tight ${className}`}>
      <svg viewBox="0 0 64 64" className="size-7" aria-hidden="true">
        <defs>
          <linearGradient id="logo-gradient" x1="0" y1="0" x2="0" y2="1">
            <stop offset="0" stopColor="#338C6B" />
            <stop offset="1" stopColor="#12453D" />
          </linearGradient>
        </defs>
        <rect width="64" height="64" rx="14.4" fill="url(#logo-gradient)" />
        <path d="M18.64 29.17V34.83M24 22.8V41.28M29.28 17.05V46.95M34.64 24.82V39.18M39.92 20.39V43.61M45.2 27.69V36.31" fill="none" stroke="#fff" strokeWidth="2.87" strokeLinecap="round" />
      </svg>
      {site.name}
    </span>
  );
}

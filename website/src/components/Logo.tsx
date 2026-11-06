import { site } from "@/config/site";

export function Logo({ className = "" }: { className?: string }) {
  return (
    <span className={`inline-flex items-center gap-2 font-semibold tracking-tight ${className}`}>
      <svg viewBox="0 0 64 64" className="size-7" aria-hidden="true">
        <rect width="64" height="64" rx="14" className="fill-accent-700" />
        <g fill="none" stroke="#fff" strokeWidth="5" strokeLinecap="round">
          <path d="M16 26v12" />
          <path d="M26 18v28" />
          <path d="M36 22v20" />
          <path d="M46 28v8" />
        </g>
      </svg>
      {site.name}
    </span>
  );
}

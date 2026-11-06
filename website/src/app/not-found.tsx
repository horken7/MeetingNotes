import Link from "next/link";

export default function NotFound() {
  return (
    <div className="mx-auto max-w-xl px-4 py-32 text-center">
      <h1 className="text-3xl font-semibold">Page not found</h1>
      <Link href="/" className="mt-6 inline-block text-accent-700 underline underline-offset-4 dark:text-accent-400">Back to the homepage</Link>
    </div>
  );
}

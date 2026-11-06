"use client";

import { useSearchParams } from "next/navigation";

export function CheckoutError({ message }: { message: string }) {
  const params = useSearchParams();
  if (params.get("checkout") !== "error") return null;
  return (
    <p role="alert" className="mx-auto mb-8 max-w-2xl rounded-lg border border-red-300 bg-red-50 px-4 py-3 text-center text-sm text-red-800 dark:border-red-800 dark:bg-red-950 dark:text-red-200">
      {message}
    </p>
  );
}

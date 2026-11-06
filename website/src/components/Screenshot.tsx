import Image from "next/image";

// Shows the light screenshot in light mode and the dark one in dark mode.
export function Screenshot({
  light,
  dark,
  alt,
  width,
  height,
  priority = false,
  className = "",
  sizes,
}: {
  light: string;
  dark: string;
  alt: string;
  width: number;
  height: number;
  priority?: boolean;
  className?: string;
  sizes?: string;
}) {
  return (
    <>
      <Image src={light} alt={alt} width={width} height={height} priority={priority} sizes={sizes} className={`dark:hidden ${className}`} />
      <Image src={dark} alt={alt} width={width} height={height} priority={priority} sizes={sizes} className={`hidden dark:block ${className}`} />
    </>
  );
}

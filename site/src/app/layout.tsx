import type { Metadata, Viewport } from "next";
import "./globals.css";

export const metadata: Metadata = {
  metadataBase: new URL("https://kaskados.xyz"),
  title: "KaskadOS — Linux без лишнего шума",
  description:
    "KaskadOS — дистрибутив на базе Arch Linux с собственным рабочим окружением, понятным установщиком и встроенными системными инструментами.",
  icons: {
    icon: "/kaskados-logo.png",
  },
  openGraph: {
    title: "KaskadOS — Linux без лишнего шума",
    description:
      "Цельная система на базе Arch Linux с собственным рабочим окружением.",
    type: "website",
    locale: "ru_RU",
    url: "https://kaskados.xyz",
    siteName: "KaskadOS",
  },
  twitter: {
    card: "summary",
    title: "KaskadOS — Linux без лишнего шума",
    description:
      "Цельная система на базе Arch Linux с собственным рабочим окружением.",
  },
};

export const viewport: Viewport = {
  colorScheme: "dark",
  themeColor: "#08130f",
};

export default function RootLayout({
  children,
}: Readonly<{ children: React.ReactNode }>) {
  return (
    <html lang="ru">
      <body>{children}</body>
    </html>
  );
}

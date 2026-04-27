import type { Metadata } from "next";
import { Inter } from "next/font/google";
import "./globals.css";
import { CommandPalette } from "@/components/CommandPalette";
import { Header } from "@/components/Header";

const inter = Inter({
  subsets: ["latin"],
  display: "swap",
  variable: "--font-inter",
});

export const metadata: Metadata = {
  title: "ZeroOnboarding",
  description: "Operator UI",
};

export default function RootLayout({
  children,
}: {
  children: React.ReactNode;
}) {
  return (
    <html lang="en" className={inter.variable}>
      <body className="font-sans bg-[#FAFAF7] text-[#1A1A1A] antialiased">
        {/* Header is a Server Component; renders nothing on /login when there's no session. */}
        <Header />
        {children}
        <CommandPalette />
      </body>
    </html>
  );
}

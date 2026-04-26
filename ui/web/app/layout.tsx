import type { Metadata } from "next";
import { Inter } from "next/font/google";
import "./globals.css";
import { OperatorNameGate } from "@/components/OperatorNameGate";

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
        <OperatorNameGate>{children}</OperatorNameGate>
      </body>
    </html>
  );
}

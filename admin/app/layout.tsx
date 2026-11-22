import type { Metadata } from "next";
import "./globals.css";

export const metadata: Metadata = { title: "Kavach Admin", description: "Internal trust & safety console" };

export default function RootLayout({ children }: LayoutProps<"/">) {
  return (
    <html lang="en">
      <body>{children}</body>
    </html>
  );
}

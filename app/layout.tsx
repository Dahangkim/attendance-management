import type { CSSProperties } from "react";
import type { Metadata, Viewport } from "next";
import "./globals.css";
import { getRequestBranding } from "./_lib/request-branding";

export async function generateMetadata(): Promise<Metadata> {
  const { branding: brand, metadataBase } = await getRequestBranding();
  const icon = brand.logoUrl || "/api/brand-icon";
  return {
    metadataBase,
    title: brand.title,
    description: brand.description,
    manifest: "/api/manifest",
    icons: { icon, shortcut: icon, apple: icon },
    appleWebApp: { capable: true, title: brand.shortTitle, statusBarStyle: "default" },
    openGraph: {
      title: brand.title,
      description: brand.description,
      type: "website",
      images: brand.ogImageUrl ? [{ url: new URL(brand.ogImageUrl, metadataBase).toString(), width: 1200, height: 630, alt: brand.title }] : undefined,
    },
    twitter: {
      card: "summary_large_image",
      title: brand.title,
      description: brand.description,
      images: brand.ogImageUrl ? [new URL(brand.ogImageUrl, metadataBase).toString()] : undefined,
    },
  };
}

export async function generateViewport(): Promise<Viewport> {
  const { branding } = await getRequestBranding();
  return { themeColor: branding.primaryColor };
}

export default async function RootLayout({
  children,
}: Readonly<{
  children: React.ReactNode;
}>) {
  const { branding } = await getRequestBranding();
  const brandStyle = {
    "--green": branding.primaryColor,
    "--brand": branding.primaryColor,
    "--lime": branding.accentColor,
  } as CSSProperties;
  return (
    <html lang="ko" data-org-code={branding.orgCode || undefined} style={brandStyle}>
      <body>{children}</body>
    </html>
  );
}

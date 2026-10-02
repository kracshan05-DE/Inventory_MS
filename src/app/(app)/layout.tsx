'use client';

import type { ReactNode } from 'react';
import { AppShell } from '@/components/AppShell';
import { SessionProvider } from '@/components/SessionProvider';

export default function AppLayout({ children }: { children: ReactNode }) {
  return (
    <SessionProvider>
      <AppShell>{children}</AppShell>
    </SessionProvider>
  );
}

'use client';

import Link from 'next/link';
import { usePathname } from 'next/navigation';
import type { ReactNode } from 'react';
import { Icon, type IconName } from './Icon';
import { useSession } from './SessionProvider';

interface NavItem { href: string; label: string; short: string; icon: IconName; section: string; adminOnly?: boolean }

const NAV: NavItem[] = [
  { href: '/dashboard',      label: 'Dashboard',        short: 'Dashboard', icon: 'dashboard', section: 'Main' },
  { href: '/post',           label: 'Post Transaction', short: 'Post',      icon: 'post',      section: 'Main' },
  { href: '/transactions',   label: 'Transactions',     short: 'History',   icon: 'list',      section: 'Main' },
  { href: '/reps',           label: 'Rep Ledger',       short: 'Reps',      icon: 'reps',      section: 'Reports' },
  { href: '/reconciliation', label: 'Reconciliation',   short: 'Recon',     icon: 'recon',     section: 'Reports' },
  { href: '/audit',          label: 'Audit Log',        short: 'Audit',     icon: 'audit',     section: 'Admin', adminOnly: true },
  { href: '/settings',       label: 'Settings',         short: 'Settings',  icon: 'settings',  section: 'Admin', adminOnly: true },
];

function CompanySwitch() {
  const { companies, company, setCompanyId } = useSession();
  return (
    <select
      className="company-switch"
      aria-label="Company"
      value={company.id}
      onChange={(e) => setCompanyId(Number(e.target.value))}
    >
      {companies.map((c) => (
        <option key={c.id} value={c.id}>
          {c.name}{c.active ? '' : ' (inactive)'}
        </option>
      ))}
    </select>
  );
}

export function AppShell({ children }: { children: ReactNode }) {
  const pathname = usePathname();
  const { profile, isAdmin, company, signOut } = useSession();
  const items = NAV.filter((n) => !n.adminOnly || isAdmin);
  const sections = [...new Set(items.map((n) => n.section))];

  return (
    <div className="shell">
      <nav className="sidebar">
        <div className="sidebar-brand">
          <div className="brand-name">Inventory<span>IQ</span></div>
          <span className="company-label">Company</span>
          <CompanySwitch />
        </div>
        <div className="sidebar-nav">
          {sections.map((s) => (
            <div key={s}>
              <div className="nav-section-label">{s}</div>
              {items.filter((n) => n.section === s).map((n) => (
                <Link key={n.href} href={n.href} className={'nav-item' + (pathname === n.href ? ' active' : '')}>
                  <Icon name={n.icon} />
                  <span>{n.label}</span>
                </Link>
              ))}
            </div>
          ))}
        </div>
        <div className="sidebar-footer">
          <div className="user-info">
            <div className="avatar">{profile.full_name.charAt(0).toUpperCase() || '?'}</div>
            <div>
              <div className="user-name">{profile.full_name}</div>
              <div className="user-role">{isAdmin ? 'Admin' : 'User'}</div>
            </div>
          </div>
          <button className="logout-btn" onClick={signOut}>Sign out</button>
        </div>
      </nav>

      <div className="main">
        <div className="mobile-bar no-print">
          <CompanySwitch />
          <button className="logout-btn" style={{ width: 'auto', marginTop: 0, padding: '8px 12px' }} onClick={signOut}>
            Sign out
          </button>
        </div>
        {/* key: switching company remounts the page, so no state from the
            previous company can leak into the next one. */}
        <div key={company.id} style={{ display: 'flex', flexDirection: 'column', flex: 1 }}>
          {children}
        </div>
      </div>

      <nav className="mobile-nav">
        <div className="mobile-nav-inner">
          {items.map((n) => (
            <Link key={n.href} href={n.href} className={'mobile-nav-item' + (pathname === n.href ? ' active' : '')}>
              <Icon name={n.icon} />
              <span>{n.short}</span>
            </Link>
          ))}
        </div>
      </nav>
    </div>
  );
}

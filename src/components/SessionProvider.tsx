'use client';

import { createContext, useCallback, useContext, useEffect, useMemo, useState, type ReactNode } from 'react';
import { useRouter } from 'next/navigation';
import { errText, supabase } from '@/lib/supabase';
import type { Company, Profile } from '@/lib/types';

interface SessionValue {
  userId: string;
  profile: Profile;
  isAdmin: boolean;
  /** Companies this user may open (the database decides, not the browser). */
  companies: Company[];
  company: Company;
  setCompanyId: (id: number) => void;
  reloadCompanies: () => Promise<void>;
  signOut: () => Promise<void>;
}

const Ctx = createContext<SessionValue | null>(null);

export function useSession(): SessionValue {
  const v = useContext(Ctx);
  if (!v) throw new Error('useSession must be used inside <SessionProvider>');
  return v;
}

const COMPANY_KEY = 'iq_company';

function readStoredCompany(): number | null {
  try {
    const v = window.localStorage.getItem(COMPANY_KEY);
    return v ? Number(v) : null;
  } catch {
    return null;
  }
}

/** Which company to open: last used if still allowed, else the first active one. */
function pickCompany(list: Company[], preferred: number | null): number | null {
  if (preferred !== null && list.some((c) => c.id === preferred)) return preferred;
  return (list.find((c) => c.active) ?? list[0])?.id ?? null;
}

export function SessionProvider({ children }: { children: ReactNode }) {
  const router = useRouter();
  const [authChecked, setAuthChecked] = useState(false);
  const [userId, setUserId] = useState<string | null>(null);
  const [profile, setProfile] = useState<Profile | null>(null);
  const [companies, setCompanies] = useState<Company[] | null>(null);
  const [companyId, setCompanyIdState] = useState<number | null>(null);
  const [error, setError] = useState<string | null>(null);

  // 1. Who is signed in. Only the user id is kept, so a silent token refresh
  //    does not reload the page data.
  useEffect(() => {
    const sb = supabase();
    let alive = true;
    sb.auth.getSession().then(({ data }) => {
      if (!alive) return;
      setUserId(data.session?.user.id ?? null);
      setAuthChecked(true);
    });
    const { data: sub } = sb.auth.onAuthStateChange((_event, session) => {
      setUserId(session?.user.id ?? null);
      setAuthChecked(true);
    });
    return () => {
      alive = false;
      sub.subscription.unsubscribe();
    };
  }, []);

  // 2. Not signed in: go to the login page.
  useEffect(() => {
    if (authChecked && !userId) router.replace('/login');
  }, [authChecked, userId, router]);

  const loadCompanies = useCallback(async () => {
    const { data, error: e } = await supabase().from('companies').select('id,name,active,created_at').order('name');
    if (e) throw new Error(e.message);
    const list = (data ?? []) as Company[];
    setCompanies(list);
    setCompanyIdState((current) => pickCompany(list, current ?? readStoredCompany()));
  }, []);

  // 3. Profile and company list for the signed-in user.
  useEffect(() => {
    if (!userId) {
      setProfile(null);
      setCompanies(null);
      return;
    }
    let alive = true;
    (async () => {
      try {
        setError(null);
        const { data, error: e } = await supabase()
          .from('user_profiles')
          .select('id,full_name,role,company_id')
          .eq('id', userId)
          .maybeSingle();
        if (e) throw new Error(e.message);
        if (!alive) return;
        setProfile((data as Profile | null) ?? null);
        await loadCompanies();
      } catch (e) {
        if (alive) setError(errText(e));
      }
    })();
    return () => {
      alive = false;
    };
  }, [userId, loadCompanies]);

  const setCompanyId = useCallback((id: number) => {
    setCompanyIdState(id);
    try {
      window.localStorage.setItem(COMPANY_KEY, String(id));
    } catch {
      /* storage unavailable: the choice just will not be remembered */
    }
  }, []);

  const signOut = useCallback(async () => {
    await supabase().auth.signOut();
    router.replace('/login');
  }, [router]);

  const company = useMemo(
    () => companies?.find((c) => c.id === companyId) ?? null,
    [companies, companyId],
  );

  if (error) {
    return (
      <div className="center-screen">
        <div className="center-card">
          <h2>Could not load your account</h2>
          <p>{error}</p>
          <button className="btn btn-primary" onClick={() => window.location.reload()}>Try again</button>
        </div>
      </div>
    );
  }

  if (!authChecked || !userId || companies === null) {
    return (
      <div className="center-screen">
        <div className="spinner" aria-label="Loading" />
      </div>
    );
  }

  if (!profile || !company) {
    return (
      <div className="center-screen">
        <div className="center-card">
          <h2>No access yet</h2>
          <p>
            Your account is signed in but has not been given access to any company.
            Ask an admin to open Settings, Users and assign you.
          </p>
          <button className="btn" onClick={signOut}>Sign out</button>
        </div>
      </div>
    );
  }

  const value: SessionValue = {
    userId,
    profile,
    isAdmin: profile.role === 'admin',
    companies,
    company,
    setCompanyId,
    reloadCompanies: loadCompanies,
    signOut,
  };

  return <Ctx.Provider value={value}>{children}</Ctx.Provider>;
}

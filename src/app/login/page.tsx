'use client';

import { useEffect, useState, type FormEvent } from 'react';
import { useRouter } from 'next/navigation';
import { supabase } from '@/lib/supabase';

export default function LoginPage() {
  const router = useRouter();
  const [email, setEmail] = useState('');
  const [password, setPassword] = useState('');
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);

  // Already signed in: skip the form.
  useEffect(() => {
    supabase().auth.getSession().then(({ data }) => {
      if (data.session) router.replace('/dashboard');
    });
  }, [router]);

  async function onSubmit(e: FormEvent) {
    e.preventDefault();
    setError(null);
    if (!email.trim() || !password) {
      setError('Enter your email and password.');
      return;
    }
    setBusy(true);
    const { error: err } = await supabase().auth.signInWithPassword({ email: email.trim(), password });
    if (err) {
      setBusy(false);
      setError(
        err.message.toLowerCase().includes('invalid')
          ? 'Wrong email or password.'
          : 'Could not sign in: ' + err.message,
      );
      return;
    }
    router.replace('/dashboard');
  }

  return (
    <div className="login">
      <div className="login-left">
        <div className="brand-name" style={{ fontSize: 22 }}>Inventory<span>IQ</span></div>
        <div>
          <h1>Every case<br /><em>accounted for.</em></h1>
          <p>Goods received, issues to reps, returns and settlements, reconciled against the warehouse for each company you distribute.</p>
        </div>
        <div />
      </div>

      <div className="login-right">
        <h2>Sign in</h2>
        <p className="muted" style={{ marginBottom: 28 }}>Use the account your admin created for you.</p>

        {error ? <div className="banner error" role="alert">{error}</div> : null}

        <form onSubmit={onSubmit} className="stack">
          <div className="field">
            <label htmlFor="email">Email</label>
            <input id="email" type="email" autoComplete="email" value={email} onChange={(e) => setEmail(e.target.value)} placeholder="you@example.com" />
          </div>
          <div className="field">
            <label htmlFor="password">Password</label>
            <input id="password" type="password" autoComplete="current-password" value={password} onChange={(e) => setPassword(e.target.value)} />
          </div>
          <button type="submit" className="btn btn-primary btn-lg" disabled={busy}>
            {busy ? 'Signing in…' : 'Sign in'}
          </button>
        </form>

        <div className="login-note">
          Your company is chosen after you sign in.<br />No account? Ask your admin.
        </div>
      </div>
    </div>
  );
}

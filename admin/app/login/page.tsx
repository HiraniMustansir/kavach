"use client";
import { useState } from "react";
import { useRouter } from "next/navigation";
import { createClient } from "@/utils/supabase/client";

// Admin accounts are email + password users created in the Supabase dashboard and listed in admin_user.
export default function Login() {
  const [email, setEmail] = useState("");
  const [password, setPassword] = useState("");
  const [error, setError] = useState("");
  const router = useRouter();

  async function submit(e: React.FormEvent) {
    e.preventDefault();
    const { error } = await createClient().auth.signInWithPassword({ email, password });
    if (error) setError(error.message);
    else router.replace("/");
  }

  return (
    <main style={{ maxWidth: 360 }}>
      <h1>Kavach Admin</h1>
      <form onSubmit={submit} className="card" style={{ display: "grid", gap: 8 }}>
        <input type="email" placeholder="Email" value={email} onChange={(e) => setEmail(e.target.value)} required autoComplete="username" />
        <input type="password" placeholder="Password" value={password} onChange={(e) => setPassword(e.target.value)} required autoComplete="current-password" />
        <button type="submit">Sign in</button>
        {error && <p className="err">{error}</p>}
      </form>
    </main>
  );
}

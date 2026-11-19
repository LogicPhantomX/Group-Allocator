# CSC Class 28 Group Allocation

Static site (plain HTML) backed by Supabase. No build step.

## Deploy on Vercel

**Option A: Dashboard**
1. Push this folder to a GitHub repo (index.html must be at the repo root).
2. On vercel.com choose Add New > Project and import the repo.
3. Framework Preset: Other. Leave Build Command and Output Directory empty. Click Deploy.

**Option B: CLI**
```
npm i -g vercel
vercel --prod
```

## Supabase checklist (before going live)
1. SQL Editor: run `supabase/01_supabase_setup.sql` (the registration and admin tables/functions must already exist).
2. `supabase/02_reset_export_migration_OPTIONAL.sql` is only for a clean restart of Round 1. It clears allocations, so do not run it after real draws.
3. Confirm the admin Auth user is in `public.admin_users`.
4. Authentication > URL Configuration: add your Vercel URL as the Site URL.

## Notes
- Only the Supabase URL and publishable key are in the page. Never add a service-role key.
- To run locally: `npx serve .` then open the printed URL (not file://).
- Security headers and a Content-Security-Policy are set in `vercel.json`. If you add a new external script or API host, add it to `script-src` / `connect-src`.

# Accessories Sahiwal

Private stock, purchase-cost, sales and profit management for **Accessories Sahiwal**
(mobile accessories — wholesale to shopkeepers, retail to customers).

* **App:** Flutter (Android + Web from one codebase)
* **Backend:** Supabase — PostgreSQL, Auth, Storage, one Edge Function
* **Design:** navy/blue theme with 3D depth — tilting cards (mouse or finger), extruded "AS" logo, raised buttons and a 3D loading screen
* **Security model:** every rule is enforced **in the database** (Row Level Security +
  `SECURITY DEFINER` functions). The app only hides buttons; it is never the guard.

> **Status: Stage 1 + Stage 2 of 5 implemented.** See [Implementation status](#implementation-status).

---

## Architecture

```
lib/
  app/                 router (role + private-area guards), theme, responsive shell
  core/                env config, error mapping, Money (Decimal), dates (Asia/Karachi), shared widgets
  features/
    auth/              login, profile/role, account, blocked screen
    private_area/      "locked folder": unlock, 10-min sliding expiry, password change
    products/          catalogue, code lookup, photos, product picker
    stock/             quantities, low stock, partner-safe movement history
    gallery/           photo gallery + customer display mode
    suppliers/         owner-only
    opening_stock/     owner-only
    purchases/         owner-only: draft → review → fully-paid posting
    valuation/         owner-only: average cost, stock value, ledger reconciliation
    users/             owner-only: partner accounts and permissions
    settings/          owner-only: branding, receipt details
supabase/
  migrations/          schema, constraints, RLS, posting functions (run in order)
  functions/admin-users/  Edge Function: create partner / reset password / block login
  tests/               SQL acceptance tests (run on plain PostgreSQL)
test/                  Dart unit tests (money, validators, image checks, purchase preview)
tool/setup_platforms.sh  generates android/ and web/ folders
```

Each feature follows `data/` (repository + Riverpod providers), `domain/` (models) and
`presentation/` (screens/widgets). State management: **Riverpod 3**. Navigation: **go_router**.
Money uses **Decimal** in the app and `numeric` in the database — never floating point.

### How privacy works

| Data | Where it lives | Who can read it |
|---|---|---|
| Products, selling prices, stock quantities, photos | `public` schema | Active owner + partner |
| Average cost, stock value, cost ledger | `private` schema | Owner **with unlocked private area** |
| Suppliers, purchases, payments, opening stock, audit log | `private` schema | Owner **with unlocked private area** |
| Private-password hash, unlock sessions | `internal` schema | Nobody via the API |

* Partner devices never receive cost or profit — those columns don't exist in any table or RPC a partner can read.
* The private area unlock is tied to the **current login session**, expires after **10 minutes of inactivity**, and is removed on sign-out.
* Revoking a partner's sessions blocks their existing tokens **even after token refresh** (checked against the original sign-in time).
* 5 wrong private-password attempts lock unlocking for 15 minutes.

### Costing rules implemented

* Moving weighted-average cost: `((old qty × old avg) + landed cost) / (old qty + received qty)`.
* Transport/other purchase costs are added to inventory cost, split by line value (by quantity if all lines are free), with a deterministic rounding remainder — never counted again as an expense.
* Opening stock creates an opening movement — no payment or expense.
* Purchases post only when **fully paid** (exact amount). Drafts never touch stock or money.
* Posting is atomic and idempotent (retries/double taps post once); stock rows are locked in a fixed order to avoid deadlocks.

---

## Setup (first time)

### 1. Supabase project (free tier is enough to start)

1. Create a project at <https://supabase.com> (choose a nearby region, e.g. Mumbai or Singapore).
2. **Authentication → Sign In / Providers → Email:** keep Email enabled, turn **off** "Allow new users to sign up".
3. **Project Settings → API → Exposed schemas:** add `private` (keep `public`). *Do not* add `internal`.
4. Apply the database migrations — either:
   * **CLI:** `supabase login`, `supabase init` (once — keeps the existing `supabase/` files), `supabase link --project-ref <ref>`, then `supabase db push`, **or**
   * **Dashboard:** open SQL Editor and run each file in `supabase/migrations/` in filename order.
5. Deploy the Edge Function (needed to create partner accounts):
   ```bash
   supabase functions deploy admin-users
   ```
6. Create the owner login: **Authentication → Users → Add user** (email + strong password, tick *Auto confirm*).
   Then in SQL Editor run once:
   ```sql
   select internal.bootstrap_owner('owner-email@example.com', 'Owner Name');
   ```

### 2. Flutter app

Requires Flutter 3.38 or newer.

**Windows (PowerShell):**

```powershell
powershell -ExecutionPolicy Bypass -File tool\setup_windows.ps1   # android/ folder + packages
# edit env\dev.json → your Supabase Project URL + anon key
# then press F5 in VS Code (launch.json included) or:
flutter run -d chrome --dart-define-from-file=env/dev.json
```

**macOS / Linux:**

```bash
./tool/setup_platforms.sh             # creates android/, adds Internet permission
cp env/example.json env/dev.json      # then paste your Project URL and anon/publishable key
flutter run -d chrome  --dart-define-from-file=env/dev.json   # laptop (web)
flutter run -d android --dart-define-from-file=env/dev.json   # phone
```

Release builds:

```bash
flutter build web --release --dart-define-from-file=env/prod.json
flutter build apk --release --dart-define-from-file=env/prod.json
```

Only the **anon/publishable** key goes in the app. Never put the service-role key in `env/`.

### 3. First sign-in

1. Sign in as the owner → **Private Area** → create the **private password** (different from the login password).
2. **Private Area → Users & permissions → Add partner.** Partners start with view-only sales & stock access.
3. Add products → enter **opening stock** with actual unit costs → record **purchases**.
4. When opening stock is complete: **Opening stock → Finished — close opening stock**.

---

## Tests

**Database (real PostgreSQL, 73 checks incl. privacy, idempotency, example B costing):**

```bash
PGHOST=localhost PGUSER=postgres ./supabase/tests/run_local.sh
```

Uses a throw-away database plus small local stand-ins for Supabase's `auth`/`storage` schemas.
Never run the test files against your real project.

**Flutter:**

```bash
flutter analyze
flutter test
```

---

## Owner notes

* **Forgot the private password?** In the Supabase SQL Editor (only you have dashboard access):
  ```sql
  delete from internal.private_secret;
  delete from internal.private_unlocks;
  ```
  Then sign in to the app and create a new private password. All old unlocks are gone.
* **Forgot login password?** Use *Forgot password?* on the login screen (set your Site URL and
  redirect URLs under Authentication → URL Configuration), or reset it in Authentication → Users.
* **Logo:** Settings → *Upload final logo*. Until then the "AS" monogram is used everywhere.
* **Photos:** max 5 per product, 5 MB each, JPEG/PNG/WebP. Photos are private (signed links, authenticated users only).
* **Customer display mode:** Gallery → *Customer view* — no stock counts, costs or suppliers; prices can be hidden.

### Partner notes

* You can see products, selling prices, stock quantities and the gallery.
* Sales screens arrive in Stage 3; the owner decides whether you can create sales or change prices.

---

## Implementation status

| Stage | Scope | Status |
|---|---|---|
| 1 Foundation | Schema, auth, roles, private unlock, navigation, branding | ✅ Done |
| 2 Inventory | Products/photos, opening stock, purchases, suppliers, stock ledger, valuation, users | ✅ Done |
| 3 Trading | Wholesale/retail sales, full-payment validation, receipts (A4/PDF), sales history | ⏳ Next |
| 4 Controls | Returns, voids, adjustments/damage, expenses, cash movements, audit viewer, reports | ⏳ |
| 5 Readiness | Exports, backup/restore, mobile polish, full acceptance run (AC-01…AC-18) | ⏳ |

**Verified so far:** AC-01 (accounts/revocation), AC-02 (partner privacy at table/RPC level),
AC-03 (private unlock + expiry), AC-04 (SKU uniqueness + lookup), AC-05 (opening stock/purchase reconcile),
AC-08 (drafts + idempotent posting, incl. 4 concurrent posts of one purchase), example B costing and the
purchase side of example A — all in `supabase/tests/`.

**Not yet verified:** the Flutter code has not been compiled in the build environment used for this stage
(Flutter SDK download was blocked there). Run `flutter analyze` and `flutter test` first and report any errors.

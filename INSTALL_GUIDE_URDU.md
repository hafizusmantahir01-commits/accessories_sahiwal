# Accessories Sahiwal — Install aur Update ka tareeqa

## Ek dafa ka kaam (pehli dafa)

1. **Netlify account**: https://app.netlify.com par Google se free sign up karein.
2. Project folder mein **DEPLOY.bat** par double-click karein.
   - App build hogi (2-4 minute).
   - Agar Node.js install hai: Netlify login khulega → "Create & configure a new project" chunein → naam e.g. `accessories-sahiwal`.
   - Agar Node.js nahi: `build` folder aur Netlify khul jayenge. Netlify mein **Add new project → Deploy manually** par `build\web` folder drag karein.
3. Aap ko link milega, jaise `https://accessories-sahiwal.netlify.app`.
4. Supabase → **Authentication → URL Configuration → Site URL** mein yahi link daal kar Save karein.

## Laptop par install
Chrome mein link kholein → address bar ke daayen **Install** icon (ya ⋮ → "Install Accessories Sahiwal").
Desktop par "AS" icon wali app ban jayegi.

## Mobile par install (aap aur partner dono)
Android Chrome mein link kholein → ⋮ → **Add to Home screen / Install app**.
iPhone Safari → Share → **Add to Home Screen**.

## Update kaise karein (jab bhi nayi files milein)
1. Nayi files project mein replace karein (`env\dev.json` ko mat chhedein).
2. Agar SQL file bhi mili ho to Supabase SQL Editor mein ek dafa Run karein.
3. **DEPLOY.bat** par double-click karein.
   (Node.js na ho to Netlify → Deploys mein naya `build\web` folder drag karein.)
4. Bas — laptop, aap ka mobile aur partner sab ko agli dafa app kholne par nayi version mil jayegi.
   Purani nazar aaye to app band karke dobara kholein ya ek dafa refresh karein.

Aap ka data (products, stock, photos, purchases) Supabase mein rehta hai — update se kuch delete nahi hota.

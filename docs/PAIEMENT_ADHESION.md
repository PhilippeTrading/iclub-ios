# Adhésion depuis l'app iOS — ce qu'il faut côté serveur

L'app iOS affiche les formules (`membership_formulas`, `actif = true`, triées par `ordre`) et propose trois façons de payer :

| Moyen | Où | Activation de l'adhésion |
|---|---|---|
| Carte (Apple Pay compris) | Page Stripe Checkout | À la confirmation Stripe, en quelques secondes |
| Prélèvement SEPA | Page Stripe Checkout | À la confirmation du prélèvement, sous quelques jours |
| Au club | Secrétariat | Par l'administration, à réception du règlement |

L'app est prête. Tant que ce qui suit n'existe pas, elle dit « Le paiement en ligne n'est pas encore activé par le club » et propose de régler au club.

Règles de sécurité qui guident tout le reste :
- la **clé secrète Stripe ne quitte jamais le serveur** ; l'app ne voit ni carte ni IBAN (page Stripe hébergée) ;
- **seul le serveur crée l'adhésion**, après confirmation de Stripe : un membre n'a pas le droit d'écrire dans `memberships`, et cela ne change pas ;
- le prix vient toujours de `membership_formulas.prix`, jamais de ce que l'app envoie.

---

## 1. Fonction `adhesion-paiement` (Supabase Edge Function)

Appelée par l'app avec le jeton de la session (`Authorization: Bearer <access_token>`).

**Requête** (`POST /functions/v1/adhesion-paiement`) :

```json
{
  "formule_id": "uuid",
  "mode": "carte" | "sepa",
  "success_url": "iclub://adhesion/succes",
  "cancel_url": "iclub://adhesion/annule"
}
```

**Réponse 200** :

```json
{ "checkout_url": "https://checkout.stripe.com/c/pay/..." }
```

**Erreurs** : `503` si Stripe n'est pas configuré pour ce club (l'app propose alors « Au club ») ; `400` avec `{ "message": "…" }` en français pour un refus lisible (formule inactive, adhésion déjà à jour…).

**Ce que fait la fonction** :
1. Lit l'utilisateur depuis le jeton ; retrouve sa ligne `club_members` et le club.
2. Vérifie que la formule appartient à ce club et qu'elle est `actif`.
3. Refuse si une adhésion `a_jour` couvre déjà aujourd'hui.
4. Crée une **Checkout Session** Stripe :
   - `mode: "payment"`, montant = `round(prix * 100)` en `eur`, libellé = `nom` de la formule ;
   - `payment_method_types`: `["card"]` pour `carte` (Apple Pay s'affiche de lui-même sur la page Checkout), `["sepa_debit"]` pour `sepa` ;
   - `customer_email` = e-mail du profil ;
   - `metadata`: `club_id`, `club_member_id`, `profile_id`, `formule_id` ;
   - `success_url` / `cancel_url` : ceux reçus, **seulement** s'ils commencent par `iclub://adhesion/` (sinon valeurs par défaut).
5. Renvoie `session.url`.

## 2. Webhook Stripe `stripe-webhook`

Vérifier la signature (`STRIPE_WEBHOOK_SECRET`). Événements :
- `checkout.session.completed` avec `payment_status = "paid"` (carte) ;
- `checkout.session.async_payment_succeeded` (SEPA, quelques jours plus tard) ;
- `checkout.session.async_payment_failed` (SEPA refusé) : ne rien créer, éventuellement prévenir le membre.

À la réussite, **une seule fois par session** (idempotence sur l'identifiant de session Stripe) :
1. insérer dans `memberships` : `club_id`, `club_member_id`, `formule` = nom de la formule, `montant` = prix, `sports_inclus` de la formule, `date_debut` = aujourd'hui, `date_fin` = fin de la saison du club, `statut = 'a_jour'` ;
2. passer `club_members.role` de `visiteur` à `adherent` si c'est le cas ;
3. émettre le reçu par `emettre_document` (type `recu`, mode de paiement « En ligne »), pour qu'il apparaisse dans « Reçus et factures » de l'app.

Décision à prendre par le club : **la date de fin de saison** (ex. 31 août). Elle mérite une colonne sur `clubs` plutôt qu'une valeur codée.

Secrets à poser : `STRIPE_SECRET_KEY`, `STRIPE_WEBHOOK_SECRET`.

## 3. « Au club » : enregistrer la demande

Pour que le secrétariat voie qui veut adhérer, l'app appelle `demander_adhesion(p_formule_id uuid) → uuid`. Si elle n'existe pas, l'app affiche simplement l'adresse, le téléphone et les moyens de paiement du comptoir.

```sql
create table if not exists public.demandes_adhesion (
  id uuid primary key default gen_random_uuid(),
  club_id uuid not null references public.clubs (id) on delete cascade,
  profile_id uuid not null references public.profiles (id) on delete cascade,
  formule_id uuid not null references public.membership_formulas (id) on delete cascade,
  statut text not null default 'en_attente' check (statut in ('en_attente', 'traitee', 'annulee')),
  created_at timestamptz not null default now()
);

alter table public.demandes_adhesion enable row level security;

create policy "demandes_lecture" on public.demandes_adhesion for select
  using (profile_id = auth.uid() or public.is_club_admin(club_id));
create policy "demandes_admin" on public.demandes_adhesion for update
  using (public.is_club_admin(club_id)) with check (public.is_club_admin(club_id));

create or replace function public.demander_adhesion(p_formule_id uuid)
returns uuid language plpgsql security definer set search_path = public as $$
declare f record; nouvelle uuid;
begin
  if auth.uid() is null then raise exception 'Authentification requise' using errcode = 'P0001'; end if;
  select * into f from public.membership_formulas where id = p_formule_id and actif;
  if not found then raise exception 'Cette formule n''est plus proposée' using errcode = 'P0001'; end if;
  if f.club_id not in (select public.current_club_ids()) then
    raise exception 'Formule d''un autre club' using errcode = 'P0001';
  end if;
  -- Une seule demande en attente par personne : la dernière remplace les autres.
  update public.demandes_adhesion set statut = 'annulee'
  where profile_id = auth.uid() and club_id = f.club_id and statut = 'en_attente';
  insert into public.demandes_adhesion (club_id, profile_id, formule_id)
  values (f.club_id, auth.uid(), p_formule_id) returning id into nouvelle;
  return nouvelle;
end $$;
grant execute on function public.demander_adhesion(uuid) to authenticated;
```

Côté web, l'administration aurait une liste « Demandes d'adhésion » à traiter.

## 4. App Store

Une adhésion de club donne accès à un service réel (terrains, cours) consommé hors de l'app : le paiement peut passer par Stripe, sans achat intégré Apple (règle 3.1.5). À préciser dans les notes de revue.

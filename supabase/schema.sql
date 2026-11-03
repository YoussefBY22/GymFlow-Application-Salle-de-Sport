-- GymFlow : fonction « Amis » (Supabase / Postgres)
--
-- À coller dans Supabase -> SQL Editor -> New query -> Run.
-- Le script peut être rejoué sans danger (il ne détruit aucune donnée).
--
-- Principes :
--  * aucune adresse e-mail n'est stockée dans les tables publiques : seulement
--    son empreinte SHA-256 (pour retrouver un ami à partir de son e-mail) ;
--  * le client ne peut ni créer ni modifier une amitié ou un « poke » en
--    direct : tout passe par des fonctions qui vérifient les règles ;
--  * chaque table a des règles d'accès par ligne (RLS) : on ne voit que soi
--    et ses amis acceptés.

-- ---------------------------------------------------------------- Tables

create table if not exists public.profiles (
  id uuid primary key references auth.users (id) on delete cascade,
  display_name text not null check (char_length(display_name) between 1 and 60),
  avatar_url text check (avatar_url is null or char_length(avatar_url) <= 500),
  -- Empreinte de l'e-mail normalisé ; calculée par le serveur, jamais par le client.
  email_hash text not null unique,
  -- La fonction Amis est facultative : désactivée par défaut.
  friends_enabled boolean not null default false,
  -- Signal de présence : « en ligne » = vu il y a moins de ~75 secondes.
  last_seen timestamptz not null default 'epoch',
  created_at timestamptz not null default now()
);

create table if not exists public.friendships (
  id uuid primary key default gen_random_uuid(),
  requester uuid not null references public.profiles (id) on delete cascade,
  addressee uuid not null references public.profiles (id) on delete cascade,
  -- pending = en attente ; accepted = amis ; declined = refusée (garde la
  -- trace pour que le demandeur ne puisse pas relancer sans fin).
  status text not null default 'pending'
    check (status in ('pending', 'accepted', 'declined')),
  created_at timestamptz not null default now(),
  responded_at timestamptz,
  check (requester <> addressee)
);

-- Une seule ligne par paire de personnes, quel que soit le sens.
create unique index if not exists friendships_pair_idx
  on public.friendships (least(requester, addressee), greatest(requester, addressee));
create index if not exists friendships_addressee_idx on public.friendships (addressee);
create index if not exists friendships_requester_idx on public.friendships (requester);

create table if not exists public.pokes (
  id uuid primary key default gen_random_uuid(),
  sender uuid not null references public.profiles (id) on delete cascade,
  recipient uuid not null references public.profiles (id) on delete cascade,
  -- Messages prédéfinis (le texte est dans l'application) : rien à modérer.
  kind text not null check (kind in ('encourage', 'challenge', 'miss_you')),
  created_at timestamptz not null default now(),
  seen_at timestamptz,
  check (sender <> recipient)
);
create index if not exists pokes_recipient_idx on public.pokes (recipient, created_at desc);
create index if not exists pokes_sender_idx on public.pokes (sender, created_at desc);

-- --------------------------------------------- Création du profil à l'inscription

create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  insert into public.profiles (id, display_name, email_hash)
  values (
    new.id,
    left(
      coalesce(nullif(trim(new.raw_user_meta_data ->> 'display_name'), ''), 'Membre GymFlow'),
      60
    ),
    encode(sha256(convert_to(lower(trim(coalesce(new.email, new.id::text))), 'utf8')), 'hex')
  )
  on conflict do nothing;
  return new;
end;
$$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();

-- ------------------------------------------------------------- Outils internes

create or replace function public.are_friends(a uuid, b uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1
    from public.friendships f
    where f.status = 'accepted'
      and ((f.requester = a and f.addressee = b) or (f.requester = b and f.addressee = a))
  );
$$;

-- ------------------------------------------------------- Règles d'accès (RLS)

alter table public.profiles enable row level security;
alter table public.friendships enable row level security;
alter table public.pokes enable row level security;

-- Droits de base : on part de zéro puis on ouvre le strict nécessaire.
revoke all on public.profiles from anon, authenticated;
revoke all on public.friendships from anon, authenticated;
revoke all on public.pokes from anon, authenticated;

-- Profils : on se voit soi-même et ses amis acceptés, personne d'autre.
grant select on public.profiles to authenticated;
-- Le client ne peut modifier que ces colonnes (jamais email_hash, ni last_seen :
-- la présence passe par heartbeat(), horodatée par le serveur).
grant update (display_name, avatar_url, friends_enabled) on public.profiles to authenticated;

drop policy if exists profiles_select on public.profiles;
create policy profiles_select on public.profiles
  for select to authenticated
  using (id = (select auth.uid()) or public.are_friends((select auth.uid()), id));

drop policy if exists profiles_update_own on public.profiles;
create policy profiles_update_own on public.profiles
  for update to authenticated
  using (id = (select auth.uid()))
  with check (id = (select auth.uid()));

-- Amitiés : visibles par les deux personnes ; supprimables (rompre une
-- amitié, annuler sa propre demande). Création et réponse par fonctions.
grant select, delete on public.friendships to authenticated;

drop policy if exists friendships_select on public.friendships;
create policy friendships_select on public.friendships
  for select to authenticated
  using (requester = (select auth.uid()) or addressee = (select auth.uid()));

drop policy if exists friendships_delete on public.friendships;
create policy friendships_delete on public.friendships
  for delete to authenticated
  using (
    (status = 'accepted'
      and (requester = (select auth.uid()) or addressee = (select auth.uid())))
    or (status = 'pending' and requester = (select auth.uid()))
  );

-- Pokes : lisibles par l'expéditeur et le destinataire ; le destinataire
-- peut seulement marquer « vu ». L'envoi passe par send_poke().
grant select on public.pokes to authenticated;
grant update (seen_at) on public.pokes to authenticated;

drop policy if exists pokes_select on public.pokes;
create policy pokes_select on public.pokes
  for select to authenticated
  using (recipient = (select auth.uid()) or sender = (select auth.uid()));

drop policy if exists pokes_mark_seen on public.pokes;
create policy pokes_mark_seen on public.pokes
  for update to authenticated
  using (recipient = (select auth.uid()))
  with check (recipient = (select auth.uid()));

-- ------------------------------------------------------------------ Fonctions

-- Envoie une demande d'ami à partir d'une adresse e-mail.
-- Répond toujours « ok » : on ne révèle jamais si une adresse a un compte.
create or replace function public.send_friend_request(p_email text)
returns text
language plpgsql
security definer
set search_path = ''
as $$
declare
  me uuid := auth.uid();
  v_hash text;
  v_target uuid;
begin
  if me is null then
    raise exception 'not_authenticated';
  end if;
  if not exists (select 1 from public.profiles where id = me and friends_enabled) then
    raise exception 'friends_disabled';
  end if;
  if p_email is null or char_length(trim(p_email)) < 3 or char_length(p_email) > 254 then
    raise exception 'invalid_email';
  end if;
  -- Anti-spam : 10 demandes par heure au plus.
  if (select count(*) from public.friendships
        where requester = me and created_at > now() - interval '1 hour') >= 10 then
    raise exception 'rate_limited';
  end if;

  v_hash := encode(sha256(convert_to(lower(trim(p_email)), 'utf8')), 'hex');
  select id into v_target
    from public.profiles
    where email_hash = v_hash and friends_enabled and id <> me;
  if v_target is null then
    return 'ok';
  end if;

  -- Une demande inverse est déjà en attente : on l'accepte (les deux le veulent).
  update public.friendships
     set status = 'accepted', responded_at = now()
   where requester = v_target and addressee = me and status = 'pending';
  if found then
    return 'ok';
  end if;

  -- Déjà amis, déjà demandé ou refusé : rien à faire (et rien à révéler).
  insert into public.friendships (requester, addressee)
  values (me, v_target)
  on conflict do nothing;
  return 'ok';
end;
$$;

-- Accepte ou refuse une demande reçue.
create or replace function public.respond_friend_request(p_id uuid, p_accept boolean)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  update public.friendships
     set status = case when p_accept then 'accepted' else 'declined' end,
         responded_at = now()
   where id = p_id and addressee = auth.uid() and status = 'pending';
  if not found then
    raise exception 'not_found';
  end if;
end;
$$;

-- Envoie un « poke » à un ami (message prédéfini).
create or replace function public.send_poke(p_to uuid, p_kind text)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  me uuid := auth.uid();
  v_id uuid;
begin
  if me is null then
    raise exception 'not_authenticated';
  end if;
  if p_kind not in ('encourage', 'challenge', 'miss_you') then
    raise exception 'invalid_kind';
  end if;
  if not public.are_friends(me, p_to) then
    raise exception 'not_friends';
  end if;
  if not exists (select 1 from public.profiles where id = me and friends_enabled)
     or not exists (select 1 from public.profiles where id = p_to and friends_enabled) then
    raise exception 'friends_disabled';
  end if;
  -- Anti-harcèlement : 1 poke par heure et par ami, 30 par jour au total.
  if exists (select 1 from public.pokes
              where sender = me and recipient = p_to
                and created_at > now() - interval '1 hour') then
    raise exception 'rate_limited';
  end if;
  if (select count(*) from public.pokes
        where sender = me and created_at > now() - interval '1 day') >= 30 then
    raise exception 'rate_limited';
  end if;

  insert into public.pokes (sender, recipient, kind)
  values (me, p_to, p_kind)
  returning id into v_id;
  return v_id;
end;
$$;

-- Demandes reçues et en attente (nom et photo seulement : on ne montre pas
-- la présence de quelqu'un qui n'est pas encore ami).
create or replace function public.my_pending_requests()
returns table (
  id uuid,
  from_name text,
  avatar_url text,
  created_at timestamptz
)
language sql
stable
security definer
set search_path = ''
as $$
  select f.id, p.display_name, p.avatar_url, f.created_at
  from public.friendships f
  join public.profiles p on p.id = f.requester
  where f.addressee = auth.uid() and f.status = 'pending'
  order by f.created_at desc;
$$;

-- Seuls les utilisateurs connectés peuvent appeler ces fonctions.
revoke all on function public.send_friend_request(text) from public, anon;
revoke all on function public.respond_friend_request(uuid, boolean) from public, anon;
revoke all on function public.send_poke(uuid, text) from public, anon;
revoke all on function public.my_pending_requests() from public, anon;
revoke all on function public.are_friends(uuid, uuid) from public, anon;
grant execute on function public.send_friend_request(text) to authenticated;
grant execute on function public.respond_friend_request(uuid, boolean) to authenticated;
grant execute on function public.send_poke(uuid, text) to authenticated;
grant execute on function public.my_pending_requests() to authenticated;
grant execute on function public.are_friends(uuid, uuid) to authenticated;

-- ------------------------------------------------- Présence et départ

-- Signal de présence, horodaté par le serveur. Renvoie l'heure du serveur.
create or replace function public.heartbeat()
returns timestamptz
language plpgsql
security definer
set search_path = ''
as $$
begin
  update public.profiles
     set last_seen = now()
   where id = auth.uid() and friends_enabled;
  return now();
end;
$$;

-- Passage hors ligne immédiat (déconnexion, application mise en arrière-plan).
create or replace function public.go_offline()
returns void
language sql
security definer
set search_path = ''
as $$
  update public.profiles set last_seen = 'epoch' where id = auth.uid();
$$;

-- Mes amis, avec leur dernier signal de présence et l'heure du serveur.
drop function if exists public.my_friends();
create function public.my_friends()
returns table (
  id uuid,
  display_name text,
  avatar_url text,
  last_seen timestamptz,
  since timestamptz,
  server_now timestamptz
)
language sql
stable
security definer
set search_path = ''
as $$
  select p.id, p.display_name, p.avatar_url, p.last_seen,
         coalesce(f.responded_at, f.created_at), now()
  from public.friendships f
  join public.profiles p
    on p.id = case when f.requester = auth.uid() then f.addressee else f.requester end
  where f.status = 'accepted'
    and (f.requester = auth.uid() or f.addressee = auth.uid())
  order by p.display_name;
$$;

-- Quitter la fonction Amis : efface mes amitiés, demandes et pokes, et me
-- rend invisible. (Droit à l'effacement ; appelé quand on désactive la
-- fonction ou supprime son compte.)
create or replace function public.leave_friends()
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  me uuid := auth.uid();
begin
  if me is null then
    raise exception 'not_authenticated';
  end if;
  delete from public.pokes where sender = me or recipient = me;
  delete from public.friendships where requester = me or addressee = me;
  update public.profiles set friends_enabled = false, last_seen = 'epoch' where id = me;
end;
$$;

revoke all on function public.heartbeat() from public, anon;
revoke all on function public.go_offline() from public, anon;
revoke all on function public.my_friends() from public, anon;
revoke all on function public.leave_friends() from public, anon;
grant execute on function public.heartbeat() to authenticated;
grant execute on function public.go_offline() to authenticated;
grant execute on function public.my_friends() to authenticated;
grant execute on function public.leave_friends() to authenticated;

-- ------------------------------------------------------------------- Temps réel
-- Les changements de ces tables sont diffusés aux applications connectées
-- (les règles d'accès ci-dessus s'appliquent : chacun ne reçoit que ce qu'il a
-- le droit de voir).

do $$
begin
  alter publication supabase_realtime add table public.profiles;
exception when duplicate_object then null;
end $$;

do $$
begin
  alter publication supabase_realtime add table public.friendships;
exception when duplicate_object then null;
end $$;

do $$
begin
  alter publication supabase_realtime add table public.pokes;
exception when duplicate_object then null;
end $$;

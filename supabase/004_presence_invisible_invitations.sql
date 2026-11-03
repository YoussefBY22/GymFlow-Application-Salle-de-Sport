-- GymFlow : mise à jour n°4 de la base (présence fiable, mode invisible,
-- invitations envoyées)
--
-- À coller dans Supabase -> SQL Editor -> New query -> Run, APRES 002 et 003.
-- Rejouable sans danger.
--
-- Installation neuve : exécuter schema.sql, puis les fichiers 004 et suivants
-- dans l'ordre (schema.sql contient déjà 002 et 003).
--
-- Changements :
--  * présence : une colonne `online` (vrai tant que la personne utilise
--    l'application) ET `last_seen` (dernier signal, pour « Vu il y a 5 min ») ;
--    quitter l'application met `online` à faux SANS effacer `last_seen` ;
--  * mode « Apparaître hors ligne » : réglage privé (table user_settings,
--    visible de soi seul) ; les amis voient « Hors ligne » sans « Vu il y a » ;
--  * invitations envoyées en attente, avec annulation ;
--  * l'envoi d'une invitation dit maintenant « aucun compte » si l'adresse
--    n'a pas de compte avec la fonction Amis (choix assumé : voir
--    SECURITE_CONFIDENTIALITE.md ; la limite de 10 invitations par heure reste).

-- ---------------------------------------------------------- Présence publique

alter table public.profiles add column if not exists online boolean not null default false;

-- ------------------------------------------------- Réglages privés (soi seul)

create table if not exists public.user_settings (
  user_id uuid primary key references public.profiles (id) on delete cascade,
  -- Apparaître hors ligne : les amis ne voient jamais « en ligne » ni « vu ».
  invisible boolean not null default false,
  -- Dernière activité réelle (même en mode invisible) : servira à décider
  -- d'envoyer une notification push quand la personne n'utilise pas l'appli.
  last_active timestamptz not null default 'epoch',
  updated_at timestamptz not null default now()
);

alter table public.user_settings enable row level security;
revoke all on public.user_settings from anon, authenticated;
grant select on public.user_settings to authenticated;

drop policy if exists user_settings_select on public.user_settings;
create policy user_settings_select on public.user_settings
  for select to authenticated
  using (user_id = (select auth.uid()));

-- ------------------------------------------------------------------ Présence

create or replace function public.heartbeat()
returns timestamptz
language plpgsql
security definer
set search_path = ''
as $$
declare
  me uuid := auth.uid();
  v_invisible boolean;
begin
  if me is null then
    raise exception 'not_authenticated';
  end if;
  insert into public.user_settings (user_id) values (me) on conflict do nothing;
  update public.user_settings
     set last_active = now()
   where user_id = me
  returning invisible into v_invisible;
  if not coalesce(v_invisible, false) then
    update public.profiles
       set online = true, last_seen = now()
     where id = me and friends_enabled;
  end if;
  return now();
end;
$$;

-- Hors ligne tout de suite (déconnexion, application en arrière-plan) : on
-- garde la date du dernier signal pour afficher « Vu il y a 5 min ».
create or replace function public.go_offline()
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  me uuid := auth.uid();
begin
  if me is null then
    return;
  end if;
  update public.user_settings set last_active = 'epoch' where user_id = me;
  update public.profiles set online = false where id = me and online;
end;
$$;

-- Mode « Apparaître hors ligne ».
create or replace function public.set_invisible(p_on boolean)
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
  insert into public.user_settings (user_id, invisible)
  values (me, p_on)
  on conflict (user_id) do update set invisible = excluded.invisible, updated_at = now();
  if p_on then
    -- Rien ne doit rester visible : ni « en ligne », ni « vu il y a ».
    update public.profiles set online = false, last_seen = 'epoch' where id = me;
  else
    update public.profiles set online = true, last_seen = now()
     where id = me and friends_enabled;
  end if;
end;
$$;

create or replace function public.my_settings()
returns table (invisible boolean)
language sql
stable
security definer
set search_path = ''
as $$
  select coalesce((select s.invisible from public.user_settings s where s.user_id = auth.uid()), false);
$$;

-- Mes amis : présence = `online` ET signal récent (un téléphone coupé sans
-- prévenir ne reste pas « en ligne » : le client compare aussi last_seen).
drop function if exists public.my_friends();
create function public.my_friends()
returns table (
  id uuid,
  display_name text,
  avatar_url text,
  online boolean,
  last_seen timestamptz,
  since timestamptz,
  server_now timestamptz
)
language sql
stable
security definer
set search_path = ''
as $$
  select p.id, p.display_name, p.avatar_url, p.online, p.last_seen,
         coalesce(f.responded_at, f.created_at), now()
  from public.friendships f
  join public.profiles p
    on p.id = case when f.requester = auth.uid() then f.addressee else f.requester end
  where f.status = 'accepted'
    and (f.requester = auth.uid() or f.addressee = auth.uid())
  order by p.display_name;
$$;

-- --------------------------------------------------------------- Invitations

-- Envoie une invitation. Renvoie : sent | accepted | already_friends | already_pending.
-- Erreur `no_account` si aucune personne avec la fonction Amis n'a cette adresse.
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
  v_status text;
  v_requester uuid;
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
  -- Anti-abus : 10 invitations par heure au plus.
  if (select count(*) from public.friendships
        where requester = me and created_at > now() - interval '1 hour') >= 10 then
    raise exception 'rate_limited';
  end if;

  v_hash := encode(sha256(convert_to(lower(trim(p_email)), 'utf8')), 'hex');
  select id into v_target
    from public.profiles
    where email_hash = v_hash and friends_enabled and id <> me;
  if v_target is null then
    raise exception 'no_account';
  end if;

  select f.status, f.requester into v_status, v_requester
    from public.friendships f
    where (f.requester = me and f.addressee = v_target)
       or (f.requester = v_target and f.addressee = me);

  if v_status = 'accepted' then
    return 'already_friends';
  end if;
  if v_status = 'pending' then
    if v_requester = v_target then
      -- Demande croisée : les deux le veulent, c'est accepté.
      update public.friendships
         set status = 'accepted', responded_at = now()
       where requester = v_target and addressee = me and status = 'pending';
      return 'accepted';
    end if;
    return 'already_pending';
  end if;
  if v_status = 'declined' then
    -- Une invitation refusée reste « en attente » pour son auteur (discrétion).
    return 'sent';
  end if;

  insert into public.friendships (requester, addressee) values (me, v_target);
  return 'sent';
end;
$$;

-- Invitations que j'ai envoyées et qui n'ont pas abouti. Une invitation
-- refusée y reste affichée « en attente » : l'auteur n'est pas informé du refus.
create or replace function public.my_sent_requests()
returns table (
  id uuid,
  to_name text,
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
  join public.profiles p on p.id = f.addressee
  where f.requester = auth.uid() and f.status in ('pending', 'declined')
  order by f.created_at desc;
$$;

-- Annule une invitation envoyée (en attente ou refusée).
create or replace function public.cancel_friend_request(p_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  delete from public.friendships
   where id = p_id and requester = auth.uid() and status in ('pending', 'declined');
  if not found then
    raise exception 'not_found';
  end if;
end;
$$;

-- Quitter la fonction Amis : on efface aussi les réglages privés.
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
  delete from public.user_settings where user_id = me;
  update public.profiles
     set friends_enabled = false, online = false, last_seen = 'epoch'
   where id = me;
end;
$$;

-- ---------------------------------------------------------------- Droits

revoke all on function public.heartbeat() from public, anon;
revoke all on function public.go_offline() from public, anon;
revoke all on function public.set_invisible(boolean) from public, anon;
revoke all on function public.my_settings() from public, anon;
revoke all on function public.my_friends() from public, anon;
revoke all on function public.send_friend_request(text) from public, anon;
revoke all on function public.my_sent_requests() from public, anon;
revoke all on function public.cancel_friend_request(uuid) from public, anon;
revoke all on function public.leave_friends() from public, anon;
grant execute on function public.heartbeat() to authenticated;
grant execute on function public.go_offline() to authenticated;
grant execute on function public.set_invisible(boolean) to authenticated;
grant execute on function public.my_settings() to authenticated;
grant execute on function public.my_friends() to authenticated;
grant execute on function public.send_friend_request(text) to authenticated;
grant execute on function public.my_sent_requests() to authenticated;
grant execute on function public.cancel_friend_request(uuid) to authenticated;
grant execute on function public.leave_friends() to authenticated;

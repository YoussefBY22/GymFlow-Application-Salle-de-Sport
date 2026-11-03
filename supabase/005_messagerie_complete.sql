-- GymFlow : mise à jour n°5 de la base — MESSAGERIE COMPLÈTE (versions 2.5 à 2.8)
--
-- À coller en UNE SEULE fois dans Supabase -> SQL Editor -> New query -> Run,
-- APRES 004. Un seul script pour toutes les étapes :
--   2.5  messagerie 1 contre 1 chiffrée dans la base, « vu », « en train
--        d'écrire », archivage, suppression, silence, blocage, signalements ;
--   2.6  partage (séance, workout, exercice, programme) : un message de type
--        « share » dont le contenu est chiffré comme le reste ;
--   2.7  (emojis : rien côté base) ;
--   2.8  notifications push quand l'application est fermée.
--
-- Le script est entouré de begin/commit : en cas d'erreur, RIEN n'est
-- appliqué, et on peut le relancer après correction. Il est aussi rejouable
-- sans danger.
--
-- Chiffrement des messages : le texte est chiffré dans la base (pgcrypto,
-- AES-256) avec une clé tirée au hasard et rangée dans le schéma privé
-- `private`, inaccessible à l'application. Dans les tables, on ne voit que du
-- texte illisible. Ce n'est PAS un chiffrement de bout en bout : le
-- propriétaire du projet Supabase pourrait déchiffrer avec la clé ; seuls les
-- deux amis (et les signalements) peuvent lire un message dans l'application.

begin;

-- ============================================================== Préparation

create extension if not exists pgcrypto with schema extensions;

create schema if not exists private;
revoke all on schema private from public, anon, authenticated;

-- Secrets du serveur (clé de chiffrement, adresse de la fonction push).
create table if not exists private.app_secrets (
  name text primary key,
  value text not null
);
alter table private.app_secrets enable row level security;
revoke all on private.app_secrets from public, anon, authenticated;

insert into private.app_secrets (name, value)
values ('messages_key', encode(extensions.gen_random_bytes(32), 'hex'))
on conflict (name) do nothing;

-- Adresses des administrateurs de GymFlow (empreinte SHA-256, comme les profils).
create table if not exists private.admin_emails (
  email_hash text primary key
);
alter table private.admin_emails enable row level security;
revoke all on private.admin_emails from public, anon, authenticated;

insert into private.admin_emails (email_hash)
values (encode(sha256(convert_to('admin@gymflow.tn', 'utf8')), 'hex'))
on conflict do nothing;

create or replace function private.key()
returns text
language sql
stable
security definer
set search_path = ''
as $$
  select value from private.app_secrets where name = 'messages_key';
$$;

create or replace function private.enc(p text)
returns bytea
language sql
security definer
set search_path = ''
as $$
  select extensions.pgp_sym_encrypt(p, private.key(), 'cipher-algo=aes256');
$$;

create or replace function private.dec(p bytea)
returns text
language sql
stable
security definer
set search_path = ''
as $$
  select extensions.pgp_sym_decrypt(p, private.key());
$$;

revoke all on function private.key() from public, anon, authenticated;
revoke all on function private.enc(text) from public, anon, authenticated;
revoke all on function private.dec(bytea) from public, anon, authenticated;

-- L'utilisateur connecté est-il administrateur de GymFlow ?
create or replace function public.is_admin()
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1
    from public.profiles p
    join private.admin_emails a on a.email_hash = p.email_hash
    where p.id = auth.uid()
  );
$$;
revoke all on function public.is_admin() from public, anon;
grant execute on function public.is_admin() to authenticated;

-- ======================================================== Réglages de la messagerie

alter table public.user_settings add column if not exists hide_read_receipts boolean not null default false;
alter table public.user_settings add column if not exists hide_typing boolean not null default false;
alter table public.user_settings add column if not exists push_preview boolean not null default true;

drop function if exists public.my_settings();
create function public.my_settings()
returns table (
  invisible boolean,
  hide_read_receipts boolean,
  hide_typing boolean,
  push_preview boolean,
  is_admin boolean
)
language sql
stable
security definer
set search_path = ''
as $$
  select coalesce(s.invisible, false),
         coalesce(s.hide_read_receipts, false),
         coalesce(s.hide_typing, false),
         coalesce(s.push_preview, true),
         public.is_admin()
  from (select 1) d
  left join public.user_settings s on s.user_id = auth.uid();
$$;

-- « Vu », « en train d'écrire » et aperçu des notifications. Règle comme
-- WhatsApp : si je masque les miens, je ne vois plus ceux des autres.
create or replace function public.set_chat_settings(
  p_hide_receipts boolean,
  p_hide_typing boolean,
  p_push_preview boolean
)
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
  insert into public.user_settings (user_id, hide_read_receipts, hide_typing, push_preview)
  values (me, p_hide_receipts, p_hide_typing, p_push_preview)
  on conflict (user_id) do update
    set hide_read_receipts = excluded.hide_read_receipts,
        hide_typing = excluded.hide_typing,
        push_preview = excluded.push_preview,
        updated_at = now();
end;
$$;

-- ================================================================== Tables

create table if not exists public.messages (
  id uuid primary key default gen_random_uuid(),
  sender uuid not null references public.profiles (id) on delete cascade,
  recipient uuid not null references public.profiles (id) on delete cascade,
  -- text = message écrit ; share = carte partagée (séance, workout…).
  kind text not null default 'text' check (kind in ('text', 'share')),
  -- Contenu CHIFFRÉ (illisible dans la base).
  body bytea not null,
  created_at timestamptz not null default now(),
  -- Supprimé pour tout le monde : le contenu est effacé, la trace reste.
  deleted_at timestamptz,
  -- Supprimé « pour moi » : identifiants des personnes qui ne le voient plus.
  deleted_for uuid[] not null default '{}',
  check (sender <> recipient)
);
create index if not exists messages_pair_idx
  on public.messages (least(sender, recipient), greatest(sender, recipient), created_at desc);
create index if not exists messages_recipient_idx
  on public.messages (recipient, created_at desc);

-- État d'une discussion, propre à chaque personne.
create table if not exists public.conversation_state (
  user_id uuid not null references public.profiles (id) on delete cascade,
  friend_id uuid not null references public.profiles (id) on delete cascade,
  archived boolean not null default false,
  muted boolean not null default false,
  -- « Supprimer la discussion » = pour moi seulement : on masque jusqu'à cette date.
  cleared_at timestamptz not null default 'epoch',
  last_read_at timestamptz not null default 'epoch',
  primary key (user_id, friend_id)
);

-- « Vu » : la dernière fois que `reader` a lu la discussion avec `peer`.
create table if not exists public.read_marks (
  reader uuid not null references public.profiles (id) on delete cascade,
  peer uuid not null references public.profiles (id) on delete cascade,
  read_at timestamptz not null default now(),
  primary key (reader, peer)
);

-- « En train d'écrire » : `user_id` écrit à `peer_id` jusqu'à `until`.
create table if not exists public.typing_state (
  user_id uuid not null references public.profiles (id) on delete cascade,
  peer_id uuid not null references public.profiles (id) on delete cascade,
  until timestamptz not null default now(),
  primary key (user_id, peer_id)
);

-- Blocages : visibles par la personne qui bloque, jamais par l'autre ni par l'admin.
create table if not exists public.blocks (
  blocker uuid not null references public.profiles (id) on delete cascade,
  blocked uuid not null references public.profiles (id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (blocker, blocked),
  check (blocker <> blocked)
);

-- Signalements, lus par l'administrateur seulement.
create table if not exists public.reports (
  id uuid primary key default gen_random_uuid(),
  reporter uuid not null references public.profiles (id) on delete cascade,
  reported uuid not null references public.profiles (id) on delete cascade,
  -- discussion = messages choisis ; personne = signalement depuis la liste d'amis.
  kind text not null check (kind in ('discussion', 'personne')),
  remark text check (remark is null or char_length(remark) <= 500),
  -- Messages signalés (JSON), CHIFFRÉS : seul l'écran admin les déchiffre.
  payload bytea,
  status text not null default 'new' check (status in ('new', 'handled')),
  created_at timestamptz not null default now(),
  handled_at timestamptz,
  handled_note text check (handled_note is null or char_length(handled_note) <= 500)
);
create index if not exists reports_status_idx on public.reports (status, created_at desc);

-- ====================================================== Règles d'accès (RLS)

alter table public.messages enable row level security;
alter table public.conversation_state enable row level security;
alter table public.read_marks enable row level security;
alter table public.typing_state enable row level security;
alter table public.blocks enable row level security;
alter table public.reports enable row level security;

revoke all on public.messages from anon, authenticated;
revoke all on public.conversation_state from anon, authenticated;
revoke all on public.read_marks from anon, authenticated;
revoke all on public.typing_state from anon, authenticated;
revoke all on public.blocks from anon, authenticated;
revoke all on public.reports from anon, authenticated;

-- Messages : lecture du texte CHIFFRÉ par les deux personnes (sert au temps
-- réel) ; le texte clair ne sort que par les fonctions ci-dessous.
grant select on public.messages to authenticated;
drop policy if exists messages_select on public.messages;
create policy messages_select on public.messages
  for select to authenticated
  using (sender = (select auth.uid()) or recipient = (select auth.uid()));

grant select on public.conversation_state to authenticated;
drop policy if exists conversation_state_select on public.conversation_state;
create policy conversation_state_select on public.conversation_state
  for select to authenticated
  using (user_id = (select auth.uid()));

-- « Vu » visible seulement si JE n'ai pas masqué les miens (réciprocité ;
-- le côté de l'autre est vérifié à l'écriture, dans mark_read).
grant select on public.read_marks to authenticated;
drop policy if exists read_marks_select on public.read_marks;
create policy read_marks_select on public.read_marks
  for select to authenticated
  using (
    peer = (select auth.uid())
    and not exists (
      select 1 from public.user_settings s
      where s.user_id = (select auth.uid()) and s.hide_read_receipts
    )
  );

grant select on public.typing_state to authenticated;
drop policy if exists typing_state_select on public.typing_state;
create policy typing_state_select on public.typing_state
  for select to authenticated
  using (
    peer_id = (select auth.uid())
    and not exists (
      select 1 from public.user_settings s
      where s.user_id = (select auth.uid()) and s.hide_typing
    )
  );

grant select on public.blocks to authenticated;
drop policy if exists blocks_select on public.blocks;
create policy blocks_select on public.blocks
  for select to authenticated
  using (blocker = (select auth.uid()));

-- reports : aucun accès direct (fonctions admin uniquement).

-- ============================================================ Messages

-- Envoie un message à un ami. Chiffré avant d'être enregistré. Aucune limite
-- d'envoi (choix de l'utilisateur) ; seule la taille d'un message est bornée.
create or replace function public.send_message(p_to uuid, p_kind text, p_body text)
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
  if p_kind not in ('text', 'share') then
    raise exception 'invalid_kind';
  end if;
  if p_body is null or char_length(btrim(p_body)) = 0 then
    raise exception 'empty_message';
  end if;
  if (p_kind = 'text' and char_length(p_body) > 1000)
     or (p_kind = 'share' and char_length(p_body) > 60000) then
    raise exception 'too_long';
  end if;
  if not public.are_friends(me, p_to) then
    raise exception 'not_friends';
  end if;
  if not exists (select 1 from public.profiles where id = me and friends_enabled)
     or not exists (select 1 from public.profiles where id = p_to and friends_enabled) then
    raise exception 'friends_disabled';
  end if;

  insert into public.messages (sender, recipient, kind, body)
  values (me, p_to, p_kind, private.enc(p_body))
  returning id into v_id;

  -- Un nouveau message fait revenir la discussion dans la liste des deux côtés.
  insert into public.conversation_state (user_id, friend_id) values (me, p_to), (p_to, me)
  on conflict (user_id, friend_id) do update set archived = false;
  return v_id;
end;
$$;

-- Messages d'une discussion (les plus récents d'abord), déchiffrés.
create or replace function public.conversation_messages(
  p_friend uuid,
  p_before timestamptz default null,
  p_limit int default 50
)
returns table (
  id uuid,
  peer uuid,
  mine boolean,
  kind text,
  body text,
  created_at timestamptz,
  deleted boolean
)
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  me uuid := auth.uid();
  v_cleared timestamptz;
begin
  if me is null then
    raise exception 'not_authenticated';
  end if;
  if not public.are_friends(me, p_friend) then
    raise exception 'not_friends';
  end if;
  select coalesce(
           (select s.cleared_at from public.conversation_state s
             where s.user_id = me and s.friend_id = p_friend),
           'epoch')
    into v_cleared;
  return query
    select m.id, p_friend, (m.sender = me), m.kind,
           case when m.deleted_at is null then private.dec(m.body) else null end,
           m.created_at, (m.deleted_at is not null)
    from public.messages m
    where ((m.sender = me and m.recipient = p_friend)
        or (m.sender = p_friend and m.recipient = me))
      and m.created_at > v_cleared
      and not (me = any (m.deleted_for))
      and (p_before is null or m.created_at < p_before)
    order by m.created_at desc
    limit greatest(1, least(p_limit, 200));
end;
$$;

-- Un message précis (après un événement en direct).
create or replace function public.message_by_id(p_id uuid)
returns table (
  id uuid,
  peer uuid,
  mine boolean,
  kind text,
  body text,
  created_at timestamptz,
  deleted boolean
)
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  me uuid := auth.uid();
begin
  if me is null then
    raise exception 'not_authenticated';
  end if;
  return query
    select m.id,
           case when m.sender = me then m.recipient else m.sender end,
           (m.sender = me), m.kind,
           case when m.deleted_at is null then private.dec(m.body) else null end,
           m.created_at, (m.deleted_at is not null)
    from public.messages m
    where m.id = p_id
      and (m.sender = me or m.recipient = me)
      and not (me = any (m.deleted_for));
end;
$$;

-- Liste des discussions (avec le dernier message et le nombre de non-lus).
create or replace function public.my_conversations(p_archived boolean default false)
returns table (
  friend_id uuid,
  friend_name text,
  avatar_url text,
  last_kind text,
  last_body text,
  last_mine boolean,
  last_at timestamptz,
  last_deleted boolean,
  unread int,
  muted boolean,
  archived boolean
)
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  me uuid := auth.uid();
begin
  if me is null then
    raise exception 'not_authenticated';
  end if;
  return query
  with friends as (
    select case when f.requester = me then f.addressee else f.requester end as fid
    from public.friendships f
    where f.status = 'accepted' and (f.requester = me or f.addressee = me)
  ),
  vis as (
    select m.id as mid, m.sender as msender, m.recipient as mrecipient,
           m.kind as mkind, m.body as mbody, m.created_at as mcreated,
           m.deleted_at as mdeleted,
           case when m.sender = me then m.recipient else m.sender end as peer
    from public.messages m
    left join public.conversation_state s
      on s.user_id = me
     and s.friend_id = (case when m.sender = me then m.recipient else m.sender end)
    where (m.sender = me or m.recipient = me)
      and m.created_at > coalesce(s.cleared_at, 'epoch')
      and not (me = any (m.deleted_for))
  ),
  last_msg as (
    select distinct on (v.peer) v.peer, v.mkind, v.mbody, v.msender, v.mcreated, v.mdeleted
    from vis v
    order by v.peer, v.mcreated desc
  )
  select p.id, p.display_name, p.avatar_url, l.mkind,
         case when l.mdeleted is null then private.dec(l.mbody) else null end,
         (l.msender = me), l.mcreated, (l.mdeleted is not null),
         (select count(*)::int from vis v2
           where v2.peer = p.id and v2.mrecipient = me and v2.mdeleted is null
             and v2.mcreated > coalesce(cs.last_read_at, 'epoch')),
         coalesce(cs.muted, false), coalesce(cs.archived, false)
  from friends fr
  join public.profiles p on p.id = fr.fid
  join last_msg l on l.peer = p.id
  left join public.conversation_state cs on cs.user_id = me and cs.friend_id = p.id
  where coalesce(cs.archived, false) = p_archived
  order by l.mcreated desc;
end;
$$;

-- Informations d'une discussion : « vu » de l'autre (seulement si les deux
-- ont gardé les « vu » actifs), silence, archivage.
create or replace function public.conversation_info(p_friend uuid)
returns table (
  peer_read_at timestamptz,
  muted boolean,
  archived boolean
)
language sql
stable
security definer
set search_path = ''
as $$
  select
    (select rm.read_at from public.read_marks rm
      where rm.reader = p_friend and rm.peer = auth.uid()
        and not coalesce((select s.hide_read_receipts from public.user_settings s
                           where s.user_id = auth.uid()), false)
        and not coalesce((select s.hide_read_receipts from public.user_settings s
                           where s.user_id = p_friend), false)),
    coalesce(cs.muted, false),
    coalesce(cs.archived, false)
  from (select 1) d
  left join public.conversation_state cs
    on cs.user_id = auth.uid() and cs.friend_id = p_friend;
$$;

-- J'ai lu la discussion : met à jour mes non-lus et, si je n'ai pas masqué
-- les « vu », l'autre le voit.
create or replace function public.mark_read(p_friend uuid)
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
  if not public.are_friends(me, p_friend) then
    raise exception 'not_friends';
  end if;
  insert into public.conversation_state (user_id, friend_id, last_read_at)
  values (me, p_friend, now())
  on conflict (user_id, friend_id) do update set last_read_at = now();
  if not coalesce((select s.hide_read_receipts from public.user_settings s
                    where s.user_id = me), false) then
    insert into public.read_marks (reader, peer, read_at)
    values (me, p_friend, now())
    on conflict (reader, peer) do update set read_at = now();
  end if;
end;
$$;

-- « En train d'écrire… » (rien n'est écrit si j'ai masqué cette option).
create or replace function public.set_typing(p_friend uuid, p_on boolean)
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
  if coalesce((select s.hide_typing from public.user_settings s
                where s.user_id = me), false) then
    return;
  end if;
  if not public.are_friends(me, p_friend) then
    return;
  end if;
  insert into public.typing_state (user_id, peer_id, until)
  values (
    me, p_friend,
    case when p_on then now() + interval '6 seconds' else now() - interval '1 second' end
  )
  on conflict (user_id, peer_id) do update set until = excluded.until;
end;
$$;

-- Supprimer un message : pour moi seulement, ou pour tout le monde (mes
-- messages) ; dans ce cas le contenu est effacé et une trace reste.
create or replace function public.delete_message(p_id uuid, p_for_all boolean)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  me uuid := auth.uid();
  v public.messages%rowtype;
begin
  if me is null then
    raise exception 'not_authenticated';
  end if;
  select * into v from public.messages m
   where m.id = p_id and (m.sender = me or m.recipient = me);
  if not found then
    raise exception 'not_found';
  end if;
  if p_for_all then
    if v.sender <> me then
      raise exception 'not_sender';
    end if;
    update public.messages
       set deleted_at = now(), body = private.enc('')
     where id = p_id and deleted_at is null;
  else
    update public.messages
       set deleted_for = array_append(deleted_for, me)
     where id = p_id and not (me = any (deleted_for));
  end if;
end;
$$;

-- Supprimer une discussion : pour moi seulement.
create or replace function public.clear_conversation(p_friend uuid)
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
  insert into public.conversation_state (user_id, friend_id, cleared_at, last_read_at)
  values (me, p_friend, now(), now())
  on conflict (user_id, friend_id)
    do update set cleared_at = now(), last_read_at = now(), archived = false;
end;
$$;

create or replace function public.set_archived(p_friend uuid, p_on boolean)
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
  insert into public.conversation_state (user_id, friend_id, archived)
  values (me, p_friend, p_on)
  on conflict (user_id, friend_id) do update set archived = excluded.archived;
end;
$$;

create or replace function public.set_muted(p_friend uuid, p_on boolean)
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
  insert into public.conversation_state (user_id, friend_id, muted)
  values (me, p_friend, p_on)
  on conflict (user_id, friend_id) do update set muted = excluded.muted;
end;
$$;

-- ================================================================ Blocage

-- Bloquer : l'amitié disparaît des deux côtés. L'autre personne voit
-- seulement qu'il n'est plus ami (comme après un retrait) : elle ne sait pas
-- qui a bloqué qui. Rien n'est visible de l'administrateur.
create or replace function public.block_user(p_user uuid)
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
  if p_user = me then
    raise exception 'invalid_user';
  end if;
  insert into public.blocks (blocker, blocked) values (me, p_user) on conflict do nothing;
  delete from public.friendships
   where (requester = me and addressee = p_user)
      or (requester = p_user and addressee = me);
  delete from public.read_marks where (reader = me and peer = p_user) or (reader = p_user and peer = me);
  delete from public.typing_state where (user_id = me and peer_id = p_user) or (user_id = p_user and peer_id = me);
end;
$$;

create or replace function public.unblock_user(p_user uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  delete from public.blocks where blocker = auth.uid() and blocked = p_user;
end;
$$;

create or replace function public.my_blocks()
returns table (user_id uuid, display_name text, avatar_url text, created_at timestamptz)
language sql
stable
security definer
set search_path = ''
as $$
  select b.blocked, p.display_name, p.avatar_url, b.created_at
  from public.blocks b
  join public.profiles p on p.id = b.blocked
  where b.blocker = auth.uid()
  order by b.created_at desc;
$$;

-- Invitations : tient compte des blocages, sans jamais révéler qui a bloqué.
--  * j'ai bloqué la personne : erreur claire (je peux la débloquer) ;
--  * la personne m'a bloqué : j'ai l'impression que l'invitation est partie
--    (elle reste « en attente »), mais elle n'arrive jamais.
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

  if exists (select 1 from public.blocks where blocker = me and blocked = v_target) then
    raise exception 'you_blocked';
  end if;
  if exists (select 1 from public.blocks where blocker = v_target and blocked = me) then
    -- Faux envoi : trace « refusée » (affichée « en attente » à l'auteur).
    insert into public.friendships (requester, addressee, status, responded_at)
    values (me, v_target, 'declined', now())
    on conflict do nothing;
    return 'sent';
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
      update public.friendships
         set status = 'accepted', responded_at = now()
       where requester = v_target and addressee = me and status = 'pending';
      return 'accepted';
    end if;
    return 'already_pending';
  end if;
  if v_status = 'declined' then
    return 'sent';
  end if;

  insert into public.friendships (requester, addressee) values (me, v_target);
  return 'sent';
end;
$$;

-- ============================================================ Signalements

-- Signaler une DISCUSSION : au moins 1 message choisi, remarque facultative.
create or replace function public.report_conversation(
  p_friend uuid,
  p_message_ids uuid[],
  p_remark text,
  p_also_block boolean
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  me uuid := auth.uid();
  v_payload jsonb;
  v_id uuid;
  v_me_name text;
  v_other_name text;
begin
  if me is null then
    raise exception 'not_authenticated';
  end if;
  if p_message_ids is null or coalesce(array_length(p_message_ids, 1), 0) = 0 then
    raise exception 'no_messages';
  end if;
  if p_remark is not null and char_length(p_remark) > 500 then
    raise exception 'too_long';
  end if;
  if not public.are_friends(me, p_friend) then
    raise exception 'not_friends';
  end if;
  if (select count(*) from public.reports
        where reporter = me and reported = p_friend
          and created_at > now() - interval '1 day') >= 3 then
    raise exception 'rate_limited';
  end if;

  select display_name into v_me_name from public.profiles where id = me;
  select display_name into v_other_name from public.profiles where id = p_friend;

  select coalesce(jsonb_agg(jsonb_build_object(
           'from', case when m.sender = me then v_me_name else v_other_name end,
           'mine', (m.sender = me),
           'at', m.created_at,
           'kind', m.kind,
           'text', case when m.deleted_at is null then private.dec(m.body) else null end
         ) order by m.created_at), '[]'::jsonb)
    into v_payload
    from public.messages m
   where m.id = any (p_message_ids)
     and ((m.sender = me and m.recipient = p_friend)
       or (m.sender = p_friend and m.recipient = me));

  if jsonb_array_length(v_payload) = 0 then
    raise exception 'no_messages';
  end if;

  insert into public.reports (reporter, reported, kind, remark, payload)
  values (me, p_friend, 'discussion', nullif(btrim(p_remark), ''), private.enc(v_payload::text))
  returning id into v_id;

  if coalesce(p_also_block, false) then
    perform public.block_user(p_friend);
  end if;
  return v_id;
end;
$$;

-- Signaler une PERSONNE depuis la liste d'amis (motif obligatoire).
create or replace function public.report_person(p_friend uuid, p_remark text)
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
  if p_remark is null or char_length(btrim(p_remark)) < 5 or char_length(p_remark) > 500 then
    raise exception 'invalid_remark';
  end if;
  if not public.are_friends(me, p_friend) then
    raise exception 'not_friends';
  end if;
  if (select count(*) from public.reports
        where reporter = me and reported = p_friend
          and created_at > now() - interval '1 day') >= 3 then
    raise exception 'rate_limited';
  end if;
  insert into public.reports (reporter, reported, kind, remark)
  values (me, p_friend, 'personne', btrim(p_remark))
  returning id into v_id;
  return v_id;
end;
$$;

-- Écran administrateur : liste des signalements (messages déchiffrés).
create or replace function public.admin_list_reports(p_status text default null)
returns table (
  id uuid,
  kind text,
  status text,
  created_at timestamptz,
  reporter_name text,
  reported_name text,
  remark text,
  messages jsonb,
  handled_at timestamptz,
  handled_note text
)
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  if not public.is_admin() then
    raise exception 'not_admin';
  end if;
  return query
    select r.id, r.kind, r.status, r.created_at,
           pr.display_name, pd.display_name, r.remark,
           case when r.payload is null then '[]'::jsonb
                else private.dec(r.payload)::jsonb end,
           r.handled_at, r.handled_note
    from public.reports r
    join public.profiles pr on pr.id = r.reporter
    join public.profiles pd on pd.id = r.reported
    where p_status is null or r.status = p_status
    order by r.created_at desc
    limit 200;
end;
$$;

create or replace function public.admin_handle_report(p_id uuid, p_note text)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  if not public.is_admin() then
    raise exception 'not_admin';
  end if;
  update public.reports
     set status = 'handled', handled_at = now(), handled_note = nullif(btrim(p_note), '')
   where id = p_id;
  if not found then
    raise exception 'not_found';
  end if;
end;
$$;

create or replace function public.admin_new_reports_count()
returns int
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  if not public.is_admin() then
    raise exception 'not_admin';
  end if;
  return (select count(*)::int from public.reports where status = 'new');
end;
$$;

-- ============================================================ Quitter

-- Quitter la fonction Amis : efface tout ce qui m'appartient (amitiés,
-- messages, réglages, blocages…). Les signalements que j'ai faits restent
-- (modération).
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
  delete from public.messages where sender = me or recipient = me;
  delete from public.conversation_state where user_id = me or friend_id = me;
  delete from public.read_marks where reader = me or peer = me;
  delete from public.typing_state where user_id = me or peer_id = me;
  delete from public.blocks where blocker = me;
  delete from public.friendships where requester = me or addressee = me;
  delete from public.push_tokens where user_id = me;
  delete from public.user_settings where user_id = me;
  update public.profiles
     set friends_enabled = false, online = false, last_seen = 'epoch'
   where id = me;
end;
$$;

-- ================================================================== Droits

revoke all on function public.my_settings() from public, anon;
revoke all on function public.set_chat_settings(boolean, boolean, boolean) from public, anon;
revoke all on function public.send_message(uuid, text, text) from public, anon;
revoke all on function public.conversation_messages(uuid, timestamptz, int) from public, anon;
revoke all on function public.message_by_id(uuid) from public, anon;
revoke all on function public.my_conversations(boolean) from public, anon;
revoke all on function public.conversation_info(uuid) from public, anon;
revoke all on function public.mark_read(uuid) from public, anon;
revoke all on function public.set_typing(uuid, boolean) from public, anon;
revoke all on function public.delete_message(uuid, boolean) from public, anon;
revoke all on function public.clear_conversation(uuid) from public, anon;
revoke all on function public.set_archived(uuid, boolean) from public, anon;
revoke all on function public.set_muted(uuid, boolean) from public, anon;
revoke all on function public.block_user(uuid) from public, anon;
revoke all on function public.unblock_user(uuid) from public, anon;
revoke all on function public.my_blocks() from public, anon;
revoke all on function public.send_friend_request(text) from public, anon;
revoke all on function public.report_conversation(uuid, uuid[], text, boolean) from public, anon;
revoke all on function public.report_person(uuid, text) from public, anon;
revoke all on function public.admin_list_reports(text) from public, anon;
revoke all on function public.admin_handle_report(uuid, text) from public, anon;
revoke all on function public.admin_new_reports_count() from public, anon;
revoke all on function public.leave_friends() from public, anon;

grant execute on function public.my_settings() to authenticated;
grant execute on function public.set_chat_settings(boolean, boolean, boolean) to authenticated;
grant execute on function public.send_message(uuid, text, text) to authenticated;
grant execute on function public.conversation_messages(uuid, timestamptz, int) to authenticated;
grant execute on function public.message_by_id(uuid) to authenticated;
grant execute on function public.my_conversations(boolean) to authenticated;
grant execute on function public.conversation_info(uuid) to authenticated;
grant execute on function public.mark_read(uuid) to authenticated;
grant execute on function public.set_typing(uuid, boolean) to authenticated;
grant execute on function public.delete_message(uuid, boolean) to authenticated;
grant execute on function public.clear_conversation(uuid) to authenticated;
grant execute on function public.set_archived(uuid, boolean) to authenticated;
grant execute on function public.set_muted(uuid, boolean) to authenticated;
grant execute on function public.block_user(uuid) to authenticated;
grant execute on function public.unblock_user(uuid) to authenticated;
grant execute on function public.my_blocks() to authenticated;
grant execute on function public.send_friend_request(text) to authenticated;
grant execute on function public.report_conversation(uuid, uuid[], text, boolean) to authenticated;
grant execute on function public.report_person(uuid, text) to authenticated;
grant execute on function public.admin_list_reports(text) to authenticated;
grant execute on function public.admin_handle_report(uuid, text) to authenticated;
grant execute on function public.admin_new_reports_count() to authenticated;
grant execute on function public.leave_friends() to authenticated;

-- ============================================================== Temps réel
-- Messages (nouveaux et supprimés pour tous), « vu » et « en train d'écrire »
-- sont diffusés en direct ; les règles d'accès ci-dessus s'appliquent.

do $$
begin
  alter publication supabase_realtime add table public.messages;
exception when duplicate_object then null;
end $$;

do $$
begin
  alter publication supabase_realtime add table public.read_marks;
exception when duplicate_object then null;
end $$;

do $$
begin
  alter publication supabase_realtime add table public.typing_state;
exception when duplicate_object then null;
end $$;

-- ======================================================= Notifications push (2.8)
-- Quand quelqu'un n'utilise pas l'application, une petite fonction Supabase
-- (`notify`, voir supabase/functions/notify) envoie une notification
-- Firebase Cloud Messaging Ã  son tÃ©lÃ©phone. Si la personne utilise
-- l'application, rien n'est envoyÃ© : le temps rÃ©el s'en charge (pas de doublon).

-- Envoi des appels HTTP vers la fonction. Si l'extension est indisponible,
-- le reste du script s'applique quand mÃªme (les push ne partiront pas tant
-- qu'elle n'est pas activÃ©e : Supabase -> Database -> Extensions -> pg_net).
do $$
begin
  create extension if not exists pg_net;
exception when others then
  raise notice 'pg_net indisponible : %', sqlerrm;
end $$;

-- Adresse de la fonction (projet gymflow). Ã€ changer si le projet change.
insert into private.app_secrets (name, value)
values ('push_url', 'https://avroiapimzybmyruyqjv.supabase.co/functions/v1/notify')
on conflict (name) do nothing;

-- Jetons d'appareil (un par tÃ©lÃ©phone et par compte).
create table if not exists public.push_tokens (
  token text primary key,
  user_id uuid not null references public.profiles (id) on delete cascade,
  platform text not null default 'android',
  updated_at timestamptz not null default now()
);
create index if not exists push_tokens_user_idx on public.push_tokens (user_id);
alter table public.push_tokens enable row level security;
revoke all on public.push_tokens from anon, authenticated;

-- Un Ã©vÃ©nement n'est notifiÃ© qu'une fois (la fonction peut Ãªtre rappelÃ©e).
create table if not exists private.push_log (
  event text primary key,
  created_at timestamptz not null default now()
);
alter table private.push_log enable row level security;
revoke all on private.push_log from public, anon, authenticated;

create or replace function public.register_push_token(p_token text)
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
  if p_token is null or char_length(p_token) < 20 or char_length(p_token) > 4096 then
    raise exception 'invalid_token';
  end if;
  insert into public.push_tokens (token, user_id)
  values (p_token, me)
  on conflict (token) do update set user_id = me, updated_at = now();
  -- On ne garde que les 5 appareils les plus rÃ©cents.
  delete from public.push_tokens
   where user_id = me
     and token not in (
       select t.token from public.push_tokens t
        where t.user_id = me
        order by t.updated_at desc
        limit 5
     );
end;
$$;

create or replace function public.unregister_push_token(p_token text)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  delete from public.push_tokens where token = p_token and user_id = auth.uid();
end;
$$;

-- Faut-il notifier ? Pas si la discussion est en silence, si la personne n'a
-- aucun appareil enregistrÃ©, ou si elle utilise l'application en ce moment.
create or replace function private.push_event(
  p_event text,
  p_recipient uuid,
  p_muted boolean default false
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_url text;
begin
  if p_muted then
    return;
  end if;
  if not exists (select 1 from public.push_tokens t where t.user_id = p_recipient) then
    return;
  end if;
  if exists (select 1 from public.user_settings s
              where s.user_id = p_recipient
                and s.last_active > now() - interval '40 seconds') then
    return;
  end if;
  select value into v_url from private.app_secrets where name = 'push_url';
  if v_url is null then
    return;
  end if;
  perform net.http_post(
    url := v_url,
    body := jsonb_build_object('event', p_event),
    headers := '{"Content-Type": "application/json"}'::jsonb
  );
exception when others then
  -- Une notification qui Ã©choue ne doit jamais empÃªcher d'envoyer un message.
  null;
end;
$$;

create or replace function private.trg_message_push()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform private.push_event(
    'message:' || new.id::text,
    new.recipient,
    coalesce((select cs.muted from public.conversation_state cs
               where cs.user_id = new.recipient and cs.friend_id = new.sender), false)
  );
  return new;
end;
$$;

create or replace function private.trg_poke_push()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform private.push_event('poke:' || new.id::text, new.recipient);
  return new;
end;
$$;

create or replace function private.trg_request_push()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform private.push_event('request:' || new.id::text, new.addressee);
  return new;
end;
$$;

create or replace function private.trg_accept_push()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform private.push_event('accepted:' || new.id::text, new.requester);
  return new;
end;
$$;

drop trigger if exists messages_push on public.messages;
create trigger messages_push after insert on public.messages
  for each row execute function private.trg_message_push();

drop trigger if exists pokes_push on public.pokes;
create trigger pokes_push after insert on public.pokes
  for each row execute function private.trg_poke_push();

drop trigger if exists friendships_request_push on public.friendships;
create trigger friendships_request_push after insert on public.friendships
  for each row when (new.status = 'pending')
  execute function private.trg_request_push();

drop trigger if exists friendships_accept_push on public.friendships;
create trigger friendships_accept_push after update of status on public.friendships
  for each row when (old.status = 'pending' and new.status = 'accepted')
  execute function private.trg_accept_push();

-- Contenu de la notification, lu par la fonction `notify` (clÃ© de service
-- uniquement : l'application n'y a pas accÃ¨s). Renvoie une ligne vide si
-- l'Ã©vÃ©nement a dÃ©jÃ  Ã©tÃ© traitÃ©.
create or replace function public.push_payload(p_event text)
returns table (
  tokens text[],
  title text,
  body text,
  route text,
  ref text
)
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_type text := split_part(p_event, ':', 1);
  v_id uuid;
  v_recipient uuid;
  v_name text;
  v_title text;
  v_body text;
  v_route text;
  v_ref text;
  v_preview boolean;
  v_msg public.messages%rowtype;
  v_poke public.pokes%rowtype;
  v_fr public.friendships%rowtype;
  v_raw text;
  v_card jsonb;
  v_label text;
begin
  begin
    v_id := split_part(p_event, ':', 2)::uuid;
  exception when others then
    return;
  end;

  insert into private.push_log (event) values (p_event) on conflict do nothing;
  if not found then
    return;
  end if;

  if v_type = 'message' then
    select * into v_msg from public.messages m where m.id = v_id and m.deleted_at is null;
    if not found then
      return;
    end if;
    v_recipient := v_msg.recipient;
    select display_name into v_name from public.profiles where id = v_msg.sender;
    v_preview := coalesce(
      (select s.push_preview from public.user_settings s where s.user_id = v_recipient),
      true
    );
    v_route := '/chat';
    v_ref := v_msg.sender::text;
    if not v_preview then
      v_title := 'GymFlow';
      v_body := v_name || ' vous a Ã©crit';
    elsif v_msg.kind = 'share' then
      v_raw := private.dec(v_msg.body);
      begin
        v_card := v_raw::jsonb;
        v_label := case v_card ->> 'type'
          when 'session' then 'une sÃ©ance'
          when 'workout' then 'un workout'
          when 'exercise' then 'un exercice'
          when 'program' then 'un programme'
          else 'un Ã©lÃ©ment'
        end;
        v_body := 'a partagÃ© ' || v_label || ' : ' || coalesce(v_card ->> 'title', '');
      exception when others then
        v_body := 'a partagÃ© un Ã©lÃ©ment';
      end;
      v_title := v_name;
    else
      v_title := v_name;
      v_body := left(private.dec(v_msg.body), 140);
    end if;

  elsif v_type = 'poke' then
    select * into v_poke from public.pokes p where p.id = v_id;
    if not found then
      return;
    end if;
    v_recipient := v_poke.recipient;
    select display_name into v_name from public.profiles where id = v_poke.sender;
    v_route := '/friends';
    v_ref := null;
    if v_poke.kind = 'challenge' then
      v_title := v_name || ' vous lance un dÃ©fi';
      v_body := v_name || ' vous dÃ©fie : une sÃ©ance aujourd''hui, partant(e) ?';
    else
      v_title := v_name || ' vous encourage';
      v_body := 'Votre ami(e) vous encourage Ã  dÃ©passer vos limites aujourd''hui !';
    end if;

  elsif v_type = 'request' then
    select * into v_fr from public.friendships f where f.id = v_id and f.status = 'pending';
    if not found then
      return;
    end if;
    v_recipient := v_fr.addressee;
    select display_name into v_name from public.profiles where id = v_fr.requester;
    v_title := v_name || ' veut vous ajouter';
    v_body := 'Ouvrez Mes amis pour accepter ou refuser la demande.';
    v_route := '/friends';
    v_ref := null;

  elsif v_type = 'accepted' then
    select * into v_fr from public.friendships f where f.id = v_id and f.status = 'accepted';
    if not found then
      return;
    end if;
    v_recipient := v_fr.requester;
    select display_name into v_name from public.profiles where id = v_fr.addressee;
    v_title := v_name || ' a acceptÃ©';
    v_body := 'Vous Ãªtes maintenant amis : vous voyez quand il ou elle est en ligne.';
    v_route := '/friends';
    v_ref := null;

  else
    return;
  end if;

  return query
    select array_agg(t.token), v_title, v_body, v_route, v_ref
    from public.push_tokens t
    where t.user_id = v_recipient
    having count(*) > 0;
end;
$$;

-- Jeton refusÃ© par Firebase (application dÃ©sinstallÃ©e) : on l'oublie.
create or replace function public.drop_push_token(p_token text)
returns void
language sql
security definer
set search_path = ''
as $$
  delete from public.push_tokens where token = p_token;
$$;

revoke all on function public.push_payload(text) from public, anon, authenticated;
revoke all on function public.drop_push_token(text) from public, anon, authenticated;
grant execute on function public.push_payload(text) to service_role;
grant execute on function public.drop_push_token(text) to service_role;

revoke all on function public.register_push_token(text) from public, anon;
revoke all on function public.unregister_push_token(text) from public, anon;
grant execute on function public.register_push_token(text) to authenticated;
grant execute on function public.unregister_push_token(text) to authenticated;

commit;

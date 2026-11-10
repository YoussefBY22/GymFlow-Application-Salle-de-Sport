-- GymFlow 3.2 : « Vu » et « en train d'écrire » se règlent par discussion.
--
-- Depuis le menu (trois points) d'une discussion, on peut masquer les « Vu »
-- et/ou « en train d'écrire » pour CETTE personne seulement (réciprocité,
-- comme les réglages généraux : si je masque les miens, je ne vois plus les
-- siens). Les réglages généraux de « Mes amis » restent valables pour tous.
--
-- À exécuter une seule fois dans l'éditeur SQL de Supabase (après 005 et 006).

begin;

alter table public.conversation_state
  add column if not exists hide_receipts boolean not null default false;
alter table public.conversation_state
  add column if not exists hide_typing boolean not null default false;

-- ------------------------------------------------------------ Réglage par ami

create or replace function public.set_chat_privacy(
  p_friend uuid,
  p_hide_receipts boolean,
  p_hide_typing boolean
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
  if not public.are_friends(me, p_friend) then
    raise exception 'not_friends';
  end if;
  insert into public.conversation_state (user_id, friend_id, hide_receipts, hide_typing)
  values (me, p_friend, p_hide_receipts, p_hide_typing)
  on conflict (user_id, friend_id) do update
    set hide_receipts = excluded.hide_receipts,
        hide_typing = excluded.hide_typing;
end;
$$;

-- --------------------------------------------------------- Infos d'une discussion

drop function if exists public.conversation_info(uuid);

create function public.conversation_info(p_friend uuid)
returns table (
  peer_read_at timestamptz,
  muted boolean,
  archived boolean,
  hide_receipts boolean,
  hide_typing boolean
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
                           where s.user_id = p_friend), false)
        and not coalesce((select c.hide_receipts from public.conversation_state c
                           where c.user_id = auth.uid() and c.friend_id = p_friend), false)
        and not coalesce((select c.hide_receipts from public.conversation_state c
                           where c.user_id = p_friend and c.friend_id = auth.uid()), false)),
    coalesce(cs.muted, false),
    coalesce(cs.archived, false),
    coalesce(cs.hide_receipts, false),
    coalesce(cs.hide_typing, false)
  from (select 1) d
  left join public.conversation_state cs
    on cs.user_id = auth.uid() and cs.friend_id = p_friend;
$$;

-- ------------------------------------------------------------------ « Vu »

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
                    where s.user_id = me), false)
     and not coalesce((select c.hide_receipts from public.conversation_state c
                        where c.user_id = me and c.friend_id = p_friend), false) then
    insert into public.read_marks (reader, peer, read_at)
    values (me, p_friend, now())
    on conflict (reader, peer) do update set read_at = now();
  end if;
end;
$$;

drop policy if exists read_marks_select on public.read_marks;
create policy read_marks_select on public.read_marks
  for select to authenticated
  using (
    peer = (select auth.uid())
    and not exists (
      select 1 from public.user_settings s
      where s.user_id = (select auth.uid()) and s.hide_read_receipts
    )
    and not exists (
      select 1 from public.conversation_state c
      where c.user_id = (select auth.uid()) and c.friend_id = read_marks.reader
        and c.hide_receipts
    )
  );

-- ------------------------------------------------------- « En train d'écrire »

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
  if coalesce((select c.hide_typing from public.conversation_state c
                where c.user_id = me and c.friend_id = p_friend), false) then
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

drop policy if exists typing_state_select on public.typing_state;
create policy typing_state_select on public.typing_state
  for select to authenticated
  using (
    peer_id = (select auth.uid())
    and not exists (
      select 1 from public.user_settings s
      where s.user_id = (select auth.uid()) and s.hide_typing
    )
    and not exists (
      select 1 from public.conversation_state c
      where c.user_id = (select auth.uid()) and c.friend_id = typing_state.user_id
        and c.hide_typing
    )
  );

-- ------------------------------------------------------------------- Droits

revoke all on function public.set_chat_privacy(uuid, boolean, boolean) from public, anon;
revoke all on function public.conversation_info(uuid) from public, anon;
revoke all on function public.mark_read(uuid) from public, anon;
revoke all on function public.set_typing(uuid, boolean) from public, anon;

grant execute on function public.set_chat_privacy(uuid, boolean, boolean) to authenticated;
grant execute on function public.conversation_info(uuid) to authenticated;
grant execute on function public.mark_read(uuid) to authenticated;
grant execute on function public.set_typing(uuid, boolean) to authenticated;

commit;

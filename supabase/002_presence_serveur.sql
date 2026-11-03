-- GymFlow : mise à jour n°2 de la base (présence à l'heure du serveur)
--
-- À coller dans Supabase -> SQL Editor -> New query -> Run, APRES schema.sql.
-- Rejouable sans danger. (schema.sql contient déjà ces changements pour une
-- installation neuve : ce fichier sert à mettre à jour une base déjà créée.)
--
-- Pourquoi : « en ligne » se calcule en comparant le dernier signal à
-- l'heure actuelle. Si chaque téléphone utilisait sa propre horloge, un
-- téléphone en avance ou en retard fausserait la présence. Le signal est
-- donc écrit avec l'heure du serveur, et le serveur envoie aussi son heure.

-- Le client ne peut plus écrire last_seen lui-même (on ne peut plus se
-- déclarer « en ligne » artificiellement) : il passe par heartbeat().
revoke update on public.profiles from authenticated;
grant update (display_name, avatar_url, friends_enabled) on public.profiles to authenticated;

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

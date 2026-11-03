-- GymFlow : mise à jour n°3 de la base (messages entre amis)
--
-- À coller dans Supabase -> SQL Editor -> New query -> Run, APRES 002.
-- Rejouable sans danger. (schema.sql contient déjà ces changements pour une
-- installation neuve.)
--
-- Changements :
--  * le message « Tu me manques » est retiré (il reste deux messages :
--    « encourage » et « challenge ») ;
--  * la limite passe d'un message par heure à un message par MINUTE et par
--    ami ; plafond de 60 messages par jour au total (anti-harcèlement).
--
-- La contrainte de la colonne `kind` n'est pas modifiée : d'anciens messages
-- « miss_you » éventuels restent lisibles ; seule la fonction send_poke() les
-- refuse désormais.

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
  if p_kind not in ('encourage', 'challenge') then
    raise exception 'invalid_kind';
  end if;
  if not public.are_friends(me, p_to) then
    raise exception 'not_friends';
  end if;
  if not exists (select 1 from public.profiles where id = me and friends_enabled)
     or not exists (select 1 from public.profiles where id = p_to and friends_enabled) then
    raise exception 'friends_disabled';
  end if;
  -- Anti-harcèlement : 1 message par minute et par ami, 60 par jour au total.
  if exists (select 1 from public.pokes
              where sender = me and recipient = p_to
                and created_at > now() - interval '1 minute') then
    raise exception 'rate_limited';
  end if;
  if (select count(*) from public.pokes
        where sender = me and created_at > now() - interval '1 day') >= 60 then
    raise exception 'daily_limit';
  end if;

  insert into public.pokes (sender, recipient, kind)
  values (me, p_to, p_kind)
  returning id into v_id;
  return v_id;
end;
$$;

revoke all on function public.send_poke(uuid, text) from public, anon;
grant execute on function public.send_poke(uuid, text) to authenticated;

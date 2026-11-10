-- GymFlow 3.1 : la fonction Amis s'active en un seul bouton, sans mot de passe.
--
-- Le compte du serveur a un secret aléatoire gardé dans le coffre du téléphone.
-- Désactiver la fonction supprime le compte du serveur (profil, amis, demandes
-- et messages partent avec lui, par suppression en cascade) : on peut ensuite
-- le réactiver, depuis n'importe quel téléphone, avec un nouveau secret.
--
-- À exécuter une seule fois dans l'éditeur SQL de Supabase (après 005).
-- Sans ce script, la désactivation efface quand même les données Amis, mais
-- le compte reste sur le serveur (et ne peut être relié qu'à ce téléphone).

begin;

create or replace function public.delete_my_account()
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
  -- Profil, amitiés, messages, signalements, jetons... sont liés au compte
  -- avec « on delete cascade ».
  delete from auth.users where id = me;
end;
$$;

revoke all on function public.delete_my_account() from public, anon;
grant execute on function public.delete_my_account() to authenticated;

commit;

-- =====================================================================
-- "Última atualização ... por <pessoa>": guardar QUEM mexeu por último.
--
-- Como usar: cole este arquivo inteiro no SQL Editor do Supabase e clique
-- em "Run". Pode rodar antes ou depois de instalar o app novo: sem a coluna,
-- o app mostra a data mas não o nome (e usa o criador/dono como aproximação).
--
-- Ideia: `lists` e `items` ganham `updated_by`, preenchido SOZINHO pelo
-- servidor (o app não envia). Quem decide é `auth.uid()`: a função do
-- Supabase que devolve o id do usuário logado na requisição. Assim ninguém
-- consegue "assinar" uma alteração em nome de outra pessoa.
-- =====================================================================

-- 1. As colunas. Se a pessoa for apagada, o campo vira nulo (não apaga a linha).
alter table public.lists
  add column if not exists updated_by uuid default auth.uid()
  references public.profiles (id) on delete set null;

alter table public.items
  add column if not exists updated_by uuid default auth.uid()
  references public.profiles (id) on delete set null;

-- 2. O trigger que já carimbava `updated_at` passa a carimbar `updated_by`
--    também. `coalesce(auth.uid(), old.updated_by)`: se a alteração vier de
--    fora do app (ex.: você rodando SQL no editor, sem usuário logado), mantém
--    quem estava antes em vez de apagar.
--
--    `products` continua com o trigger antigo (catálogo é pessoal, não precisa).
create or replace function public.touch_updated_at_and_by()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  new.updated_at = now();
  new.updated_by = coalesce(auth.uid(), old.updated_by);
  return new;
end;
$$;

drop trigger if exists lists_touch on public.lists;
create trigger lists_touch
  before update on public.lists
  for each row execute function public.touch_updated_at_and_by();

drop trigger if exists items_touch on public.items;
create trigger items_touch
  before update on public.items
  for each row execute function public.touch_updated_at_and_by();

-- Linhas que já existem ficam com `updated_by` nulo de propósito: mexer nelas
-- aqui mudaria `updated_at` e faria todos os celulares baixarem tudo de novo.
-- O app usa o criador do item / o dono da lista enquanto ninguém mexer de novo.

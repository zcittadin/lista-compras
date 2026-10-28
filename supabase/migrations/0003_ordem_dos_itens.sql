-- =====================================================================
-- Ordem manual dos itens (arrastar pelo puxador de 6 pontinhos).
--
-- Como usar: cole este arquivo inteiro no SQL Editor do Supabase e clique
-- em "Run". Rode ANTES de instalar a versão nova do app: o app novo envia
-- a coluna `position`, que precisa existir no servidor.
--
-- Ideia: cada item tem uma posição (número com casas decimais). Mover um
-- item entre outros dois só muda a posição DELE (a média das posições dos
-- vizinhos), então um arrasto é uma única alteração, de um único item.
-- =====================================================================

-- 1. A coluna. Começa vazia para podermos preencher abaixo.
alter table public.items
  add column if not exists position double precision;

-- 2. Os itens que já existem ficam na ordem em que foram criados (a ordem de
--    hoje), numerados 1, 2, 3... dentro de cada lista. Nada muda de lugar.
--    `row_number() over (partition by ...)` numera as linhas separadamente
--    para cada lista.
update public.items i
set position = r.rn
from (
  select id, row_number() over (partition by list_id order by created_at, id) as rn
  from public.items
) r
where r.id = i.id and i.position is null;

-- 3. Item inserido SEM posição (por um celular que ainda não atualizou o app)
--    vai para o fim da lista. Um trigger "before insert" ajusta a linha antes
--    de ela ser gravada.
create or replace function public.items_default_position()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if new.position is null then
    select coalesce(max(position), 0) + 1
      into new.position
    from public.items
    where list_id = new.list_id;
  end if;
  return new;
end;
$$;

drop trigger if exists items_default_position on public.items;
create trigger items_default_position
  before insert on public.items
  for each row execute function public.items_default_position();

-- 4. Agora toda linha tem posição: a coluna passa a ser obrigatória.
alter table public.items
  alter column position set not null;

-- 5. Ler os itens de uma lista em ordem fica rápido.
create index if not exists items_list_position_idx
  on public.items (list_id, position);

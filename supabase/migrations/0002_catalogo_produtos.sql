-- =====================================================================
-- Catálogo de produtos: nomes únicos sem diferenciar maiúsculas, e
-- produtos apagados deixam de ocupar o nome.
--
-- Como usar: cole este arquivo inteiro no SQL Editor do Supabase e clique
-- em "Run". Rode ANTES de instalar a versão nova do app (o app antigo
-- continua funcionando normalmente depois desta migração).
--
-- Por que:
--   * A regra antiga `unique (owner_id, name)` diferenciava maiúsculas
--     ("Arroz" e "arroz" podiam coexistir), mas o app trata como o mesmo
--     produto.
--   * Ela também contava os produtos apagados (exclusão suave): apagar
--     "Arroz" e cadastrar "Arroz" de novo seria recusado pelo servidor.
--
-- O que muda: no lugar da regra, um ÍNDICE ÚNICO PARCIAL. "Parcial" quer
-- dizer que ele só vale para as linhas que satisfazem a condição do
-- `where`, aqui, os produtos que não foram apagados.
-- =====================================================================

-- Se já existirem produtos ativos repetidos (ignorando maiúsculas), o índice
-- não poderia ser criado. Em vez de falhar com uma mensagem obscura, paramos
-- aqui e mostramos quais são. Nada é alterado nesse caso.
do $$
declare
  v_duplicados text;
begin
  select string_agg(format('%s (%s vezes)', nome, qtd), ', ')
    into v_duplicados
  from (
    select min(name) as nome, count(*) as qtd
    from public.products
    where deleted_at is null
    group by owner_id, lower(name)
    having count(*) > 1
  ) d;

  if v_duplicados is not null then
    raise exception 'Há produtos repetidos no catálogo: %. Apague os repetidos (ou marque deleted_at) e rode de novo.', v_duplicados;
  end if;
end;
$$;

-- Remove a regra antiga (o nome padrão que o Postgres deu a ela).
alter table public.products
  drop constraint if exists products_owner_id_name_key;

-- Nova regra: no máximo um produto ATIVO por nome (ignorando maiúsculas) por dono.
create unique index if not exists products_owner_name_active_idx
  on public.products (owner_id, lower(name))
  where deleted_at is null;
